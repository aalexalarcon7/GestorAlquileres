-- ═══════════════════════════════════════════════════════════════════════════
-- BLOQUEO DE RPCs DE COBRO LEGACY
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Fecha: 2026-06-24
--
-- CONTEXTO:
-- El cobro viejo (registrar_cobro_operativo_v4_multipago y anteriores)
-- actualiza campos legacy (monto_pagado, saldo, estado) pero NO los campos
-- de componentes (monto_alquiler_pagado, saldo_alquiler, monto_impuesto_pagado,
-- saldo_impuesto, etc.) en cuotas_operativas.
-- Esto causó el caso RAMIREZ RICARDO (2026-06-24): recibo generado correcto
-- pero cuota sin impacto, requiriendo corrección manual.
--
-- FIX:
-- Reemplazar todas las RPCs de cobro viejo con stubs que retornan error
-- COBRO_LEGACY_DESHABILITADO. No se borran (quedan como documentación).
-- El nuevo cobro usa exclusivamente registrar_cobro_por_componentes.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── v4_multipago (la más reciente del cobro viejo) ──────────────────────
CREATE OR REPLACE FUNCTION registrar_cobro_operativo_v4_multipago(
  p_contrato_id       bigint,
  p_anio              integer,
  p_mes               integer,
  p_monto_pago        numeric,
  p_fecha_pago        date,
  p_medio             text,
  p_referencia        text,
  p_observacion       text,
  p_numero_recibo     text,
  p_monto_alquiler    numeric,
  p_monto_impuesto    numeric,
  p_descripcion_pago  text,
  p_medios_pago       jsonb,
  p_impuesto_mensual  numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'ok',     false,
    'codigo', 'COBRO_LEGACY_DESHABILITADO',
    'mensaje',
      'El cobro legacy fue deshabilitado. '
      'Usar registrar_cobro_por_componentes que actualiza correctamente '
      'los campos de componentes en cuotas_operativas. '
      'Si ves este error desde la UI, recargá la página (Ctrl+F5).'
  );
END;
$$;

COMMENT ON FUNCTION registrar_cobro_operativo_v4_multipago IS
  'DESHABILITADA 2026-06-24. Usar registrar_cobro_por_componentes.';

-- ─── v3_multipago ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION registrar_cobro_operativo_v3_multipago(
  p_contrato_id       bigint,
  p_anio              integer,
  p_mes               integer,
  p_monto_pago        numeric,
  p_fecha_pago        date,
  p_medio             text,
  p_referencia        text,
  p_observacion       text,
  p_numero_recibo     text,
  p_monto_alquiler    numeric,
  p_monto_impuesto    numeric,
  p_descripcion_pago  text,
  p_medios_pago       jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'ok', false, 'codigo', 'COBRO_LEGACY_DESHABILITADO',
    'mensaje', 'El cobro legacy fue deshabilitado. Usar registrar_cobro_por_componentes.'
  );
END;
$$;

COMMENT ON FUNCTION registrar_cobro_operativo_v3_multipago IS
  'DESHABILITADA 2026-06-24. Usar registrar_cobro_por_componentes.';

-- ─── v2 ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION registrar_cobro_operativo_v2(
  p_contrato_id       bigint,
  p_anio              integer,
  p_mes               integer,
  p_monto_pago        numeric,
  p_fecha_pago        date,
  p_medio             text,
  p_referencia        text,
  p_observacion       text,
  p_numero_recibo     text,
  p_monto_alquiler    numeric,
  p_monto_impuesto    numeric,
  p_descripcion_pago  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'ok', false, 'codigo', 'COBRO_LEGACY_DESHABILITADO',
    'mensaje', 'El cobro legacy fue deshabilitado. Usar registrar_cobro_por_componentes.'
  );
END;
$$;

COMMENT ON FUNCTION registrar_cobro_operativo_v2 IS
  'DESHABILITADA 2026-06-24. Usar registrar_cobro_por_componentes.';

-- ─── v1 (firma extendida) ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION registrar_cobro_operativo(
  p_contrato_id       bigint,
  p_anio              integer,
  p_mes               integer,
  p_monto_pago        numeric,
  p_fecha_pago        date,
  p_medio             text,
  p_referencia        text,
  p_observacion       text,
  p_numero_recibo     text,
  p_monto_alquiler    numeric,
  p_monto_impuesto    numeric,
  p_descripcion_pago  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'ok', false, 'codigo', 'COBRO_LEGACY_DESHABILITADO',
    'mensaje', 'El cobro legacy fue deshabilitado. Usar registrar_cobro_por_componentes.'
  );
END;
$$;

-- ─── v1 (firma original) ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION registrar_cobro_operativo(
  p_contrato_id  bigint,
  p_anio         integer,
  p_mes          integer,
  p_monto_pago   numeric,
  p_fecha_pago   date,
  p_medio        text,
  p_referencia   text,
  p_observacion  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'ok', false, 'codigo', 'COBRO_LEGACY_DESHABILITADO',
    'mensaje', 'El cobro legacy fue deshabilitado. Usar registrar_cobro_por_componentes.'
  );
END;
$$;

COMMENT ON FUNCTION registrar_cobro_operativo(bigint,integer,integer,numeric,date,text,text,text) IS
  'DESHABILITADA 2026-06-24. Usar registrar_cobro_por_componentes.';

-- ─── v1 firma corta (8 params) → RETURNS TABLE(ok, pago_id, mensaje) ─────
-- Bloqueada en deploy separado 2026-06-24 (firma distinta requirió script aparte)
-- Verificar con:
-- SELECT prosrc ILIKE '%COBRO_LEGACY_DESHABILITADO%' FROM pg_proc WHERE proname='registrar_cobro_operativo';

