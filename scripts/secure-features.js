let refreshInProgress=false,lastRefreshAt=null,signatureMarks=0,signatureDrawing=false;
function resetSignature(){const canvas=$('signaturecanvas');if(!canvas)return;const ctx=canvas.getContext('2d');ctx.fillStyle='#ffffff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.strokeStyle='#172033';ctx.lineWidth=2.5;ctx.lineCap='round';signatureMarks=0;signatureDrawing=false;}
{
 const canvas=$('signaturecanvas'),ctx=canvas.getContext('2d');
 const point=e=>{const r=canvas.getBoundingClientRect();return[(e.clientX-r.left)*canvas.width/r.width,(e.clientY-r.top)*canvas.height/r.height];};
 canvas.addEventListener('pointerdown',e=>{signatureDrawing=true;canvas.setPointerCapture(e.pointerId);ctx.beginPath();ctx.moveTo(...point(e));});
 canvas.addEventListener('pointermove',e=>{if(signatureDrawing){ctx.lineTo(...point(e));ctx.stroke();signatureMarks++;}});
 for(const name of ['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(name,()=>signatureDrawing=false);
}
async function compactProof(file){
 if(file.type==='application/pdf'){if(file.size>500000)throw new Error('Comprime el PDF a menos de 500 KB antes de subirlo.');return file;}
 if(!['image/jpeg','image/png','image/webp'].includes(file.type))throw new Error('Formato no permitido.');
 const bitmap=await createImageBitmap(file),scale=Math.min(1,1600/Math.max(bitmap.width,bitmap.height)),canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(bitmap.width*scale));canvas.height=Math.max(1,Math.round(bitmap.height*scale));canvas.getContext('2d').drawImage(bitmap,0,0,canvas.width,canvas.height);bitmap.close();let blob;
 for(const quality of [.85,.65,.45,.25]){blob=await new Promise(r=>canvas.toBlob(r,'image/webp',quality));if(blob?.type==='image/webp'&&blob.size<=500000)break;}
 if(!blob||blob.type!=='image/webp'||blob.size>500000)throw new Error('No se pudo comprimir la imagen. Reduce su tamaño.');
 return new File([blob],file.name.replace(/\.[^.]+$/,'')+'.webp',{type:'image/webp'});
}
async function showIdentity(id){const {data,error}=await sb.rpc('get_delivery_identity',{p_id:id});if(error)return showToast('Consulta no disponible',error.message,'warn');alert(data?'Identificación: '+data:'No se registró identificación en esta entrega antigua.');}
async function showDigitalSignature(id){const {data,error}=await sb.from('delivery_signatures').select('storage_path').eq('shipment_id',id).maybeSingle();if(error)return showToast('Firma no disponible',error.message,'warn');if(!data)return showToast('Sin firma digital','Este expediente es anterior a la captura de firma. Consulta sus justificantes.','info');const {data:link,error:e}=await sb.storage.from('signatures').createSignedUrl(data.storage_path,120);if(e)return showToast('No se pudo abrir',e.message,'warn');window.open(link.signedUrl,'_blank','noopener');}
async function checkCapacity(){if(me?.role!=='ADMIN')return;const {data,error}=await sb.rpc('get_capacity_status');if(error)return;const used=Number(data.files_bytes),db=Number(data.database_bytes);if(used>700000000||db>400000000)showToast('Revisar capacidad',`Archivos: ${(used/1000000).toFixed(0)} MB. Base: ${(db/1000000).toFixed(0)} MB. Exporta una copia antes de alcanzar la cuota gratuita.`,'warn');}
setInterval(()=>{if(!document.hidden)checkCapacity()},300000);
// Exact lookup complements the recent operational window without loading all history.
let searchDelay;
$('search')?.addEventListener('input',()=>{clearTimeout(searchDelay);const value=$('search').value.trim();if(!value)return;searchDelay=setTimeout(async()=>{const {data,error}=await sb.from('shipments').select(SHIPMENT_SELECT).ilike('tracking',value.replace(/[\\%_]/g,'\\$&')).limit(20);if(error||$('search').value.trim()!==value)return;const existing=new Map(shipments.map(s=>[s.id,s]));for(const s of data||[])existing.set(s.id,{...s,recipient_id:''});shipments=[...existing.values()];render();},350);});
