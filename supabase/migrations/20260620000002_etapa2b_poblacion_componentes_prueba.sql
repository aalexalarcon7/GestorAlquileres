-- ═══════════════════════════════════════════════════════════════════════════
-- ETAPA 2B — Población inicial de columnas por componentes (contratos de prueba)
-- GestorAlquileres · Proyecto: axsrpvsacxpqhxecxydm
-- Fecha: 2026-06-20
-- Ejecutado: 2026-06-20 en producción
--
-- OPERACIÓN: UPDATE por id exacto (+ contrato_id + anio + mes como protección)
-- 14 cuotas de 5 contratos de prueba
-- RIESGO: Solo modifica las columnas nuevas (Etapa 2A). NO toca legacy.
--
-- CONTRATOS DE PRUEBA:
--   BRITEZ SAMUEL    / PTO24  / contrato_id=20 / sin servicio / imp=13500
--   PANIAGUA LUCIA   / PTO70  / contrato_id=4  / sin servicio / imp=54000
--   MELGAREJO LORENA / PTO114 / contrato_id=43 / sin servicio / imp=13500
--   KIOSCO SAMIR     / LC1    / contrato_id=35 / con servicio / imp=27000
--   DOVISs ALEJANDRO / LC3    / contrato_id=6  / con servicio / imp=27000
--
-- CRITERIO DE POBLACIÓN:
--   Solo se poblan cuotas donde recibos_aplicaciones_operativas tiene datos
--   limpios y consistentes, o cuotas PENDIENTE con monto_pagado=0.
--
-- CUOTAS EXCLUIDAS (REQUIEREN REVISIÓN MANUAL):
--   BRITEZ 05/2026  (id=269):  alq_apps (413460) > total (386460) por $27.000
--   PANIAGUA 05/2026 (id=334): alq_apps (950000) vs pagado (896000) diff $54.000
--   MELGAREJO 04/2026 (id=218): posible fila duplicada en aplicaciones (imp=27000>mensual)
--   SAMIR 05/2026 (id=114):    apps incompletas (510.000 vs 1.127.950 cuota)
--   SAMIR 06/2026 (id=1716):   alq_apps > total por $27.000 + serv sin apps
--   DOVIS 03/2026 (id=137):    monto_pagado (519.700) > monto_total (482.700)
--   DOVIS 04/2026 (id=138):    igual que 03/2026
--
-- NOTA SERVICIO SAMIR/DOVIS históricos:
--   monto_servicio_pagado=NULL para meses donde las aplicaciones históricas
--   (pago_id=NULL, importadas) no registran el campo monto_servicio.
--   Estos meses quedan pendientes para Etapa 7 (migración histórica).
--
-- DIFERENCIAS CON LEGACY ESPERADAS (por diseño):
--   BRITEZ 06/2026: saldo_alquiler=413.460 vs legacy saldo=399.960 (+13.500=impuesto)
--     → el legacy mezcló impuesto en monto_pagado; el nuevo modelo lo separa correctamente.
--   DOVIS 05/2026:  nuevo total saldo=582.700 vs legacy saldo=482.700 (+100.000=servicio)
--     → el legacy no contaba el servicio en el saldo; el nuevo modelo lo incluye.
--   DOVIS 06/2026:  nuevo total saldo=635.178 vs legacy saldo=525.178 (+110.000=servicio)
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── BRITEZ SAMUEL (contrato_id=20) ──────────────────────────────────────

-- 04/2026 (id=268, PAGADO): 2 apps: alq≈386500 (diff 40 rounding), imp=13500
-- monto_alquiler_pagado capado en monto_alquiler_total (cuota totalmente pagada)
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 386460,
  monto_alquiler_pagado  = 386460,
  saldo_alquiler         = 0,
  monto_impuesto_total   = 13500,
  monto_impuesto_pagado  = 13500,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = 0,
  saldo_servicio         = 0
WHERE id = 268 AND contrato_id = 20 AND anio = 2026 AND mes = 4;

-- 06/2026 (id=1665, PARCIAL): 1 app: alq=7040, imp=13500, total=20540=monto_pagado legacy ✓
-- Diferencia con legacy: saldo_alquiler=413.460 vs saldo legacy=399.960 (+13.500=impuesto separado)
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 420500,
  monto_alquiler_pagado  = 7040,
  saldo_alquiler         = 413460,
  monto_impuesto_total   = 13500,
  monto_impuesto_pagado  = 13500,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = 0,
  saldo_servicio         = 0
WHERE id = 1665 AND contrato_id = 20 AND anio = 2026 AND mes = 6;

