/* Libro Diario: tablero histórico y edición de etiquetas de revisión.
 * No escribe en libro_diario_cuentas, libro_diario_movimientos ni tablas de alquileres.
 * Usa security_invoker views que respetan las políticas RLS de las tablas privadas.
 */
(function () {
  'use strict';
  if (typeof sb === 'undefined') return;

  const $ = (id) => document.getElementById(id);
  const safe = (x) => String(x == null ? '' : x).replace(/[&<>"']/g, ch => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
  const n = value => Number.isFinite(Number(value)) ? Number(value) : null;
  const sum = (arr, field) => arr.reduce((total, row) => total + (n(row[field]) ?? 0), 0);
  const fmt = (x, currency = 'ARS') => x == null ? '—' : new Intl.NumberFormat('es-AR', {
    style: 'currency', currency, maximumFractionDigits: 2, minimumFractionDigits: 2
  }).format(Number(x));
  const compact = x => new Intl.NumberFormat('es-AR', { notation: 'compact', maximumFractionDigits: 1 }).format(Number(x) || 0);
  const number = x => new Intl.NumberFormat('es-AR').format(x);
  const monthText = iso => {
    if (!/^\d{4}-\d{2}/.test(String(iso))) return 'Sin fecha';
    const [y, m] = iso.split('-').map(Number);
    return new Intl.DateTimeFormat('es-AR', {month: 'short', year: '2-digit'}).format(new Date(y, m - 1, 12)).replace('.', '');
  };
  const dayText = iso => /^\d{4}-\d{2}-\d{2}$/.test(String(iso)) ? iso.split('-').reverse().join('/') : '—';
  const lastDayOfMonth = (y, m) => new Date(y, m, 0).getDate();
  const monthsBetween = (start, end) => {
    const [y1, m1] = start.split('-').map(Number);
    const [y2, m2] = end.split('-').map(Number);
    if (![y1,m1,y2,m2].every(Number.isFinite) || y1 < 1900 || y2 > 2150) return [];
    const len = (y2-y1)*12+m2-m1+1;
    if (len < 1 || len > 360) return [];
    return Array.from({length:len},(_,i)=> {
      const d = new Date(y1, m1-1+i, 1);
      return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-01`;
    });
  };
  const sourceName = {
    GARUPA: 'GARUPA', JARDIN: 'JARDIN', USD: 'USD efectivo'
  };
  const viewState = { cache: null, loading: false, sequence: 0, userId: null, active: false };
  const groupMatches = (segment, group) => group === 'GARUPA' ? /^GARUPA_[AB]$/.test(segment) : segment === group;

  function range() {
    const month = $('ldMonth')?.value || `${new Date().getFullYear()}-${String(new Date().getMonth()+1).padStart(2,'0')}`;
    if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) return null;
    const [y, m] = month.split('-').map(Number);
    const kind = $('ldPeriod')?.value || 'mensual';
    if (kind === 'personalizado') {
      const from = $('ldFrom')?.value, to = $('ldTo')?.value;
      if (!/^\d{4}-\d{2}-\d{2}$/.test(from || '') || !/^\d{4}-\d{2}-\d{2}$/.test(to || '') || from > to) return null;
      return {start:from, end:to, customized:true};
    }
    let first = m-1, last=m-1;
    if (kind === 'bimestral') { first = Math.floor((m-1)/2)*2;last=first+1; }
    else if(kind === 'trimestral') { first = Math.floor((m-1)/3)*3;last=first+2; }
    else if(kind === 'anual') { first=0;last=11; }
    const sm = String(first+1).padStart(2,'0'), em = String(last+1).padStart(2,'0');
    return {start:`${y}-${sm}-01`,end:`${y}-${em}-${lastDayOfMonth(y,last+1)}`,customized:false};
  }

  function scaffold() {
    const root=document.createElement('section');
    root.id='ldcRoot'; root.className='ld-card ldc-root';
    root.setAttribute('aria-label','Conciliación del histórico de Libro Diario');
    root.innerHTML=`
      <header class="ldc-header">
        <div><span class="ldc-eyebrow">ARCHIVO HISTÓRICO · SUPABASE</span>
          <h2>Balance histórico y conciliación</h2>
          <p>Consultá los registros del Excel sin mezclarlos con tus cuentas y movimientos actuales.</p>
        </div><span class="ldc-tag">En revisión · No contabilizado</span>
      </header>
      <div class="ldc-explain"><strong>Información histórica.</strong> Las entradas y salidas incluyen posibles traspasos y fechas heredadas del Excel. No son necesariamente ingresos y gastos finales. Los cierres corresponden a fechas distintas y <strong>no se suman entre cuentas</strong>.</div>
      <div class="ldc-toolbar">
        <label class="ldc-field">Consultar libro
          <select id="ldcBook"><option value="GARUPA">GARUPA · ARS</option><option value="JARDIN">JARDIN · ARS</option><option value="USD">Dólares efectivo · USD</option></select>
        </label>
        <span class="ldc-period-text" id="ldcRange" aria-live="polite"></span>
        <button type="button" class="ld-btn" id="ldcReload">↻ Recargar histórico</button>
      </div>
      <div id="ldcFallback" class="ldc-fallback" role="status" hidden></div>
      <p id="ldcError" class="ldc-error" role="alert" hidden></p>
      <div class="ldc-kpis" id="ldcKpis" aria-live="polite">
        <div class="ldc-kpi"><span>Entradas registradas</span><strong id="ldcIn">—</strong><small>Del libro y período seleccionados</small></div>
        <div class="ldc-kpi"><span>Salidas registradas</span><strong id="ldcOut">—</strong><small>Pueden incluir traspasos</small></div>
        <div class="ldc-kpi"><span>Variación registrada</span><strong id="ldcDelta">—</strong><small>No es ganancia neta</small></div>
        <div class="ldc-kpi"><span>Movimientos revisados</span><strong id="ldcCount">—</strong><small id="ldcCountsNote">Filas del Excel</small></div>
      </div>
      <div class="ldc-grid">
        <div class="ldc-subcard"><div class="ldc-cardtitle"><h3>Evolución histórica</h3><span id="ldcChartNote">Entradas y salidas por mes</span></div><div class="ldc-chart" id="ldcChart"><div class="ldc-empty">Cargando datos…</div></div>
          <div class="ldc-legend"><span><i class="ldc-swatch ldc-green"></i> Entradas</span><span><i class="ldc-swatch ldc-red"></i> Salidas</span></div>
          <div id="ldcMonthlyTable" class="ldc-monthly"></div>
        </div>
        <div class="ldc-subcard"><div class="ldc-cardtitle"><h3>Últimos cierres del Excel</h3><span>Cortes históricos, no saldos de hoy</span></div><div id="ldcClosures"><div class="ldc-empty">Cargando cierres…</div></div></div>
      </div>
      <details class="ldc-details" id="ldcReview" open>
        <summary><span>Casos para revisar</span><small id="ldcReviewCount">Cargando…</small></summary>
        <p>Clasificá los casos con la información que tengas. Guardar una categoría u observación no cambia los importes, el Excel ni los balances. Las referencias de fechas son las del histórico.</p>
        <div id="ldcReviewList" aria-live="polite"></div>
      </details>
      <details class="ldc-details" id="ldcExpenses"><summary><span>Gastos de hojas bimestrales sin conciliar</span><small>Consultar clasificación original</small></summary>
        <p>Importes extraídos de otras hojas del Excel. Pueden superponerse con los libros fechados; no se agregan al balance.</p>
        <div id="ldcExpenseList"></div>
      </details>
    `;
    const anchor = $('viewLibroDiario')?.querySelector('.ld-duo');
    if (!anchor) return null;
    anchor.insertAdjacentElement('afterend',root);
    $('ldcBook').addEventListener('change', updatePeriod);
    $('ldcReload').addEventListener('click', () => fetchAll(true));
    ['ldPeriod','ldMonth','ldFrom','ldTo'].forEach(id=>$(id)?.addEventListener('change',updatePeriod));
    $('ldRefresh')?.addEventListener('click',()=>setTimeout(updatePeriod,0));
    return root;
  }

  function error(msg) {
    const box=$('ldcError'); if(!box)return;
    box.hidden=!msg;box.textContent=msg||'';
  }
  function resetForError(message) {
    ['ldcIn','ldcOut','ldcDelta','ldcCount'].forEach(id=>{if($(id))$(id).textContent='No disponible';});
    if($('ldcChart'))$('ldcChart').innerHTML='<div class="ldc-empty">No fue posible cargar los datos de conciliación.</div>';
    if($('ldcClosures'))$('ldcClosures').innerHTML='<div class="ldc-empty">No disponible</div>';
    if($('ldcExpenseList'))$('ldcExpenseList').innerHTML='No disponible';
    error(message);
  }

  async function ensureOwner() {
    const u=await sb.auth.getUser();
    if(u.error || !u.data?.user?.id) throw new Error('Tenés que iniciar sesión como el jefe.');
    const id=u.data.user.id;
    const a=await sb.from('libro_diario_accesos').select('user_id').eq('user_id',id).eq('habilitado',true).maybeSingle();
    if(a.error || !a.data) throw new Error('La cuenta no está habilitada para consultar Libro Diario.');
    viewState.userId=id;
    return id;
  }

  async function fetchAll(force=false) {
    if(viewState.loading || !$('ldcRoot'))return;
    viewState.loading=true;
    const reload=$('ldcReload'); if(reload)reload.disabled=true;
    error('');
    try {
      await ensureOwner();
      if(!viewState.cache || force){
        const reqs=[
          sb.from('libro_diario_conciliacion_cierres').select('segmento,moneda,desde,hasta,movimientos,filas_descuadradas,posibles_traspasos,saldo_final_excel,saldo_final_reconstruido,diferencia_final,estado_cierre').order('segmento'),
          sb.from('libro_diario_conciliacion_mensual').select('segmento,moneda,periodo,movimientos,fecha_heredada,diferencias,posibles_traspasos,entradas,salidas,variacion_caja_no_conciliada').order('periodo'),
          sb.from('libro_diario_conciliacion_gastos_resumen').select('rubro_preliminar,importes_identificados,importes_sin_detalle,suma_sin_conciliar')
        ];
        const results=await Promise.all(reqs);
        for(let i=0;i<results.length;i++)if(results[i].error)throw new Error(['Cierres','Movimientos mensuales','Gastos'][i]+': '+results[i].error.message);
        viewState.cache={closures:results[0].data||[],monthly:results[1].data||[],expenses:results[2].data||[]};
        if(!viewState.cache.closures.length)throw new Error('No aparecen cierres históricos autorizados en Supabase.');
      }
      updatePeriod();
      renderClosures();
      renderExpenses();
      await loadReviewCases();
    } catch(e) {
      viewState.cache=null;
      console.error('[Libro Diario conciliación]',e);
      resetForError('No se pudo consultar el histórico privado: '+(e?.message||'error desconocido')+'. Los saldos operativos no se modificaron.');
    } finally {viewState.loading=false;if(reload)reload.disabled=false;}
  }

  function renderClosures(){
    const root=$('ldcClosures'); if(!root||!viewState.cache)return;
    const closures=viewState.cache.closures;
    const toShow=[
      {label:'GARUPA',row:closures.find(x=>x.segmento==='GARUPA_B')},
      {label:'JARDIN',row:closures.find(x=>x.segmento==='JARDIN')},
      {label:'USD efectivo',row:closures.find(x=>x.segmento==='USD')}
    ];
    const primerTramo=closures.find(x=>x.segmento==='GARUPA_A');
    const saldoPrimerTramo=primerTramo?fmt(n(primerTramo.saldo_final_excel),'ARS'):'no disponible';
    root.innerHTML=toShow.map(({label,row})=> {
      if(!row) return `<div class="ldc-closure"><div><strong>${safe(label)}</strong><small>Sin cierre registrado</small></div><b>—</b></div>`;
      const diff=n(row.diferencia_final),isOk=row.estado_cierre==='CIERRE_CUADRA' && Math.abs(diff||0)<=0.01;
      return `<div class="ldc-closure ${isOk?'ldc-ok':'ldc-attention'}">
        <div><strong>${safe(label)}</strong><small>Último corte: ${dayText(row.hasta)} · ${number(row.movimientos||0)} movimientos</small>
          <span class="ldc-closure-state">${isOk?'Cierre cuadra':'Pendiente de conciliar'}</span></div>
        <div class="ldc-closure-values"><b>${fmt(n(row.saldo_final_excel),row.moneda)}</b>
        ${isOk?'':`<small>Diferencia: ${fmt(diff,row.moneda)}</small>`}</div>
      </div>`;
    }).join('')+`<p class="ldc-closure-foot">GARUPA incluye un tramo anterior (2024) con cierre de ${safe(saldoPrimerTramo)} que no se suma nuevamente. Estos cierres no equivalen a disponibilidad bancaria actual.</p>`;
  }

  const reviewLabels={TRANSFERENCIA:'Transferencia',AJUSTE:'Ajuste',GASTO:'Gasto',INGRESO:'Ingreso',OTRO:'Otro',PENDIENTE:'Pendiente de identificar'};
  async function loadReviewCases(){
    const list=$('ldcReviewList'),count=$('ldcReviewCount');
    if(!list || !count)return;
    try{
      const owner=await ensureOwner();
      const res=await sb.from('libro_diario_casos_revision').select('id,libro,referencia,fecha_referencial,importe,moneda,evidencia,categoria_sugerida,categoria,observacion,revisado').eq('user_id',owner).order('fecha_referencial').order('codigo');
      if(res.error)throw res.error;
      if(!list.isConnected || viewState.userId!==owner)return;
      const rows=res.data||[];
      count.textContent=`${rows.filter(r=>r.revisado).length} de ${rows.length} revisados`;
      if(!rows.length){list.textContent='No hay casos registrados.';return;}
      list.innerHTML=rows.map((r,i)=>`<article class="ldc-review-case" data-case="${i}">
        <div class="ldc-review-top"><div><strong>${safe(r.libro)} · ${safe(r.referencia)}</strong><small>${safe(dayText(r.fecha_referencial))} · Sugerencia: ${safe(reviewLabels[r.categoria_sugerida]||r.categoria_sugerida)}</small></div><div><strong>${safe(fmt(r.importe,r.moneda))}</strong><small class="ldc-review-status">${r.revisado?'Revisado':'Por revisar'}</small></div></div>
        <p class="ldc-evidence">${safe(r.evidencia)}</p>
        <div class="ldc-review-fields"><label>Categoría<select class="ldc-review-category">${Object.entries(reviewLabels).map(([k,v])=>`<option value="${k}"${r.categoria===k?' selected':''}>${safe(v)}</option>`).join('')}</select></label><label>Observación<textarea class="ldc-review-note" maxlength="2000" rows="2">${safe(r.observacion)}</textarea></label></div>
        <div class="ldc-review-actions"><label><input type="checkbox" class="ldc-review-checked"${r.revisado?' checked':''}> Marcar como revisado</label><button type="button" class="ld-btn ldc-review-save">Guardar cambios</button><span class="ldc-review-message" role="status"></span></div>
      </article>`).join('');
      list.querySelectorAll('[data-case]').forEach(el=>{
        const row=rows[Number(el.dataset.case)];const button=el.querySelector('.ldc-review-save'), msg=el.querySelector('.ldc-review-message');
        button.addEventListener('click',async()=>{
          const cat=el.querySelector('.ldc-review-category'),note=el.querySelector('.ldc-review-note'),checked=el.querySelector('.ldc-review-checked');
          const changes={categoria:cat.value,observacion:note.value,revisado:checked.checked};
          if(!Object.prototype.hasOwnProperty.call(reviewLabels,changes.categoria))return;
          button.disabled=cat.disabled=note.disabled=checked.disabled=true;msg.textContent='Guardando…';
          try{
            if(await ensureOwner()!==owner)throw new Error('La sesión cambió. Volvé a cargar el módulo.');
            const result=await sb.from('libro_diario_casos_revision').update(changes).eq('id',row.id).eq('user_id',owner).select('id').single();
            if(result.error||!result.data)throw result.error||new Error('No se confirmó el guardado.');
            if(!el.isConnected || viewState.userId!==owner)return;
            Object.assign(row,changes);
            count.textContent=`${rows.filter(r=>r.revisado).length} de ${rows.length} revisados`;
            el.querySelector('.ldc-review-status').textContent=row.revisado?'Revisado':'Por revisar';
            msg.textContent='Cambios guardados.';
          }catch(e){msg.textContent='No se guardó: '+(e?.message||'error');}
          finally{button.disabled=cat.disabled=note.disabled=checked.disabled=false;}
        });
      });
    }catch(e){list.textContent='No se pudieron cargar los casos: '+(e?.message||'error');count.textContent='No disponible';}
  }

  function renderExpenses(){
    const el=$('ldcExpenseList');if(!el||!viewState.cache)return;
    const groups=new Map();
    for(const r of viewState.cache.expenses){
      const key=r.rubro_preliminar||'OTROS',g=groups.get(key)||{count:0,total:0,missing:0};
      g.count+=n(r.importes_identificados)||0;
      g.total+=n(r.suma_sin_conciliar)||0;
      g.missing+=n(r.importes_sin_detalle)||0;
      groups.set(key,g);
    }
    const labels={BANCOS:'Bancos',EFECTIVO:'Efectivo',MERCADO_PAGO:'Mercado Pago',SALADITA:'Saladita (solo referencia histórica)',VTV:'VTV (solo referencia histórica)'};
    if(!groups.size){el.innerHTML='<div class="ldc-empty">Todavía no hay gastos históricos clasificados.</div>';return;}
    el.innerHTML=`<div class="ldc-expense-table"><div class="ldc-expense-row ldc-expense-head"><span>Rubro histórico</span><span>Partidas</span><span>Importe sin conciliar</span></div>${[...groups].sort((a,b)=>b[1].count-a[1].count).map(([key,g])=>`<div class="ldc-expense-row"><span>${safe(labels[key]||key)}<small>${number(g.missing)} sin detalle individual</small></span><span>${number(g.count)}</span><strong>${fmt(g.total)}</strong></div>`).join('')}</div>`;
  }

  async function fetchCustomDaily(start,end,book,sequence) {
    const segments=book==='GARUPA'?['GARUPA_A','GARUPA_B']:[book];
    const rows=[],limit=750,ceiling=10000;
    for(let i=0;i<ceiling/limit;i++){
      const resp=await sb.from('libro_diario_conciliacion_lineas')
        .select('fecha_referencial,segmento,entrada,salida,tipo_fecha,estado_conciliacion,clasificacion_preliminar')
        .in('segmento',segments).eq('tipo_registro','MOVIMIENTO')
        .gte('fecha_referencial',start).lte('fecha_referencial',end)
        .order('id',{ascending:true}).range(i*limit,i*limit+limit-1);
      if(resp.error)throw resp.error;
      if(sequence!==viewState.sequence)return null;
      rows.push(...(resp.data||[]));
      if((resp.data||[]).length<limit)break;
      if(rows.length>=ceiling)throw new Error('Demasiados registros para mostrar el intervalo exacto. Reducí el rango.');
    }
    const months=new Map();
    for(const r of rows){
      const period=String(r.fecha_referencial||'').slice(0,7)+'-01';
      const x=months.get(period)||{periodo:period,entradas:0,salidas:0,movimientos:0,fecha_heredada:0,diferencias:0,posibles_traspasos:0};
      x.entradas+=(n(r.entrada)||0);x.salidas+=(n(r.salida)||0);x.movimientos++;
      if(r.tipo_fecha==='HEREDADA')x.fecha_heredada++;
      if(r.estado_conciliacion==='DIFERENCIA')x.diferencias++;
      if(r.clasificacion_preliminar==='POSIBLE_TRASPASO_O_CAMBIO')x.posibles_traspasos++;
      months.set(period,x);
    }
    return [...months.values()].sort((a,b)=>a.periodo.localeCompare(b.periodo));
  }

  function displayPeriod(rows,r,book,usingFallbackFrom=null) {
    if(!$('ldcRoot') || !viewState.cache)return;
    const currency=book==='USD'?'USD':'ARS';
    const count=sum(rows,'movimientos');
    const totalIn=sum(rows,'entradas'),totalOut=sum(rows,'salidas');
    const inherited=sum(rows,'fecha_heredada'),diff=sum(rows,'diferencias'),potential=sum(rows,'posibles_traspasos');
    $('ldcRange').textContent=`${dayText(r.start)} — ${dayText(r.end)} · ${sourceName[book]}${usingFallbackFrom ? ' · Último histórico disponible' : ''}`;
    const fallbackNotice=$('ldcFallback');
    if(fallbackNotice){
      fallbackNotice.hidden=!usingFallbackFrom;
      if(usingFallbackFrom){
        fallbackNotice.textContent=`El libro ${sourceName[book]} no tiene movimientos entre ${dayText(usingFallbackFrom.start)} y ${dayText(usingFallbackFrom.end)}. Se muestran los meses históricos más recientes (${dayText(r.start)} a ${dayText(r.end)}), sin modificar el filtro principal ni los saldos operativos.`;
      }else fallbackNotice.textContent='';
    }
    $('ldcIn').textContent=rows.length?fmt(totalIn,currency):'—';
    $('ldcOut').textContent=rows.length?fmt(totalOut,currency):'—';
    $('ldcDelta').textContent=rows.length?fmt(totalIn-totalOut,currency):'—';
    $('ldcCount').textContent=rows.length?number(count):'—';
    $('ldcCountsNote').textContent=rows.length?`${number(diff)} diferencias · ${number(inherited)} fechas heredadas · ${number(potential)} posibles traspasos`:'Sin movimientos en el período seleccionado';
    const periods=monthsBetween(r.start,r.end);
    // GARUPA_A y GARUPA_B se solapan en junio de 2024: acumular ambos en el mismo mes.
    const rowsMap=new Map();
    for(const x of rows){
      const val=rowsMap.get(x.periodo)||{periodo:x.periodo,entradas:0,salidas:0,movimientos:0};
      val.entradas+=(n(x.entradas)||0); val.salidas+=(n(x.salidas)||0);
      val.movimientos+=(n(x.movimientos)||0);
      rowsMap.set(x.periodo,val);
    }
    const shown=periods.length>18?periods.slice(-18):periods;
    const plotted=shown.map(periodo=>({periodo,entradas:0,salidas:0,...rowsMap.get(periodo)}));
    $('ldcChartNote').textContent=periods.length>18?'Últimos 18 meses (cifras anteriores incluidas en indicadores)':'Entradas y salidas del Excel por mes';
    if(!rows.length){
      $('ldcChart').innerHTML='<div class="ldc-empty">No hay movimientos históricos en este período. Probá cambiar el mes o el libro.</div>';
      $('ldcMonthlyTable').innerHTML='';
    } else {
      const max=Math.max(1,...plotted.flatMap(x=>[n(x.entradas)||0,n(x.salidas)||0]));
      $('ldcChart').innerHTML=plotted.map(x=> {
        const incoming=Math.max(0,Math.round(100*(n(x.entradas)||0)/max));
        const outgoing=Math.max(0,Math.round(100*(n(x.salidas)||0)/max));
        const label=monthText(x.periodo);
        return `<div class="ldc-bar-group" aria-label="${safe(label)}: entradas ${safe(fmt(n(x.entradas)||0,currency))}; salidas ${safe(fmt(n(x.salidas)||0,currency))}">
          <div class="ldc-bar-pair"><span class="ldc-bar ldc-bar-in" style="height:${incoming}%" title="Entradas ${safe(fmt(n(x.entradas)||0,currency))}"></span><span class="ldc-bar ldc-bar-out" style="height:${outgoing}%" title="Salidas ${safe(fmt(n(x.salidas)||0,currency))}"></span></div><span class="ldc-bar-label">${safe(label)}</span></div>`;
      }).join('');
      $('ldcMonthlyTable').innerHTML=`<details><summary>Ver importes por mes</summary><div class="ldc-table-scroll"><table><thead><tr><th>Mes</th><th>Entradas</th><th>Salidas</th><th>Registros</th></tr></thead><tbody>${shown.map(period=>{
        const row=rowsMap.get(period)||{};
        return `<tr><td>${safe(monthText(period))}</td><td>${fmt(n(row.entradas)||0,currency)}</td><td>${fmt(n(row.salidas)||0,currency)}</td><td>${number(n(row.movimientos)||0)}</td></tr>`;
      }).join('')}</tbody></table></div></details>`;
    }
  }

  async function updatePeriod() {
    if(!viewState.cache||!$('ldcRoot'))return;
    const seq=++viewState.sequence;
    const selected=$('ldcBook')?.value||'GARUPA';
    const r=range();
    if(!r){error('El intervalo de fechas no es válido. Revisá los filtros de período.');return;}
    error('');
    const allMonths=viewState.cache.monthly
      .filter(x=>groupMatches(x.segmento,selected))
      .sort((a,b)=>a.periodo.localeCompare(b.periodo));
    let rows=allMonths.filter(x=>x.periodo>=r.start.slice(0,7)+'-01'&&x.periodo<=r.end.slice(0,7)+'-01');
    let shownRange=r, fallbackFrom=null;
    // Cada libro tiene un cierre distinto. Si el filtro global no contiene
    // movimientos, NO usar ceros ni fingir que el saldo es actual:
    // mostrar el tramo HISTORICO del libro y etiquetarlo explícitamente.
    // Intervalos personalizados se respetan exactamente, sin sustituir fechas.
    if(!r.customized && !rows.length && allMonths.length){
      const earliest=allMonths[0].periodo;
      const latest=allMonths[allMonths.length-1].periodo;
      const [y,m]=latest.split('-').map(Number);
      const d=new Date(y,m-12,1); // último mes incluido + 11 anteriores
      const candidate=`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-01`;
      const start=candidate>earliest?candidate:earliest;
      const end=`${y}-${String(m).padStart(2,'0')}-${lastDayOfMonth(y,m)}`;
      shownRange={start,end,customized:false};
      rows=allMonths.filter(x=>x.periodo>=start&&x.periodo<=latest);
      fallbackFrom=r;
    }
    const needDays=r.customized && (!r.start.endsWith('-01') || Number(r.end.slice(-2))!==lastDayOfMonth(Number(r.end.slice(0,4)),Number(r.end.slice(5,7))));
    if(needDays){
      $('ldcRange').textContent='Consultando intervalo personalizado exacto…';
      try{rows=await fetchCustomDaily(r.start,r.end,selected,seq);}
      catch(e){if(seq===viewState.sequence)resetForError('No se pudieron cargar las fechas personalizadas: '+(e?.message||'error'));return;}
    }
    if(seq!==viewState.sequence||!rows)return;
    displayPeriod(rows,shownRange,selected,fallbackFrom);
  }

  // Compactar el módulo histórico YA IMPORTADO, sin borrar registros.
  // Se conserva el importador original, accesible al pulsar "Importar otro".
  function upgradeHistoricViewer() {
    const root=$('ldhRoot');
    if(!root)return;
    if(!root.querySelector('#ldhCompactActions')){
      const header=root.querySelector('.ldh-header');
      if(!header)return;
      const actions=document.createElement('div');
      actions.id='ldhCompactActions';
      actions.className='ldh-compact-actions';
      actions.innerHTML='<button type="button" class="ld-btn" id="ldhOpenViewer">Consultar hojas</button><button type="button" class="ld-btn" id="ldhOpenUpload">Importar otro archivo</button>';
      header.appendChild(actions);
      $('ldhOpenViewer')?.addEventListener('click',()=>{
        const opened=root.classList.toggle('ldh-viewer-open');
        $('ldhOpenViewer').textContent=opened?'Ocultar hojas':'Consultar hojas';
      });
      $('ldhOpenUpload')?.addEventListener('click',()=>{
        const opened=root.classList.toggle('ldh-upload-open');
        $('ldhOpenUpload').textContent=opened?'Cerrar importador':'Importar otro archivo';
        if(opened){root.querySelector('#ldhFile')?.focus({preventScroll:true});}
      });
      const saved=root.querySelector('#ldhSaved');
      if(saved){
        const watchSaved=new MutationObserver(()=>syncHistoricViewer(root));
        watchSaved.observe(saved,{childList:true,subtree:false});
      }
    }
    syncHistoricViewer(root);
  }
  function syncHistoricViewer(root){
    const imported=!!root.querySelector('#ldhSaved .ldh-source');
    root.classList.toggle('ldh-has-data',imported);
    const actions=$('ldhCompactActions');
    if(actions) actions.hidden=!imported;
    if(!imported){root.classList.remove('ldh-viewer-open');}
  }
  // El botón de importación existente tiene un listener propio de captura.
  // La captura de document ocurre antes, para desplegar el selector oculto.
  document.addEventListener('click', e=>{
    if(!e.target.closest?.('#ldImportInfo'))return;
    const root=$('ldhRoot');
    if(root?.classList.contains('ldh-has-data')){
      root.classList.add('ldh-upload-open');
      const b=$('ldhOpenUpload');if(b)b.textContent='Cerrar importador';
    }
  },true);

  function mount() {
    const view=$('viewLibroDiario');
    if(!view || !view.querySelector('#ldNewMove') || view.querySelector('#ldcRoot'))return;
    if(!scaffold())return;
    fetchAll();
  }
  function attach() {
    const view=$('viewLibroDiario');
    if(view){
      new MutationObserver(mount).observe(view,{childList:true});
      const historicObserver=new MutationObserver(upgradeHistoricViewer);
      historicObserver.observe(view,{childList:true,subtree:true});
      upgradeHistoricViewer();
      mount();
      return;
    }
    const host=$('app');
    if(host){
      const observer=new MutationObserver(()=>{if($('viewLibroDiario')){observer.disconnect();attach();}});
      observer.observe(host,{childList:true});
    }
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',attach,{once:true});
  else attach();
  sb.auth.onAuthStateChange((event)=>{
    if(event==='SIGNED_OUT'){viewState.cache=null;viewState.userId=null;viewState.sequence++;if($('ldcReviewList'))$('ldcReviewList').textContent='';if($('ldcReviewCount'))$('ldcReviewCount').textContent='';}
  });
})();
