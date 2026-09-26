import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const base='https://envios-recepcion-estacionados.alejandro-ferras-cttexpress.workers.dev';
const html=await fetch(base);assert.equal(html.status,200);assert.equal(html.headers.get('x-content-type-options'),'nosniff');assert.match(await html.text(),/Versión 48/);console.log('PASS production HTML, version and security headers');
const js=await (await fetch(base+'/app.js')).text(),local=await readFile(new URL('../public/app.js',import.meta.url),'utf8');
const hash=s=>createHash('sha256').update(s).digest('hex');assert.equal(hash(js),hash(local));console.log('PASS production JavaScript matches tested artifact');
const url=js.match(/SB_URL='([^']+)'/)[1],key=js.match(/SB_KEY='([^']+)'/)[1];
const headers={apikey:key,'Content-Type':'application/json'};
for(const table of ['shipments','delivery_signatures']){
 const r=await fetch(url+'/rest/v1/'+table+'?select=*&limit=1',{headers});
 const body=await r.json();assert.ok([401,403].includes(r.status)||(r.ok&&Array.isArray(body)&&body.length===0));console.log('PASS anonymous cannot read '+table);
}
const r=await fetch(url+'/rest/v1/rpc/complete_delivery_secure',{method:'POST',headers,body:JSON.stringify({p_id:'10000000-0000-4000-8000-000000000001',p_name:'Prueba',p_dni:'TEST-12345',p_path:'test',p_expected_updated_at:'2026-09-26T10:00:00Z'})});
assert.ok([401,403].includes(r.status));console.log('PASS public API refuses unauthenticated delivery');
console.log('5 live deployment checks passed');
