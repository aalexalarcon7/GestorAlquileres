-- ═══════════════════════════════════════════════════════════════════════════
-- ETAPA 3B: Agrega modo dry_run a registrar_cobro_por_componentes
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Fecha: 2026-06-20
--
-- CAMBIOS sobre la versión anterior (Etapa 3):
--   1. Nuevo parámetro: p_dry_run boolean DEFAULT false
--   2. En Paso 4 (validación): pre-calcula nuevos saldos y construye
--      v_cuotas_afectadas con antes/despues por cuota.
--   3. Nuevo Paso 4.5: si dry_run=true, retorna simulación inmediatamente
--      sin ejecutar ningún INSERT/UPDATE.
--   4. Pasos 5–10 (persistencia) solo se alcanzan si dry_run=false.
--
-- Garantía: cuando dry_run=true, la función no modifica NINGUNA tabla.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION registrar_cobro_por_componentes(
  p_contrato_id    bigint,
  p_fecha_pago     date,
  p_total_recibido numeric,
  p_numero_recibo  text    DEFAULT NULL,
  p_observacion    text    DEFAULT NULL,
  p_medios_pago    jsonb   DEFAULT '[]'::jsonb,
  p_aplicaciones   jsonb   DEFAULT '[]'::jsonb,
  p_usuario        text    DEFAULT 'sistema',
  p_dry_run        boolean DEFAULT false        -- NUEVO: simula sin persistir
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_contrato          RECORD;
  v_pago_id           bigint;
  v_recibo_hist_id    bigint;
  v_numero_recibo     text;
  v_suma_medios       numeric := 0;
  v_suma_apps         numeric := 0;
  v_idx               integer;
  v_app_elem          jsonb;
  v_app_anio          integer;
  v_app_mes           integer;
  v_app_alquiler      numeric;
  v_app_impuesto      numeric;
  v_app_servicio      numeric;
  v_app_total         numeric;
  v_cuota             RECORD;
  v_saldo_alq_disp    numeric;
  v_new_alq_pagado    numeric;
  v_new_alq_saldo     numeric;
  v_new_imp_pagado    numeric;
  v_new_imp_saldo     numeric;
  v_new_serv_pagado   numeric;
  v_new_serv_saldo    numeric;
  v_new_monto_pago    numeric;
  v_new_saldo_total   numeric;
  v_new_estado        text;
  v_total_alquiler    numeric := 0;
  v_total_impuesto    numeric := 0;
  v_total_servicio    numeric := 0;
  v_anio_primario     integer;
  v_mes_primario      integer;
  v_min_periodo       integer;
  v_periodo_primario  text;
  v_periodo_detalle   text;
  v_medio_principal   text;
  v_detalle_visual    text;
  v_linea             text;
  v_sep               text;
  v_max_recibo        bigint;
  v_n_apps            integer;
  -- Variables exclusivas de dry_run
  v_cuotas_afectadas  jsonb := '[]'::jsonb;
  v_cuota_antes       jsonb;
  v_cuota_despues     jsonb;
BEGIN

-- ─── PASO 0: Validaciones básicas ─────────────────────────────────────────

  IF p_contrato_id IS NULL OR p_contrato_id <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','contrato_id es obligatorio','codigo','PARAM_ERROR');
  END IF;
  IF p_fecha_pago IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','fecha_pago es obligatoria','codigo','PARAM_ERROR');
  END IF;
  IF COALESCE(p_total_recibido,0) <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','total_recibido debe ser mayor a 0','codigo','PARAM_ERROR');
  END IF;
  v_n_apps := jsonb_array_length(COALESCE(p_aplicaciones,'[]'::jsonb));
  IF v_n_apps = 0 THEN
    RETURN jsonb_build_object('ok',false,'error','Se requiere al menos una aplicacion','codigo','PARAM_ERROR');
  END IF;

-- ─── PASO 1: Cargar contrato ──────────────────────────────────────────────

  SELECT c.id, c.estado, c.inquilino_id, c.local_id, c.servicios_habilitados,
         COALESCE(l.codigo_local, l.codigo, '?') AS codigo_local,
         COALESCE(i.nombre, '?') AS nombre_inquilino
  INTO v_contrato
  FROM contratos c
  LEFT JOIN locales    l ON l.id = c.local_id
  LEFT JOIN inquilinos i ON i.id = c.inquilino_id
  WHERE c.id = p_contrato_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','Contrato no encontrado: '||p_contrato_id,'codigo','NOT_FOUND');
  END IF;
  IF v_contrato.estado <> 'ACTIVO' THEN
    RETURN jsonb_build_object('ok',false,'error','Contrato no activo (estado: '||v_contrato.estado||')','codigo','CONTRATO_INACTIVO');
  END IF;

-- ─── PASO 2: Suma de medios_pago = total_recibido ─────────────────────────

  SELECT COALESCE(SUM((e->>'monto')::numeric),0)
  INTO v_suma_medios
  FROM jsonb_array_elements(COALESCE(p_medios_pago,'[]'::jsonb)) AS e;

  IF ABS(v_suma_medios - p_total_recibido) > 0.009 THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','Suma de medios ('||v_suma_medios||') distinta a total_recibido ('||p_total_recibido||')',
      'codigo','SUMA_MEDIOS_ERROR');
  END IF;

