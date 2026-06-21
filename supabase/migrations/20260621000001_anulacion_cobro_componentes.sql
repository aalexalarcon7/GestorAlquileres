-- ═══════════════════════════════════════════════════════════════════════════
-- ANULACIÓN DE COBROS POR COMPONENTES
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Fecha: 2026-06-21
--
-- PARTE A: Columnas nuevas para soft-delete en 3 tablas (no destructivo)
-- PARTE B: RPC anular_cobro_por_componentes
--
-- Objetivo: revertir un cobro registrado con registrar_cobro_por_componentes
-- sin borrar físicamente datos. Soft-delete en pagos + recibos + aplicaciones.
-- Reversión de cuotas usando las aplicaciones reales como fuente.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── PARTE A: ALTER TABLE (7 columnas nuevas, todas NULL por defecto) ──────

-- pagos: soft-delete + estado de anulación
ALTER TABLE pagos ADD COLUMN IF NOT EXISTS deleted_at        timestamptz;
ALTER TABLE pagos ADD COLUMN IF NOT EXISTS estado            text;
ALTER TABLE pagos ADD COLUMN IF NOT EXISTS motivo_anulacion  text;

-- recibos_historicos_operativos: ídem
ALTER TABLE recibos_historicos_operativos ADD COLUMN IF NOT EXISTS deleted_at        timestamptz;
ALTER TABLE recibos_historicos_operativos ADD COLUMN IF NOT EXISTS estado            text;
ALTER TABLE recibos_historicos_operativos ADD COLUMN IF NOT EXISTS motivo_anulacion  text;

-- recibos_aplicaciones_operativas: ya tiene deleted_at, agrega razón
ALTER TABLE recibos_aplicaciones_operativas ADD COLUMN IF NOT EXISTS deleted_reason  text;


