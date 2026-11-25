/* Libro Diario - módulo privado. No interfiere con Recibos, Balance o medios de pago. */
(function(){
  'use strict';
  if (typeof sb === 'undefined' || typeof window.setRoute !== 'function') { console.warn('[Libro Diario] Frontend incompatible'); return; }
  const data={uid:null,granted:false,ready:false,accounts:[],moves:[],loading:false,page:1,editing:null,history:[],historyError:null};
  const byId=id=>document.getElementById(id);
  const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const money=(n,c='ARS')=>new Intl.NumberFormat('es-AR',{style:'currency',currency:c,minimumFractionDigits:2,maximumFractionDigits:2}).format(Number(n)||0);
  const isoDate=d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
  const parseDate=s=>{const [y,m,d]=String(s).split('-').map(Number);return new Date(y,m-1,d||1);};
  const fmtDay=s=>String(s||'').split('-').reverse().join('/');
  const currentDate=new Date();
  const today=isoDate(currentDate);
  const initialMonth=today.slice(0,7);
  const allowedTypes=['INGRESO','EGRESO','TRANSFERENCIA'];
  const oldSetRoute=window.setRoute;
  const oldApplyRoleUI=window.applyRoleUI;
  const nav=document.createElement('button');
  nav.type='button';nav.className='sb-item';nav.dataset.route='libro-diario';nav.title='Libro Diario · Privado';
  nav.setAttribute('aria-label','Libro Diario');nav.hidden=true;nav.style.display='none';
  nav.innerHTML='<span class="sb-item-icon" style="font-size:19px">▤</span><span class="sb-item-label">Libro Diario</span><span aria-hidden="true" style="margin-left:auto;font-size:11px">🔒</span>';
  nav.addEventListener('click',()=>window.setRoute('libro-diario'));
  const anchor=document.querySelector('#appSidebar .sb-item[data-route="balance-real"]')||document.querySelector('.sb-nav .sb-item[data-route="balance-real"]');
  if(anchor)anchor.insertAdjacentElement('afterend',nav);else document.querySelector('.sb-nav')?.append(nav);
  const app=byId('app');if(!app)return;
  const view=document.createElement('section');view.id='viewLibroDiario';view.style.display='none';
  app.append(view);
  // `user` en la app es una variable lexical global, no necesariamente window.user.
  function currentUserId(){try{return typeof user!=='undefined'&&user?.id||null;}catch(_){return null;}}
  function access(){return !!(data.granted&&data.uid&&currentUserId()===data.uid&&typeof isJefe==='function'&&isJefe());}
  function updateNav(){nav.hidden=!access();nav.style.display=access()?'':'none';nav.tabIndex=access()?0:-1;}
  window.applyRoleUI=function(...args){const result=oldApplyRoleUI.apply(this,args);updateNav();return result;};
  window.setRoute=function(next){
    if(next!=='libro-diario'){
      view.style.display='none';
      return oldSetRoute.call(this,next);
    }
    if(!access()){console.warn('[Libro Diario] Acceso denegado.');return oldSetRoute.call(this,getDefaultRouteForRole());}
    if(route==='libro-diario'&&view.style.display==='block'&&byId('ldNewMove'))return;
    route='libro-diario';
    document.querySelectorAll('#app > section[id^="view"]').forEach(el=>el.style.display='none');
    view.style.display='block';
    document.querySelectorAll('.sb-item,.mobile-nav-item').forEach(el=>el.classList.toggle('active',el.dataset.route==='libro-diario'));
    if(typeof saveCurrentRoute==='function')saveCurrentRoute('libro-diario');
    if(typeof updateTopSearchUI==='function')updateTopSearchUI();
    if(typeof closeSidebarIfMobile==='function')closeSidebarIfMobile();
    renderScaffold();
    refreshData();
  };
  let permissionRequest=null;
  let permissionEpoch=0;
  function resetPrivateView(){
    permissionEpoch++;
    data.uid=null;data.granted=false;data.ready=false;
    data.accounts=[];data.moves=[];data.history=[];data.historyError=null;data.editing=null;data.loading=false;
    view.style.display='none';view.replaceChildren();updateNav();
  }
  async function refreshPermission(){
    const uid=currentUserId();
    if(!uid)return false;
    if(permissionRequest?.uid===uid&&permissionRequest.epoch===permissionEpoch)return permissionRequest.promise;
    const epoch=permissionEpoch;
    const promise=(async()=>{
      try{
        const r=await sb.auth.getUser();
        if(r.error)throw r.error;
        if(epoch!==permissionEpoch||currentUserId()!==uid)return false;
        if(r.data?.user?.id!==uid){resetPrivateView();if(route==='libro-diario')oldSetRoute(getDefaultRouteForRole());return false;}
        const {data:entry,error}=await sb.from('libro_diario_accesos').select('user_id').eq('user_id',uid).eq('habilitado',true).maybeSingle();
        if(error)throw error;
        if(epoch!==permissionEpoch||currentUserId()!==uid)return false;
        data.uid=uid;data.granted=!!entry;data.ready=true;updateNav();
        if(!access()&&route==='libro-diario'){resetPrivateView();oldSetRoute(getDefaultRouteForRole());}
        return access();
      }catch(e){
        // A transient network error does not revoke a previously verified permission.
        // Actual reads/writes remain protected by RLS; a different user is never accepted.
        console.warn('[Libro Diario] Permiso no disponible',e?.message||e);
        return epoch===permissionEpoch&&access();
      }
    })();
    permissionRequest={uid,epoch,promise};
    try{return await promise;}finally{if(permissionRequest?.promise===promise)permissionRequest=null;}
  }
  window.gaLibroDiarioCanRestore=refreshPermission;
  sb.auth.onAuthStateChange((event,session)=>{
    if(event==='SIGNED_OUT'||event==='PASSWORD_RECOVERY'||(data.uid&&session?.user?.id!==data.uid)){resetPrivateView();return;}
    setTimeout(()=>refreshPermission(),0);
  });
  // The host init loads the role before restoring any private route.
  document.addEventListener('DOMContentLoaded',()=>setTimeout(refreshPermission,0),{once:true});

  function getRange(){
    const period=byId('ldPeriod')?.value||'bimestral';
    const m=byId('ldMonth')?.value||initialMonth;
    const [year,mon]=m.split('-').map(Number);let first=mon-1,last=mon-1;
    if(period==='bimestral'){first=Math.floor((mon-1)/2)*2;last=first+1;}
    if(period==='trimestral'){first=Math.floor((mon-1)/3)*3;last=first+2;}
    if(period==='anual'){first=0;last=11;}
    if(period==='personalizado'){
      return {start:byId('ldFrom')?.value||today,end:byId('ldTo')?.value||today};
    }
    return {start:isoDate(new Date(year,first,1)),end:isoDate(new Date(year,last+1,0))};
  }
  function renderScaffold(){
    view.innerHTML=`
      <div class="ld-head"><div><span class="ld-eyebrow">Área financiera privada · Solo jefe</span><h1>Libro Diario</h1><div class="ld-muted">Tus cuentas, saldos y movimientos en un único lugar. Independiente de alquileres.</div></div>
      <div class="ld-controls"><button class="ld-btn" type="button" id="ldNewAccount">＋ Cuenta</button><button class="ld-btn ld-primary" type="button" id="ldNewMove">＋ Nuevo movimiento</button></div></div>
      <div class="ld-period"><div class="ld-field"><label for="ldPeriod">Período</label><select id="ldPeriod"><option value="mensual">Mensual</option><option value="bimestral" selected>Bimestral</option><option value="trimestral">Trimestral</option><option value="anual">Anual</option><option value="personalizado">Personalizado</option></select></div>
      <div class="ld-field"><label for="ldMonth">Mes de referencia</label><input id="ldMonth" type="month" value="${initialMonth}"></div>
      <div id="ldCustom" class="ld-custom"><div class="ld-field"><label for="ldFrom">Desde</label><input id="ldFrom" type="date" value="${today}"></div><div class="ld-field"><label for="ldTo">Hasta</label><input id="ldTo" type="date" value="${today}"></div></div>
      <button class="ld-btn" type="button" id="ldRefresh">↻ Actualizar</button><span id="ldDates" class="ld-muted"></span></div>
      <div id="ldAlert" class="ld-alert" hidden></div>
      <div class="ld-kpis"><div class="ld-kpi"><span class="ld-kpi-icon">▤</span><span class="ld-kpi-label">Saldo general · ARS</span><strong id="ldBalance">—</strong><div class="ld-muted">Saldo operativo al cierre del período</div></div>
      <div class="ld-kpi ld-in"><span class="ld-kpi-icon">↗</span><span class="ld-kpi-label">Ingresos nuevos · ARS</span><strong id="ldIncome">—</strong><div class="ld-muted">Operativos desde la apertura; excluye traspasos</div></div>
      <div class="ld-kpi ld-out"><span class="ld-kpi-icon">↘</span><span class="ld-kpi-label">Gastos nuevos · ARS</span><strong id="ldExpense">—</strong><div class="ld-muted">Egresos operativos del período</div></div>
      <div class="ld-kpi"><span class="ld-kpi-icon">＄</span><span class="ld-kpi-label">Saldo general · USD</span><strong id="ldUsd">—</strong><div class="ld-muted">Sin convertir a pesos</div></div></div>
      <div class="ld-duo"><div class="ld-card"><div class="ld-card-title"><div><h2>Evolución del período</h2><div class="ld-muted">Movimientos nuevos · ARS (no incluye el Excel histórico)</div></div></div><div class="ld-bars" id="ldChart"><div class="ld-empty">Preparando gráfico…</div></div><div class="ld-legend"><span><b></b>Ingresos nuevos</span><span><b class="eg"></b>Gastos nuevos</span></div>
      <div style="margin-top:20px;border-top:1px solid #e5eaf1;padding-top:16px"><div class="ld-card-title"><div><h2>Movimientos históricos del período</h2><div class="ld-muted">Entradas y salidas del Excel hasta el cierre del 25/11/2026. Pueden incluir traspasos.</div></div></div>
      <div class="ld-field"><label for="ldHistBook">Libro histórico</label><select id="ldHistBook"><option value="GARUPA">GARUPA · ARS</option><option value="JARDIN">JARDIN · ARS</option><option value="USD">USD · histórico</option></select></div>
      <div id="ldHistSummary" class="ld-muted" aria-live="polite" style="margin-top:10px"></div><div id="ldHistChart" class="ld-bars"><div class="ld-empty">Cargando histórico…</div></div><div class="ld-legend"><span><b></b>Entradas del Excel</span><span><b class="eg"></b>Salidas del Excel</span></div></div></div>
      <div class="ld-card"><div class="ld-card-title"><div><h2>Cuentas y saldos</h2><div class="ld-muted">Bancos, cajas, Mercado Pago, USD y plazos fijos</div></div></div><div id="ldAccounts"><div class="ld-empty">Preparando cuentas…</div></div></div></div>
      <div class="ld-card"><div class="ld-card-title"><div><h2>Movimientos del libro</h2><div class="ld-muted">Editarás operaciones sin perder el historial de auditoría</div></div><button type="button" class="ld-btn" id="ldImportInfo">ⓘ Importación histórica</button></div>
      <div class="ld-filters"><input id="ldQuery" placeholder="Buscar detalle o categoría…" aria-label="Buscar movimiento"><select id="ldAccountFilter" aria-label="Filtrar cuenta"><option value="">Todas las cuentas</option></select><select id="ldTypeFilter" aria-label="Filtrar tipo"><option value="">Todos los movimientos</option><option value="INGRESO">Ingresos</option><option value="EGRESO">Egresos</option><option value="TRANSFERENCIA">Transferencias</option></select></div>
      <div class="ld-table-scroll"><table><thead><tr><th>Fecha</th><th>Detalle</th><th>Cuenta</th><th>Categoría</th><th>Tipo</th><th>Importe</th><th></th></tr></thead><tbody id="ldRows"><tr><td colspan="7" class="ld-empty">Cargando movimientos…</td></tr></tbody></table></div>
      <div class="ld-foot"><span id="ldCount" class="ld-muted"></span><div class="ld-controls"><button class="ld-btn" id="ldPrev" type="button">Anterior</button><span id="ldPage" class="ld-muted"></span><button class="ld-btn" id="ldNext" type="button">Siguiente</button></div></div></div>
      <div id="ldModalRoot"></div>`;
    byId('ldNewAccount').addEventListener('click',()=>openAccountForm());
    byId('ldNewMove').addEventListener('click',()=>openMoveForm());
    byId('ldImportInfo').addEventListener('click',()=>alert('El Excel histórico tiene 22 hojas con resúmenes, gastos y saldos que pueden superponerse. Se importará después de conciliar las filas, con fuente identificada y sin duplicados. Esta versión NO importa ni modifica el Excel.'));
    byId('ldRefresh').addEventListener('click',refreshData);
    byId('ldHistBook').addEventListener('change',drawHistory);
    byId('ldPeriod').addEventListener('change',()=>{byId('ldCustom').classList.toggle('ld-visible',byId('ldPeriod').value==='personalizado');refreshData();});
    ['ldMonth','ldFrom','ldTo'].forEach(id=>byId(id).addEventListener('change',refreshData));
    ['ldQuery','ldAccountFilter','ldTypeFilter'].forEach(id=>byId(id).addEventListener(id==='ldQuery'?'input':'change',()=>{data.page=1;drawTable();}));
    byId('ldPrev').addEventListener('click',()=>{data.page=Math.max(1,data.page-1);drawTable();});
    byId('ldNext').addEventListener('click',()=>{data.page++;drawTable();});
  }
  function showError(msg){const el=byId('ldAlert');if(!el)return;el.hidden=!msg;el.textContent=msg||'';}
  async function fetchEveryMove(end){
    const out=[];const perPage=750;const hardLimit=50000;
    for(let p=0;p<hardLimit/perPage;p++){
      const lo=p*perPage;
      const {data:rows,error}=await sb.from('libro_diario_movimientos')
        .select('id,user_id,fecha,tipo,cuenta_id,cuenta_destino_id,categoria,detalle,importe,origen,anulado')
        .eq('anulado',false).lte('fecha',end).order('fecha',{ascending:false}).order('id',{ascending:true}).range(lo,lo+perPage-1);
      if(error)throw error;
      out.push(...(rows||[]));
      if((rows||[]).length<perPage)return out;
    }
    throw new Error('Superaste 50.000 movimientos. El panel no mostrará totales parciales: se requiere paginación de servidor.');
  }
  // Los movimientos anteriores al corte se consultan exclusivamente como histórico.
  async function fetchHistory(start,end,uid){
    const until=end<'2026-11-25'?end:'2026-11-25';
    if(start>until)return [];
    const src=await sb.from('libro_diario_fuente_vigente').select('fuente_id').eq('user_id',uid).maybeSingle();
    if(src.error)throw src.error;
    if(!src.data)return [];
    const out=[],size=750;
    for(let i=0;i<40;i++){
      const result=await sb.from('libro_diario_conciliacion_lineas').select('segmento,fecha_referencial,entrada,salida').eq('fuente_id',src.data.fuente_id).eq('user_id',uid).eq('tipo_registro','MOVIMIENTO').gte('fecha_referencial',start).lte('fecha_referencial',until).order('id',{ascending:true}).range(i*size,(i+1)*size-1);
      if(result.error)throw result.error;
      out.push(...(result.data||[]));
      if((result.data||[]).length<size)return out;
    }
    throw new Error('El histórico excede el límite de consulta. Reducí el intervalo.');
  }
  async function refreshData(){
    if(!access()||data.loading||!byId('ldBalance'))return;
    const {start,end}=getRange();
    if(start>end){showError('La fecha inicial no puede ser posterior a la final.');return;}
    const loadEpoch=permissionEpoch,uid=data.uid;
    data.loading=true;showError('');byId('ldDates').textContent=`${fmtDay(start)} — ${fmtDay(end)}`;
    try{
      const {data:accounts,error}=await sb.from('libro_diario_cuentas').select('id,user_id,nombre,tipo,moneda,saldo_inicial,fecha_saldo_inicial,activa').eq('activa',true).order('nombre');
      if(error)throw error;
      if(loadEpoch!==permissionEpoch||!access()||data.uid!==uid)return;
      const [moves,history]=await Promise.all([fetchEveryMove(end),fetchHistory(start,end,uid).then(rows=>({rows,error:null})).catch(error=>({rows:[],error}))]);
      if(loadEpoch!==permissionEpoch||!access()||data.uid!==uid||!byId('ldBalance'))return;
      const latest=getRange();if(latest.start!==start||latest.end!==end){setTimeout(refreshData,0);return;}
      data.accounts=accounts||[];data.moves=moves;data.history=history.rows;data.historyError=history.error;data.page=1;
      drawAll();
    }catch(err){
      if(loadEpoch!==permissionEpoch||!access()||data.uid!==uid)return;
      console.error('[Libro Diario] Error de carga:',err);
      data.accounts=[];data.moves=[];data.history=[];data.historyError=err;
      if(byId('ldHistChart'))byId('ldHistChart').textContent='No disponible';
      ['ldBalance','ldIncome','ldExpense','ldUsd'].forEach(id=>{if(byId(id))byId(id).textContent='No disponible';});
      if(byId('ldRows'))byId('ldRows').innerHTML='<tr><td colspan="7" class="ld-empty">No se pudo cargar el Libro Diario.</td></tr>';
      showError('Error de consulta: '+(err?.message||'No disponible')+'. No se muestran ceros para datos incompletos.');
    }finally{if(loadEpoch===permissionEpoch)data.loading=false;}
  }
  const accountsById=()=>new Map(data.accounts.map(a=>[a.id,a]));
  function calculateBalance(acc,end){
    if(end<acc.fecha_saldo_inicial)return null;
    let total=Number(acc.saldo_inicial)||0;
    for(const m of data.moves){if(m.fecha<acc.fecha_saldo_inicial||m.fecha>end)continue;
      const amount=Number(m.importe)||0;
      if(m.cuenta_id===acc.id)total+=m.tipo==='INGRESO'?amount:-amount;
      if(m.tipo==='TRANSFERENCIA'&&m.cuenta_destino_id===acc.id)total+=amount;
    }
    return total;
  }
  function drawAll(){
    const {start,end}=getRange();
    const map=accountsById();
    let ars=0,usd=0,income=0,expense=0;
    const opened=data.accounts.filter(a=>a.fecha_saldo_inicial<=end);
    for(const acc of opened){const balance=calculateBalance(acc,end);if(acc.moneda==='USD')usd+=balance;else ars+=balance;}
    const periodMoves=data.moves.filter(m=>m.fecha>=start&&m.fecha<=end);
    for(const m of periodMoves){const acc=map.get(m.cuenta_id);if(!acc||acc.moneda!=='ARS')continue;
      if(m.tipo==='INGRESO')income+=Number(m.importe)||0;
      if(m.tipo==='EGRESO')expense+=Number(m.importe)||0;
    }
    byId('ldBalance').textContent=opened.some(a=>a.moneda==='ARS')?money(ars):'—';
    byId('ldIncome').textContent=money(income);
    byId('ldExpense').textContent=money(expense);
    byId('ldUsd').textContent=opened.some(a=>a.moneda==='USD')?money(usd,'USD'):'—';
    byId('ldAccounts').innerHTML=opened.length?opened.map(a=>`<div class="ld-account"><div class="ld-account-icon">${a.tipo==='BANCO'?'▦':a.tipo==='EFECTIVO'?'▣':a.tipo==='PLAZO_FIJO'?'◷':'◈'}</div><div class="ld-account-name">${esc(a.nombre)}<small>${esc(a.tipo.replaceAll('_',' '))} · ${a.moneda}</small></div><div class="ld-account-value">${money(calculateBalance(a,end),a.moneda)}</div></div>`).join(''):'<div class="ld-empty">No hay cuentas operativas abiertas al cierre de este período. Consultá los movimientos históricos para fechas anteriores.</div>';
    const sel=byId('ldAccountFilter'),selected=sel.value;
    sel.innerHTML='<option value="">Todas las cuentas</option>'+data.accounts.map(a=>`<option value="${esc(a.id)}">${esc(a.nombre)}</option>`).join('');
    if(data.accounts.some(a=>a.id===selected))sel.value=selected;
    drawChart(start,end,periodMoves,map);drawHistory();drawTable();
  }
  function drawChart(start,end,moves,map){
    const startD=parseDate(start),endD=parseDate(end),bucket=[];
    let d=new Date(startD.getFullYear(),startD.getMonth(),1);
    while(d<=endD&&bucket.length<36){bucket.push({key:`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}`,month:d.toLocaleDateString('es-AR',{month:'short',year:'2-digit'}),i:0,o:0});d=new Date(d.getFullYear(),d.getMonth()+1,1);}
    const byMonth=new Map(bucket.map(x=>[x.key,x]));
    for(const m of moves){const b=byMonth.get(m.fecha.slice(0,7));if(!b||map.get(m.cuenta_id)?.moneda!=='ARS')continue;
      if(m.tipo==='INGRESO')b.i+=Number(m.importe)||0;
      if(m.tipo==='EGRESO')b.o+=Number(m.importe)||0;
    }
    if(!bucket.some(x=>x.i||x.o)){byId('ldChart').innerHTML='<div class="ld-empty">Sin ingresos ni gastos operativos registrados en este período. El saldo de apertura no es un ingreso.</div>';return;}
    const max=Math.max(1,...bucket.flatMap(x=>[x.i,x.o]));
    byId('ldChart').innerHTML=bucket.map(x=>`<div class="ld-month" title="${esc(x.month)}: ingresos ${money(x.i)}, egresos ${money(x.o)}"><div class="ld-bar-pair"><div class="ld-bar" style="height:${x.i/max*100}%"></div><div class="ld-bar eg" style="height:${x.o/max*100}%"></div></div><span>${esc(x.month)}</span></div>`).join('')||'<div class="ld-empty">Sin meses en el período</div>';
  }
  function drawHistory(){
    const target=byId('ldHistChart'),summary=byId('ldHistSummary');if(!target||!summary)return;
    if(data.historyError){summary.textContent='No se pudo consultar el histórico. Los saldos operativos no se modificaron.';target.textContent='No disponible';return;}
    const selected=byId('ldHistBook').value,currency=selected==='USD'?'USD':'ARS';
    const rows=data.history.filter(x=>selected==='GARUPA'?['GARUPA_A','GARUPA_B'].includes(x.segmento):x.segmento===selected);
    if(!rows.length){summary.textContent='Sin registros históricos para el libro y período elegidos.';target.innerHTML='<div class="ld-empty">Seleccioná otro libro o período. No se sustituyen fechas automáticamente.</div>';return;}
    const byMonth=new Map();let totalIn=0,totalOut=0;
    for(const row of rows){const key=row.fecha_referencial.slice(0,7),i=Number(row.entrada)||0,o=Number(row.salida)||0;const b=byMonth.get(key)||{i:0,o:0};b.i+=i;b.o+=o;byMonth.set(key,b);totalIn+=i;totalOut+=o;}
    const {start,end}=getRange(),first=parseDate(start),last=parseDate(end);let d=new Date(first.getFullYear(),first.getMonth(),1),bucket=[];
    while(d<=last&&bucket.length<120){const key=isoDate(d).slice(0,7);bucket.push({key,month:d.toLocaleDateString('es-AR',{month:'short',year:'2-digit'}),...byMonth.get(key)});d=new Date(d.getFullYear(),d.getMonth()+1,1);}
    if(d<=last){summary.textContent='El intervalo supera 120 meses. Reducí el rango.';target.textContent='No disponible';return;}
    summary.textContent=`${rows.length} registros · Entradas: ${money(totalIn,currency)} · Salidas: ${money(totalOut,currency)}. No se suman al saldo operativo.`;
    const max=Math.max(1,...bucket.flatMap(b=>[b.i||0,b.o||0]));
    target.innerHTML=bucket.map(b=>`<div class="ld-month" title="${esc(b.month)}: ${b.i==null?'sin registros':esc(money(b.i,currency)+' / '+money(b.o,currency))}"><div class="ld-bar-pair"><div class="ld-bar" style="height:${(b.i||0)/max*100}%"></div><div class="ld-bar eg" style="height:${(b.o||0)/max*100}%"></div></div><span>${esc(b.month)}</span></div>`).join('');
  }
  function drawTable(){
    if(!byId('ldRows'))return;
    const {start,end}=getRange(),q=(byId('ldQuery')?.value||'').toLowerCase().trim(),account=byId('ldAccountFilter')?.value||'',type=byId('ldTypeFilter')?.value||'';
    const map=accountsById();
    const filtered=data.moves.filter(m=>m.fecha>=start&&m.fecha<=end&&(!account||(m.cuenta_id===account||m.cuenta_destino_id===account))&&(!type||m.tipo===type)&&(!q||(m.detalle+' '+m.categoria+' '+(map.get(m.cuenta_id)?.nombre||'')).toLowerCase().includes(q)));
    const per=30,pages=Math.max(1,Math.ceil(filtered.length/per));data.page=Math.min(Math.max(1,data.page),pages);
    const rows=filtered.slice((data.page-1)*per,data.page*per);
    byId('ldRows').innerHTML=rows.map(m=>{
      const a=map.get(m.cuenta_id),b=map.get(m.cuenta_destino_id),symbol=m.tipo==='INGRESO'?'+':m.tipo==='EGRESO'?'−':'↔';
      return `<tr><td>${fmtDay(m.fecha)}</td><td><strong>${esc(m.detalle)}</strong>${m.origen==='EXCEL'?'<br><small class="ld-muted">Importado del Excel</small>':''}</td><td>${esc(a?.nombre||'Cuenta no disponible')}${b?' → '+esc(b.nombre):''}</td><td>${esc(m.categoria)}</td><td><span class="ld-tag ${m.tipo==='INGRESO'?'in':m.tipo==='EGRESO'?'out':''}">${esc(m.tipo)}</span></td><td style="font-weight:800;white-space:nowrap">${symbol} ${money(m.importe,a?.moneda||'ARS')}</td><td><button class="ld-btn ld-edit" type="button" data-id="${esc(m.id)}">Editar</button></td></tr>`;
    }).join('')||'<tr><td colspan="7" class="ld-empty">No hay movimientos para estos filtros.</td></tr>';
    byId('ldRows').querySelectorAll('.ld-edit').forEach(btn=>btn.addEventListener('click',()=>openMoveForm(data.moves.find(m=>m.id===btn.dataset.id))));
    byId('ldCount').textContent=`${filtered.length} movimientos del período`;
    byId('ldPage').textContent=`Página ${data.page} de ${pages}`;
    byId('ldPrev').disabled=data.page<=1;byId('ldNext').disabled=data.page>=pages;
  }
  function modal(inner){
    const root=byId('ldModalRoot');root.innerHTML=`<div class="ld-modal-backdrop"><div class="ld-modal" role="dialog" aria-modal="true">${inner}</div></div>`;
    root.querySelector('.ld-modal-backdrop').addEventListener('click',e=>{if(e.target.classList.contains('ld-modal-backdrop'))closeModal();});
    root.querySelectorAll('[data-close]').forEach(b=>b.addEventListener('click',closeModal));
  }
  function closeModal(){const root=byId('ldModalRoot');if(root)root.innerHTML='';}
  function openAccountForm(){
    if(!access())return;
    modal(`<h2>Nueva cuenta</h2><form id="ldAccountForm" class="ld-form-grid">
      <div class="ld-field ld-full"><label>Nombre de la cuenta</label><input name="nombre" required minlength="2" maxlength="100" placeholder="Ej. Banco Galicia"></div>
      <div class="ld-field"><label>Tipo</label><select name="tipo"><option value="BANCO">Banco</option><option value="EFECTIVO">Efectivo / Caja</option><option value="MERCADO_PAGO">Mercado Pago</option><option value="PLAZO_FIJO">Plazo fijo</option><option value="OTRA">Otra</option></select></div>
      <div class="ld-field"><label>Moneda</label><select name="moneda"><option value="ARS">Pesos argentinos</option><option value="USD">Dólares</option></select></div>
      <div class="ld-field"><label>Saldo inicial</label><input name="saldo_inicial" type="number" step="0.01" value="0" required></div>
      <div class="ld-field"><label>Fecha del saldo inicial</label><input name="fecha_saldo_inicial" type="date" value="${today}" required></div>
      <div class="ld-field ld-full"><small class="ld-muted">Importante: el saldo inicial es una foto contable de esta fecha. No vuelvas a registrar como ingresos los movimientos anteriores que ya estén incluidos en ese saldo.</small></div>
      <div class="ld-field ld-full"><div class="ld-modal-actions"><button type="button" class="ld-btn" data-close>Cancelar</button><button type="submit" class="ld-btn ld-primary">Guardar cuenta</button></div></div></form>`);
    byId('ldAccountForm').addEventListener('submit',async e=>{
      e.preventDefault();const f=new FormData(e.target);const btn=e.target.querySelector('[type="submit"]');btn.disabled=true;
      try{const {error}=await sb.from('libro_diario_cuentas').insert({user_id:data.uid,nombre:String(f.get('nombre')).trim(),tipo:f.get('tipo'),moneda:f.get('moneda'),saldo_inicial:Number(f.get('saldo_inicial')),fecha_saldo_inicial:f.get('fecha_saldo_inicial')});if(error)throw error;closeModal();await refreshData();}
      catch(ex){alert('No se pudo guardar la cuenta: '+ex.message);btn.disabled=false;}
    });
  }
  function openMoveForm(existing=null){
    if(!access())return;
    if(!data.accounts.length){alert('Primero tenés que crear una cuenta.');return;}
    const opts=data.accounts.map(a=>`<option value="${esc(a.id)}">${esc(a.nombre)} (${a.moneda})</option>`).join('');
    modal(`<h2>${existing?'Editar movimiento':'Nuevo movimiento'}</h2><form id="ldMoveForm" class="ld-form-grid">
      <div class="ld-field"><label>Fecha</label><input name="fecha" type="date" required value="${esc(existing?.fecha||today)}"></div>
      <div class="ld-field"><label>Tipo</label><select name="tipo" id="ldMoveType"><option value="INGRESO">Ingreso</option><option value="EGRESO">Egreso</option><option value="TRANSFERENCIA">Transferencia entre cuentas</option></select></div>
      <div class="ld-field"><label>Cuenta</label><select name="cuenta_id" id="ldMoveAccount" required>${opts}</select></div>
      <div class="ld-field" id="ldDestWrap" style="display:none"><label>Cuenta de destino</label><select name="cuenta_destino_id" id="ldDest"><option value="">Elegir destino…</option>${opts}</select></div>
      <div class="ld-field"><label>Importe</label><input name="importe" type="number" min="0.01" step="0.01" required value="${existing?esc(existing.importe):''}" placeholder="0,00"></div>
      <div class="ld-field"><label>Categoría</label><input name="categoria" maxlength="100" required value="${esc(existing?.categoria||'General')}"></div>
      <div class="ld-field ld-full"><label>Detalle</label><input name="detalle" minlength="2" maxlength="500" required value="${esc(existing?.detalle||'')}" placeholder="Descripción del ingreso o gasto"></div>
      <div class="ld-field ld-full"><small class="ld-muted">Las cuentas importadas tienen apertura el 26/11/2026 (cierre Excel del 25/11). No cargues nuevamente movimientos ya incluidos. Las transferencias internas no cuentan como ingresos ni gastos. Cada edición queda registrada en auditoría.</small></div>
      <div class="ld-field ld-full"><div class="ld-modal-actions"><button type="button" data-close class="ld-btn">Cancelar</button><button type="submit" class="ld-btn ld-primary">${existing?'Guardar cambios':'Registrar movimiento'}</button></div></div></form>`);
    const form=byId('ldMoveForm'),type=byId('ldMoveType');
    type.value=existing?.tipo||'EGRESO';byId('ldMoveAccount').value=existing?.cuenta_id||data.accounts[0]?.id;
    byId('ldDest').value=existing?.cuenta_destino_id||'';
    function syncType(){const isT=type.value==='TRANSFERENCIA';byId('ldDestWrap').style.display=isT?'flex':'none';byId('ldDest').required=isT;}
    type.addEventListener('change',syncType);syncType();
    form.addEventListener('submit',async e=>{
      e.preventDefault();const f=new FormData(form),kind=f.get('tipo'),a=data.accounts.find(x=>x.id===f.get('cuenta_id')),b=data.accounts.find(x=>x.id===f.get('cuenta_destino_id')),amount=Number(f.get('importe')),fecha=f.get('fecha');
      if(!allowedTypes.includes(kind)||!a||!(Number.isFinite(amount)&&amount>0)){alert('Revisá el tipo, cuenta e importe.');return;}
      if(fecha<a.fecha_saldo_inicial||(kind==='TRANSFERENCIA'&&b&&fecha<b.fecha_saldo_inicial)){alert('La fecha del movimiento no puede ser anterior al saldo inicial de la cuenta.');return;}
      if(kind==='TRANSFERENCIA'&&(!b||a.id===b.id||a.moneda!==b.moneda)){alert('La transferencia requiere dos cuentas diferentes de la misma moneda. Para cambio ARS/USD se debe registrar conversión con cotización por separado.');return;}
      const payload={user_id:data.uid,fecha,tipo:kind,cuenta_id:a.id,cuenta_destino_id:kind==='TRANSFERENCIA'?b.id:null,categoria:String(f.get('categoria')).trim(),detalle:String(f.get('detalle')).trim(),importe:amount};
      const btn=form.querySelector('[type="submit"]');btn.disabled=true;
      try{
        const req=existing?sb.from('libro_diario_movimientos').update(payload).eq('id',existing.id).eq('user_id',data.uid):sb.from('libro_diario_movimientos').insert(payload);
        const {error}=await req;if(error)throw error;closeModal();await refreshData();
      }catch(err){alert('No se pudo guardar el movimiento: '+err.message);btn.disabled=false;}
    });
  }
})();
