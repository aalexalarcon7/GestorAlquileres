-- ═══════════════════════════════════════════════════════════════════════════
-- ETAPA 7A: RPC editar_cuota_componentes_manual
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Creada: 2026-06-23
--
-- PROPÓSITO:
-- Permitir la edición manual y auditada de los componentes de una cuota
-- específica (alquiler / impuesto / servicio), con modo dry_run.
--
-- GARANTÍAS:
-- • p_dry_run = true  → SOLO validación + vista previa. NINGÚN UPDATE ni INSERT.
-- • p_dry_run = false → UPDATE cuotas_operativas + INSERT auditoria_operativa.
-- • No toca pagos, recibos, recibos_historicos_operativos ni recibos_aplicaciones_operativas.
-- • p_motivo y p_usuario son OBLIGATORIOS (error si vacíos).
-- • La cuota debe existir y coincidir exactamente en id, contrato_id, anio y mes.
-- • Ningún monto pagado puede superar su monto total.
-- • Ningún monto puede ser negativo.
-- • Si impuesto_total es NULL o 0 → impuesto_pagado debe ser 0.
-- • Si servicio_total es NULL o 0 → servicio_pagado debe ser 0.
--
-- COLUMNA EN BD: monto_servicio = total del servicio del mes.
--   p_monto_servicio_total del parámetro mapea a la columna monto_servicio.
--
-- NO CONECTAR AL FRONTEND HASTA ETAPA 7B (modal visual).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION editar_cuota_componentes_manual(
  p_cuota_id              bigint,
  p_contrato_id           bigint,
  p_anio                  integer,
  p_mes                   integer,
  p_monto_alquiler_total  numeric,
  p_monto_alquiler_pagado numeric,
  p_monto_impuesto_total  numeric,    -- NULL = este mes no lleva impuesto
  p_monto_impuesto_pagado numeric,
  p_monto_servicio_total  numeric,    -- mapea a cuotas_operativas.monto_servicio
  p_monto_servicio_pagado numeric,
  p_motivo                text,
  p_usuario               text,
  p_dry_run               boolean     DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_cuota          RECORD;
  v_saldo_alquiler numeric;
  v_saldo_impuesto numeric;
  v_saldo_servicio numeric;
  v_monto_total    numeric;
  v_monto_pagado   numeric;
  v_saldo_total    numeric;
  v_estado         text;
  v_antes          jsonb;
  v_despues        jsonb;
  v_diferencias    jsonb;
BEGIN

-- ─── PASO 0: Parámetros obligatorios ─────────────────────────────────────

  IF COALESCE(TRIM(p_motivo), '') = '' THEN
    RETURN jsonb_build_object('ok',false,'error','p_motivo es obligatorio','codigo','MOTIVO_VACIO');
  END IF;
  IF COALESCE(TRIM(p_usuario), '') = '' THEN
    RETURN jsonb_build_object('ok',false,'error','p_usuario es obligatorio','codigo','USUARIO_VACIO');
  END IF;
  IF p_cuota_id IS NULL OR p_cuota_id <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','p_cuota_id es obligatorio y debe ser mayor a 0','codigo','PARAM_ERROR');
  END IF;
  IF p_contrato_id IS NULL OR p_contrato_id <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','p_contrato_id es obligatorio y debe ser mayor a 0','codigo','PARAM_ERROR');
  END IF;
  IF p_anio IS NULL OR p_mes IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','p_anio y p_mes son obligatorios','codigo','PARAM_ERROR');
  END IF;
  IF p_monto_alquiler_total IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','p_monto_alquiler_total es obligatorio','codigo','PARAM_ERROR');
  END IF;

-- ─── PASO 1: Cargar cuota y verificar coincidencia exacta ─────────────────

  SELECT * INTO v_cuota
  FROM cuotas_operativas
  WHERE id = p_cuota_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','Cuota no encontrada con id='||p_cuota_id,
      'codigo','CUOTA_NOT_FOUND'
    );
  END IF;

  IF v_cuota.contrato_id <> p_contrato_id THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','La cuota '||p_cuota_id||' pertenece al contrato '||v_cuota.contrato_id||
              ', no a '||p_contrato_id||'. Verificar cuota_id.',
      'codigo','CONTRATO_MISMATCH'
    );
  END IF;

  IF v_cuota.anio <> p_anio OR v_cuota.mes <> p_mes THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','La cuota '||p_cuota_id||' corresponde a '||v_cuota.anio||'/'||
              LPAD(v_cuota.mes::text,2,'0')||', no a '||p_anio||'/'||LPAD(p_mes::text,2,'0')||
              '. Verificar cuota_id.',
      'codigo','PERIODO_MISMATCH'
    );
  END IF;