-- ─── PASO 3: Suma de aplicaciones = total_recibido ────────────────────────

  SELECT COALESCE(SUM(
    COALESCE((e->>'monto_alquiler')::numeric,0) +
    COALESCE((e->>'monto_impuesto')::numeric,0) +
    COALESCE((e->>'monto_servicio')::numeric,0)
  ),0)
  INTO v_suma_apps
  FROM jsonb_array_elements(p_aplicaciones) AS e;

  IF ABS(v_suma_apps - p_total_recibido) > 0.009 THEN
    RETURN jsonb_build_object(
      'ok',false,
      'error','Suma de aplicaciones ('||v_suma_apps||') distinta a total_recibido ('||p_total_recibido||')',
      'codigo','SUMA_APPS_ERROR');
  END IF;

-- ─── PASO 4: Validar cada aplicación + pre-calcular nuevos saldos ─────────
-- Este bloque se ejecuta siempre (dry_run=true y false).
-- Al terminar, v_cuotas_afectadas tiene el antes/despues de cada cuota.

  FOR v_idx IN 0..v_n_apps-1 LOOP
    v_app_elem     := p_aplicaciones->v_idx;
    v_app_anio     := (v_app_elem->>'anio')::integer;
    v_app_mes      := (v_app_elem->>'mes')::integer;
    v_app_alquiler := COALESCE((v_app_elem->>'monto_alquiler')::numeric, 0);
    v_app_impuesto := COALESCE((v_app_elem->>'monto_impuesto')::numeric, 0);
    v_app_servicio := COALESCE((v_app_elem->>'monto_servicio')::numeric, 0);
    v_app_total    := v_app_alquiler + v_app_impuesto + v_app_servicio;

    -- Montos negativos o cero
    IF v_app_alquiler < 0 OR v_app_impuesto < 0 OR v_app_servicio < 0 THEN
      RETURN jsonb_build_object('ok',false,'error','Monto negativo en '||v_app_anio||'/'||v_app_mes,'codigo','MONTO_NEGATIVO');
    END IF;
    IF v_app_total <= 0 THEN
      RETURN jsonb_build_object('ok',false,'error','Aplicacion con total 0 en '||v_app_anio||'/'||v_app_mes,'codigo','MONTO_CERO');
    END IF;

    -- Cargar cuota
    SELECT * INTO v_cuota FROM cuotas_operativas
    WHERE contrato_id = p_contrato_id AND anio = v_app_anio AND mes = v_app_mes;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok',false,'error','Sin cuota para '||v_app_anio||'/'||v_app_mes,'codigo','CUOTA_NOT_FOUND');
    END IF;

    -- Cuota debe tener datos de componentes (Etapa 2B)
    IF v_cuota.monto_alquiler_total IS NULL THEN
      RETURN jsonb_build_object(
        'ok',false,
        'error','Cuota '||v_app_anio||'/'||v_app_mes||' sin datos de componentes (ejecutar Etapa 2B primero)',
        'codigo','CUOTA_SIN_COMPONENTES');
    END IF;

    -- Alquiler vs saldo
    v_saldo_alq_disp := COALESCE(v_cuota.saldo_alquiler, v_cuota.saldo, 0);
    IF v_app_alquiler > v_saldo_alq_disp + 0.009 THEN
      RETURN jsonb_build_object(
        'ok',false,
        'error','Alquiler ('||v_app_alquiler||') excede saldo alquiler ('||v_saldo_alq_disp||') en '||v_app_anio||'/'||v_app_mes,
        'codigo','SALDO_INSUF_ALQ');
    END IF;

    -- Impuesto: solo si el jefe lo cargó para este mes
    IF v_app_impuesto > 0 THEN
      IF v_cuota.monto_impuesto_total IS NULL THEN
        RETURN jsonb_build_object(
          'ok',false,
          'error','El mes '||v_app_anio||'/'||v_app_mes||' no tiene impuesto cargado. El jefe debe cargarlo primero.',
          'codigo','IMPUESTO_NO_CARGADO');
      END IF;
      IF COALESCE(v_cuota.saldo_impuesto,0) < v_app_impuesto - 0.009 THEN
        RETURN jsonb_build_object(
          'ok',false,
          'error','Impuesto ('||v_app_impuesto||') excede saldo impuesto ('||COALESCE(v_cuota.saldo_impuesto,0)||') en '||v_app_anio||'/'||v_app_mes,
          'codigo','SALDO_INSUF_IMP');
      END IF;
    END IF;

    -- Servicio: solo contratos habilitados
    IF v_app_servicio > 0 THEN
      IF NOT COALESCE(v_contrato.servicios_habilitados, false) THEN
        RETURN jsonb_build_object('ok',false,'error','Contrato sin servicios habilitados','codigo','SERVICIO_NO_HABILITADO');
      END IF;
      IF COALESCE(v_cuota.saldo_servicio,0) < v_app_servicio - 0.009 THEN
        RETURN jsonb_build_object(
          'ok',false,
          'error','Servicio ('||v_app_servicio||') excede saldo servicio ('||COALESCE(v_cuota.saldo_servicio,0)||') en '||v_app_anio||'/'||v_app_mes,
          'codigo','SALDO_INSUF_SERV');
      END IF;
    END IF;

    -- Acumular totales por componente
    v_total_alquiler := v_total_alquiler + v_app_alquiler;
    v_total_impuesto := v_total_impuesto + v_app_impuesto;
    v_total_servicio := v_total_servicio + v_app_servicio;

    -- ── Pre-calcular nuevos saldos (sirve para dry_run Y para paso 10) ────
    v_new_alq_pagado  := ROUND(COALESCE(v_cuota.monto_alquiler_pagado,0) + v_app_alquiler, 2);
    v_new_alq_saldo   := ROUND(GREATEST(0, COALESCE(v_cuota.monto_alquiler_total, v_cuota.monto_total, 0) - v_new_alq_pagado), 2);
    v_new_imp_pagado  := ROUND(COALESCE(v_cuota.monto_impuesto_pagado,0) + v_app_impuesto, 2);
    v_new_imp_saldo   := ROUND(GREATEST(0, COALESCE(v_cuota.monto_impuesto_total,0) - v_new_imp_pagado), 2);
    v_new_serv_pagado := ROUND(COALESCE(v_cuota.monto_servicio_pagado,0) + v_app_servicio, 2);
    v_new_serv_saldo  := ROUND(GREATEST(0, COALESCE(v_cuota.monto_servicio,0) - v_new_serv_pagado), 2);
    v_new_monto_pago  := ROUND(v_new_alq_pagado + v_new_imp_pagado + v_new_serv_pagado, 2);
    v_new_saldo_total := ROUND(v_new_alq_saldo + v_new_imp_saldo + v_new_serv_saldo, 2);
    v_new_estado := CASE
      WHEN v_new_saldo_total <= 0.009 THEN 'PAGADO'
      WHEN v_new_monto_pago  >  0.009 THEN 'PARCIAL'
      ELSE 'PENDIENTE'
    END;

    -- ── Construir antes/despues para dry_run ──────────────────────────────
    v_cuota_antes := jsonb_build_object(
      'monto_alquiler_pagado',  COALESCE(v_cuota.monto_alquiler_pagado,0),
      'saldo_alquiler',         COALESCE(v_cuota.saldo_alquiler,0),
      'monto_impuesto_pagado',  COALESCE(v_cuota.monto_impuesto_pagado,0),
      'saldo_impuesto',         COALESCE(v_cuota.saldo_impuesto,0),
      'monto_servicio_pagado',  COALESCE(v_cuota.monto_servicio_pagado,0),
      'saldo_servicio',         COALESCE(v_cuota.saldo_servicio,0),
      'monto_pagado_legacy',    COALESCE(v_cuota.monto_pagado,0),
      'saldo_legacy',           COALESCE(v_cuota.saldo,0),
      'estado',                 v_cuota.estado
    );
    v_cuota_despues := jsonb_build_object(
      'monto_alquiler_pagado',  v_new_alq_pagado,
      'saldo_alquiler',         v_new_alq_saldo,
      'monto_impuesto_pagado',  v_new_imp_pagado,
      'saldo_impuesto',         v_new_imp_saldo,
      'monto_servicio_pagado',  v_new_serv_pagado,
      'saldo_servicio',         v_new_serv_saldo,
      'monto_pagado_legacy',    v_new_monto_pago,
      'saldo_legacy',           v_new_saldo_total,
      'estado',                 v_new_estado
    );

    v_cuotas_afectadas := v_cuotas_afectadas || jsonb_build_array(
      jsonb_build_object(
        'cuota_id', v_cuota.id,
        'anio',     v_app_anio,
        'mes',      v_app_mes,
        'imputado', jsonb_build_object(
          'monto_alquiler', v_app_alquiler,
          'monto_impuesto', v_app_impuesto,
          'monto_servicio', v_app_servicio,
          'total',          v_app_total
        ),
        'antes',   v_cuota_antes,
        'despues', v_cuota_despues
      )
    );

  END LOOP;  -- fin Paso 4

