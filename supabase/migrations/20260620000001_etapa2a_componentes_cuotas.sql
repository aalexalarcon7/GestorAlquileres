-- ═══════════════════════════════════════════════════════════════════════════
-- ETAPA 2A — Estructura de BD para modelo por componentes
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Fecha: 2026-06-20
-- Ejecutado: 2026-06-20 en producción via Management API
--
-- OPERACIÓN: Solo ADD COLUMN IF NOT EXISTS + CREATE TABLE IF NOT EXISTS
-- RIESGO: Cero — no modifica datos, no elimina nada, no toca RPCs ni vistas
--
-- CONTEXTO:
-- Rediseño del sistema de cobros para distinguir explícitamente entre tres
-- componentes por cuota: alquiler, impuesto y servicio.
-- Las columnas legacy (monto_total, monto_pagado, saldo, monto_servicio)
-- se mantienen intactas para compatibilidad con el frontend y RPCs actuales.
--
-- NOTA IMPORTANTE:
-- monto_servicio ya existía en cuotas_operativas → equivale al total de
-- servicio del mes. No se agrega de nuevo. Solo se agregan monto_servicio_pagado
-- y saldo_servicio como columnas nuevas.
--
-- PRÓXIMO PASO: Etapa 2B — poblar columnas nuevas para contratos activos
-- seleccionados y verificar contra recibos_aplicaciones_operativas.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── SECCIÓN 1: Columnas por componente en cuotas_operativas ──────────────
--
-- Semántica de cada columna nueva:
--
-- monto_alquiler_total   → monto de alquiler puro que corresponde al mes.
--                          Equivale al monto_total actual menos impuesto y servicio.
--                          Se pobla cuando se migra o edita manualmente la cuota.
--
-- monto_alquiler_pagado  → cuánto se pagó de alquiler en este mes.
--                          Calculado desde recibos_aplicaciones_operativas.monto_alquiler.
--
-- saldo_alquiler         → monto_alquiler_total - monto_alquiler_pagado.
--                          Fuente de verdad para el saldo del alquiler (reemplaza saldo legacy).
--
-- monto_impuesto_total   → cuánto impuesto corresponde a este mes.
--                          NULL = este mes NO lleva impuesto (decisión manual del jefe).
--                          > 0  = impuesto cargado manualmente para este mes.
--                          El sistema NUNCA lo llena automáticamente.
--
-- monto_impuesto_pagado  → cuánto se pagó de impuesto en este mes.
--                          Calculado desde recibos_aplicaciones_operativas.monto_impuesto.
--
-- saldo_impuesto         → monto_impuesto_total - monto_impuesto_pagado.
--                          Si monto_impuesto_total IS NULL → no hay impuesto a cobrar.
--
-- monto_servicio_pagado  → cuánto se pagó de servicio en este mes.
--                          Calculado desde recibos_aplicaciones_operativas.monto_servicio.
--                          monto_servicio (existente) sigue siendo el total del mes.
--
-- saldo_servicio         → monto_servicio - monto_servicio_pagado.
--                          Solo aplica si el contrato tiene servicios_habilitados = true.
--
-- impuesto_cargado_por   → nombre/email del usuario que cargó el impuesto del mes.
--                          Trazabilidad manual.
--
-- impuesto_cargado_at    → timestamp de cuando se cargó el impuesto del mes.
--                          Trazabilidad manual.

-- Componente Alquiler
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS monto_alquiler_total   numeric;
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS monto_alquiler_pagado  numeric;
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS saldo_alquiler         numeric;

-- Componente Impuesto (NULL = este mes no lleva impuesto)
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS monto_impuesto_total   numeric;
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS monto_impuesto_pagado  numeric;
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS saldo_impuesto         numeric;

-- Componente Servicio (monto_servicio ya existe como total)
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS monto_servicio_pagado  numeric;
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS saldo_servicio         numeric;

-- Trazabilidad del impuesto manual
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS impuesto_cargado_por   text;
ALTER TABLE cuotas_operativas ADD COLUMN IF NOT EXISTS impuesto_cargado_at    timestamptz;