-- ─── PASO 2: Validaciones de montos ───────────────────────────────────────

  -- Sin negativos
  IF p_monto_alquiler_total < 0 THEN
    RETURN jsonb_build_object('ok',false,'error','p_monto_alquiler_total no puede ser negativo','codigo','MONTO_NEGATIVO');
  END IF;
  IF COALESCE(p_monto_alquiler_pagado, 0) < 0 THEN
    RETURN jsonb_build_object('ok',false,'error','p_monto_alquiler_pagado no puede ser negativo','codigo','MONTO_NEGATIVO');
  END IF;
  IF COALESCE(p_monto_impuesto_total, 0) < 0 THEN
    RETURN jsonb_build_object('ok',false,'error','p_monto_impuesto_total no puede ser negativo','codigo','MONTO_NEGATIVO');
  END IF;
  IF COALESCE(p_monto_impuesto_pagado, 0) < 0 THEN
    RETURN jsonb_build_object('ok',false,'error','p_monto_impuesto_pagado no puede ser negativo','codigo','MONTO_NEGATIVO');
  END IF;
  IF COALESCE(p_monto_servicio_total, 0) < 0 THEN
    RETURN jsonb_build_object('ok',false,'error','p_monto_servicio_total no puede ser negativo','codigo','MONTO_NEGATIVO');
  END IF;
  IF COALESCE(p_monto_servicio_pagado, 0) < 0 THEN
    RETURN jsonb_build_object('ok',false,'error','p_monto_servicio_pagado no puede ser negativo','codigo','MONTO_NEGATIVO');
  END IF;

  -- pagado no puede superar total
  IF COALESCE(p_monto_alquiler_pagado, 0) > p_monto_alquiler_total + 0.009 THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','p_monto_alquiler_pagado ('||COALESCE(p_monto_alquiler_pagado,0)||
              ') supera p_monto_alquiler_total ('||p_monto_alquiler_total||')',
      'codigo','PAGADO_EXCEDE_TOTAL'
    );
  END IF;

  -- Impuesto: si total es NULL o 0, pagado debe ser 0
  IF COALESCE(p_monto_impuesto_total, 0) = 0 AND COALESCE(p_monto_impuesto_pagado, 0) > 0 THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','p_monto_impuesto_pagado debe ser 0 cuando p_monto_impuesto_total es NULL o 0',
      'codigo','IMPUESTO_PAGADO_SIN_TOTAL'
    );
  END IF;
  IF COALESCE(p_monto_impuesto_pagado, 0) > COALESCE(p_monto_impuesto_total, 0) + 0.009 THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','p_monto_impuesto_pagado ('||COALESCE(p_monto_impuesto_pagado,0)||
              ') supera p_monto_impuesto_total ('||COALESCE(p_monto_impuesto_total,0)||')',
      'codigo','PAGADO_EXCEDE_TOTAL'
    );
  END IF;

  -- Servicio: si total es NULL o 0, pagado debe ser 0
  IF COALESCE(p_monto_servicio_total, 0) = 0 AND COALESCE(p_monto_servicio_pagado, 0) > 0 THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','p_monto_servicio_pagado debe ser 0 cuando p_monto_servicio_total es NULL o 0',
      'codigo','SERVICIO_PAGADO_SIN_TOTAL'
    );
  END IF;
  IF COALESCE(p_monto_servicio_pagado, 0) > COALESCE(p_monto_servicio_total, 0) + 0.009 THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','p_monto_servicio_pagado ('||COALESCE(p_monto_servicio_pagado,0)||
              ') supera p_monto_servicio_total ('||COALESCE(p_monto_servicio_total,0)||')',
      'codigo','PAGADO_EXCEDE_TOTAL'
    );
  END IF;

