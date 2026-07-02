-- ═══════════════════════════════════════════════════════════════════════════
-- Trabajador puede anular cobros + nota adicional robusta en recibos
-- Fecha: 2026-07-02
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE recibos_historicos_operativos
  ADD COLUMN IF NOT EXISTS nota_adicional text;

ALTER TABLE pagos
  ADD COLUMN IF NOT EXISTS nota_adicional text;

-- Reemplaza la sobrecarga con p_nota_adicional para guardar la nota de forma robusta.
-- Si el usuario escribió en "Descripción adicional", usa p_nota_adicional.
-- Si escribió en el campo chico "Observación", también se conserva como nota visible.
CREATE OR REPLACE FUNCTION public.registrar_cobro_por_componentes(
  p_contrato_id      bigint,
  p_fecha_pago       date,
  p_total_recibido   numeric,
  p_numero_recibo    text DEFAULT NULL,
  p_observacion      text DEFAULT NULL,
  p_nota_adicional   text DEFAULT NULL,
  p_medios_pago      jsonb DEFAULT '[]'::jsonb,
  p_aplicaciones     jsonb DEFAULT '[]'::jsonb,
  p_usuario          text DEFAULT 'sistema',
  p_dry_run          boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res jsonb;
  v_pago_id bigint;
  v_recibo_id bigint;
  v_numero_recibo text;
  v_nota text := NULLIF(BTRIM(COALESCE(p_nota_adicional, p_observacion, '')), '');
BEGIN
  -- Llama a la RPC original de 9 parámetros, conservando toda la lógica validada.
  v_res := public.registrar_cobro_por_componentes(
    p_contrato_id::bigint,
    p_fecha_pago::date,
    p_total_recibido::numeric,
    p_numero_recibo::text,
    p_observacion::text,
    p_medios_pago::jsonb,
    p_aplicaciones::jsonb,
    p_usuario::text,
    p_dry_run::boolean
  );

  IF p_dry_run IS TRUE THEN
    RETURN v_res;
  END IF;

  IF COALESCE((v_res->>'ok')::boolean, false) IS NOT TRUE OR v_nota IS NULL THEN
    RETURN v_res;
  END IF;

  v_pago_id := NULLIF(v_res->>'pago_id', '')::bigint;
  v_recibo_id := NULLIF(v_res->>'recibo_id', '')::bigint;
  v_numero_recibo := NULLIF(v_res->>'numero_recibo', '');

  IF v_pago_id IS NOT NULL THEN
    UPDATE pagos
    SET nota_adicional = v_nota,
        updated_at = now()
    WHERE id = v_pago_id;
  END IF;

  IF v_recibo_id IS NOT NULL THEN
    UPDATE recibos_historicos_operativos
    SET nota_adicional = v_nota,
        updated_at = now()
    WHERE id = v_recibo_id;
  END IF;

  -- Fallback por si alguna versión futura de la RPC cambia nombres de IDs en el JSON.
  IF v_numero_recibo IS NOT NULL THEN
    UPDATE pagos
    SET nota_adicional = COALESCE(NULLIF(nota_adicional, ''), v_nota),
        updated_at = now()
    WHERE contrato_id = p_contrato_id
      AND numero_recibo = v_numero_recibo;
  END IF;

  IF v_numero_recibo IS NOT NULL THEN
    UPDATE recibos_historicos_operativos
    SET nota_adicional = COALESCE(NULLIF(nota_adicional, ''), v_nota),
        updated_at = now()
    WHERE contrato_id = p_contrato_id
      AND numero_recibo = v_numero_recibo
      AND COALESCE(origen, '') = 'COBRO_COMPONENTES';
  END IF;

  RETURN v_res || jsonb_build_object('nota_adicional_guardada', true);
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_cobro_por_componentes(
  bigint, date, numeric, text, text, text, jsonb, jsonb, text, boolean
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.registrar_cobro_por_componentes(
  bigint, date, numeric, text, text, text, jsonb, jsonb, text, boolean
) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';