-- ─── PARTE B: RPC ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION anular_cobro_por_componentes(
  p_pago_id    bigint  DEFAULT NULL,
  p_recibo_id  bigint  DEFAULT NULL,
  p_motivo     text    DEFAULT NULL,
  p_usuario    text    DEFAULT 'sistema'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_pago            RECORD;
  v_recibo_hist     RECORD;
  v_pago_id_real    bigint;
  v_recibo_id_real  bigint;
  v_contrato_id     bigint;
  v_app             RECORD;
  v_cuota           RECORD;
  v_new_alq_pagado  numeric;
  v_new_alq_saldo   numeric;
  v_new_imp_pagado  numeric;
  v_new_imp_saldo   numeric;
  v_new_serv_pagado numeric;
  v_new_serv_saldo  numeric;
  v_new_monto_pago  numeric;
  v_new_saldo_total numeric;
  v_new_estado      text;
  v_cuotas_rev      jsonb    := '[]'::jsonb;
  v_apps_anuladas   integer  := 0;
  v_advertencias    jsonb    := '[]'::jsonb;
  v_antes           jsonb;
  v_despues         jsonb;
BEGIN

  -- ── PASO 0: Validaciones básicas ──────────────────────────────────────────
  IF p_pago_id IS NULL AND p_recibo_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','Se requiere p_pago_id o p_recibo_id','codigo','PARAM_ERROR');
  END IF;
  IF COALESCE(p_motivo,'') = '' THEN
    RETURN jsonb_build_object('ok',false,'error','El motivo de anulación es obligatorio','codigo','PARAM_ERROR');
  END IF;

  -- ── PASO 1: Cargar pago ────────────────────────────────────────────────────
  IF p_pago_id IS NOT NULL THEN
    SELECT * INTO v_pago FROM pagos WHERE id = p_pago_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok',false,'error','Pago no encontrado: '||p_pago_id,'codigo','NOT_FOUND');
    END IF;
    v_pago_id_real := p_pago_id;
    v_contrato_id  := v_pago.contrato_id;
  END IF;

  -- Cargar recibo histórico (parámetro directo, o derivado del pago)
  IF p_recibo_id IS NOT NULL THEN
    SELECT * INTO v_recibo_hist FROM recibos_historicos_operativos WHERE id = p_recibo_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok',false,'error','Recibo no encontrado: '||p_recibo_id,'codigo','NOT_FOUND');
    END IF;
    v_recibo_id_real := p_recibo_id;
    v_contrato_id    := COALESCE(v_contrato_id, v_recibo_hist.contrato_id);
    IF v_pago_id_real IS NULL AND v_recibo_hist.pago_id IS NOT NULL THEN
      v_pago_id_real := v_recibo_hist.pago_id;
      SELECT * INTO v_pago FROM pagos WHERE id = v_pago_id_real;
    END IF;
  ELSIF v_pago_id_real IS NOT NULL THEN
    SELECT * INTO v_recibo_hist FROM recibos_historicos_operativos
    WHERE pago_id = v_pago_id_real ORDER BY created_at DESC LIMIT 1;
    IF FOUND THEN v_recibo_id_real := v_recibo_hist.id; END IF;
  END IF;

  -- ── PASO 2: Guard — solo cobros de COBRO_COMPONENTES ──────────────────────
  IF v_pago.id IS NOT NULL AND COALESCE(v_pago.origen,'') != 'COBRO_COMPONENTES' THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','Este cobro no fue registrado por el sistema de componentes (origen: '||COALESCE(v_pago.origen,'desconocido')||'). Usar el flujo de anulación anterior.',
      'codigo','ORIGEN_INCORRECTO'
    );
  END IF;

  -- ── PASO 3: Guard — no anular dos veces ───────────────────────────────────
  IF v_pago.id IS NOT NULL AND (
    v_pago.deleted_at IS NOT NULL OR
    UPPER(COALESCE(v_pago.estado,'')) = 'ANULADO'
  ) THEN
    RETURN jsonb_build_object('ok',false,'error','Este cobro ya fue anulado anteriormente','codigo','YA_ANULADO');
  END IF;

  -- ── PASO 4–5: Verificar que hay aplicaciones activas ─────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM recibos_aplicaciones_operativas
    WHERE (pago_id = v_pago_id_real OR recibo_id = v_recibo_id_real)
      AND deleted_at IS NULL
  ) THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','No hay aplicaciones activas para este cobro. Puede que ya haya sido anulado.',
      'codigo','SIN_APLICACIONES'
    );
  END IF;

  -- ── PASO 6: Revertir cuota por cada aplicación activa ────────────────────
  FOR v_app IN
    SELECT * FROM recibos_aplicaciones_operativas
    WHERE (pago_id = v_pago_id_real OR recibo_id = v_recibo_id_real)
      AND deleted_at IS NULL
    ORDER BY anio, mes
  LOOP
    SELECT * INTO v_cuota FROM cuotas_operativas
    WHERE contrato_id = v_contrato_id AND anio = v_app.anio AND mes = v_app.mes
    FOR UPDATE;

    IF NOT FOUND THEN
      v_advertencias := v_advertencias || jsonb_build_array(
        jsonb_build_object('aviso','Cuota '||v_app.anio||'/'||v_app.mes||' no encontrada','app_id',v_app.id)
      );
      CONTINUE;
    END IF;

    IF v_cuota.monto_alquiler_total IS NULL THEN
      v_advertencias := v_advertencias || jsonb_build_array(
        jsonb_build_object('aviso','Cuota '||v_app.anio||'/'||v_app.mes||' sin datos de componentes — reversión solo en campos legacy','app_id',v_app.id)
      );
    END IF;

    -- Estado ANTES
    v_antes := jsonb_build_object(
      'monto_alquiler_pagado', COALESCE(v_cuota.monto_alquiler_pagado,0),
      'saldo_alquiler',        COALESCE(v_cuota.saldo_alquiler,0),
      'monto_impuesto_pagado', COALESCE(v_cuota.monto_impuesto_pagado,0),
      'saldo_impuesto',        COALESCE(v_cuota.saldo_impuesto,0),
      'monto_servicio_pagado', COALESCE(v_cuota.monto_servicio_pagado,0),
      'saldo_servicio',        COALESCE(v_cuota.saldo_servicio,0),
      'monto_pagado',          v_cuota.monto_pagado,
      'saldo',                 v_cuota.saldo,
      'estado',                v_cuota.estado
    );

    -- Calcular reversión (GREATEST 0 evita valores negativos)
    v_new_alq_pagado  := ROUND(GREATEST(0, COALESCE(v_cuota.monto_alquiler_pagado,0) - COALESCE(v_app.monto_alquiler,0)), 2);
    v_new_imp_pagado  := ROUND(GREATEST(0, COALESCE(v_cuota.monto_impuesto_pagado,0) - COALESCE(v_app.monto_impuesto,0)), 2);
    v_new_serv_pagado := ROUND(GREATEST(0, COALESCE(v_cuota.monto_servicio_pagado,0) - COALESCE(v_app.monto_servicio,0)), 2);
    v_new_alq_saldo   := ROUND(GREATEST(0, COALESCE(v_cuota.monto_alquiler_total, v_cuota.monto_total, 0) - v_new_alq_pagado), 2);
    v_new_imp_saldo   := ROUND(GREATEST(0, COALESCE(v_cuota.monto_impuesto_total,0) - v_new_imp_pagado), 2);
    v_new_serv_saldo  := ROUND(GREATEST(0, COALESCE(v_cuota.monto_servicio,0) - v_new_serv_pagado), 2);
    v_new_monto_pago  := ROUND(v_new_alq_pagado + v_new_imp_pagado + v_new_serv_pagado, 2);
    v_new_saldo_total := ROUND(v_new_alq_saldo + v_new_imp_saldo + v_new_serv_saldo, 2);
    v_new_estado      := CASE
      WHEN v_new_saldo_total <= 0.009 THEN 'PAGADO'
      WHEN v_new_monto_pago  >  0.009 THEN 'PARCIAL'
      ELSE 'PENDIENTE'
    END;

    -- Auditoría por cuota
    INSERT INTO auditoria_operativa
      (usuario,accion,tabla_afectada,registro_id,contrato_id,anio,mes,campo,valor_anterior,valor_nuevo,motivo,recibo_ref)
    VALUES (
      p_usuario,'ANULAR_COBRO_COMPONENTES','cuotas_operativas',
      v_cuota.id, v_contrato_id, v_app.anio, v_app.mes,
      'alq_pagado|imp_pagado|serv_pagado|saldo|estado',
      'alq_pag:'||COALESCE(v_cuota.monto_alquiler_pagado,0)||
        ' imp_pag:'||COALESCE(v_cuota.monto_impuesto_pagado,0)||
        ' serv_pag:'||COALESCE(v_cuota.monto_servicio_pagado,0)||
        ' saldo:'||v_cuota.saldo||' estado:'||v_cuota.estado,
      'alq_pag:'||v_new_alq_pagado||
        ' imp_pag:'||v_new_imp_pagado||
        ' serv_pag:'||v_new_serv_pagado||
        ' saldo:'||v_new_saldo_total||' estado:'||v_new_estado,
      p_motivo,
      'pago_id:'||COALESCE(v_pago_id_real::text,'?')
    );

    -- UPDATE cuota
    UPDATE cuotas_operativas SET
      monto_alquiler_pagado = v_new_alq_pagado,
      saldo_alquiler        = v_new_alq_saldo,
      monto_impuesto_pagado = v_new_imp_pagado,
      saldo_impuesto        = v_new_imp_saldo,
      monto_servicio_pagado = v_new_serv_pagado,
      saldo_servicio        = v_new_serv_saldo,
      monto_pagado          = v_new_monto_pago,
      saldo                 = v_new_saldo_total,
      estado                = v_new_estado,
      updated_at            = NOW()
    WHERE contrato_id = v_contrato_id AND anio = v_app.anio AND mes = v_app.mes;

    -- Estado DESPUÉS
    v_despues := jsonb_build_object(
      'monto_alquiler_pagado', v_new_alq_pagado,
      'saldo_alquiler',        v_new_alq_saldo,
      'monto_impuesto_pagado', v_new_imp_pagado,
      'saldo_impuesto',        v_new_imp_saldo,
      'monto_servicio_pagado', v_new_serv_pagado,
      'saldo_servicio',        v_new_serv_saldo,
      'monto_pagado',          v_new_monto_pago,
      'saldo',                 v_new_saldo_total,
      'estado',                v_new_estado
    );

    v_cuotas_rev := v_cuotas_rev || jsonb_build_array(jsonb_build_object(
      'cuota_id', v_cuota.id, 'anio', v_app.anio, 'mes', v_app.mes,
      'aplicacion_revertida', jsonb_build_object(
        'monto_alquiler', v_app.monto_alquiler,
        'monto_impuesto', v_app.monto_impuesto,
        'monto_servicio', v_app.monto_servicio
      ),
      'antes', v_antes, 'despues', v_despues
    ));
  END LOOP;

  -- ── PASO 7: Soft-delete aplicaciones activas ──────────────────────────────
  UPDATE recibos_aplicaciones_operativas SET
    deleted_at     = NOW(),
    deleted_reason = p_motivo
  WHERE (pago_id = v_pago_id_real OR recibo_id = v_recibo_id_real)
    AND deleted_at IS NULL;
  GET DIAGNOSTICS v_apps_anuladas = ROW_COUNT;

  -- ── PASO 8: Soft-delete pago ──────────────────────────────────────────────
  IF v_pago_id_real IS NOT NULL THEN
    UPDATE pagos SET
      deleted_at       = NOW(),
      estado           = 'ANULADO',
      motivo_anulacion = p_motivo,
      updated_at       = NOW()
    WHERE id = v_pago_id_real;
  END IF;

  -- ── PASO 9: Soft-delete recibo histórico ──────────────────────────────────
  UPDATE recibos_historicos_operativos SET
    deleted_at       = NOW(),
    estado           = 'ANULADO',
    motivo_anulacion = p_motivo,
    updated_at       = NOW()
  WHERE id = v_recibo_id_real
     OR (v_recibo_id_real IS NULL AND pago_id = v_pago_id_real);

  -- ── PASO 10: Auditoría del pago anulado ───────────────────────────────────
  INSERT INTO auditoria_operativa
    (usuario,accion,tabla_afectada,registro_id,contrato_id,anio,mes,campo,valor_anterior,valor_nuevo,motivo)
  VALUES (
    p_usuario,'ANULAR_COBRO_COMPONENTES','pagos',
    v_pago_id_real, v_contrato_id,
    COALESCE(v_pago.anio_aplicado,0), COALESCE(v_pago.mes_aplicado,0),
    'deleted_at|estado',
    'deleted_at:NULL estado:'||COALESCE(v_pago.estado,'ACTIVO'),
    'deleted_at:now() estado:ANULADO',
    p_motivo
  );

  -- ── Retorno ───────────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'ok',                    true,
    'pago_id',               v_pago_id_real,
    'recibo_id',             v_recibo_id_real,
    'contrato_id',           v_contrato_id,
    'aplicaciones_anuladas', v_apps_anuladas,
    'cuotas_revertidas',     v_cuotas_rev,
    'advertencias',          v_advertencias,
    'mensaje',              'Cobro anulado correctamente. '||v_apps_anuladas||' aplicación(es) revertida(s).'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok',false,'error',SQLERRM,'codigo','INTERNAL_ERROR');
END;
$func$;

REVOKE ALL ON FUNCTION anular_cobro_por_componentes FROM PUBLIC;
GRANT EXECUTE ON FUNCTION anular_cobro_por_componentes TO authenticated;

COMMENT ON FUNCTION anular_cobro_por_componentes IS
  'Anula un cobro registrado por registrar_cobro_por_componentes. Soft-delete en pagos/recibos/aplicaciones + reversión de cuotas. Solo para origen=COBRO_COMPONENTES.';
