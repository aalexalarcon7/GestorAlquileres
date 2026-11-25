/* GA_UI_UNIFICADA_V1: presentation only; existing controls and events stay intact. */
(()=>{'use strict';
 const app=document.getElementById('app');if(!app)return;
 const specs={viewInicio:['home','Resumen de la gestión de alquileres.'],viewActivos:['building','Gestión de unidades, contratos y estado de deuda.'],viewDocumentos:['folder','Contratos y documentación de locatarios.'],viewRecibos:['receipt','Historial y consulta de recibos internos.'],viewImpuestos:['calendar','Organizador de obligaciones, vencimientos y pagos administrativos.'],viewEmpleados:['users','Gestión de personal y salarios.'],viewInformes:['chart','Registro y consulta de gastos administrativos.'],viewBalance:['wallet','Ingresos y gastos según su fecha de registro.'],viewBalanceReal:['banknote','Cuotas, pagos aplicados y deuda por período.'],viewLibroDiario:['book','Tus cuentas, saldos y movimientos en un único lugar. Independiente de alquileres.']};
 const paths={home:'<path d="m3 10 9-7 9 7v10H3z"/><path d="M9 20v-7h6v7"/>',building:'<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 7h1m4 0h1M9 11h1m4 0h1M9 15h1m4 0h1M10 21v-3h4v3"/>',folder:'<path d="M3 7V5a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v11H3z"/>',receipt:'<path d="M6 3h12v18l-3-2-3 2-3-2-3 2zM9 8h6M9 12h6M9 16h3"/>',calendar:'<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 3v4m10-4v4M3 10h18m-14 4h3m4 0h3m-10 3h3"/>',users:'<circle cx="9" cy="7" r="3"/><path d="M3 20v-2a6 6 0 0 1 12 0v2m2-15a3 3 0 0 1 0 6m1 3a5 5 0 0 1 3 5v1"/>',chart:'<path d="M3 3v18h18M7 17v-5m5 5V6m5 11V9"/>',wallet:'<rect x="3" y="5" width="18" height="15" rx="3"/><path d="M3 9h18m0 3h-6v5h6m-3-2h.01"/>',banknote:'<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="12" cy="12" r="3"/><path d="M6 12h.01m12 0h.01"/>',book:'<rect x="5" y="3" width="15" height="18" rx="2"/><path d="M9 3v18M12 8h5m-5 4h5m-5 4h3"/>'};
 const make=(tag,cls)=>{const e=document.createElement(tag);e.className=cls;return e;};
 function decorate(copy,title,kind,desc){
   copy.classList.add('ga-u-copy');title.classList.add('ga-u-title');
   if(!copy.querySelector(':scope > .ga-u-sub')&&!copy.querySelector(':scope > .page-heading-sub, :scope > p, :scope > .ld-muted')){const p=make('p','ga-u-sub');p.textContent=desc;title.after(p);}
   for(const e of copy.querySelectorAll(':scope > p, :scope > .ld-muted'))e.classList.add('ga-u-sub');
   const icon=make('span','ga-u-icon');icon.setAttribute('aria-hidden','true');icon.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">'+paths[kind]+'</svg>';return icon;
 }
 function unify(view){
   const spec=specs[view.id];if(!spec)return;
   const root=view.firstElementChild;if(!root||root.dataset.gaUnified==='1')return;
   if(root.matches('.section-hero')){
     const grid=root.querySelector('.section-hero-grid'),main=grid?.querySelector('.section-hero-main'),title=main?.querySelector('h2');if(!title)return;
     const copy=title.parentElement===main?make('div','ga-u-copy'):title.parentElement;
     if(title.parentElement===main)copy.append(title);
     const context=grid.querySelector('.balance-view-context');if(context)copy.append(context);
     const icon=decorate(copy,title,...spec);
     const head=make('div','ga-u-head'), actions=grid.querySelector('.section-hero-actions')||make('div','ga-u-actions');actions.classList.add('ga-u-actions');
     const toolbar=grid.querySelector('.section-hero-toolbar');
     if(toolbar){for(const b of Array.from(toolbar.querySelectorAll(':scope > button'))){if(view.id!=='viewInformes'||/recargar/i.test(b.textContent))actions.append(b);}}
     if(actions.childElementCount)head.append(icon,copy,actions);else head.append(icon,copy);
     const kpis=grid.querySelector('.section-hero-kpis');root.insertBefore(head,grid);
     if(toolbar){toolbar.classList.add('ga-u-filters');root.insertBefore(toolbar,grid);}
     if(kpis){kpis.classList.add('ga-u-metrics');root.insertBefore(kpis,grid);}
     if(grid.textContent.trim()||grid.querySelector('button,input,select,textarea,a[href],[id]')){grid.classList.add('ga-u-extra');}else{grid.remove();}root.classList.add('ga-u-legacy');
   }else{
     const row=root.matches('.ld-head')?root:root.querySelector(':scope > .row');
     const title=(row||root).querySelector('h1,h2');if(!title||!/^((Inicio)|(Activos)|(Empleados)|(Impuestos y Pagos)|(Libro Diario))$/.test(title.textContent.trim()))return;
     let copy=title.parentElement;
     if(copy===root){copy=make('div','ga-u-copy');copy.append(title);}
     const icon=decorate(copy,title,...spec);
     if(view.id==='viewLibroDiario'){root.classList.add('ga-u-head');root.insertBefore(icon,copy);root.querySelector('.ld-controls')?.classList.add('ga-u-actions');}
     else if(row){
       const head=view.id==='viewActivos'?make('div','ga-u-head'):root;
       head.classList.add('ga-u-head');
       const actions=make('div','ga-u-actions');for(const node of Array.from(row.children))if(node!==copy)actions.append(node);
       head.append(icon,copy,actions);row.remove();
       if(view.id==='viewActivos'){head.dataset.gaUnified='1';view.insertBefore(head,root);}
       if(view.id==='viewEmpleados'&&!actions.querySelector('.ga-u-refresh')){const b=make('button','btn secondary ga-u-refresh');b.type='button';b.textContent='Actualizar';b.addEventListener('click',()=>document.querySelector('#topHeader .top-refresh-btn')?.click());actions.prepend(b);}
     }else{root.classList.add('ga-u-head');root.prepend(icon,copy);}
   }
   root.dataset.gaUnified='1';
 }
 let queued=false;
 function run(){queued=false;for(const id of Object.keys(specs)){const v=document.getElementById(id);if(v)unify(v);}
   const active=Array.from(app.querySelectorAll(':scope > section[id^="view"]')).find(v=>v.style.display!=='none'&&!v.hidden);
   const compact=!!active&&['viewEmpleados','viewImpuestos','viewLibroDiario'].includes(active.id);
   document.getElementById('topHeader')?.classList.toggle('ga-u-compact-top',compact);
 }
 function queue(){if(!queued){queued=true;requestAnimationFrame(run);}}
 new MutationObserver(queue).observe(app,{childList:true,subtree:true,attributes:true,attributeFilter:['style','hidden']});queue();
})();
