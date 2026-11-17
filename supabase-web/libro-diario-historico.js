/* Archivo historico de Libro Diario. Solo lectura financiera hasta conciliacion. */
(function () {
  'use strict';
  if (typeof sb === 'undefined') return;
  const byId = id => document.getElementById(id);
  const esc = v => String(v ?? '').replace(/[&<>"']/g, s => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[s]));
  const fmt = x => new Intl.NumberFormat('es-AR', { maximumFractionDigits: 2, minimumFractionDigits: 2 }).format(Number(x) || 0);
  const hex64 = /^[0-9a-f]{64}$/;
  const expectedSha = '1886fde2adbc418e83836f87cc2cd75a7cc15290a4c728b5de3953e2c9478585';
  const expectedJsonSha = 'e6b66153099b0dcf31521980887254421bab467d105eef650b16a202a2bde33d';
  const state = { local: null, sources: [], source: null, tabs: [], tab: null, page: 1, search: '', month: '', rows: [], ledger: false, busy: false };
  const col = index => { let v = Number(index) + 1, s = ''; while (v > 0) { s = String.fromCharCode(65 + (v - 1) % 26) + s; v = Math.floor((v - 1) / 26); } return s; };
  const validMoney = v => typeof v === 'number' && Number.isFinite(v) ? v : 0;
  const excelDay = n => {
    if (!(typeof n === 'number' && n >= 40000 && n < 60000)) return '';
    const d = new Date(Date.UTC(1899, 11, 30) + Math.round(n) * 86400000);
    return d.toISOString().slice(0, 10);
  };
  let renderLock = false;
  function mount() {
    const view = byId('viewLibroDiario');
    if (!view || !view.querySelector('#ldNewMove') || !view.querySelector('#ldImportInfo') || byId('ldhRoot')) return;
    const section = document.createElement('div');
    section.id = 'ldhRoot';
    section.className = 'ld-card ldh-root';
    section.innerHTML = `
      <div class="ld-card-title ldh-header"><div>
        <h2>Histórico del Excel</h2>
        <div class="ld-muted">Registros originales conservados para revisión y conciliación</div>
      </div><span class="ldh-pill">No contabilizado</span></div>
      <div class="ldh-note"><strong>Archivo separado.</strong> Importar el histórico no crea ingresos, egresos ni saldos operativos; conserva los originales hasta que se revisen las fechas, cuentas y posibles duplicados.</div>
      <div class="ldh-import">
        <label class="ldh-file-label" for="ldhFile">Seleccionar archivo privado (.json)</label>
        <input type="file" id="ldhFile" accept=".json,application/json">
        <button type="button" class="ld-btn ld-primary" id="ldhImport" disabled>Importar histórico</button>
        <button type="button" class="ld-btn" id="ldhRefresh">Ver importaciones</button>
      </div>
      <p id="ldhMessage" class="ldh-feedback" role="status" aria-live="polite">Seleccioná el archivo privado preparado a partir de LIBRO DIARIO.xlsx.</p>
      <div id="ldhSaved"></div>
      <div id="ldhViewer" style="display:none">
        <div class="ldh-filters">
          <label>Hoja <select id="ldhSheet"></select></label>
          <label>Filtrar mes (solo registros fechados) <input type="month" id="ldhMonth"></label>
          <label>Buscar <input type="search" id="ldhSearch" placeholder="Concepto, importe o celda"></label>
        </div>
        <div id="ldhSheetInfo" class="ldh-muted"></div>
        <div class="ld-table-scroll"><table class="ldh-table"><thead id="ldhHeaders"></thead><tbody id="ldhRows"></tbody></table></div>
        <div class="ld-foot"><span id="ldhCount" class="ld-muted"></span><div class="ld-controls"><button class="ld-btn" type="button" id="ldhPrev">Anterior</button><span id="ldhPage" class="ld-muted"></span><button class="ld-btn" type="button" id="ldhNext">Siguiente</button></div></div>
      </div>`;
    // Reutiliza el botón ORIGINAL de Libro Diario, sin crear un botón duplicado.
    // El listener en captura detiene exclusivamente la alerta informativa vieja.
    const oldButton = view.querySelector('#ldImportInfo');
    const header = oldButton?.closest('.ld-card-title');
    if (!header) { console.warn('[Libro Diario histórico] No se encontró el encabezado de movimientos.'); return; }
    header.insertAdjacentElement('afterend', section);
    oldButton.textContent = 'Importar histórico';
    oldButton.setAttribute('aria-controls', 'ldhRoot');
    oldButton.title = 'Abrir el importador privado del Excel';
    oldButton.addEventListener('click', e => {
      e.preventDefault();
      e.stopImmediatePropagation();
      section.scrollIntoView({ behavior: 'smooth', block: 'center' });
      const picker = byId('ldhFile');
      if (picker) picker.focus({ preventScroll: true });
    }, true);
    byId('ldhFile').addEventListener('change', chooseFile);
    byId('ldhImport').addEventListener('click', upload);
    byId('ldhRefresh').addEventListener('click', refresh);
    byId('ldhSheet').addEventListener('change', async e => { state.tab = state.tabs.find(t => String(t.orden) === e.target.value); state.page = 1; await loadTab(); });
    byId('ldhMonth').addEventListener('change', e => { state.month = e.target.value; state.page = 1; drawRows(); });
    byId('ldhSearch').addEventListener('input', e => { state.search = e.target.value.toLocaleLowerCase('es-AR').trim(); state.page = 1; drawRows(); });
    byId('ldhPrev').addEventListener('click', () => { state.page = Math.max(1, state.page - 1); drawRows(); });
    byId('ldhNext').addEventListener('click', () => { state.page++; drawRows(); });
    refresh();
  }
  function info(msg, bad = false) {
    const el = byId('ldhMessage'); if (!el) return;
    el.textContent = msg; el.classList.toggle('ldh-error', !!bad);
  }
  async function owner() {
    const auth = await sb.auth.getUser();
    if (auth.error || !auth.data?.user) throw new Error('Iniciá sesión con la cuenta autorizada.');
    const uid = auth.data.user.id;
    const permission = await sb.from('libro_diario_accesos').select('user_id').eq('user_id', uid).eq('habilitado', true).maybeSingle();
    if (permission.error || !permission.data) throw new Error('Acceso privado no autorizado.');
    return uid;
  }
  async function chooseFile(ev) {
    state.local = null;
    const b = byId('ldhImport'); if (b) b.disabled = true;
    const file = ev.target.files?.[0]; if (!file) return;
    try {
      if (file.size > 6 * 1024 * 1024) throw new Error('El archivo excede el tamaño admitido.');
      const bytes = await file.arrayBuffer();
      if (!crypto?.subtle?.digest) throw new Error('Este navegador no permite verificar la integridad SHA-256. Probá desde la web HTTPS.');
      const digest = await crypto.subtle.digest('SHA-256', bytes);
      const checkSha = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
      if (checkSha !== expectedJsonSha) throw new Error('El contenido del archivo no coincide con la versión verificada.');
      const raw = JSON.parse(new TextDecoder().decode(bytes));
      if (raw.formato !== 'libro-diario-excel-archivo-v1' || !hex64.test(String(raw.sha256)) || raw.sha256 !== expectedSha) throw new Error('El archivo no coincide con el Excel histórico verificado.');
      if (raw.nombre_archivo !== 'LIBRO DIARIO.xlsx' || raw.hojas_total !== 22 || !Array.isArray(raw.hojas) || raw.hojas.length !== 22) throw new Error('La cantidad de hojas no coincide con la fuente verificada.');
      const n = raw.hojas.reduce((sum, sh) => sum + (Array.isArray(sh.filas) ? sh.filas.length : 0), 0);
      if (n !== 3985 || n !== raw.filas_total) throw new Error('El número de filas históricas no coincide con la fuente verificada.');
      const seen = new Set();
      for (let i = 0; i < raw.hojas.length; i++) {
        const sh = raw.hojas[i];
        if (!sh || typeof sh.nombre !== 'string' || !Array.isArray(sh.filas) || seen.has(sh.nombre) || sh.filas.some(r => !Number.isInteger(r.r) || r.r < 1 || !r.v || typeof r.v !== 'object')) throw new Error('Hay una hoja mal formada.');
        seen.add(sh.nombre);
      }
      state.local = raw; b.disabled = false;
      info(`Verificado: ${raw.hojas_total} hojas y ${n.toLocaleString('es-AR')} filas. Importación disponible (sin contabilizar importes).`);
    } catch (e) { info('Archivo no válido: ' + e.message, true); }
  }
  async function upload() {
    if (state.busy || !state.local) return;
    const doc = state.local;
    if (!confirm(`¿Importar las ${doc.hojas_total} hojas y ${doc.filas_total} filas originales a tu archivo privado? No se modificarán los saldos ni los movimientos operativos.`)) return;
    const btn = byId('ldhImport'); btn.disabled = true; state.busy = true;
    try {
      const uid = await owner();
      let found = await sb.from('libro_diario_fuentes_excel').select('id').eq('user_id', uid).eq('sha256', doc.sha256).maybeSingle();
      if (found.error) throw found.error;
      let sourceId = found.data?.id;
      if (!sourceId) {
        const add = await sb.from('libro_diario_fuentes_excel').insert({ user_id: uid, nombre_archivo: doc.nombre_archivo, sha256: doc.sha256, hojas_total: doc.hojas_total, filas_total: doc.filas_total, estado: 'EN_REVISION', observaciones: 'Fuente original preservada. Sin contabilizar; pendiente de conciliación.' }).select('id').single();
        if (add.error) throw add.error;
        sourceId = add.data.id;
      }
      for (let i = 0; i < doc.hojas.length; i++) {
        const sh = doc.hojas[i];
        info(`Guardando hoja ${i + 1} de ${doc.hojas.length}: ${sh.nombre}`);
        const up = await sb.from('libro_diario_fuentes_excel_hojas').upsert({ fuente_id: sourceId, user_id: uid, orden: i, hoja: sh.nombre, filas_total: sh.filas.length, filas_json: sh.filas }, { onConflict: 'fuente_id,orden' });
        if (up.error) throw new Error(`No se pudo importar ${sh.nombre}: ${up.error.message}`);
      }
      const check = await sb.from('libro_diario_fuentes_excel_hojas').select('orden,filas_total').eq('fuente_id', sourceId);
      if (check.error) throw check.error;
      const n = (check.data || []).reduce((a, x) => a + Number(x.filas_total), 0);
      if ((check.data || []).length !== 22 || n !== 3985) throw new Error(`Importación incompleta (${(check.data || []).length}/22 hojas, ${n}/3985 filas). Reintentá con el mismo archivo.`);
      info('Importación completa: 22 hojas, 3.985 filas. Todos los registros están en revisión; no se han contabilizado saldos ni movimientos.');
      state.local = null; byId('ldhFile').value = '';
      await refresh(false);
    } catch (e) {
      info(`Importación interrumpida: ${e.message}. Podés reintentar con el mismo archivo; se reutiliza la fuente existente.`, true);
    } finally { state.busy = false; btn.disabled = !state.local; }
  }
  async function refresh(withMessage = true) {
    const root = byId('ldhSaved'); if (!root) return;
    try {
      const uid = await owner();
      const list = await sb.from('libro_diario_fuentes_excel').select('id,sha256,nombre_archivo,hojas_total,filas_total,estado,created_at').eq('user_id', uid).order('created_at', { ascending: false });
      if (list.error) throw list.error;
      state.sources = list.data || [];
      if (!state.sources.length) { root.textContent = 'Todavía no hay históricos importados.'; byId('ldhViewer').style.display = 'none'; return; }
      const src = state.sources[0]; state.source = src;
      const tabs = await sb.from('libro_diario_fuentes_excel_hojas').select('orden,hoja,filas_total').eq('fuente_id', src.id).order('orden');
      if (tabs.error) throw tabs.error;
      state.tabs = tabs.data || [];
      const rows = state.tabs.reduce((n, t) => n + t.filas_total, 0);
      root.innerHTML = `<div class="ldh-source"><strong>${esc(src.nombre_archivo)}</strong> · ${state.tabs.length}/${src.hojas_total} hojas · ${rows.toLocaleString('es-AR')}/${Number(src.filas_total).toLocaleString('es-AR')} filas <span class="ldh-pill">${esc(src.estado)}</span></div>`;
      const selector = byId('ldhSheet');
      selector.innerHTML = state.tabs.map(t => `<option value="${t.orden}">${esc(t.hoja)} (${t.filas_total} filas)</option>`).join('');
      byId('ldhViewer').style.display = state.tabs.length ? '' : 'none';
      if (state.tabs.length) { state.tab = state.tabs.find(t => t.orden === state.tab?.orden) || state.tabs[0]; selector.value = String(state.tab.orden); await loadTab(); }
      if (withMessage) info('Histórico disponible para consulta. No modifica los saldos operativos del Libro Diario.');
    } catch (e) { info('No se pudo consultar el archivo histórico: ' + e.message, true); }
  }
  async function loadTab() {
    if (!state.source || !state.tab) return;
    try {
      const res = await sb.from('libro_diario_fuentes_excel_hojas').select('hoja,filas_json').eq('fuente_id', state.source.id).eq('orden', state.tab.orden).single();
      if (res.error) throw res.error;
      const rows = res.data.filas_json || [];
      const sheet = res.data.hoja;
      state.ledger = ['GARUPA', 'JARDIN', 'USD'].includes(sheet);
      state.rows = state.ledger ? ledgerRows(sheet, rows) : rows;
      state.page = 1;
      byId('ldhSheetInfo').textContent = state.ledger
        ? 'Movimientos fechados detectados para revisión. Los importes y saldos son los originales del Excel; no están contabilizados.'
        : 'Vista fiel de celdas originales por fila. Estas hojas mezclan saldos y gastos sin una fecha individual confirmada.';
      byId('ldhMonth').disabled = !state.ledger;
      drawRows();
    } catch (e) { info('No se pudo leer esta hoja: ' + e.message, true); }
  }
  function ledgerRows(sheet, rows) {
    const out = []; let d1 = '', d2 = '';
    for (const row of rows) {
      const v = row.v || {}, r = Number(row.r);
      if (sheet === 'GARUPA') {
        if (excelDay(v['0'])) d1 = excelDay(v['0']);
        if (excelDay(v['9'])) d2 = excelDay(v['9']);
        if (r > 2 && (validMoney(v['5']) > 0 || validMoney(v['6']) > 0)) out.push({ r, date: d1, desc: v['1'] || '', debit: validMoney(v['5']), credit: validMoney(v['6']), saldo: v['7'], group: 'Columna izquierda' });
        if (validMoney(v['14']) > 0 || validMoney(v['15']) > 0) out.push({ r, date: d2, desc: v['10'] || '', debit: validMoney(v['14']), credit: validMoney(v['15']), saldo: v['16'], group: 'Columna derecha' });
      } else {
        if (excelDay(v['0'])) d1 = excelDay(v['0']);
        if (validMoney(v['4']) > 0 || validMoney(v['5']) > 0) out.push({ r, date: d1, desc: v['1'] || '', debit: validMoney(v['4']), credit: validMoney(v['5']), saldo: v['6'], group: '' });
      }
    }
    return out.sort((a, b) => (a.date || '').localeCompare(b.date || '') || a.r - b.r);
  }
  function drawRows() {
    if (!byId('ldhRows')) return;
    const filtered = state.rows.filter(row => {
      const text = state.ledger ? [row.date, row.desc, row.debit, row.credit, row.saldo, row.group, row.r].join(' ') : [row.r, ...Object.values(row.v || {})].join(' ');
      if (state.search && !text.toLocaleLowerCase('es-AR').includes(state.search)) return false;
      return !state.ledger || !state.month || (row.date || '').startsWith(state.month);
    });
    const count = 35, pages = Math.max(1, Math.ceil(filtered.length / count));
    state.page = Math.min(Math.max(1, state.page), pages);
    const subset = filtered.slice((state.page - 1) * count, state.page * count);
    byId('ldhHeaders').innerHTML = state.ledger
      ? '<tr><th>Fila</th><th>Fecha</th><th>Detalle original</th><th>Ingreso</th><th>Egreso</th><th>Saldo anotado</th></tr>'
      : '<tr><th>Fila</th><th>Celdas originales y valores</th></tr>';
    byId('ldhRows').innerHTML = subset.map(r => state.ledger
      ? `<tr><td>${r.r}</td><td>${esc(r.date || 'Sin fecha')}</td><td>${esc(r.desc || 'Sin descripción')}${r.group ? `<small class="ld-muted ldh-block">${esc(r.group)}</small>` : ''}</td><td>${r.credit > 0 ? fmt(r.credit) : '—'}</td><td>${r.debit > 0 ? fmt(r.debit) : '—'}</td><td>${typeof r.saldo === 'number' ? fmt(r.saldo) : '—'}</td></tr>`
      : `<tr><td>${r.r}</td><td class="ldh-cells">${Object.entries(r.v || {}).map(([i, v]) => `<span><b>${col(i)}</b>: ${esc(String(v).slice(0, 300))}</span>`).join('')}</td></tr>`).join('') || `<tr><td colspan="${state.ledger ? 6 : 2}" class="ld-empty">No hay filas para este filtro.</td></tr>`;
    byId('ldhCount').textContent = `${filtered.length.toLocaleString('es-AR')} registros en la vista`;
    byId('ldhPage').textContent = `Página ${state.page} de ${pages}`;
    byId('ldhPrev').disabled = state.page <= 1;
    byId('ldhNext').disabled = state.page >= pages;
  }
  const view = byId('viewLibroDiario');
  if (view) { new MutationObserver(mount).observe(view, { childList: true }); mount(); }
  else document.addEventListener('DOMContentLoaded', () => { const el = byId('viewLibroDiario'); if (el) { new MutationObserver(mount).observe(el, { childList: true }); mount(); } });
})();