-- ─── PASO 4.5: DRY_RUN — retornar simulación sin persistir NADA ──────────
-- Todas las validaciones pasaron. Si dry_run=true, la función termina aquí.
-- Ningún INSERT ni UPDATE fue ejecutado hasta este punto.

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'ok',              true,
      'dry_run',         true,
      'contrato_id',     p_contrato_id,
      'total_recibido',  p_total_recibido,
      'total_imputado',  v_suma_apps,
      'diferencia',      ROUND(p_total_recibido - v_suma_apps, 2),
      'medios_pago',     COALESCE(p_medios_pago,'[]'::jsonb),
      'aplicaciones',    p_aplicaciones,
      'cuotas_afectadas', v_cuotas_afectadas,
      'advertencias',    '[]'::jsonb,
      'mensaje',         'Simulacion completada. Ningun dato fue modificado.'
    );
  END IF;

-- ─── PASO 5: Número de recibo ─────────────────────────────────────────────
-- Solo se llega aquí si dry_run = false.

  IF COALESCE(p_numero_recibo,'') = '' THEN
    SELECT COALESCE(MAX(numero_recibo::bigint),9000) + 1
    INTO v_max_recibo
    FROM pagos WHERE numero_recibo ~ '^[0-9]+$';
    v_numero_recibo := v_max_recibo::text;
  ELSE
    v_numero_recibo := p_numero_recibo;
    IF EXISTS (SELECT 1 FROM pagos WHERE numero_recibo = v_numero_recibo) THEN
      RETURN jsonb_build_object('ok',false,'error','Numero de recibo ya existe: '||v_numero_recibo,'codigo','RECIBO_DUPLICADO');
    END IF;
  END IF;

