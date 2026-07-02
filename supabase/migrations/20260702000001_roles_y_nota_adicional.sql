-- ═══════════════════════════════════════════════════════════════════════════
-- Roles Jefe/Trabajador + nota adicional para recibos
-- Fecha: 2026-07-02
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) Roles operativos de la app
CREATE TABLE IF NOT EXISTS usuarios_operativos (
  id          bigserial PRIMARY KEY,
  email       text UNIQUE NOT NULL,
  nombre      text,
  rol         text NOT NULL CHECK (rol IN ('JEFE','TRABAJADOR')),
  activo      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE usuarios_operativos IS
  'Usuarios y roles de la interfaz operativa. JEFE ve todo; TRABAJADOR solo Activos, Recibos y Cobro.';

COMMENT ON COLUMN usuarios_operativos.rol IS
  'JEFE: acceso total. TRABAJADOR: Activos, detalle/deudas, cobro por componentes, recibos y cerrar sesión.';

-- Ejemplo de configuración manual posterior:
-- INSERT INTO usuarios_operativos(email,nombre,rol)
-- VALUES ('jefe@email.com','Jefe','JEFE'), ('trabajador@email.com','Trabajador','TRABAJADOR')
-- ON CONFLICT (email) DO UPDATE SET nombre=EXCLUDED.nombre, rol=EXCLUDED.rol, activo=true, updated_at=now();

CREATE OR REPLACE FUNCTION obtener_rol_usuario()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text := lower(coalesce(auth.email(), ''));
  v_row usuarios_operativos%rowtype;
BEGIN
  IF v_email = '' THEN
    RETURN jsonb_build_object('ok', true, 'rol', 'JEFE', 'email', null, 'source', 'fallback_sin_auth');
  END IF;

  SELECT *
  INTO v_row
  FROM usuarios_operativos
  WHERE lower(email) = v_email
    AND activo IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    -- Fallback para no bloquear al jefe si todavía no se cargaron usuarios_operativos.
    -- Una vez cargado el trabajador, su email debe existir con rol TRABAJADOR.
    RETURN jsonb_build_object(
      'ok', true,
      'rol', 'JEFE',
      'email', v_email,
      'nombre', split_part(v_email, '@', 1),
      'source', 'fallback_sin_registro'
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'rol', v_row.rol,
    'email', v_row.email,
    'nombre', coalesce(v_row.nombre, v_row.email),
    'activo', v_row.activo,
    'source', 'usuarios_operativos'
  );
END;
$$;

REVOKE ALL ON FUNCTION obtener_rol_usuario() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION obtener_rol_usuario() TO authenticated;

-- 2) Nota adicional para recibos
ALTER TABLE recibos_historicos_operativos
  ADD COLUMN IF NOT EXISTS nota_adicional text;

ALTER TABLE pagos
  ADD COLUMN IF NOT EXISTS nota_adicional text;

COMMENT ON COLUMN recibos_historicos_operativos.nota_adicional IS
  'Texto opcional escrito por el jefe/trabajador para explicar el recibo al inquilino. No se usa para cálculos.';

COMMENT ON COLUMN pagos.nota_adicional IS
  'Texto opcional de respaldo asociado al pago. No se usa para cálculos.';

-- 3) Sobrecarga de registrar_cobro_por_componentes con p_nota_adicional.
-- No reemplaza la RPC original: la envuelve para preservar toda la lógica existente.
CREATE OR REPLACE FUNCTION registrar_cobro_por_componentes(
  p_contrato_id      bigint,
  p_fecha_pago       date,
  p_total_recibido   numeric,
  p_numero_recibo    text    DEFAULT NULL,
  p_observacion      text    DEFAULT NULL,
  p_nota_adicional   text    DEFAULT NULL,
  p_medios_pago      jsonb   DEFAULT '[]'::jsonb,
  p_aplicaciones     jsonb   DEFAULT '[]'::jsonb,
  p_usuario          text    DEFAULT 'sistema',
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
  v_nota text := nullif(btrim(coalesce(p_nota_adicional, '')), '');
BEGIN
  -- Llama a la función original de 9 argumentos por posición para evitar ambigüedad
  -- con esta sobrecarga.
  v_res := public.registrar_cobro_por_componentes(
    p_contrato_id,
    p_fecha_pago,
    p_total_recibido,
    p_numero_recibo,
    p_observacion,
    p_medios_pago,
    p_aplicaciones,
    p_usuario,
    p_dry_run
  );

  IF p_dry_run OR coalesce((v_res->>'ok')::boolean, false) IS NOT TRUE OR v_nota IS NULL THEN
    RETURN v_res;
  END IF;

  v_pago_id := nullif(v_res->>'pago_id','')::bigint;
  v_recibo_id := nullif(v_res->>'recibo_id','')::bigint;

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

  RETURN v_res || jsonb_build_object('nota_adicional_guardada', true);
END;
$$;

REVOKE ALL ON FUNCTION registrar_cobro_por_componentes(bigint, date, numeric, text, text, text, jsonb, jsonb, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION registrar_cobro_por_componentes(bigint, date, numeric, text, text, text, jsonb, jsonb, text, boolean) TO authenticated;

COMMENT ON FUNCTION registrar_cobro_por_componentes(bigint, date, numeric, text, text, text, jsonb, jsonb, text, boolean) IS
  'Sobrecarga del cobro por componentes que guarda nota_adicional en pagos y recibos. Mantiene la lógica original intacta.';
