-- ═══════════════════════════════════════════════════════════════════════════
-- ETAPA 12E: RPC cargar_impuesto_base_componentes
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Creada: 2026-06-23
--
-- PROPÓSITO:
-- Restaurar el impuesto mensual en cuotas que quedaron sin impuesto
-- después de la preparación masiva de componentes (Etapa 12).
-- Cada cuota recibe el impuesto que históricamente le correspondía,
-- derivado de las aplicaciones reales o del impuesto típico del contrato.
--
-- ESTRATEGIA:
-- 1. IMP_DESDE_APPS:
--    La cuota tiene aplicaciones activas con monto_impuesto > 0 para ese
--    período. Se usa la suma exacta de las aplicaciones como imp_total e
--    imp_pagado (el pago ya ocurrió). saldo_impuesto = 0. Estado no cambia.
--
-- 2. RESTAURAR_IMP_PAGADO:
--    Cuota PAGADA sin aplicaciones de impuesto. Se carga el impuesto típico
--    del contrato (derivado de 5+ meses de historial, o default p_monto_impuesto)
--    como total = pagado, saldo = 0. El estado sigue siendo PAGADO porque
--    el impuesto ya fue cobrado como parte del pago total.
--
-- 3. CARGAR_IMP_PENDIENTE:
--    Cuota PENDIENTE o PARCIAL sin aplicaciones de impuesto. Se carga el
--    impuesto típico como total, pagado = 0, saldo = imp_total. El saldo
--    total de la cuota AUMENTA. El estado puede cambiar a PARCIAL/PENDIENTE
--    con mayor deuda.
--
-- GARANTÍAS:
-- • p_dry_run = true  → NINGÚN UPDATE ni INSERT. Solo diagnóstico.
-- • p_dry_run = false → UPDATE cuotas APLICABLES + INSERT auditoria.
-- • No toca pagos, recibos_historicos ni recibos_aplicaciones.
-- • No duplica impuestos (solo actúa si monto_impuesto_total es NULL/0).
-- • Para el impuesto típico: usa MODE() de apps con 5+ meses; else default.
-- • Impuestos altos con < 5 meses de datos (acumulaciones multi-período)
--   se tratan con el default 13500 para evitar sobrecargar.
--
-- ACCIONES POR CUOTA:
-- • YA_TIENE_IMPUESTO    → cuota ya tiene imp_total > 0, se omite.
-- • IMP_DESDE_APPS       → impuesto derivado de aplicaciones reales activas.
-- • RESTAURAR_IMP_PAGADO → cuota PAGADA; imp_total=imp_pagado=tipico.
-- • CARGAR_IMP_PENDIENTE → cuota PENDIENTE/PARCIAL; imp_total=tipico, pagado=0.
-- • OMITIDA              → monto_alquiler_total IS NULL (legacy no preparada).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION cargar_impuesto_base_componentes(
  p_contrato_id      bigint  DEFAULT NULL,    -- NULL = todos los contratos activos
  p_monto_impuesto   numeric DEFAULT 13500,   -- impuesto base si no hay historial
  p_usuario          text    DEFAULT 'sistema',
  p_motivo           text    DEFAULT NULL,
  p_dry_run          boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_cuota           RECORD;
  v_sum_apps_imp    numeric;
  v_imp_tipico      numeric;
  v_imp_total       numeric;
  v_imp_pagado      numeric;
  v_imp_saldo       numeric;
  v_monto_total_new numeric;
  v_monto_pago_new  numeric;
  v_saldo_new       numeric;
  v_estado_new      text;
  v_accion          text;
  v_razon           text;
  v_antes           jsonb;
  v_despues         jsonb;
  v_n_ya_tiene      integer := 0;
  v_n_desde_apps    integer := 0;
  v_n_pago_rest     integer := 0;
  v_n_pend_carg     integer := 0;
  v_n_omitida       integer := 0;
  v_n_actualizada   integer := 0;
  v_detalle         jsonb   := '[]'::jsonb;
BEGIN

  -- ─── Validaciones básicas ──────────────────────────────────────────────────
  IF NOT p_dry_run AND COALESCE(TRIM(p_motivo), '') = '' THEN
    RETURN jsonb_build_object('ok',false,'error','p_motivo es obligatorio','codigo','MOTIVO_VACIO');
  END IF;
  IF NOT p_dry_run AND COALESCE(TRIM(p_usuario), '') = '' THEN
    RETURN jsonb_build_object('ok',false,'error','p_usuario es obligatorio','codigo','USUARIO_VACIO');
  END IF;

  -- ─── Recorrer cuotas de contratos activos ────────────────────────────────
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

    -- ── Omitir cuotas sin componentes (legacy no preparada) ─────────────────
    IF v_cuota.monto_alquiler_total IS NULL THEN
      v_n_omitida := v_n_omitida + 1;
      CONTINUE;
    END IF;

    -- ── Omitir cuotas que ya tienen impuesto ────────────────────────────────
    IF COALESCE(v_cuota.monto_impuesto_total, 0) > 0.009 THEN
      v_n_ya_tiene := v_n_ya_tiene + 1;
      v_detalle := v_detalle || jsonb_build_array(jsonb_build_object(
        'cuota_id', v_cuota.id, 'contrato_id', v_cuota.contrato_id,
        'codigo', v_cuota.codigo_local, 'inquilino', v_cuota.nombre_inquilino,
        'anio', v_cuota.anio, 'mes', v_cuota.mes, 'periodo', v_cuota.periodo,
        'accion', 'YA_TIENE_IMPUESTO',
        'imp_actual', v_cuota.monto_impuesto_total,
        'razon', 'Ya tiene monto_impuesto_total > 0'
      ));
      CONTINUE;
    END IF;

    -- ── Derivar impuesto típico del contrato (fuente: apps con 5+ meses) ────
    SELECT COALESCE(
      (SELECT MODE() WITHIN GROUP (ORDER BY rao.monto_impuesto)
       FROM recibos_aplicaciones_operativas rao
       WHERE rao.contrato_id = v_cuota.contrato_id
         AND rao.monto_impuesto > 0
         AND rao.deleted_at IS NULL
       HAVING COUNT(DISTINCT rao.anio * 100 + rao.mes) >= 5),
      p_monto_impuesto   -- fallback al default si < 5 meses de historial
    )
    INTO v_imp_tipico;

    -- ── Buscar aplicaciones activas con impuesto para este período ───────────
    SELECT COALESCE(SUM(rao.monto_impuesto), 0)
    INTO v_sum_apps_imp
    FROM recibos_aplicaciones_operativas rao
    WHERE rao.contrato_id = v_cuota.contrato_id
      AND rao.anio        = v_cuota.anio
      AND rao.mes         = v_cuota.mes
      AND rao.deleted_at IS NULL
      AND rao.monto_impuesto > 0;

    -- ── Determinar acción y valores de impuesto ──────────────────────────────
    IF v_sum_apps_imp > 0.009 THEN
      -- Caso 1: hay aplicaciones reales con impuesto para este período
      v_imp_total  := ROUND(v_sum_apps_imp, 2);
      v_imp_pagado := ROUND(v_sum_apps_imp, 2);  -- ya fue pagado
      v_imp_saldo  := 0;
      v_accion     := 'IMP_DESDE_APPS';
      v_razon      := 'Impuesto derivado de aplicaciones reales activas (' || v_sum_apps_imp || ')';
      v_n_desde_apps := v_n_desde_apps + 1;

    ELSIF v_cuota.estado = 'PAGADO' THEN
      -- Caso 2: cuota PAGADA, sin apps de impuesto → restaurar como pagado
      v_imp_total  := ROUND(v_imp_tipico, 2);
      v_imp_pagado := ROUND(v_imp_tipico, 2);  -- incluido en el pago total
      v_imp_saldo  := 0;
      v_accion     := 'RESTAURAR_IMP_PAGADO';
      v_razon      := 'Cuota PAGADA; impuesto restaurado como cobrado (imp_tipico=' || v_imp_tipico || ')';
      v_n_pago_rest := v_n_pago_rest + 1;

    ELSE
      -- Caso 3: cuota PENDIENTE o PARCIAL → cargar impuesto como pendiente
      v_imp_total  := ROUND(v_imp_tipico, 2);
      v_imp_pagado := 0;
      v_imp_saldo  := ROUND(v_imp_tipico, 2);  -- saldo aumenta
      v_accion     := 'CARGAR_IMP_PENDIENTE';
      v_razon      := 'Cuota ' || v_cuota.estado || '; impuesto cargado como pendiente (imp_tipico=' || v_imp_tipico || ')';
      v_n_pend_carg := v_n_pend_carg + 1;
    END IF;

    -- ── Recalcular totales legacy ─────────────────────────────────────────────
    v_monto_total_new := ROUND(
      COALESCE(v_cuota.monto_alquiler_total, 0) + v_imp_total +
      COALESCE(v_cuota.monto_servicio, 0), 2);

    v_monto_pago_new := ROUND(
      COALESCE(v_cuota.monto_alquiler_pagado, 0) + v_imp_pagado +
      COALESCE(v_cuota.monto_servicio_pagado, 0), 2);

    v_saldo_new := ROUND(
      COALESCE(v_cuota.saldo_alquiler, 0) + v_imp_saldo +
      COALESCE(v_cuota.saldo_servicio, 0), 2);

    v_estado_new := CASE
      WHEN v_saldo_new        <= 0.009 THEN 'PAGADO'
      WHEN v_monto_pago_new   >  0.009 THEN 'PARCIAL'
      ELSE 'PENDIENTE'
    END;

    -- ── Snapshots antes / despues ─────────────────────────────────────────────
    v_antes := jsonb_build_object(
      'monto_impuesto_total',  v_cuota.monto_impuesto_total,
      'monto_impuesto_pagado', COALESCE(v_cuota.monto_impuesto_pagado, 0),
      'saldo_impuesto',        COALESCE(v_cuota.saldo_impuesto, 0),
      'monto_total',           COALESCE(v_cuota.monto_total, 0),
      'monto_pagado',          COALESCE(v_cuota.monto_pagado, 0),
      'saldo',                 COALESCE(v_cuota.saldo, 0),
      'estado',                v_cuota.estado
    );
    v_despues := jsonb_build_object(
      'monto_impuesto_total',  v_imp_total,
      'monto_impuesto_pagado', v_imp_pagado,
      'saldo_impuesto',        v_imp_saldo,
      'monto_total_new',       v_monto_total_new,
      'monto_pagado_new',      v_monto_pago_new,
      'saldo_new',             v_saldo_new,
      'estado_new',            v_estado_new,
      'imp_tipico_contrato',   v_imp_tipico
    );

    v_detalle := v_detalle || jsonb_build_array(jsonb_build_object(
      'cuota_id',    v_cuota.id,
      'contrato_id', v_cuota.contrato_id,
      'codigo',      v_cuota.codigo_local,
      'inquilino',   v_cuota.nombre_inquilino,
      'anio', v_cuota.anio, 'mes', v_cuota.mes, 'periodo', v_cuota.periodo,
      'accion', v_accion, 'razon', v_razon,
      'antes', v_antes, 'despues', v_despues
    ));

    -- ── Ejecución real (solo si dry_run=false) ────────────────────────────────
    IF NOT p_dry_run THEN

      UPDATE cuotas_operativas SET
        monto_impuesto_total  = v_imp_total,
        monto_impuesto_pagado = v_imp_pagado,
        saldo_impuesto        = v_imp_saldo,
        monto_total           = v_monto_total_new,
        monto_pagado          = v_monto_pago_new,
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
        'CARGAR_IMPUESTO_BASE_COMPONENTES',
        'cuotas_operativas',
        v_cuota.id,
        v_cuota.contrato_id,
        v_cuota.anio,
        v_cuota.mes,
        'impuesto_componente',
        v_antes::text,
        v_despues::text,
        COALESCE(p_motivo, 'Carga de impuesto base post migración a componentes')
      );

      v_n_actualizada := v_n_actualizada + 1;
    END IF;

  END LOOP;

  -- ─── Retorno ──────────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'ok',             true,
    'dry_run',        p_dry_run,
    'impuesto_base',  p_monto_impuesto,
    'total_cuotas',   v_n_ya_tiene + v_n_desde_apps + v_n_pago_rest + v_n_pend_carg + v_n_omitida,
    'ya_tenian_imp',  v_n_ya_tiene,
    'desde_apps',     v_n_desde_apps,
    'restauradas_pagadas', v_n_pago_rest,
    'cargadas_pendientes', v_n_pend_carg,
    'omitidas',       v_n_omitida,
    'actualizadas',   v_n_actualizada,
    'cuotas',         v_detalle,
    'mensaje', CASE p_dry_run
      WHEN true THEN 'Simulación completada. Ningún dato fue modificado.'
      ELSE 'Impuesto cargado en ' || v_n_actualizada || ' cuotas.'
    END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok',false,'error',SQLERRM,'codigo','INTERNAL_ERROR');
END;
$func$;

REVOKE ALL ON FUNCTION cargar_impuesto_base_componentes FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cargar_impuesto_base_componentes TO authenticated;

COMMENT ON FUNCTION cargar_impuesto_base_componentes IS
  'Etapa 12E - Restaurar impuesto mensual en cuotas preparadas sin impuesto. p_dry_run=true simula sin persistir.';