-- ─── PASO 6: Período primario y texto visual ──────────────────────────────

  SELECT MIN((e->>'anio')::integer * 100 + (e->>'mes')::integer)
  INTO v_min_periodo
  FROM jsonb_array_elements(p_aplicaciones) AS e;

  v_anio_primario    := v_min_periodo / 100;
  v_mes_primario     := v_min_periodo % 100;
  v_periodo_primario := LPAD(v_mes_primario::text,2,'0')||'/'||v_anio_primario;

  SELECT STRING_AGG(
    LPAD((e->>'mes')::text,2,'0')||'/'||(e->>'anio'),
    ' + '
    ORDER BY (e->>'anio')::integer, (e->>'mes')::integer
  )
  INTO v_periodo_detalle
  FROM jsonb_array_elements(p_aplicaciones) AS e;

  SELECT COALESCE(e->>'metodo','EFECTIVO')
  INTO v_medio_principal
  FROM jsonb_array_elements(COALESCE(p_medios_pago,'[]'::jsonb)) AS e
  LIMIT 1;

  v_detalle_visual := 'Aplicado a: '||v_periodo_detalle||' | Aplicaciones: ';
  v_sep := '';
  FOR v_idx IN 0..v_n_apps-1 LOOP
    v_app_elem     := p_aplicaciones->v_idx;
    v_app_alquiler := COALESCE((v_app_elem->>'monto_alquiler')::numeric,0);
    v_app_impuesto := COALESCE((v_app_elem->>'monto_impuesto')::numeric,0);
    v_app_servicio := COALESCE((v_app_elem->>'monto_servicio')::numeric,0);
    v_linea := LPAD((v_app_elem->>'mes')::text,2,'0')||'/'||(v_app_elem->>'anio')||': ';
    IF v_app_alquiler > 0 THEN
      v_linea := v_linea||'alquiler '||v_app_alquiler;
    END IF;
    IF v_app_impuesto > 0 THEN
      IF v_app_alquiler > 0 THEN v_linea := v_linea||' / '; END IF;
      v_linea := v_linea||'impuesto '||v_app_impuesto;
    END IF;
    IF v_app_servicio > 0 THEN
      IF v_app_alquiler > 0 OR v_app_impuesto > 0 THEN v_linea := v_linea||' / '; END IF;
      v_linea := v_linea||'servicio '||v_app_servicio;
    END IF;
    v_detalle_visual := v_detalle_visual||v_sep||v_linea;
    v_sep := ' | ';
  END LOOP;
  v_detalle_visual := v_detalle_visual||' | Total recibido: '||p_total_recibido;

