-- ═══════════════════════════════════════════════════════════════════════════
-- FIX: modificar_cuota_operativa_alquiler
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Fecha: 2026-06-25
--
-- BUG: cuando el contrato no tiene cuota para el mes solicitado,
-- la RPC hace un INSERT en cuotas_operativas sin incluir
-- codigo_local ni nombre_inquilino (ambos NOT NULL sin default).
-- Resultado: "null value in column 'codigo_local' violates not-null constraint"
--
-- FIX: agregar lookup de codigo_local + nombre_inquilino desde
-- contratos JOIN locales JOIN inquilinos, e incluirlos en el INSERT.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION modificar_cuota_operativa_alquiler(
  p_contrato_id bigint,
  p_anio        integer,
  p_mes         integer,
  p_monto_total numeric
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
  v_id              bigint;
  v_monto_pagado    numeric := 0;
  v_saldo           numeric := 0;
  v_estado          text    := 'PENDIENTE';
  v_periodo         text;
  v_codigo_local    text;
  v_nombre_inquilino text;
BEGIN

  -- Validaciones básicas
  IF p_contrato_id IS NULL OR p_anio IS NULL OR p_mes IS NULL THEN
    RETURN QUERY SELECT false, 'Faltan datos para modificar la cuota.',
      NULL::bigint, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text;
    RETURN;
  END IF;

  IF p_monto_total IS NULL OR p_monto_total < 0 THEN
    RETURN QUERY SELECT false, 'El monto total no es válido.',
      NULL::bigint, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text;
    RETURN;
  END IF;

  -- Obtener codigo_local y nombre_inquilino desde el contrato (para INSERT si no existe cuota)
  SELECT
    COALESCE(l.codigo_local, l.codigo, ''),
    COALESCE(i.nombre, '')
  INTO v_codigo_local, v_nombre_inquilino
  FROM public.contratos ct
  LEFT JOIN public.locales    l ON l.id = ct.local_id
  LEFT JOIN public.inquilinos i ON i.id = ct.inquilino_id
  WHERE ct.id = p_contrato_id
  LIMIT 1;

  -- Si el contrato no existe, informar
  IF v_codigo_local IS NULL THEN
    RETURN QUERY SELECT false, 'No se encontró el contrato.',
      NULL::bigint, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text;
    RETURN;
  END IF;

  -- Buscar cuota existente
  SELECT
    co.id,
    COALESCE(co.monto_pagado, 0)
  INTO v_id, v_monto_pagado
  FROM public.cuotas_operativas co
  WHERE co.contrato_id = p_contrato_id
    AND co.anio = p_anio
    AND co.mes  = p_mes
  ORDER BY co.id DESC
  LIMIT 1;

  -- Calcular saldo y estado
  v_saldo := GREATEST(0, ROUND((p_monto_total - COALESCE(v_monto_pagado, 0))::numeric, 2));
  IF v_saldo <= 0.009 THEN
    v_estado := 'PAGADO';
  ELSIF COALESCE(v_monto_pagado, 0) > 0.009 THEN
    v_estado := 'PARCIAL';
  ELSE
    v_estado := 'PENDIENTE';
  END IF;

  v_periodo := LPAD(p_mes::text, 2, '0') || '/' || p_anio::text;

  IF v_id IS NOT NULL THEN
    -- Cuota existente: solo actualizar los campos de monto/saldo/estado
    UPDATE public.cuotas_operativas co
    SET
      monto_total = p_monto_total,
      saldo       = v_saldo,
      estado      = v_estado,
      updated_at  = NOW()
    WHERE co.id = v_id;
  ELSE
    -- Cuota nueva: INSERT con todos los campos NOT NULL obligatorios
    INSERT INTO public.cuotas_operativas (
      contrato_id,
      anio,
      mes,
      periodo,
      monto_total,
      monto_pagado,
      saldo,
      estado,
      codigo_local,
      nombre_inquilino
    )
    VALUES (
      p_contrato_id,
      p_anio,
      p_mes,
      v_periodo,
      p_monto_total,
      0,
      p_monto_total,
      'PENDIENTE',
      v_codigo_local,
      v_nombre_inquilino
    )
    RETURNING id INTO v_id;

    v_monto_pagado := 0;
    v_saldo        := p_monto_total;
    v_estado       := 'PENDIENTE';
  END IF;

  RETURN QUERY
  SELECT
    true,
    'Cuota modificada correctamente.',
    v_id,
    p_monto_total,
    v_monto_pagado,
    v_saldo,
    v_estado;

EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT false, SQLERRM,
    NULL::bigint, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text;
END;
$func$;

COMMENT ON FUNCTION modificar_cuota_operativa_alquiler IS
  'Fix 2026-06-25: INSERT incluye codigo_local y nombre_inquilino (campos NOT NULL). '
  'Usado por saveActivoModal en modo isAlquilerMode para crear/actualizar cuotas.';
