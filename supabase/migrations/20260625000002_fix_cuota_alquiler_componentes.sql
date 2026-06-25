-- ═══════════════════════════════════════════════════════════════════════════
-- FIX: modificar_cuota_operativa_alquiler — soporte para impuesto y componentes
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Fecha: 2026-06-25
--
-- PROBLEMA: la RPC solo aceptaba p_monto_total (alquiler solo) y no
-- guardaba los campos de componentes (monto_alquiler_total, monto_impuesto_total,
-- saldo_alquiler, saldo_impuesto, etc.). El frontend tampoco pasaba el impuesto.
-- Resultado: cuota con monto_total=alquiler (sin impuesto), componentes NULL,
-- y el saldo era incorrecto si el monto era 0.
--
-- FIX: agrega p_impuesto_total con DEFAULT NULL y guarda todos los componentes.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION modificar_cuota_operativa_alquiler(
  p_contrato_id  bigint,
  p_anio         integer,
  p_mes          integer,
  p_monto_total  numeric,
  p_impuesto_total numeric DEFAULT NULL  -- NULL = no cambiar / no cargar impuesto
)
RETURNS TABLE(
  ok           boolean,
  mensaje      text,
  cuota_id     bigint,
  monto_total  numeric,
  monto_pagado numeric,
  saldo        numeric,
  estado       text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_id               bigint;
  v_monto_pagado     numeric := 0;
  v_alq_pagado       numeric := 0;
  v_imp_pagado       numeric := 0;
  v_serv             numeric := 0;
  v_serv_pagado      numeric := 0;
  v_saldo            numeric := 0;
  v_saldo_alq        numeric := 0;
  v_saldo_imp        numeric := 0;
  v_estado           text    := 'PENDIENTE';
  v_periodo          text;
  v_codigo_local     text;
  v_nombre_inquilino text;
  v_imp_final        numeric;
BEGIN

  -- Validaciones básicas
  IF p_contrato_id IS NULL OR p_anio IS NULL OR p_mes IS NULL THEN
    RETURN QUERY SELECT false, 'Faltan datos para modificar la cuota.',
      NULL::bigint, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text;
    RETURN;
  END IF;

  IF p_monto_total IS NULL OR p_monto_total < 0 THEN
    RETURN QUERY SELECT false, 'El monto de alquiler no es válido.',
      NULL::bigint, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text;
    RETURN;
  END IF;

  IF p_impuesto_total IS NOT NULL AND p_impuesto_total < 0 THEN
    RETURN QUERY SELECT false, 'El impuesto no puede ser negativo.',
      NULL::bigint, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text;
    RETURN;
  END IF;

  -- Obtener codigo_local y nombre_inquilino del contrato
  SELECT
    COALESCE(l.codigo_local, l.codigo, ''),
    COALESCE(i.nombre, '')
  INTO v_codigo_local, v_nombre_inquilino
  FROM public.contratos ct
  LEFT JOIN public.locales    l ON l.id = ct.local_id
  LEFT JOIN public.inquilinos i ON i.id = ct.inquilino_id
  WHERE ct.id = p_contrato_id
  LIMIT 1;

  IF v_codigo_local IS NULL THEN
    RETURN QUERY SELECT false, 'No se encontró el contrato.',
      NULL::bigint, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text;
    RETURN;
  END IF;

  -- Buscar cuota existente
  SELECT
    co.id,
    COALESCE(co.monto_pagado, 0),
    COALESCE(co.monto_alquiler_pagado, 0),
    COALESCE(co.monto_impuesto_pagado, 0),
    COALESCE(co.monto_servicio, 0),
    COALESCE(co.monto_servicio_pagado, 0)
  INTO v_id, v_monto_pagado, v_alq_pagado, v_imp_pagado, v_serv, v_serv_pagado
  FROM public.cuotas_operativas co
  WHERE co.contrato_id = p_contrato_id
    AND co.anio = p_anio
    AND co.mes  = p_mes
  ORDER BY co.id DESC
  LIMIT 1;

  -- Impuesto final: usar el recibido o el que ya tenía la cuota
  -- Si p_impuesto_total = NULL se interpreta como "sin impuesto" (0)
  v_imp_final := COALESCE(p_impuesto_total, 0);

  -- Calcular saldos por componente
  v_saldo_alq := GREATEST(0, ROUND((p_monto_total - v_alq_pagado)::numeric, 2));
  v_saldo_imp := GREATEST(0, ROUND((v_imp_final   - v_imp_pagado)::numeric, 2));
  v_saldo     := v_saldo_alq + v_saldo_imp + GREATEST(0, v_serv - v_serv_pagado);
  v_monto_pagado := v_alq_pagado + v_imp_pagado + v_serv_pagado;

  IF v_saldo <= 0.009 THEN
    v_estado := 'PAGADO';
  ELSIF v_monto_pagado > 0.009 THEN
    v_estado := 'PARCIAL';
  ELSE
    v_estado := 'PENDIENTE';
  END IF;

  v_periodo := LPAD(p_mes::text, 2, '0') || '/' || p_anio::text;

  IF v_id IS NOT NULL THEN
    -- UPDATE cuota existente — actualiza legacy + componentes
    UPDATE public.cuotas_operativas co
    SET
      monto_total           = p_monto_total + v_imp_final + v_serv,
      monto_pagado          = v_monto_pagado,
      saldo                 = v_saldo,
      estado                = v_estado,
      -- Componentes nuevos
      monto_alquiler_total  = p_monto_total,
      monto_alquiler_pagado = v_alq_pagado,
      saldo_alquiler        = v_saldo_alq,
      monto_impuesto_total  = CASE WHEN v_imp_final > 0 THEN v_imp_final ELSE NULL END,
      monto_impuesto_pagado = v_imp_pagado,
      saldo_impuesto        = v_saldo_imp,
      monto_servicio        = v_serv,
      monto_servicio_pagado = v_serv_pagado,
      saldo_servicio        = GREATEST(0, v_serv - v_serv_pagado),
      updated_at            = NOW()
    WHERE co.id = v_id;

  ELSE
    -- INSERT cuota nueva — todos los campos NOT NULL + componentes
    INSERT INTO public.cuotas_operativas (
      contrato_id, anio, mes, periodo,
      monto_total, monto_pagado, saldo, estado,
      codigo_local, nombre_inquilino,
      -- Componentes
      monto_alquiler_total,  monto_alquiler_pagado,  saldo_alquiler,
      monto_impuesto_total,  monto_impuesto_pagado,  saldo_impuesto,
      monto_servicio,        monto_servicio_pagado,  saldo_servicio
    )
    VALUES (
      p_contrato_id, p_anio, p_mes, v_periodo,
      p_monto_total + v_imp_final, 0, p_monto_total + v_imp_final, 'PENDIENTE',
      v_codigo_local, v_nombre_inquilino,
      -- Componentes
      p_monto_total,                       0,                  p_monto_total,
      CASE WHEN v_imp_final > 0 THEN v_imp_final ELSE NULL END, 0, v_saldo_imp,
      0,                                   0,                  0
    )
    RETURNING id INTO v_id;

    v_monto_pagado := 0;
    v_saldo        := p_monto_total + v_imp_final;
    v_estado       := 'PENDIENTE';
  END IF;

  RETURN QUERY
  SELECT
    true,
    'Cuota modificada correctamente.',
    v_id,
    p_monto_total + v_imp_final,
    v_monto_pagado,
    v_saldo,
    v_estado;

EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT false, SQLERRM,
    NULL::bigint, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text;
END;
$func$;

COMMENT ON FUNCTION modificar_cuota_operativa_alquiler IS
  'Fix 2026-06-25 v2: acepta p_impuesto_total (opcional) y guarda todos los '
  'campos de componentes (monto_alquiler_total, monto_impuesto_total, etc.). '
  'monto_total = alquiler + impuesto + servicio. '
  'El frontend debe pasar impuesto_mensual como p_impuesto_total.';