-- ─── PASO 7: INSERT en pagos ──────────────────────────────────────────────

  INSERT INTO pagos (
    contrato_id, inquilino_id, local_id,
    fecha, fecha_pago,
    monto_total, monto, monto_alquiler, monto_impuesto, monto_servicio,
    numero_recibo, medio, referencia, observacion, descripcion_pago,
    periodo_aplicado, anio_aplicado, mes_aplicado, detalle_aplicacion,
    origen, impuesto_porcentaje, monto_adicional, created_at, updated_at
  ) VALUES (
    p_contrato_id, v_contrato.inquilino_id, v_contrato.local_id,
    p_fecha_pago, p_fecha_pago,
    p_total_recibido, p_total_recibido, v_total_alquiler, v_total_impuesto, v_total_servicio,
    v_numero_recibo, v_medio_principal,
    v_numero_recibo, p_observacion, v_detalle_visual,
    v_periodo_detalle, v_anio_primario, v_mes_primario, v_detalle_visual,
    'COBRO_COMPONENTES', 0, 0, NOW(), NOW()
  )
  RETURNING id INTO v_pago_id;

-- ─── PASO 8: INSERT en recibos_historicos_operativos ─────────────────────

  INSERT INTO recibos_historicos_operativos (
    contrato_id, local_id, inquilino_id,
    codigo_local, nombre_inquilino,
    numero_recibo, recibo_base,
    anio, mes, periodo, fecha_pago,
    monto, monto_total, monto_alquiler, monto_impuesto, monto_servicio,
    medio, referencia, observacion, descripcion_pago,
    periodo_aplicado, detalle_aplicacion,
    origen, pago_id, impuesto_porcentaje,
    created_at, updated_at
  ) VALUES (
    p_contrato_id, v_contrato.local_id, v_contrato.inquilino_id,
    v_contrato.codigo_local, v_contrato.nombre_inquilino,
    v_numero_recibo, v_numero_recibo,
    v_anio_primario, v_mes_primario, v_periodo_primario, p_fecha_pago,
    p_total_recibido, p_total_recibido, v_total_alquiler, v_total_impuesto, v_total_servicio,
    v_medio_principal, v_numero_recibo,
    p_observacion, v_detalle_visual,
    v_periodo_detalle, v_detalle_visual,
    'COBRO_COMPONENTES', v_pago_id, 0,
    NOW(), NOW()
  )
  RETURNING id INTO v_recibo_hist_id;