-- ─── PANIAGUA LUCIA (contrato_id=4) ──────────────────────────────────────

-- 04/2026 (id=333, PAGADO): 1 app: alq=929484, imp=54000. Cuota total=932742. Diff=3258.
-- monto_alquiler_pagado capado en total (cuota PAGADO, saldo=0)
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 932742,
  monto_alquiler_pagado  = 932742,
  saldo_alquiler         = 0,
  monto_impuesto_total   = 54000,
  monto_impuesto_pagado  = 54000,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = 0,
  saldo_servicio         = 0
WHERE id = 333 AND contrato_id = 4 AND anio = 2026 AND mes = 4;

-- 06/2026 (id=1705, PENDIENTE, sin apps): cuota nueva del mes, 0 pagado
-- monto_impuesto_total=NULL: el jefe decide si junio lleva impuesto
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 1014823,
  monto_alquiler_pagado  = 0,
  saldo_alquiler         = 1014823,
  monto_impuesto_total   = NULL,
  monto_impuesto_pagado  = 0,
  saldo_impuesto         = NULL,
  monto_servicio_pagado  = 0,
  saldo_servicio         = 0
WHERE id = 1705 AND contrato_id = 4 AND anio = 2026 AND mes = 6;

-- ─── MELGAREJO LORENA (contrato_id=43) ───────────────────────────────────

-- 05/2026 (id=219, PARCIAL): 2 apps: alq=370000=monto_pagado ✓, imp=13500
-- CASO MÁS LIMPIO: saldo_alquiler=16350 coincide exactamente con legacy saldo=16350
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 386350,
  monto_alquiler_pagado  = 370000,
  saldo_alquiler         = 16350,
  monto_impuesto_total   = 13500,
  monto_impuesto_pagado  = 13500,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = 0,
  saldo_servicio         = 0
WHERE id = 219 AND contrato_id = 43 AND anio = 2026 AND mes = 5;

-- 06/2026 (id=1713, PENDIENTE, sin apps)
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 420349,
  monto_alquiler_pagado  = 0,
  saldo_alquiler         = 420349,
  monto_impuesto_total   = NULL,
  monto_impuesto_pagado  = 0,
  saldo_impuesto         = NULL,
  monto_servicio_pagado  = 0,
  saldo_servicio         = 0
WHERE id = 1713 AND contrato_id = 43 AND anio = 2026 AND mes = 6;

-- ─── KIOSCO SAMIR (contrato_id=35, servicios=true) ───────────────────────
-- monto_servicio_pagado=NULL: apps históricas importadas sin monto_servicio.
-- Pendiente para Etapa 7 (migración histórica).

-- 01/2026 (id=110, PAGADO): app alq=723300=cuota_total ✓, imp=27000
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 723300,
  monto_alquiler_pagado  = 723300,
  saldo_alquiler         = 0,
  monto_impuesto_total   = 27000,
  monto_impuesto_pagado  = 27000,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = NULL,
  saldo_servicio         = NULL
WHERE id = 110 AND contrato_id = 35 AND anio = 2026 AND mes = 1;

-- 02/2026 (id=111, PAGADO): app alq=1023300=cuota_total ✓, imp=27000
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 1023300,
  monto_alquiler_pagado  = 1023300,
  saldo_alquiler         = 0,
  monto_impuesto_total   = 27000,
  monto_impuesto_pagado  = 27000,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = NULL,
  saldo_servicio         = NULL
WHERE id = 111 AND contrato_id = 35 AND anio = 2026 AND mes = 2;

-- 03/2026 (id=112, PAGADO): app alq=1115000=cuota_total ✓, imp=27000
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 1115000,
  monto_alquiler_pagado  = 1115000,
  saldo_alquiler         = 0,
  monto_impuesto_total   = 27000,
  monto_impuesto_pagado  = 27000,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = NULL,
  saldo_servicio         = NULL
WHERE id = 112 AND contrato_id = 35 AND anio = 2026 AND mes = 3;

-- 04/2026 (id=113, PAGADO): app alq=1115000=cuota_total ✓, imp=27000
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 1115000,
  monto_alquiler_pagado  = 1115000,
  saldo_alquiler         = 0,
  monto_impuesto_total   = 27000,
  monto_impuesto_pagado  = 27000,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = NULL,
  saldo_servicio         = NULL
WHERE id = 113 AND contrato_id = 35 AND anio = 2026 AND mes = 4;

-- ─── DOVISs ALEJANDRO (contrato_id=6, servicios=true) ────────────────────