-- ─── PASO 3: Calcular saldos y estado nuevo ───────────────────────────────

  v_saldo_alquiler := ROUND(GREATEST(0, p_monto_alquiler_total         - COALESCE(p_monto_alquiler_pagado, 0)), 2);
  v_saldo_impuesto := ROUND(GREATEST(0, COALESCE(p_monto_impuesto_total, 0) - COALESCE(p_monto_impuesto_pagado, 0)), 2);
  v_saldo_servicio := ROUND(GREATEST(0, COALESCE(p_monto_servicio_total, 0) - COALESCE(p_monto_servicio_pagado, 0)), 2);

  v_monto_total  := ROUND(p_monto_alquiler_total
                        + COALESCE(p_monto_impuesto_total, 0)
                        + COALESCE(p_monto_servicio_total, 0), 2);
  v_monto_pagado := ROUND(COALESCE(p_monto_alquiler_pagado, 0)
                        + COALESCE(p_monto_impuesto_pagado, 0)
                        + COALESCE(p_monto_servicio_pagado, 0), 2);
  v_saldo_total  := ROUND(v_saldo_alquiler + v_saldo_impuesto + v_saldo_servicio, 2);

  v_estado := CASE
    WHEN v_saldo_total  <= 0.009 THEN 'PAGADO'
    WHEN v_monto_pagado >  0.009 THEN 'PARCIAL'
    ELSE 'PENDIENTE'
  END;

-- ─── PASO 4: Construir snapshots antes / despues / diferencias ────────────

  v_antes := jsonb_build_object(
    'monto_alquiler_total',  v_cuota.monto_alquiler_total,
    'monto_alquiler_pagado', COALESCE(v_cuota.monto_alquiler_pagado, 0),
    'saldo_alquiler',        COALESCE(v_cuota.saldo_alquiler, 0),
    'monto_impuesto_total',  v_cuota.monto_impuesto_total,
    'monto_impuesto_pagado', COALESCE(v_cuota.monto_impuesto_pagado, 0),
    'saldo_impuesto',        COALESCE(v_cuota.saldo_impuesto, 0),
    'monto_servicio_total',  v_cuota.monto_servicio,
    'monto_servicio_pagado', COALESCE(v_cuota.monto_servicio_pagado, 0),
    'saldo_servicio',        COALESCE(v_cuota.saldo_servicio, 0),
    'monto_total',           COALESCE(v_cuota.monto_total, 0),
    'monto_pagado',          COALESCE(v_cuota.monto_pagado, 0),
    'saldo',                 COALESCE(v_cuota.saldo, 0),
    'estado',                v_cuota.estado
  );

  v_despues := jsonb_build_object(
    'monto_alquiler_total',  p_monto_alquiler_total,
    'monto_alquiler_pagado', COALESCE(p_monto_alquiler_pagado, 0),
    'saldo_alquiler',        v_saldo_alquiler,
    'monto_impuesto_total',  p_monto_impuesto_total,
    'monto_impuesto_pagado', COALESCE(p_monto_impuesto_pagado, 0),
    'saldo_impuesto',        v_saldo_impuesto,
    'monto_servicio_total',  p_monto_servicio_total,
    'monto_servicio_pagado', COALESCE(p_monto_servicio_pagado, 0),
    'saldo_servicio',        v_saldo_servicio,
    'monto_total',           v_monto_total,
    'monto_pagado',          v_monto_pagado,
    'saldo',                 v_saldo_total,
    'estado',                v_estado
  );

  -- Diferencias: solo campos con valores distintos (NULL-safe con IS DISTINCT FROM)
  v_diferencias := '{}'::jsonb;

  IF v_cuota.monto_alquiler_total IS DISTINCT FROM p_monto_alquiler_total THEN
    v_diferencias := v_diferencias || jsonb_build_object('monto_alquiler_total',
      jsonb_build_object('antes', v_cuota.monto_alquiler_total, 'despues', p_monto_alquiler_total));
  END IF;
  IF COALESCE(v_cuota.monto_alquiler_pagado, 0) IS DISTINCT FROM COALESCE(p_monto_alquiler_pagado, 0) THEN
    v_diferencias := v_diferencias || jsonb_build_object('monto_alquiler_pagado',
      jsonb_build_object('antes', COALESCE(v_cuota.monto_alquiler_pagado,0), 'despues', COALESCE(p_monto_alquiler_pagado,0)));
  END IF;
  IF v_cuota.monto_impuesto_total IS DISTINCT FROM p_monto_impuesto_total THEN
    v_diferencias := v_diferencias || jsonb_build_object('monto_impuesto_total',
      jsonb_build_object('antes', v_cuota.monto_impuesto_total, 'despues', p_monto_impuesto_total));
  END IF;
  IF COALESCE(v_cuota.monto_impuesto_pagado, 0) IS DISTINCT FROM COALESCE(p_monto_impuesto_pagado, 0) THEN
    v_diferencias := v_diferencias || jsonb_build_object('monto_impuesto_pagado',
      jsonb_build_object('antes', COALESCE(v_cuota.monto_impuesto_pagado,0), 'despues', COALESCE(p_monto_impuesto_pagado,0)));
  END IF;
  IF v_cuota.monto_servicio IS DISTINCT FROM p_monto_servicio_total THEN
    v_diferencias := v_diferencias || jsonb_build_object('monto_servicio_total',
      jsonb_build_object('antes', v_cuota.monto_servicio, 'despues', p_monto_servicio_total));
  END IF;
  IF COALESCE(v_cuota.monto_servicio_pagado, 0) IS DISTINCT FROM COALESCE(p_monto_servicio_pagado, 0) THEN
    v_diferencias := v_diferencias || jsonb_build_object('monto_servicio_pagado',
      jsonb_build_object('antes', COALESCE(v_cuota.monto_servicio_pagado,0), 'despues', COALESCE(p_monto_servicio_pagado,0)));
  END IF;
  IF v_cuota.estado IS DISTINCT FROM v_estado THEN
    v_diferencias := v_diferencias || jsonb_build_object('estado',
      jsonb_build_object('antes', v_cuota.estado, 'despues', v_estado));
  END IF;