-- ─── PASO 9: INSERT en recibos_aplicaciones_operativas ───────────────────

  INSERT INTO recibos_aplicaciones_operativas (
    contrato_id, pago_id, recibo_id,
    anio, mes, periodo,
    monto_aplicado, monto_alquiler, monto_impuesto, monto_servicio,
    impuesto_mensual_objetivo, created_at
  )
  SELECT
    p_contrato_id, v_pago_id, v_recibo_hist_id,
    (e->>'anio')::integer,
    (e->>'mes')::integer,
    LPAD((e->>'mes')::text,2,'0')||'/'||(e->>'anio'),
    COALESCE((e->>'monto_alquiler')::numeric,0) + COALESCE((e->>'monto_impuesto')::numeric,0) + COALESCE((e->>'monto_servicio')::numeric,0),
    COALESCE((e->>'monto_alquiler')::numeric,0),
    COALESCE((e->>'monto_impuesto')::numeric,0),
    COALESCE((e->>'monto_servicio')::numeric,0),
    0, NOW()
  FROM jsonb_array_elements(p_aplicaciones) AS e;

-- ─── PASO 10: UPDATE cuotas_operativas + auditoría por mes ───────────────

  FOR v_idx IN 0..v_n_apps-1 LOOP
    v_app_elem     := p_aplicaciones->v_idx;
    v_app_anio     := (v_app_elem->>'anio')::integer;
    v_app_mes      := (v_app_elem->>'mes')::integer;
    v_app_alquiler := COALESCE((v_app_elem->>'monto_alquiler')::numeric, 0);
    v_app_impuesto := COALESCE((v_app_elem->>'monto_impuesto')::numeric, 0);
    v_app_servicio := COALESCE((v_app_elem->>'monto_servicio')::numeric, 0);

    -- Re-leer con FOR UPDATE para garantizar consistencia en escritura
    SELECT * INTO v_cuota FROM cuotas_operativas
    WHERE contrato_id = p_contrato_id AND anio = v_app_anio AND mes = v_app_mes
    FOR UPDATE;

    v_new_alq_pagado  := ROUND(COALESCE(v_cuota.monto_alquiler_pagado,0) + v_app_alquiler, 2);
    v_new_alq_saldo   := ROUND(GREATEST(0, COALESCE(v_cuota.monto_alquiler_total, v_cuota.monto_total, 0) - v_new_alq_pagado), 2);
    v_new_imp_pagado  := ROUND(COALESCE(v_cuota.monto_impuesto_pagado,0) + v_app_impuesto, 2);
    v_new_imp_saldo   := ROUND(GREATEST(0, COALESCE(v_cuota.monto_impuesto_total,0) - v_new_imp_pagado), 2);
    v_new_serv_pagado := ROUND(COALESCE(v_cuota.monto_servicio_pagado,0) + v_app_servicio, 2);
    v_new_serv_saldo  := ROUND(GREATEST(0, COALESCE(v_cuota.monto_servicio,0) - v_new_serv_pagado), 2);
    v_new_monto_pago  := ROUND(v_new_alq_pagado + v_new_imp_pagado + v_new_serv_pagado, 2);
    v_new_saldo_total := ROUND(v_new_alq_saldo + v_new_imp_saldo + v_new_serv_saldo, 2);
    v_new_estado := CASE
      WHEN v_new_saldo_total <= 0.009 THEN 'PAGADO'
      WHEN v_new_monto_pago  >  0.009 THEN 'PARCIAL'
      ELSE 'PENDIENTE'
    END;

    INSERT INTO auditoria_operativa
      (usuario,accion,tabla_afectada,registro_id,contrato_id,anio,mes,campo,valor_anterior,valor_nuevo,motivo)
    VALUES (
      p_usuario, 'REGISTRAR_COBRO_COMPONENTES', 'cuotas_operativas',
      v_cuota.id, p_contrato_id, v_app_anio, v_app_mes,
      'alq_pagado|imp_pagado|serv_pagado|saldo|estado',
      'alq_pag:'||COALESCE(v_cuota.monto_alquiler_pagado,0)||
        ' imp_pag:'||COALESCE(v_cuota.monto_impuesto_pagado,0)||
        ' serv_pag:'||COALESCE(v_cuota.monto_servicio_pagado,0)||
        ' saldo:'||v_cuota.saldo||' estado:'||v_cuota.estado,
      'alq_pag:'||v_new_alq_pagado||
        ' imp_pag:'||v_new_imp_pagado||
        ' serv_pag:'||v_new_serv_pagado||
        ' saldo:'||v_new_saldo_total||' estado:'||v_new_estado,
      'Cobro registrado por componentes - recibo '||v_numero_recibo
    );

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
    WHERE contrato_id = p_contrato_id AND anio = v_app_anio AND mes = v_app_mes;
  END LOOP;

  -- Auditoría del pago completo
  INSERT INTO auditoria_operativa
    (usuario,accion,tabla_afectada,registro_id,contrato_id,anio,mes,campo,valor_anterior,valor_nuevo,motivo)
  VALUES (
    p_usuario, 'REGISTRAR_COBRO_COMPONENTES', 'pagos',
    v_pago_id, p_contrato_id, v_anio_primario, v_mes_primario,
    'nuevo_pago', NULL,
    'pago_id:'||v_pago_id||' recibo:'||v_numero_recibo||
      ' total:'||p_total_recibido||
      ' alq:'||v_total_alquiler||' imp:'||v_total_impuesto||' serv:'||v_total_servicio,
    'Cobro registrado por componentes'
  );

-- ─── Retorno (dry_run=false) ───────────────────────────────────────────────

  RETURN jsonb_build_object(
    'ok',               true,
    'dry_run',          false,
    'pago_id',          v_pago_id,
    'recibo_id',        v_recibo_hist_id,
    'numero_recibo',    v_numero_recibo,
    'total_registrado', p_total_recibido,
    'aplicaciones_count', v_n_apps,
    'cuotas_afectadas', v_cuotas_afectadas,
    'mensaje',          'Cobro registrado correctamente. Recibo '||v_numero_recibo
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok',false,'error',SQLERRM,'codigo','INTERNAL_ERROR');

END;
$func$;

REVOKE ALL ON FUNCTION registrar_cobro_por_componentes(bigint, date, numeric, text, text, jsonb, jsonb, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION registrar_cobro_por_componentes(bigint, date, numeric, text, text, jsonb, jsonb, text, boolean) TO authenticated;

COMMENT ON FUNCTION registrar_cobro_por_componentes(bigint, date, numeric, text, text, jsonb, jsonb, text, boolean) IS
  'Etapa 3B - Cobro por componentes con modo dry_run. p_dry_run=true simula sin persistir. NO conectar al frontend hasta Etapa 4.';
