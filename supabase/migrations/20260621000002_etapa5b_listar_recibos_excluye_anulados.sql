-- ═══════════════════════════════════════════════════════════════════════════
-- ETAPA 5B: listar_recibos_operativos excluye recibos/pagos anulados
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Fecha: 2026-06-21
--
-- CAMBIO: agrega WHERE al final del FROM para excluir:
--   1. recibos con deleted_at IS NOT NULL (soft-deleted)
--   2. recibos con estado = 'ANULADO'
--   3. recibos cuyo pago tiene deleted_at IS NOT NULL
--   4. recibos cuyo pago tiene estado = 'ANULADO'
--
-- p.id IS NULL cubre recibos históricos sin pago asociado (siempre incluidos).
-- La firma de retorno no cambia → compatible con el frontend existente.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.listar_recibos_operativos()
 RETURNS TABLE(
   id bigint, recibo_id bigint, pago_id bigint, contrato_id bigint,
   anio integer, mes integer, numero_recibo text, recibo_base text,
   codigo_local text, nombre_inquilino text,
   fecha_pago date, created_at timestamp with time zone,
   medio text, referencia text,
   monto numeric, monto_total numeric, monto_alquiler numeric,
   monto_impuesto numeric, impuesto_porcentaje numeric,
   periodo_aplicado text, detalle_aplicacion text,
   descripcion_pago text, observacion text,
   documento text, telefono text, email text,
   origen text, fuente_hoja text
 )
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT
    r.id::bigint,
    r.id::bigint,
    r.pago_id::bigint,
    r.contrato_id::bigint,
    r.anio::integer,
    r.mes::integer,
    r.numero_recibo::text,
    r.recibo_base::text,
    COALESCE(r.codigo_local, l.codigo)::text,
    COALESCE(r.nombre_inquilino, i.nombre)::text,
    r.fecha_pago::date,
    r.created_at::timestamptz,
    COALESCE(r.medio, p.medio, 'EFECTIVO')::text,
    COALESCE(r.referencia, p.referencia, r.numero_recibo::text)::text,
    COALESCE(r.monto, r.monto_total, p.monto, p.monto_total, 0)::numeric,
    COALESCE(r.monto_total, r.monto, p.monto_total, p.monto, 0)::numeric,
    COALESCE(r.monto_alquiler, p.monto_alquiler, 0)::numeric,
    COALESCE(r.monto_impuesto, p.monto_impuesto, 0)::numeric,
    COALESCE(p.impuesto_porcentaje, 0)::numeric,
    COALESCE(r.periodo_aplicado, p.periodo_aplicado, r.periodo, '')::text,
    COALESCE(r.detalle_aplicacion, p.detalle_aplicacion, r.observacion, p.observacion, '')::text,
    COALESCE(p.descripcion_pago, r.observacion, p.observacion, '')::text,
    COALESCE(r.observacion, p.observacion, '')::text,
    COALESCE(i.documento, '')::text,
    COALESCE(i.telefono, '')::text,
    COALESCE(i.email, '')::text,
    COALESCE(r.origen, 'OPERATIVO')::text,
    COALESCE(r.origen, 'recibos_historicos_operativos')::text
  FROM recibos_historicos_operativos r
  LEFT JOIN pagos      p ON p.id = r.pago_id
  LEFT JOIN contratos  c ON c.id = r.contrato_id
  LEFT JOIN locales    l ON l.id = c.local_id
  LEFT JOIN inquilinos i ON i.id = c.inquilino_id
  WHERE r.deleted_at IS NULL
    AND (r.estado IS NULL OR UPPER(r.estado) != 'ANULADO')
    AND (
      p.id IS NULL
      OR (p.deleted_at IS NULL AND (p.estado IS NULL OR UPPER(p.estado) != 'ANULADO'))
    )
  ORDER BY r.created_at DESC NULLS LAST, r.id DESC;
$function$;
