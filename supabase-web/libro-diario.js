/* Libro Diario - módulo privado. No interfiere con Recibos, Balance o medios de pago. */
(function(){
  'use strict';
  if (typeof sb === 'undefined' || typeof window.setRoute !== 'function') { console.warn('[Libro Diario] Frontend incompatible'); return; }
  const data={uid:null,granted:false,ready:false,accounts:[],moves:[],loading:false,page:1,pages:{GARUPA:1,JARDIN:1,OTROS:1},editing:null,history:[],historyError:null};
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
  nav.innerHTML='<span class="sb-item-icon" style="font-size:19px">▤</span><span class="sb-item-label">Libro Diario</span>';
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
    data.accounts=[];data.moves=[];data.history=[];data.pages={GARUPA:1,JARDIN:1,OTROS:1};data.historyError=null;data.editing=null;data.loading=false;
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
      <div class="ld-head"><div><span class="ld-eyebrow">Área financiera privada · Solo jefe</span><h1>Libro Diario</h1><div class="ld-muted">Libros y balances por negocio. Independiente de alquileres.</div></div>
      <div class="ld-controls"><button class="ld-btn" type="button" id="ldNewAccount">＋ Cuenta</button><button class="ld-btn ld-primary" type="button" id="ldNewMove">＋ Nuevo movimiento</button></div></div>
      <div class="ld-period"><div class="ld-field"><label for="ldPeriod">Período</label><select id="ldPeriod"><option value="mensual">Mensual</option><option value="bimestral" selected>Bimestral</option><option value="trimestral">Trimestral</option><option value="anual">Anual</option><option value="personalizado">Personalizado</option></select></div>
      <div class="ld-field"><label for="ldMonth">Mes de referencia</label><input id="ldMonth" type="month" value="${initialMonth}"></div>
      <div id="ldCustom" class="ld-custom"><div class="ld-field"><label for="ldFrom">Desde</label><input id="ldFrom" type="date" value="${today}"></div><div class="ld-field"><label for="ldTo">Hasta</label><input id="ldTo" type="date" value="${today}"></div></div>
      <button class="ld-btn" type="button" id="ldRefresh">↻ Actualizar</button><span id="ldDates" class="ld-muted"></span></div>
      <div id="ldAlert" class="ld-alert" hidden></div>
      <div class="ld6-layout"><div class="ld6-books">${['GARUPA','JARDIN'].map(g=>bookMarkup(g)).join('')}</div><aside class="ld6-accounts">${['GARUPA','JARDIN'].map(g=>accountMarkup(g)).join('')}</aside></div>
      <details class="ld-card ld6-other"><summary>Otras cuentas y movimientos</summary><p class="ld-muted">Cuentas sin negocio asignado y conceptos generales. Se incluyen una sola vez en el total consolidado.</p>${bookMarkup('OTROS')}${accountMarkup('OTROS')}</details>
      <section class="ld-card ld6-consolidated"><div class="ld-card-title"><div><h2>Balance total consolidado</h2><div class="ld-muted">GARUPA + JARDÍN + otras cuentas · al cierre del período seleccionado</div></div></div><div id="ld6Total" aria-live="polite">Cargando…</div></section>
      <details class="ld-card ld6-archive"><summary>Archivo histórico, gráficos y balances del Excel</summary><div class="ld-duo ld6-archive-anchor" hidden></div><div class="ld-card-title"><div><h2>Consultar hojas originales</h2><div class="ld-muted">Referencia histórica; no se suma nuevamente a los saldos.</div></div><button type="button" class="ld-btn" id="ldImportInfo">Importar histórico</button></div></details>
      <div id="ldModalRoot"></div>`;
    byId('ldNewAccount').addEventListener('click',()=>openAccountForm());
    byId('ldNewMove').addEventListener('click',()=>openMoveForm());
    byId('ldImportInfo').addEventListener('click',()=>alert('Consultá el archivo original en el histórico privado.'));
    byId('ldRefresh').addEventListener('click',refreshData);
    byId('ldPeriod').addEventListener('change',()=>{byId('ldCustom').classList.toggle('ld-visible',byId('ldPeriod').value==='personalizado');refreshData();});
    ['ldMonth','ldFrom','ldTo'].forEach(id=>byId(id).addEventListener('change',refreshData));
    for(const g of groups){
      byId('ld6new'+g).addEventListener('click',()=>openMoveForm(null,g));
      byId('ld6q'+g).addEventListener('input',()=>{data.pages[g]=1;drawBook(g);});
      byId('ld6source'+g).addEventListener('change',()=>{data.pages[g]=1;drawBook(g);});
      byId('ld6prev'+g).addEventListener('click',()=>{data.pages[g]--;drawBook(g);});
      byId('ld6next'+g).addEventListener('click',()=>{data.pages[g]++;drawBook(g);});
    }
  }
  const groups=['GARUPA','JARDIN','OTROS'];
  const groupOf=a=>groups.includes(a?.negocio)?a.negocio:'OTROS';
  const label=g=>g==='JARDIN'?'JARDÍN':g==='OTROS'?'Otras cuentas':g;
  function bookMarkup(g){return `<section class="ld-card ld6-book"><div class="ld-card-title"><div><h2>Libro diario · ${label(g)}</h2><div class="ld-muted">${g==='OTROS'?'Movimientos operativos generales':'Histórico del Excel y nuevos movimientos'}</div></div><button class="ld-btn ld-primary" id="ld6new${g}" type="button">＋ Movimiento</button></div><div class="ld6-filter"><input id="ld6q${g}" type="search" placeholder="Buscar detalle o cuenta…" aria-label="Buscar en ${label(g)}"><select id="ld6source${g}" aria-label="Origen de movimientos ${label(g)}"><option value="ALL">Todos los registros</option><option value="MANUAL">Operativos</option><option value="EXCEL">Históricos</option></select></div><div id="ld6summary${g}" class="ld6-summary"></div><div class="ld-table-scroll"><table><thead><tr><th>Fecha</th><th>Detalle / cuenta</th><th>Entrada</th><th>Salida</th><th>Saldo Excel</th><th></th></tr></thead><tbody id="ld6rows${g}"><tr><td colspan="6" class="ld-empty">Cargando…</td></tr></tbody></table></div><div class="ld-foot"><span id="ld6count${g}" class="ld-muted"></span><div class="ld-controls"><button class="ld-btn" type="button" id="ld6prev${g}">Anterior</button><button class="ld-btn" type="button" id="ld6next${g}">Siguiente</button></div></div></section>`;}
  function accountMarkup(g){return `<section class="ld-card ld6-account-card"><div class="ld-card-title"><div><h2>Balance · ${label(g)}</h2><div class="ld-muted">Cuentas y saldos operativos</div></div></div><div id="ld6bal${g}">Cargando…</div><div id="ld6acc${g}"></div></section>`;}

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
      const result=await sb.from('libro_diario_conciliacion_lineas').select('id,segmento,fecha_referencial,tipo_fecha,detalle,entrada,salida,saldo_excel,fila,moneda').eq('fuente_id',src.data.fuente_id).eq('user_id',uid).eq('tipo_registro','MOVIMIENTO').gte('fecha_referencial',start).lte('fecha_referencial',until).order('id',{ascending:true}).range(i*size,(i+1)*size-1);
      if(result.error)throw result.error;
      out.push(...(result.data||[]));
      if((result.data||[]).length<size)return out;
    }
    throw new Error('El histórico excede el límite de consulta. Reducí el intervalo.');
  }
  async function refreshData(){
    if(!access()||data.loading||!byId('ld6Total'))return;
    const {start,end}=getRange();
    if(start>end){showError('La fecha inicial no puede ser posterior a la final.');return;}
    const loadEpoch=permissionEpoch,uid=data.uid;
    data.loading=true;showError('');byId('ldDates').textContent=`${fmtDay(start)} — ${fmtDay(end)}`;
    try{
      const {data:accounts,error}=await sb.from('libro_diario_cuentas').select('id,user_id,nombre,tipo,moneda,saldo_inicial,fecha_saldo_inicial,activa,negocio').order('nombre');
      if(error)throw error;
      if(loadEpoch!==permissionEpoch||!access()||data.uid!==uid)return;
      const [moves,history]=await Promise.all([fetchEveryMove(end),fetchHistory(start,end,uid).then(rows=>({rows,error:null})).catch(error=>({rows:[],error}))]);
      if(loadEpoch!==permissionEpoch||!access()||data.uid!==uid||!byId('ld6Total'))return;
      const latest=getRange();if(latest.start!==start||latest.end!==end){setTimeout(refreshData,0);return;}
      data.accounts=accounts||[];data.moves=moves;data.history=history.rows;data.historyError=history.error;data.pages={GARUPA:1,JARDIN:1,OTROS:1};
      drawAll();
    }catch(err){
      if(loadEpoch!==permissionEpoch||!access()||data.uid!==uid)return;
      console.error('[Libro Diario] Error de carga:',err);
      data.accounts=[];data.moves=[];data.history=[];data.historyError=err;
      for(const g of groups){byId('ld6rows'+g).innerHTML='<tr><td colspan="6" class="ld-empty">No disponible</td></tr>';byId('ld6bal'+g).textContent='No disponible';byId('ld6acc'+g).textContent='';byId('ld6summary'+g).textContent='';}
      byId('ld6Total').textContent='No disponible';
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
  const cents=v=>Math.round(Number(v||0)*100);
  function aggregate(g,end){const accounts=data.accounts.filter(a=>(g==='ALL'||groupOf(a)===g)&&a.fecha_saldo_inicial<=end);const totals={ARS:0,USD:0},present={ARS:false,USD:false};for(const a of accounts){totals[a.moneda]+=cents(calculateBalance(a,end));present[a.moneda]=true;}return {accounts,totals,present};}
  function balancesHTML(result){return `<div class="ld6-balances">${['ARS','USD'].map(c=>`<div><span>Saldo ${c}</span><strong>${result.present[c]?money(result.totals[c]/100,c):'—'}</strong></div>`).join('')}</div>`;}
  function drawAll(){
    const {end}=getRange();
    for(const g of groups){
      const r=aggregate(g,end);byId('ld6bal'+g).innerHTML=balancesHTML(r);
      byId('ld6acc'+g).innerHTML=r.accounts.map(a=>`<div class="ld-account"><div class="ld-account-name">${esc(a.nombre)}<small>${esc(a.tipo.replaceAll('_',' '))}${a.activa?'':' · Inactiva'}</small></div><div class="ld-account-value">${money(calculateBalance(a,end),a.moneda)}</div></div>`).join('')||'<div class="ld-empty">Sin cuentas abiertas al cierre elegido.</div>';
      drawBook(g);
    }
    const r=aggregate('ALL',end);
    const {start}=getRange(),map=accountsById(),flow={ARS:{i:0,o:0},USD:{i:0,o:0}};
    for(const m of data.moves){const a=map.get(m.cuenta_id);if(!a||m.fecha<start||m.fecha>end||m.fecha<a.fecha_saldo_inicial)continue;if(m.tipo==='INGRESO')flow[a.moneda].i+=cents(m.importe);if(m.tipo==='EGRESO')flow[a.moneda].o+=cents(m.importe);}
    const breakdown=groups.map(g=>{const v=aggregate(g,end);return `<tr><td>${label(g)}</td>${['ARS','USD'].map(c=>`<td>${v.present[c]?money(v.totals[c]/100,c):'—'}</td>`).join('')}</tr>`;}).join('');
    byId('ld6Total').innerHTML=balancesHTML(r)+`<div class="ld-table-scroll ld6-total-table"><table><thead><tr><th>Negocio</th><th>Saldo ARS</th><th>Saldo USD</th></tr></thead><tbody>${breakdown}</tbody></table></div><div class="ld6-summary ld6-flow">${['ARS','USD'].map(c=>`<div><b>Movimientos nuevos · ${c}</b><span>${money(flow[c].i/100,c)} ingresos · ${money(flow[c].o/100,c)} gastos</span></div>`).join('')}</div><div class="ld-muted ld6-note">Los traspasos no son ingresos ni gastos. El histórico no se vuelve a sumar. Los saldos de apertura se aplican desde el 26/11/2026.</div>`;
  }
  function drawBook(g){
    const tbody=byId('ld6rows'+g);if(!tbody)return;
    const {start,end}=getRange(),map=accountsById(),query=(byId('ld6q'+g).value||'').trim().toLowerCase(),source=byId('ld6source'+g).value;
    const rows=[],historical={i:0,o:0},op={ARS:{i:0,o:0,ti:0,to:0},USD:{i:0,o:0,ti:0,to:0}};
    for(const h of data.history){if((g==='GARUPA'&&!['GARUPA_A','GARUPA_B'].includes(h.segmento))||(g==='JARDIN'&&h.segmento!=='JARDIN')||g==='OTROS')continue;
      const i=cents(h.entrada),o=cents(h.salida);historical.i+=i;historical.o+=o;
      rows.push({id:'h'+h.id,fecha:h.fecha_referencial,detalle:h.detalle||'Sin detalle',account:'Excel · fila '+h.fila,source:'EXCEL',i,o,c:'ARS',saldo:h.saldo_excel,heredada:h.tipo_fecha==='HEREDADA'});
    }
    for(const m of data.moves){if(m.fecha<start||m.fecha>end)continue;const a=map.get(m.cuenta_id),b=map.get(m.cuenta_destino_id),src=a&&groupOf(a)===g&&m.fecha>=a.fecha_saldo_inicial,dst=b&&groupOf(b)===g&&m.fecha>=b.fecha_saldo_inicial;if(!src&&!dst)continue;
      const c=a?.moneda||b?.moneda||'ARS',v=cents(m.importe);let i=0,o=0;
      if(m.tipo==='INGRESO'&&src){i=v;op[c].i+=v;}else if(m.tipo==='EGRESO'&&src){o=v;op[c].o+=v;}else if(m.tipo==='TRANSFERENCIA'){if(src){o=v;op[c].to+=v;}if(dst){i=v;op[c].ti+=v;}}
      rows.push({id:m.id,fecha:m.fecha,detalle:m.detalle,account:(a?.nombre||'Cuenta no disponible')+(b?' → '+b.nombre:''),source:'MANUAL',i,o,c,saldo:null,tipo:m.tipo});
    }
    const filtered=rows.filter(r=>(source==='ALL'||r.source===source)&&(!query||(r.detalle+' '+r.account).toLowerCase().includes(query))).sort((a,b)=>b.fecha.localeCompare(a.fecha)||String(b.id).localeCompare(String(a.id),undefined,{numeric:true}));
    const summary=byId('ld6summary'+g);summary.innerHTML=`${g!=='OTROS'?`<div><b>Excel · ARS</b><span>${data.historyError?'No disponible':money(historical.i/100)+' entradas · '+money(historical.o/100)+' salidas'}</span></div>`:''}<div><b>Operativo · ARS</b><span>${money(op.ARS.i/100)} ingresos · ${money(op.ARS.o/100)} gastos</span></div>${op.USD.i||op.USD.o?`<div><b>Operativo · USD</b><span>${money(op.USD.i/100,'USD')} ingresos · ${money(op.USD.o/100,'USD')} gastos</span></div>`:''}${op.ARS.ti||op.ARS.to||op.USD.ti||op.USD.to?'<small>Traspasos visibles en el libro; excluidos de ingresos y gastos.</small>':''}`;
    const per=12,pages=Math.max(1,Math.ceil(filtered.length/per));data.pages[g]=Math.min(pages,Math.max(1,data.pages[g]||1));const page=data.pages[g];
    tbody.innerHTML=filtered.slice((page-1)*per,page*per).map(r=>`<tr><td>${fmtDay(r.fecha)}${r.heredada?'<small class="ld-muted" title="Fecha referencial del Excel"> *</small>':''}</td><td><strong>${esc(r.detalle)}</strong><small class="ld6-row-sub">${esc(r.account)} · ${r.source==='EXCEL'?'Histórico':esc(r.tipo)}</small></td><td class="ld6-in">${r.i?money(r.i/100,r.c):'—'}</td><td class="ld6-out">${r.o?money(r.o/100,r.c):'—'}</td><td>${r.saldo==null?'—':money(r.saldo,r.c)}</td><td>${r.source==='MANUAL'?`<button type="button" class="ld-btn ld-edit" data-id="${esc(r.id)}">Editar</button>`:''}</td></tr>`).join('')||'<tr><td colspan="6" class="ld-empty">Sin movimientos para los filtros seleccionados.</td></tr>';
    tbody.querySelectorAll('.ld-edit').forEach(b=>b.addEventListener('click',()=>openMoveForm(data.moves.find(m=>m.id===b.dataset.id),g)));
    byId('ld6count'+g).textContent=`${filtered.length} registros · Página ${page} de ${pages}${g!=='OTROS'?' · * fecha referencial':''}${data.historyError&&g!=='OTROS'?' · Histórico no disponible':''}`;
    byId('ld6prev'+g).disabled=page<=1;byId('ld6next'+g).disabled=page>=pages;
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
      <div class="ld-field"><label>Negocio</label><select name="negocio" required><option value="">Elegir negocio…</option><option value="GARUPA">GARUPA</option><option value="JARDIN">JARDÍN</option><option value="OTROS">Otras cuentas</option></select></div><div class="ld-field"><label>Tipo</label><select name="tipo"><option value="BANCO">Banco</option><option value="EFECTIVO">Efectivo / Caja</option><option value="MERCADO_PAGO">Mercado Pago</option><option value="PLAZO_FIJO">Plazo fijo</option><option value="OTRA">Otra</option></select></div>
      <div class="ld-field"><label>Moneda</label><select name="moneda"><option value="ARS">Pesos argentinos</option><option value="USD">Dólares</option></select></div>
      <div class="ld-field"><label>Saldo inicial</label><input name="saldo_inicial" type="number" step="0.01" value="0" required></div>
      <div class="ld-field"><label>Fecha del saldo inicial</label><input name="fecha_saldo_inicial" type="date" value="${isoDate(new Date())}" required></div>
      <div class="ld-field ld-full"><small class="ld-muted">Importante: el saldo inicial es una foto contable de esta fecha. No vuelvas a registrar como ingresos los movimientos anteriores que ya estén incluidos en ese saldo.</small></div>
      <div class="ld-field ld-full"><div class="ld-modal-actions"><button type="button" class="ld-btn" data-close>Cancelar</button><button type="submit" class="ld-btn ld-primary">Guardar cuenta</button></div></div></form>`);
    byId('ldAccountForm').addEventListener('submit',async e=>{
      e.preventDefault();const f=new FormData(e.target);const btn=e.target.querySelector('[type="submit"]');btn.disabled=true;
      try{const {error}=await sb.from('libro_diario_cuentas').insert({user_id:data.uid,nombre:String(f.get('nombre')).trim(),negocio:f.get('negocio'),tipo:f.get('tipo'),moneda:f.get('moneda'),saldo_inicial:Number(f.get('saldo_inicial')),fecha_saldo_inicial:f.get('fecha_saldo_inicial')});if(error)throw error;closeModal();await refreshData();}
      catch(ex){alert('No se pudo guardar la cuenta: '+ex.message);btn.disabled=false;}
    });
  }
  function openMoveForm(existing=null,group=null){
    if(!access())return;
    const active=data.accounts.filter(a=>a.activa||a.id===existing?.cuenta_id||a.id===existing?.cuenta_destino_id);
    const sources=active.filter(a=>!group||groupOf(a)===group||a.id===existing?.cuenta_id);
    if(!sources.length){alert('Primero creá una cuenta para este negocio.');return;}
    const options=arr=>arr.map(a=>`<option value="${esc(a.id)}">${label(groupOf(a))} · ${esc(a.nombre)}</option>`).join('');
    const opts=options(sources), destinations=options(active);
    modal(`<h2>${existing?'Editar movimiento':'Nuevo movimiento'}</h2><form id="ldMoveForm" class="ld-form-grid">
      <div class="ld-field"><label>Fecha</label><input name="fecha" type="date" required value="${esc(existing?.fecha||isoDate(new Date()))}"></div>
      <div class="ld-field"><label>Tipo</label><select name="tipo" id="ldMoveType"><option value="INGRESO">Ingreso</option><option value="EGRESO">Egreso</option><option value="TRANSFERENCIA">Transferencia entre cuentas</option></select></div>
      <div class="ld-field"><label>Cuenta</label><select name="cuenta_id" id="ldMoveAccount" required>${opts}</select></div>
      <div class="ld-field" id="ldDestWrap" style="display:none"><label>Cuenta de destino</label><select name="cuenta_destino_id" id="ldDest"><option value="">Elegir destino…</option>${destinations}</select></div>
      <div class="ld-field"><label>Importe</label><input name="importe" type="number" min="0.01" step="0.01" required value="${existing?esc(existing.importe):''}" placeholder="0,00"></div>
      <div class="ld-field"><label>Categoría</label><input name="categoria" maxlength="100" required value="${esc(existing?.categoria||'General')}"></div>
      <div class="ld-field ld-full"><label>Detalle</label><input name="detalle" minlength="2" maxlength="500" required value="${esc(existing?.detalle||'')}" placeholder="Descripción del ingreso o gasto"></div>
      <div class="ld-field ld-full"><small class="ld-muted">Las cuentas importadas tienen apertura el 26/11/2026 (cierre Excel del 25/11). No cargues nuevamente movimientos ya incluidos. Las transferencias internas no cuentan como ingresos ni gastos. Cada edición queda registrada en auditoría.</small></div>
      <div class="ld-field ld-full"><div class="ld-modal-actions"><button type="button" data-close class="ld-btn">Cancelar</button><button type="submit" class="ld-btn ld-primary">${existing?'Guardar cambios':'Registrar movimiento'}</button></div></div></form>`);
    const form=byId('ldMoveForm'),type=byId('ldMoveType');
    type.value=existing?.tipo||'EGRESO';byId('ldMoveAccount').value=existing?.cuenta_id||sources[0]?.id;
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