-- ─── PASO 5: DRY_RUN — retornar simulación sin persistir NADA ────────────
-- Todas las validaciones pasaron. Si dry_run=true la función termina aquí.
-- Ningún UPDATE ni INSERT fue ejecutado hasta este punto.

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'ok',              true,
      'dry_run',         true,
      'cuota_id',        p_cuota_id,
      'contrato_id',     p_contrato_id,
      'anio',            p_anio,
      'mes',             p_mes,
      'antes',           v_antes,
      'despues',         v_despues,
      'diferencias',     v_diferencias,
      'estado_anterior', v_cuota.estado,
      'estado_nuevo',    v_estado,
      'mensaje',         'Simulacion completada. Ningun dato fue modificado.'
    );
  END IF;

-- ─── PASO 6: UPDATE real en cuotas_operativas ─────────────────────────────
-- Solo se llega aquí si p_dry_run = false.

  UPDATE cuotas_operativas SET
    -- Columnas nuevas (componentes)
    monto_alquiler_total  = p_monto_alquiler_total,
    monto_alquiler_pagado = COALESCE(p_monto_alquiler_pagado, 0),
    saldo_alquiler        = v_saldo_alquiler,
    monto_impuesto_total  = p_monto_impuesto_total,       -- NULL si el mes no lleva impuesto
    monto_impuesto_pagado = COALESCE(p_monto_impuesto_pagado, 0),
    saldo_impuesto        = v_saldo_impuesto,
    monto_servicio        = p_monto_servicio_total,       -- columna legacy de servicio total
    monto_servicio_pagado = COALESCE(p_monto_servicio_pagado, 0),
    saldo_servicio        = v_saldo_servicio,
    -- Columnas legacy de compatibilidad
    monto_total           = v_monto_total,
    monto_pagado          = v_monto_pagado,
    saldo                 = v_saldo_total,
    estado                = v_estado,
    updated_at            = NOW()
  WHERE id = p_cuota_id;

-- ─── PASO 7: INSERT en auditoria_operativa ────────────────────────────────

  INSERT INTO auditoria_operativa (
    usuario,
    accion,
    tabla_afectada,
    registro_id,
    contrato_id,
    anio,
    mes,
    campo,
    valor_anterior,
    valor_nuevo,
    motivo
  ) VALUES (
    p_usuario,
    'EDITAR_CUOTA_COMPONENTES_MANUAL',
    'cuotas_operativas',
    p_cuota_id,
    p_contrato_id,
    p_anio,
    p_mes,
    'componentes_cuota_manual',
    v_antes::text,
    v_despues::text,
    p_motivo
  );

