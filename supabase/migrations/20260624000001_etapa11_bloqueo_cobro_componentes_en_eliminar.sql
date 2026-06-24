-- ═══════════════════════════════════════════════════════════════════════════
-- ETAPA 11 FIX BACKEND: Bloquear eliminar_recibo_operativo para COBRO_COMPONENTES
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Fecha: 2026-06-24
--
-- PROBLEMA DETECTADO:
-- La RPC eliminar_recibo_operativo solo revierte los campos legacy
-- (monto_pagado, saldo, estado) pero NO los campos de componentes
-- (monto_alquiler_pagado, saldo_alquiler, monto_impuesto_pagado, etc.)
-- Cuando se eliminaba un recibo de COBRO_COMPONENTES con esta RPC,
-- las cuotas_operativas quedaban con componentes incorrectos.
--
-- CASO DOCUMENTADO:
-- Recibo 10001 de HERNAN NIELSEN (pago_id=181, 2026-06-24):
-- Eliminar via RPC vieja → cuota 1692 (06/2026) quedó en PARCIAL
-- con alquiler_pagado=11500, impuesto_pagado=13500, saldo=1401235
-- cuando debía ser PENDIENTE con todo en 0, saldo=1414735.
--
-- También: Recibo 10001 de MELGAREJO (pago_id=180, 2026-06-21):
-- El jefe hizo una reversión manual (REVERSION_COBRO_PRUEBA) 13 min después.
--
-- FIX:
-- Agregar verificación al inicio de eliminar_recibo_operativo:
-- Si el recibo tiene origen='COBRO_COMPONENTES' → rechazar con error claro.
-- El usuario debe usar anular_cobro_por_componentes en su lugar.
-- El fix en el frontend (deleteReciboById) ya bloquea en la UI (commit 82d7f06).
-- Este fix agrega la misma protección en el backend como defensa en profundidad.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION eliminar_recibo_operativo(
  p_pago_id        bigint  DEFAULT NULL,
  p_recibo_id      bigint  DEFAULT NULL,
  p_numero_recibo  text    DEFAULT NULL,
  p_contrato_id    bigint  DEFAULT NULL,
  p_anio           integer DEFAULT NULL,
  p_mes            integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_numero text := NULLIF(TRIM(COALESCE(p_numero_recibo, '')), '');
  v_target_count int := 0;
  v_apps_count int := 0;
  v_recibos_deleted int := 0;
  v_pagos_deleted int := 0;
BEGIN
  /*
    0) Verificar origen ANTES de buscar el target.
    Recibos de COBRO_COMPONENTES deben anularse con anular_cobro_por_componentes.
    Esta RPC solo revierte campos legacy (monto_pagado, saldo) pero NO los campos
    de componentes (monto_alquiler_pagado, saldo_alquiler, etc.).
    Rechazar explícitamente para evitar dejar cuotas con datos incorrectos.
  */
  IF EXISTS (
    SELECT 1 FROM recibos_historicos_operativos rho
    WHERE (
      (p_recibo_id IS NOT NULL AND rho.id = p_recibo_id)
      OR (p_pago_id IS NOT NULL AND rho.pago_id = p_pago_id)
      OR (
        v_numero IS NOT NULL
        AND (
          rho.numero_recibo::text = v_numero
          OR rho.recibo_base::text = v_numero
          OR rho.referencia::text = v_numero
        )
        AND (p_contrato_id IS NULL OR rho.contrato_id = p_contrato_id)
      )
    )
    AND UPPER(COALESCE(rho.origen, '')) = 'COBRO_COMPONENTES'
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'codigo', 'COBRO_COMPONENTES_REQUIERE_ANULAR',
      'mensaje',
        'Este recibo pertenece a un Cobro por Componentes (origen=COBRO_COMPONENTES). '
        'Para anularlo correctamente, usar anular_cobro_por_componentes que revierte '
        'cuotas, pagos y aplicaciones de forma segura y con auditoría. '
        'La eliminación directa deja los componentes de cuotas_operativas en estado incorrecto.'
    );
  END IF;

  /*
    1) Buscar el recibo exacto.
    Tiene que encontrar 1 solo. Si encuentra 0 o varios, no toca nada.
  */
  CREATE TEMP TABLE tmp_delete_target ON COMMIT DROP AS
  SELECT
    rho.id AS recibo_id,
    rho.pago_id,
    rho.contrato_id,
    rho.numero_recibo::text AS numero_recibo,
    rho.codigo_local,
    rho.nombre_inquilino
  FROM recibos_historicos_operativos rho
  WHERE
    (p_recibo_id IS NOT NULL AND rho.id = p_recibo_id)
    OR (p_pago_id IS NOT NULL AND rho.pago_id = p_pago_id)
    OR (
      v_numero IS NOT NULL
      AND (
        rho.numero_recibo::text = v_numero
        OR rho.recibo_base::text = v_numero
        OR rho.referencia::text = v_numero
      )
      AND (p_contrato_id IS NULL OR rho.contrato_id = p_contrato_id)
    );

  SELECT COUNT(*) INTO v_target_count FROM tmp_delete_target;

  IF v_target_count = 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'mensaje', 'No encontré el recibo para eliminar. No se tocó nada.'
    );
  END IF;

  IF v_target_count > 1 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'mensaje', 'Encontré más de un recibo candidato. No se eliminó nada por seguridad.'
    );
  END IF;

  /*
    2) Buscar TODAS las aplicaciones activas de ese recibo/pago.
    Acá entran todos los meses donde cayó plata: mes original + meses con sobrante.
  */
  CREATE TEMP TABLE tmp_delete_apps ON COMMIT DROP AS
  SELECT
    a.*,
    COALESCE(
      a.cuota_id,
      (
        SELECT co.id
        FROM cuotas_operativas co
        WHERE co.contrato_id = a.contrato_id
          AND co.anio = a.anio
          AND co.mes = a.mes
        LIMIT 1
      )
    ) AS cuota_id_resuelta
  FROM recibos_aplicaciones_operativas a
  WHERE a.deleted_at IS NULL
    AND (
      a.recibo_id IN (SELECT recibo_id FROM tmp_delete_target)
      OR a.pago_id IN (
        SELECT pago_id
        FROM tmp_delete_target
        WHERE pago_id IS NOT NULL
      )
    );

  SELECT COUNT(*) INTO v_apps_count FROM tmp_delete_apps;

  IF v_apps_count = 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'mensaje', 'Este recibo no tiene aplicaciones activas para revertir. No se eliminó nada.'
    );
  END IF;

  /*
    3) Backup antes de tocar nada.
  */
  INSERT INTO backup_admin_operativo_json (motivo, tabla, data)
  SELECT
    'Eliminar recibo operativo multimes - backup recibo',
    'recibos_historicos_operativos',
    to_jsonb(rho)
  FROM recibos_historicos_operativos rho
  JOIN tmp_delete_target t ON t.recibo_id = rho.id;

  INSERT INTO backup_admin_operativo_json (motivo, tabla, data)
  SELECT
    'Eliminar recibo operativo multimes - backup pago',
    'pagos',
    to_jsonb(p)
  FROM pagos p
  WHERE p.id IN (
    SELECT pago_id
    FROM tmp_delete_target
    WHERE pago_id IS NOT NULL
  );

  INSERT INTO backup_admin_operativo_json (motivo, tabla, data)
  SELECT
    'Eliminar recibo operativo multimes - backup aplicaciones',
    'recibos_aplicaciones_operativas',
    to_jsonb(a)
  FROM tmp_delete_apps a;

  INSERT INTO backup_admin_operativo_json (motivo, tabla, data)
  SELECT
    'Eliminar recibo operativo multimes - backup cuotas afectadas',
    'cuotas_operativas',
    to_jsonb(co)
  FROM cuotas_operativas co
  WHERE co.id IN (
    SELECT DISTINCT cuota_id_resuelta
    FROM tmp_delete_apps
    WHERE cuota_id_resuelta IS NOT NULL
  );

  /*
    4) Revertir cuotas.
    IMPORTANTE:
    cuotas_operativas.monto_pagado guarda alquiler.
    El impuesto se ve desde recibos_aplicaciones_operativas.
    Por eso se resta SOLO monto_alquiler.
  */
  WITH por_cuota AS (
    SELECT
      cuota_id_resuelta AS cuota_id,
      SUM(COALESCE(monto_alquiler, 0)) AS alquiler_a_revertir
    FROM tmp_delete_apps
    WHERE cuota_id_resuelta IS NOT NULL
    GROUP BY cuota_id_resuelta
  ),
  calculo AS (
    SELECT
      co.id,
      GREATEST(
        0,
        COALESCE(co.monto_pagado, 0) - COALESCE(pc.alquiler_a_revertir, 0)
      ) AS nuevo_pagado
    FROM cuotas_operativas co
    JOIN por_cuota pc ON pc.cuota_id = co.id
  )
  UPDATE cuotas_operativas co
  SET
    monto_pagado = calculo.nuevo_pagado,
    saldo = GREATEST(0, COALESCE(co.monto_total, 0) - calculo.nuevo_pagado),
    estado = CASE
      WHEN calculo.nuevo_pagado <= 0.009 THEN 'PENDIENTE'
      WHEN GREATEST(0, COALESCE(co.monto_total, 0) - calculo.nuevo_pagado) <= 0.009 THEN 'PAGADO'
      ELSE 'PARCIAL'
    END,
    updated_at = now()
  FROM calculo
  WHERE co.id = calculo.id;

  /*
    5) Marcar aplicaciones como eliminadas.
    Esto hace que desaparezca el impuesto aplicado de todos los meses afectados.
  */
  UPDATE recibos_aplicaciones_operativas a
  SET deleted_at = now()
  FROM tmp_delete_apps t
  WHERE a.id = t.id
    AND a.deleted_at IS NULL;

  /*
    6) Borrar medios de pago si existe la tabla.
  */
  IF to_regclass('public.recibo_medios_pago') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'recibo_medios_pago'
        AND column_name = 'recibo_id'
    ) THEN
      EXECUTE '
        DELETE FROM recibo_medios_pago
        WHERE recibo_id IN (
          SELECT recibo_id
          FROM tmp_delete_target
        )
      ';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'recibo_medios_pago'
        AND column_name = 'pago_id'
    ) THEN
      EXECUTE '
        DELETE FROM recibo_medios_pago
        WHERE pago_id IN (
          SELECT pago_id
          FROM tmp_delete_target
          WHERE pago_id IS NOT NULL
        )
      ';
    END IF;
  END IF;

  /*
    7) Borrar recibo histórico y pago.
  */
  DELETE FROM recibos_historicos_operativos rho
  WHERE rho.id IN (
    SELECT recibo_id
    FROM tmp_delete_target
  );

  GET DIAGNOSTICS v_recibos_deleted = ROW_COUNT;

  DELETE FROM pagos p
  WHERE p.id IN (
    SELECT pago_id
    FROM tmp_delete_target
    WHERE pago_id IS NOT NULL
  );

  GET DIAGNOSTICS v_pagos_deleted = ROW_COUNT;

  /*
    8) Sincronización final si existe.
  */
  BEGIN
    PERFORM public.sync_operativo_desde_cuotas();
  EXCEPTION WHEN undefined_function THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'mensaje', 'Recibo eliminado correctamente. Se revirtieron todos los meses afectados por ese recibo.',
    'aplicaciones_revertidas', v_apps_count,
    'recibos_eliminados', v_recibos_deleted,
    'pagos_eliminados', v_pagos_deleted
  );
END;
$func$;

COMMENT ON FUNCTION eliminar_recibo_operativo IS
  'Elimina un recibo legacy de cuotas_operativas. '
  'Bloquea recibos de origen COBRO_COMPONENTES: deben anularse con anular_cobro_por_componentes. '
  'Fix 2026-06-24: protección backend para evitar dejar componentes de cuotas en estado incorrecto.';
