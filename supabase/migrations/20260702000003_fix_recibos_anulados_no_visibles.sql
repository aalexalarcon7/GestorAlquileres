-- ═══════════════════════════════════════════════════════════════════════════
-- Fix: recibos anulados no deben seguir visibles después de revertir cuotas
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE recibos_historicos_operativos
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

ALTER TABLE recibos_historicos_operativos
  ADD COLUMN IF NOT EXISTS estado text;

ALTER TABLE recibos_historicos_operativos
  ADD COLUMN IF NOT EXISTS motivo_anulacion text;

ALTER TABLE pagos
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

ALTER TABLE pagos
  ADD COLUMN IF NOT EXISTS estado text;

ALTER TABLE pagos
  ADD COLUMN IF NOT EXISTS motivo_anulacion text;

NOTIFY pgrst, 'reload schema';