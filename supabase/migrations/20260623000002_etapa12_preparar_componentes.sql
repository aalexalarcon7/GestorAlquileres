-- ═══════════════════════════════════════════════════════════════════════════
-- ETAPA 12: RPC preparar_componentes_contrato
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Creada: 2026-06-23
--
-- PROPÓSITO:
-- Poblar columnas de componentes (alquiler/impuesto/servicio) en cuotas
-- que todavía están en modo legacy (monto_alquiler_total IS NULL).
-- Solo actualiza cuotas clasificadas como PREPARABLE.
-- Cuotas REQUIERE_REVISION se informan pero no se tocan.
--
-- GARANTÍAS:
-- • p_dry_run = true  → SOLO diagnóstico. NINGÚN UPDATE ni INSERT.
-- • p_dry_run = false → UPDATE cuotas PREPARABLE + INSERT auditoria.
-- • No toca pagos, recibos, aplicaciones ni recibos_historicos.
-- • No inventa impuestos (monto_impuesto_total = NULL = sin impuesto).
-- • No inventa servicios (solo si servicios_habilitados=true).
-- • Alquiler pagado: prioriza aplicaciones reales; fallback monto_pagado.
-- • p_motivo y p_usuario son OBLIGATORIOS para ejecución real.
--
-- CLASIFICACIÓN DE CADA CUOTA:
-- • LISTA              → ya tiene componentes completos, no se toca.
-- • INCOMPLETA         → tiene algunos campos nuevos pero no todos.
-- • PREPARABLE         → legacy, puede migrarse con seguridad.
-- • REQUIERE_REVISION  → legacy pero con datos ambiguos/problemáticos.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION preparar_componentes_contrato(
  p_contrato_id  bigint  DEFAULT NULL,    -- NULL = todos los contratos activos
  p_usuario      text    DEFAULT 'sistema',
  p_motivo       text    DEFAULT NULL,
  p_dry_run      boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_cuota             RECORD;
  v_apps              RECORD;
  v_alq_total         numeric;
  v_alq_pagado        numeric;
  v_alq_saldo         numeric;
  v_imp_pagado        numeric;
  v_serv_total        numeric;
  v_serv_pagado       numeric;
  v_serv_saldo        numeric;
  v_monto_total_new   numeric;
  v_monto_pagado_new  numeric;
  v_saldo_new         numeric;
  v_estado_new        text;
  v_accion            text;
  v_razon             text;
  v_n_lista           integer := 0;
  v_n_preparable      integer := 0;
  v_n_revision        integer := 0;
  v_n_incompleta      integer := 0;
  v_n_actualizada     integer := 0;
  v_cuotas_detalle    jsonb   := '[]'::jsonb;
  v_antes             jsonb;
  v_despues           jsonb;
BEGIN

  -- ─── Validaciones básicas ─────────────────────────────────────────────────
  IF NOT p_dry_run AND COALESCE(TRIM(p_motivo), '') = '' THEN
    RETURN jsonb_build_object('ok',false,'error','p_motivo es obligatorio para ejecución real','codigo','MOTIVO_VACIO');
  END IF;
  IF NOT p_dry_run AND COALESCE(TRIM(p_usuario), '') = '' THEN
    RETURN jsonb_build_object('ok',false,'error','p_usuario es obligatorio','codigo','USUARIO_VACIO');
  END IF;

  -- ─── Recorrer cuotas de contratos activos ─────────────────────────────────
  FOR v_cuota IN
    SELECT co.*,
           c.servicios_habilitados,
           COALESCE(l.codigo_local, l.codigo, l.id::text) AS codigo_local,
           i.nombre AS nombre_inquilino
    FROM cuotas_operativas co
    JOIN contratos  c ON c.id = co.contrato_id
    JOIN locales    l ON l.id = c.local_id
    JOIN inquilinos i ON i.id = c.inquilino_id
    WHERE (p_contrato_id IS NULL OR co.contrato_id = p_contrato_id)
      AND c.estado = 'ACTIVO'
      AND (c.oculto IS NULL OR c.oculto = false)
    ORDER BY co.contrato_id, co.anio, co.mes
  LOOP

    -- ── Clasificar cuota ──────────────────────────────────────────────────

    -- LISTA: ya tiene componentes completos
    IF v_cuota.monto_alquiler_total  IS NOT NULL
    AND v_cuota.monto_alquiler_pagado IS NOT NULL
    AND v_cuota.saldo_alquiler         IS NOT NULL
    THEN
      v_n_lista := v_n_lista + 1;
      v_cuotas_detalle := v_cuotas_detalle || jsonb_build_array(jsonb_build_object(
        'cuota_id',    v_cuota.id,
        'contrato_id', v_cuota.contrato_id,
        'codigo',      v_cuota.codigo_local,
        'inquilino',   v_cuota.nombre_inquilino,
        'anio', v_cuota.anio, 'mes', v_cuota.mes, 'periodo', v_cuota.periodo,
        'accion', 'LISTA', 'razon', 'Ya tiene componentes completos'
      ));
      CONTINUE;
    END IF;

    -- INCOMPLETA: tiene algunos campos nuevos pero no todos
    IF v_cuota.monto_alquiler_total IS NOT NULL THEN
      v_n_incompleta := v_n_incompleta + 1;
      v_cuotas_detalle := v_cuotas_detalle || jsonb_build_array(jsonb_build_object(
        'cuota_id',    v_cuota.id,
        'contrato_id', v_cuota.contrato_id,
        'codigo',      v_cuota.codigo_local,
        'inquilino',   v_cuota.nombre_inquilino,
        'anio', v_cuota.anio, 'mes', v_cuota.mes, 'periodo', v_cuota.periodo,
        'accion', 'INCOMPLETA', 'razon', 'Tiene monto_alquiler_total pero le faltan pagado/saldo'
      ));
      CONTINUE;
    END IF;

    -- ── Cuota legacy: calcular componentes propuestos ──────────────────────

    -- Alquiler total = monto_total legacy (representa el alquiler base del mes)
    v_alq_total := ROUND(COALESCE(v_cuota.monto_total, 0), 2);

    -- Buscar aplicaciones reales activas para este período
    SELECT
      COALESCE(SUM(rao.monto_alquiler), 0) AS sum_alq,
      COALESCE(SUM(rao.monto_impuesto), 0) AS sum_imp,
      COALESCE(SUM(rao.monto_servicio), 0) AS sum_serv,
      COALESCE(SUM(rao.monto_aplicado), 0) AS sum_total,
      COUNT(*)                              AS n_apps
    INTO v_apps
    FROM recibos_aplicaciones_operativas rao
    WHERE rao.contrato_id = v_cuota.contrato_id
      AND rao.anio        = v_cuota.anio
      AND rao.mes         = v_cuota.mes
      AND rao.deleted_at IS NULL;

    -- Calcular pagados: priorizar aplicaciones reales
    IF v_apps.n_apps > 0 THEN
      v_alq_pagado  := ROUND(v_apps.sum_alq,  2);
      v_imp_pagado  := ROUND(v_apps.sum_imp,  2);
      v_serv_pagado := ROUND(v_apps.sum_serv, 2);
    ELSE
      -- Sin aplicaciones: usar monto_pagado legacy como alquiler_pagado (cap = total)
      v_alq_pagado  := ROUND(LEAST(COALESCE(v_cuota.monto_pagado, 0), v_alq_total), 2);
      v_imp_pagado  := 0;
      v_serv_pagado := 0;
    END IF;

    -- Impuesto: NO se inventa. Siempre NULL total + 0 pagado.
    -- El jefe puede cargarlo manualmente después.

    -- Servicio: solo si el contrato tiene servicios_habilitados
    IF COALESCE(v_cuota.servicios_habilitados, false) THEN
      v_serv_total := ROUND(COALESCE(v_cuota.monto_servicio, 0), 2);
    ELSE
      v_serv_total  := 0;
      v_serv_pagado := 0;
    END IF;

    -- Saldos calculados
    v_alq_saldo  := ROUND(GREATEST(0, v_alq_total  - v_alq_pagado),  2);
    v_serv_saldo := ROUND(GREATEST(0, v_serv_total - v_serv_pagado), 2);

    -- Totales recalculados (impuesto = 0 porque se pone NULL en total)
    v_monto_total_new  := ROUND(v_alq_total  + v_serv_total,  2);
    v_monto_pagado_new := ROUND(v_alq_pagado + v_imp_pagado + v_serv_pagado, 2);
    v_saldo_new        := ROUND(v_alq_saldo  + v_serv_saldo, 2);

    -- Estado nuevo
    v_estado_new := CASE
      WHEN v_saldo_new        <= 0.009 THEN 'PAGADO'
      WHEN v_monto_pagado_new >  0.009 THEN 'PARCIAL'
      ELSE 'PENDIENTE'
    END;

    -- ── Clasificar: PREPARABLE o REQUIERE_REVISION ────────────────────────
    v_accion := 'PREPARABLE';
    v_razon  := CASE WHEN v_apps.n_apps > 0
                     THEN 'Calculado desde aplicaciones reales (' || v_apps.n_apps || ' apps)'
                     ELSE 'Calculado desde monto_pagado legacy'
                END;

    IF v_alq_total <= 0 THEN
      v_accion := 'REQUIERE_REVISION';
      v_razon  := 'monto_total = 0: no se puede determinar alquiler';
    ELSIF v_alq_pagado > v_alq_total + 0.009 THEN
      v_accion := 'REQUIERE_REVISION';
      v_razon  := 'Alquiler pagado (' || v_alq_pagado || ') excede el total (' || v_alq_total || ')';
    ELSIF COALESCE(v_cuota.saldo, 0) < -0.009 THEN
      v_accion := 'REQUIERE_REVISION';
      v_razon  := 'Saldo legacy negativo (' || v_cuota.saldo || ')';
    END IF;

    -- Snapshots para detalle
    v_antes := jsonb_build_object(
      'monto_total',  COALESCE(v_cuota.monto_total, 0),
      'monto_pagado', COALESCE(v_cuota.monto_pagado, 0),
      'saldo',        COALESCE(v_cuota.saldo, 0),
      'estado',       v_cuota.estado
    );
    v_despues := jsonb_build_object(
      'monto_alquiler_total',  v_alq_total,
      'monto_alquiler_pagado', v_alq_pagado,
      'saldo_alquiler',        v_alq_saldo,
      'monto_impuesto_total',  NULL,
      'monto_impuesto_pagado', 0,
      'saldo_impuesto',        0,
      'monto_servicio',        v_serv_total,
      'monto_servicio_pagado', v_serv_pagado,
      'saldo_servicio',        v_serv_saldo,
      'monto_total_new',       v_monto_total_new,
      'monto_pagado_new',      v_monto_pagado_new,
      'saldo_new',             v_saldo_new,
      'estado_new',            v_estado_new,
      'n_apps_reales',         v_apps.n_apps
    );

    IF v_accion = 'PREPARABLE' THEN
      v_n_preparable := v_n_preparable + 1;
    ELSE
      v_n_revision := v_n_revision + 1;
    END IF;

    v_cuotas_detalle := v_cuotas_detalle || jsonb_build_array(jsonb_build_object(
      'cuota_id',    v_cuota.id,
      'contrato_id', v_cuota.contrato_id,
      'codigo',      v_cuota.codigo_local,
      'inquilino',   v_cuota.nombre_inquilino,
      'anio', v_cuota.anio, 'mes', v_cuota.mes, 'periodo', v_cuota.periodo,
      'accion', v_accion, 'razon', v_razon,
      'antes', v_antes, 'despues', v_despues
    ));

    -- ── Si dry_run=false y PREPARABLE: ejecutar UPDATE + auditoría ─────────
    IF NOT p_dry_run AND v_accion = 'PREPARABLE' THEN

      UPDATE cuotas_operativas SET
        monto_alquiler_total  = v_alq_total,
        monto_alquiler_pagado = v_alq_pagado,
        saldo_alquiler        = v_alq_saldo,
        monto_impuesto_total  = NULL,    -- NULL = mes sin impuesto cargado aún
        monto_impuesto_pagado = 0,
        saldo_impuesto        = 0,
        monto_servicio        = v_serv_total,
        monto_servicio_pagado = v_serv_pagado,
        saldo_servicio        = v_serv_saldo,
        monto_total           = v_monto_total_new,
        monto_pagado          = v_monto_pagado_new,
        saldo                 = v_saldo_new,
        estado                = v_estado_new,
        updated_at            = NOW()
      WHERE id = v_cuota.id;

      INSERT INTO auditoria_operativa(
        usuario, accion, tabla_afectada, registro_id,
        contrato_id, anio, mes, campo,
        valor_anterior, valor_nuevo, motivo
      ) VALUES (
        p_usuario,
        'PREPARAR_COMPONENTES_CUOTA',
        'cuotas_operativas',
        v_cuota.id,
        v_cuota.contrato_id,
        v_cuota.anio,
        v_cuota.mes,
        'componentes_preparacion',
        v_antes::text,
        v_despues::text,
        COALESCE(p_motivo, 'Preparación automática de componentes')
      );

      v_n_actualizada := v_n_actualizada + 1;
    END IF;

  END LOOP;

  -- ─── Retorno ──────────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'ok',           true,
    'dry_run',      p_dry_run,
    'total_cuotas', v_n_lista + v_n_preparable + v_n_revision + v_n_incompleta,
    'ya_listas',    v_n_lista,
    'preparables',  v_n_preparable,
    'revision',     v_n_revision,
    'incompletas',  v_n_incompleta,
    'actualizadas', v_n_actualizada,
    'cuotas',       v_cuotas_detalle,
    'mensaje', CASE p_dry_run
      WHEN true THEN 'Simulación completada. Ningún dato fue modificado.'
      ELSE 'Preparación ejecutada. ' || v_n_actualizada || ' cuotas actualizadas.'
    END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok',false,'error',SQLERRM,'codigo','INTERNAL_ERROR');

END;
$func$;

REVOKE ALL ON FUNCTION preparar_componentes_contrato FROM PUBLIC;
GRANT EXECUTE ON FUNCTION preparar_componentes_contrato TO authenticated;

COMMENT ON FUNCTION preparar_componentes_contrato IS
  'Etapa 12 - Preparar columnas de componentes en cuotas legacy. p_dry_run=true simula sin persistir. Solo actualiza cuotas PREPARABLE; informa REQUIERE_REVISION sin tocarlas.';