-- ─── Retorno (dry_run=false) ───────────────────────────────────────────────

  RETURN jsonb_build_object(
    'ok',              true,
    'dry_run',         false,
    'cuota_id',        p_cuota_id,
    'contrato_id',     p_contrato_id,
    'anio',            p_anio,
    'mes',             p_mes,
    'antes',           v_antes,
    'despues',         v_despues,
    'diferencias',     v_diferencias,
    'estado_anterior', v_cuota.estado,
    'estado_nuevo',    v_estado,
    'mensaje',         'Cuota editada correctamente. Cambios persistidos y auditados.'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok',false,'error',SQLERRM,'codigo','INTERNAL_ERROR');

END;
$func$;

REVOKE ALL ON FUNCTION editar_cuota_componentes_manual FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editar_cuota_componentes_manual TO authenticated;

COMMENT ON FUNCTION editar_cuota_componentes_manual IS
  'Etapa 7A - Edicion manual auditada de componentes de cuota (alquiler/impuesto/servicio). p_dry_run=true simula sin persistir. NO conectar al frontend hasta Etapa 7B.';


-- ═══════════════════════════════════════════════════════════════════════════
-- VALIDACIONES MANUALES — ejecutar ANTES de aprobar ejecución real
-- Paso 1: obtener cuota_id de Melgarejo 05/2026
-- ═══════════════════════════════════════════════════════════════════════════

-- PASO A: Localizar cuota_id de Melgarejo (contrato_id de MELGAREJO LORENA / PTO114)
-- SELECT co.id, co.contrato_id, co.anio, co.mes, co.estado,
--        co.monto_alquiler_total, co.monto_alquiler_pagado, co.saldo_alquiler,
--        co.monto_impuesto_total, co.monto_impuesto_pagado, co.saldo_impuesto,
--        co.monto_servicio, co.monto_servicio_pagado, co.saldo_servicio,
--        co.monto_total, co.monto_pagado, co.saldo
-- FROM cuotas_operativas co
-- JOIN contratos c ON c.id = co.contrato_id
-- JOIN inquilinos i ON i.id = c.inquilino_id
-- WHERE i.nombre ILIKE '%melgarejo%'
--   AND co.anio = 2026 AND co.mes = 5;

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 1: dry_run válido sobre Melgarejo 05/2026 (NO persiste)
-- Reemplazar <cuota_id> y <contrato_id> con los valores del PASO A.
-- Esperado: ok=true, dry_run=true, antes con saldo_alquiler=16350, mensaje simulacion
-- ─────────────────────────────────────────────────────────────────────────
-- SELECT editar_cuota_componentes_manual(
--   p_cuota_id              => <cuota_id>,
--   p_contrato_id           => <contrato_id>,
--   p_anio                  => 2026,
--   p_mes                   => 5,
--   p_monto_alquiler_total  => 436349,
--   p_monto_alquiler_pagado => 419999,    -- lo que ya está pagado
--   p_monto_impuesto_total  => 0,
--   p_monto_impuesto_pagado => 0,
--   p_monto_servicio_total  => NULL,
--   p_monto_servicio_pagado => 0,
--   p_motivo                => 'TEST dry_run etapa 7A — sin persistencia',
--   p_usuario               => 'test@gestor',
--   p_dry_run               => true
-- );

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 2: motivo vacío → debe fallar con MOTIVO_VACIO
-- ─────────────────────────────────────────────────────────────────────────
-- SELECT editar_cuota_componentes_manual(
--   p_cuota_id=>1, p_contrato_id=>1, p_anio=>2026, p_mes=>5,
--   p_monto_alquiler_total=>100000, p_monto_alquiler_pagado=>0,
--   p_monto_impuesto_total=>NULL,   p_monto_impuesto_pagado=>0,
--   p_monto_servicio_total=>NULL,   p_monto_servicio_pagado=>0,
--   p_motivo=>'', p_usuario=>'test@gestor', p_dry_run=>true
-- );

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 3: usuario vacío → debe fallar con USUARIO_VACIO
-- ─────────────────────────────────────────────────────────────────────────
-- SELECT editar_cuota_componentes_manual(
--   p_cuota_id=>1, p_contrato_id=>1, p_anio=>2026, p_mes=>5,
--   p_monto_alquiler_total=>100000, p_monto_alquiler_pagado=>0,
--   p_monto_impuesto_total=>NULL,   p_monto_impuesto_pagado=>0,
--   p_monto_servicio_total=>NULL,   p_monto_servicio_pagado=>0,
--   p_motivo=>'motivo valido', p_usuario=>'', p_dry_run=>true
-- );

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 4: alquiler_pagado > alquiler_total → debe fallar con PAGADO_EXCEDE_TOTAL
-- ─────────────────────────────────────────────────────────────────────────
-- SELECT editar_cuota_componentes_manual(
--   p_cuota_id=><cuota_id>, p_contrato_id=><contrato_id>, p_anio=>2026, p_mes=>5,
--   p_monto_alquiler_total=>100000, p_monto_alquiler_pagado=>100001,
--   p_monto_impuesto_total=>NULL,   p_monto_impuesto_pagado=>0,
--   p_monto_servicio_total=>NULL,   p_monto_servicio_pagado=>0,
--   p_motivo=>'test exceso', p_usuario=>'test@gestor', p_dry_run=>true
-- );

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 5: monto negativo → debe fallar con MONTO_NEGATIVO
-- ─────────────────────────────────────────────────────────────────────────
-- SELECT editar_cuota_componentes_manual(
--   p_cuota_id=><cuota_id>, p_contrato_id=><contrato_id>, p_anio=>2026, p_mes=>5,
--   p_monto_alquiler_total=>-100, p_monto_alquiler_pagado=>0,
--   p_monto_impuesto_total=>NULL,  p_monto_impuesto_pagado=>0,
--   p_monto_servicio_total=>NULL,  p_monto_servicio_pagado=>0,
--   p_motivo=>'test negativo', p_usuario=>'test@gestor', p_dry_run=>true
-- );

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 6: cuota_id incorrecto → debe fallar con CUOTA_NOT_FOUND
-- ─────────────────────────────────────────────────────────────────────────
-- SELECT editar_cuota_componentes_manual(
--   p_cuota_id=>999999999, p_contrato_id=>1, p_anio=>2026, p_mes=>5,
--   p_monto_alquiler_total=>100000, p_monto_alquiler_pagado=>0,
--   p_monto_impuesto_total=>NULL,   p_monto_impuesto_pagado=>0,
--   p_monto_servicio_total=>NULL,   p_monto_servicio_pagado=>0,
--   p_motivo=>'test not found', p_usuario=>'test@gestor', p_dry_run=>true
-- );

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 7: contrato_id/anio/mes que no coinciden → debe fallar con CONTRATO_MISMATCH
-- Usar cuota_id real pero contrato_id de otro contrato
-- ─────────────────────────────────────────────────────────────────────────
-- SELECT editar_cuota_componentes_manual(
--   p_cuota_id=><cuota_id_melgarejo>, p_contrato_id=>99999, p_anio=>2026, p_mes=>5,
--   p_monto_alquiler_total=>436349, p_monto_alquiler_pagado=>419999,
--   p_monto_impuesto_total=>NULL,   p_monto_impuesto_pagado=>0,
--   p_monto_servicio_total=>NULL,   p_monto_servicio_pagado=>0,
--   p_motivo=>'test mismatch', p_usuario=>'test@gestor', p_dry_run=>true
-- );

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 8: confirmar que dry_run=true NO modifica cuotas_operativas
-- Ejecutar TEST 1, luego verificar que los datos no cambiaron:
-- SELECT id, estado, saldo_alquiler, saldo_impuesto, saldo_servicio, saldo, updated_at
-- FROM cuotas_operativas WHERE id = <cuota_id>;
-- ─────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 9: confirmar que dry_run=true NO inserta en auditoria_operativa
-- SELECT * FROM auditoria_operativa
-- WHERE accion = 'EDITAR_CUOTA_COMPONENTES_MANUAL'
-- ORDER BY created_at DESC LIMIT 5;
-- Resultado esperado: 0 filas (si nunca se ejecutó con dry_run=false)
-- ─────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────
-- TEST 10: TEST impuesto_pagado>0 sin total → debe fallar con IMPUESTO_PAGADO_SIN_TOTAL
-- ─────────────────────────────────────────────────────────────────────────
-- SELECT editar_cuota_componentes_manual(
--   p_cuota_id=><cuota_id>, p_contrato_id=><contrato_id>, p_anio=>2026, p_mes=>5,
--   p_monto_alquiler_total=>436349, p_monto_alquiler_pagado=>0,
--   p_monto_impuesto_total=>NULL,   p_monto_impuesto_pagado=>5000,
--   p_monto_servicio_total=>NULL,   p_monto_servicio_pagado=>0,
--   p_motivo=>'test imp sin total', p_usuario=>'test@gestor', p_dry_run=>true
-- );

-- ─────────────────────────────────────────────────────────────────────────
-- EJECUCIÓN REAL: NO ejecutar todavía. Solo con aprobación explícita.
-- Cuando se apruebe, cambiar p_dry_run => false y ejecutar.
-- Antes verificar: ¿los datos del PASO A coinciden con lo esperado?
-- ─────────────────────────────────────────────────────────────────────────
