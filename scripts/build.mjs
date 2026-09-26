import {readFile,writeFile,mkdir,copyFile} from 'node:fs/promises';
const reference='reference/';
let app=await readFile(reference+'app.js','utf8'),html=await readFile(reference+'index.html','utf8');
function replaceFunction(name,code){const pattern=new RegExp('(?:async )?function '+name+'\\([^\\n]*');if(!pattern.test(app))throw new Error('Missing function '+name);app=app.replace(pattern,()=>code);}
app=app.replace("sb.auth.getSession().then(({data})=>{if(data.session)loadApp(data.session.user)});",'');
app=app.replace("if(error){console.error(error);return true}","if(error){showToast('Conexión interrumpida','No se pueden comprobar los permisos. Reintenta.','warn');return false}");
app=app.replace('refreshTimer=setInterval(refresh,60000)','refreshTimer=setInterval(()=>{if(!document.hidden)refresh()},60000)');
replaceFunction('refresh',`async function refresh(){
 if(refreshInProgress)return;refreshInProgress=true;
 try{if(!await ensureAccountActive())return;
 const query=sb.from('shipments').select(SHIPMENT_SELECT).order('updated_at',{ascending:false}).limit(1000);
 if(lastRefreshAt)query.gte('updated_at',new Date(lastRefreshAt-120000).toISOString());
 const [a,b,c]=await Promise.all([query,sb.from('events').select('*').order('created_at',{ascending:false}).limit(100),sb.from('incidents').select('*').eq('resolved',false).order('created_at',{ascending:false}).limit(500)]);
 if(a.error||b.error||c.error)throw a.error||b.error||c.error;
 const merged=new Map(shipments.map(s=>[s.id,s]));
 if(!lastRefreshAt){for(let offset=0;;offset+=1000){const pending=await sb.from('shipments').select(SHIPMENT_SELECT).neq('status','ENTREGADO').order('id').range(offset,offset+999);if(pending.error)throw pending.error;for(const s of pending.data)merged.set(s.id,{...s,recipient_id:''});if(pending.data.length<1000)break;}}
 for(const s of a.data||[])merged.set(s.id,{...s,recipient_id:''});shipments=[...merged.values()].sort((a,b)=>new Date(b.requested_at)-new Date(a.requested_at));
 lastRefreshAt=a.data.length===1000?null:Math.max(lastRefreshAt||0,...a.data.map(s=>new Date(s.updated_at).getTime()));events=b.data||[];incs=c.data||[];metrics();render();renderWork();renderIncidents();updateOperationalAlert();
 if(a.data.length===1000)showToast('Vista limitada','Busca por número para consultar expedientes antiguos.','warn');
 }catch(e){showToast('No se pudo actualizar',e.message,'warn')}finally{refreshInProgress=false}
}`);
replaceFunction('loadStock',`async function loadStock(force=false){if(stockLoaded&&!force)return renderStock();let rows=[];for(let offset=0;offset<10000;offset+=1000){const {data,error}=await sb.from('warehouse_stock').select('*').order('tracking').range(offset,offset+999);if(error){$('stockcount').textContent='No se pudo cargar el stock.';return}rows.push(...data);if(data.length<1000)break;}const {data}=await sb.from('stock_imports').select('*').order('imported_at',{ascending:false}).limit(1).maybeSingle();stockRows=rows;latestStockImport=data;stockLoaded=true;renderStock()}`);
replaceFunction('confirmDelivery',`async function confirmDelivery(){
 const id=deliveryShipmentId,s=shipments.find(x=>x.id===id);if(!s)return closeDelivery();
 const n=$('deliveryname').value.trim(),dni=$('deliveryid').value.trim();if(n.length<2||dni.length<5)return showToast('Faltan datos','Indica nombre e identificación de quien recoge.','warn');
 if(signatureMarks<8)return showToast('Falta la firma','La persona que recoge debe firmar en el recuadro.','warn');
 $('deliveryconfirm').disabled=true;
 try{let file;for(const q of [.85,.65,.45,.25]){file=await new Promise(r=>$('signaturecanvas').toBlob(r,'image/webp',q));if(file?.type==='image/webp'&&file.size<=15000)break;}if(!file||file.type!=='image/webp'||file.size>15000)throw new Error('No se pudo generar una firma compacta. Borra y vuelve a firmar.');
 const path=id+'/'+crypto.randomUUID()+'.webp';const {error:upload}=await sb.storage.from('signatures').upload(path,file,{upsert:false,contentType:'image/webp'});if(upload)throw upload;
 const {error}=await sb.rpc('complete_delivery_secure',{p_id:id,p_name:n,p_dni:dni,p_path:path,p_expected_updated_at:s.updated_at});if(error)throw error;
 closeDelivery();await refresh();showToast('Entrega registrada',s.tracking+' · Firma guardada e identificación cifrada.','ok');
 }catch(e){showToast('No se pudo registrar la entrega',e.message+' Actualiza antes de repetir.','warn')}finally{$('deliveryconfirm').disabled=false}
}`);
app=app.replace("$('deliverymodal').classList.add('open');","resetSignature();$('deliverymodal').classList.add('open');");
app=app.replace("if(file.size>10*1024*1024)throw new Error(file.name+': supera 10 MB.');","file=await compactProof(file);if(file.size>500000)throw new Error(file.name+': supera 500 KB. Comprime el archivo antes de subirlo.');");
app=app.replace("'Identificacion'","'Identificacion protegida'").replace("s.recipient_id||''","''");
// Existing role-specific UI remains; every privileged operation is enforced by RLS/triggers.
const detailEnd="$('detail').scrollIntoView({behavior:'smooth'})}";
if(!app.includes(detailEnd))throw new Error('Detail insertion point missing');
app=app.replace(detailEnd,"$('detail').scrollIntoView({behavior:'smooth'});if(['RECEPCION','ADMIN'].includes(me.role)&&s.status==='ENTREGADO'){const box=document.createElement('div');box.className='actions';const b=document.createElement('button');b.className='btn btn2';b.textContent='Consultar identificación';b.onclick=()=>showIdentity(s.id);box.append(b);const f=document.createElement('button');f.className='btn btn2';f.textContent='Ver firma digital';f.onclick=()=>showDigitalSignature(s.id);box.append(f);$('detail').append(box)}}");
html=html.replace('<script src="app.js?v=47.2"></script>','<script src="app.js?v=48.0"></script>');
html=html.replace('id="deliveryid" class="field" autocomplete="off" placeholder="Opcional"','id="deliveryid" class="field" autocomplete="off" maxlength="32" placeholder="Obligatorio"');
html=html.replace('id="deliveryname" class="field" autocomplete="off"','id="deliveryname" class="field" autocomplete="off" maxlength="300"');
html=html.replace('<button id="deliveryconfirm"', '<button id="deliveryconfirm"');
const marker='<button id="deliveryconfirm"';
// Insert before the action row, using the observed DNI input as the stable anchor.
const dniMatch=html.match(/<input id="deliveryid"[^>]*>/);if(!dniMatch)throw new Error('Delivery input missing');
html=html.replace(dniMatch[0],dniMatch[0]+'<label class="formlabel" for="signaturecanvas">Firma de la persona que recoge</label><canvas id="signaturecanvas" width="600" height="220" aria-label="Firma de quien recoge"></canvas><button type="button" class="btn btn2" onclick="resetSignature()">Borrar firma</button><p class="fieldhint">La identificación se guarda cifrada. Firma vinculada exclusivamente a esta entrega.</p>');
html=html.replace('</style>','\n#signaturecanvas{width:100%;height:170px;border:1px solid #cbd5e1;border-radius:10px;background:white;touch-action:none;margin:8px 0}.releasebadge{font-size:11px;color:#64748b}\n</style>');
html=html.replace('</body>','<div class="releasebadge" style="text-align:center;padding:10px">Versión 48 · Firma digital · Acceso protegido</div></body>');
app+='\n'+await readFile('scripts/secure-features.js','utf8');
app+="\nsb.auth.getSession().then(({data})=>{if(data.session)loadApp(data.session.user)});\n";
await writeFile('public/app.js',app);await writeFile('public/index.html',html);
console.log('Version 48 generated from original ZIP.');