-- 01/2026 (id=135, PAGADO): app alq=443740=cuota_total ✓, imp=27000. Serv NULL (apps sin serv).
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 443740,
  monto_alquiler_pagado  = 443740,
  saldo_alquiler         = 0,
  monto_impuesto_total   = 27000,
  monto_impuesto_pagado  = 27000,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = NULL,
  saldo_servicio         = NULL
WHERE id = 135 AND contrato_id = 6 AND anio = 2026 AND mes = 1;

-- 02/2026 (id=136, PAGADO): igual que 01/2026
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 443740,
  monto_alquiler_pagado  = 443740,
  saldo_alquiler         = 0,
  monto_impuesto_total   = 27000,
  monto_impuesto_pagado  = 27000,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = NULL,
  saldo_servicio         = NULL
WHERE id = 136 AND contrato_id = 6 AND anio = 2026 AND mes = 2;

-- 05/2026 (id=139, PENDIENTE): CASO CLAVE — solo impuesto pagado, alquiler+servicio pendientes
-- App: alq=0 (sin pagar), imp=27000 (pagado). Cuota: pagado=0, saldo=482700. Serv cuota=100000.
-- El jefe pagó el impuesto del mes sin pagar alquiler — el nuevo modelo refleja esto perfectamente.
-- Nuevo total saldo = 482700 (alq) + 0 (imp) + 100000 (serv) = 582700 vs legacy 482700 (+100k serv)
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 482700,
  monto_alquiler_pagado  = 0,
  saldo_alquiler         = 482700,
  monto_impuesto_total   = 27000,
  monto_impuesto_pagado  = 27000,
  saldo_impuesto         = 0,
  monto_servicio_pagado  = 0,
  saldo_servicio         = 100000
WHERE id = 139 AND contrato_id = 6 AND anio = 2026 AND mes = 5;

-- 06/2026 (id=1699, PENDIENTE, sin apps): cuota nueva del mes. Serv=110000 definido en cuota.
-- Nuevo total saldo = 525178 (alq) + ? (imp) + 110000 (serv) = 635178 vs legacy 525178 (+110k serv)
UPDATE cuotas_operativas SET
  monto_alquiler_total   = 525178,
  monto_alquiler_pagado  = 0,
  saldo_alquiler         = 525178,
  monto_impuesto_total   = NULL,
  monto_impuesto_pagado  = 0,
  saldo_impuesto         = NULL,
  monto_servicio_pagado  = 0,
  saldo_servicio         = 110000
WHERE id = 1699 AND contrato_id = 6 AND anio = 2026 AND mes = 6;

-- ─── Auditoría ────────────────────────────────────────────────────────────
INSERT INTO auditoria_operativa
  (usuario, accion, tabla_afectada, registro_id, contrato_id, anio, mes, campo, valor_anterior, valor_nuevo, motivo)
VALUES
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',268,  20,2026,4,'componentes','NULL','alq:386460 imp:13500 serv:0','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',1665, 20,2026,6,'componentes','NULL','alq:7040 imp:13500 serv:0 saldo_alq:413460','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',333,  4,2026,4,'componentes','NULL','alq:932742 imp:54000 serv:0','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',1705, 4,2026,6,'componentes','NULL','alq:1014823 imp:NULL serv:0','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',219,  43,2026,5,'componentes','NULL','alq:370000 imp:13500 serv:0 saldo_alq:16350','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',1713, 43,2026,6,'componentes','NULL','alq:420349 imp:NULL serv:0','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',110,  35,2026,1,'componentes','NULL','alq:723300 imp:27000 serv:NULL','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',111,  35,2026,2,'componentes','NULL','alq:1023300 imp:27000 serv:NULL','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',112,  35,2026,3,'componentes','NULL','alq:1115000 imp:27000 serv:NULL','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',113,  35,2026,4,'componentes','NULL','alq:1115000 imp:27000 serv:NULL','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',135,  6,2026,1,'componentes','NULL','alq:443740 imp:27000 serv:NULL','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',136,  6,2026,2,'componentes','NULL','alq:443740 imp:27000 serv:NULL','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',139,  6,2026,5,'componentes','NULL','alq:0 imp:27000 serv:100000 saldo_alq:482700 saldo_serv:100000','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba'),
  ('sistema-etapa2b','POBLACION_INICIAL','cuotas_operativas',1699, 6,2026,6,'componentes','NULL','alq:525178 imp:NULL serv:110000','Etapa 2B - poblacion inicial de columnas por componentes para contrato de prueba');