-- ─── SECCIÓN 2: Tabla de auditoría ────────────────────────────────────────
--
-- Registra toda corrección manual sobre cuotas, aplicaciones o recibos.
-- Escritura desde RPCs con SECURITY DEFINER (Etapa 6).
-- Campo motivo es NOT NULL — el jefe siempre debe justificar una corrección.

CREATE TABLE IF NOT EXISTS auditoria_operativa (
  id             bigserial    PRIMARY KEY,

  -- Quién hizo la acción
  usuario        text         NOT NULL,

  -- Qué tipo de acción fue
  -- Valores esperados: 'EDICION_CUOTA' | 'EDICION_APLICACION' | 'CARGA_IMPUESTO'
  --                    | 'ELIMINACION_RECIBO' | 'CORRECCION_SALDO' | 'CORRECCION_SERVICIO'
  accion         text         NOT NULL,

  -- En qué tabla se modificó el registro
  tabla_afectada text         NOT NULL,

  -- ID del registro modificado dentro de tabla_afectada
  registro_id    bigint,

  -- Para filtrar por contrato rápidamente
  contrato_id    bigint,

  -- Período afectado
  anio           integer,
  mes            integer,

  -- Qué campo específico se modificó (ej: 'monto_impuesto_total')
  campo          text,

  -- Valor antes del cambio (JSON o texto plano según la acción)
  valor_anterior text,

  -- Valor después del cambio
  valor_nuevo    text,

  -- Motivo obligatorio (sin motivo no se guarda)
  motivo         text         NOT NULL,

  -- Referencia al número de recibo relacionado (opcional)
  recibo_ref     text,

  created_at     timestamptz  DEFAULT now()
);

-- Índices para búsquedas frecuentes
CREATE INDEX IF NOT EXISTS idx_auditoria_contrato    ON auditoria_operativa (contrato_id);
CREATE INDEX IF NOT EXISTS idx_auditoria_periodo     ON auditoria_operativa (anio, mes);
CREATE INDEX IF NOT EXISTS idx_auditoria_created_at  ON auditoria_operativa (created_at DESC);

-- RLS: solo usuarios autenticados pueden leer e insertar
ALTER TABLE auditoria_operativa ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'auditoria_operativa'
      AND policyname = 'auditoria_insert_authenticated'
  ) THEN
    CREATE POLICY "auditoria_insert_authenticated"
      ON auditoria_operativa FOR INSERT TO authenticated WITH CHECK (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'auditoria_operativa'
      AND policyname = 'auditoria_select_authenticated'
  ) THEN
    CREATE POLICY "auditoria_select_authenticated"
      ON auditoria_operativa FOR SELECT TO authenticated USING (true);
  END IF;
END $$;


-- ─── SECCIÓN 3: SELECTs de verificación (ejecutar manualmente para confirmar)
--
-- 1. Columnas nuevas en cuotas_operativas:
-- SELECT column_name, data_type, is_nullable, column_default
-- FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'cuotas_operativas'
--   AND column_name IN (
--     'monto_alquiler_total','monto_alquiler_pagado','saldo_alquiler',
--     'monto_impuesto_total','monto_impuesto_pagado','saldo_impuesto',
--     'monto_servicio_pagado','saldo_servicio',
--     'impuesto_cargado_por','impuesto_cargado_at'
--   )
-- ORDER BY column_name;
-- Resultado esperado: 10 filas, todas nullable=YES, column_default=NULL
--
-- 2. Datos existentes intactos:
-- SELECT COUNT(*) as total, COUNT(monto_total) as con_monto,
--        SUM(CASE WHEN monto_alquiler_total IS NULL THEN 1 ELSE 0 END) as nuevas_en_null
-- FROM cuotas_operativas;
-- Resultado esperado: total=1011, con_monto=1011, nuevas_en_null=1011
--
-- 3. Tabla de auditoría y políticas:
-- SELECT tablename, policyname, cmd FROM pg_policies
-- WHERE tablename = 'auditoria_operativa';
-- Resultado esperado: 2 políticas (INSERT, SELECT) para rol authenticated
