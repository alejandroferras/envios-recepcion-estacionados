import {createClient} from "https://esm.sh/@supabase/supabase-js@2";
const ALLOWED_ORIGINS=new Set([
  "https://envios-recepcion-estacionados.alejandro-ferras-cttexpress.workers.dev",
  "https://alejandroferras.github.io",
  "http://localhost:3000"
]);
function headers(req:Request){
  const origin=req.headers.get("Origin")||"";
  const h:Record<string,string>={
    "Content-Type":"application/json",
    "Cache-Control":"no-store",
    "Vary":"Origin",
    "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods":"POST, OPTIONS"
  };
  if(ALLOWED_ORIGINS.has(origin))h["Access-Control-Allow-Origin"]=origin;
  return h;
}
function out(req:Request,body:unknown,status=200){return new Response(JSON.stringify(body),{status,headers:headers(req)})}
const ROLES=["RECEPCION","ESTACIONADOS","ADMIN"];
Deno.serve(async(req)=>{
  const H=headers(req);
  if(req.method==="OPTIONS")return new Response("ok",{headers:H});
  if(req.method!=="POST")return out(req,{error:"Método no permitido"},405);
  const origin=req.headers.get("Origin");
  if(origin&&!ALLOWED_ORIGINS.has(origin))return out(req,{error:"Origen no permitido"},403);
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,svc=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth=req.headers.get("Authorization")||"";
  const caller=createClient(url,anon,{global:{headers:{Authorization:auth}},auth:{persistSession:false}});
  const {data:{user}}=await caller.auth.getUser();
  if(!user)return out(req,{error:"No autorizado"},401);
  const admin=createClient(url,svc,{auth:{persistSession:false}});
  const {data:p}=await admin.from("profiles").select("id,full_name,role,active").eq("id",user.id).single();
  if(!p?.active||p.role!=="ADMIN")return out(req,{error:"Solo ADMIN"},403);
  let b:any;
  try{b=await req.json()}catch{return out(req,{error:"Solicitud no válida"},400)}
  const activeAdminCount=async()=>{
    const {count}=await admin.from("profiles").select("*",{count:"exact",head:true}).eq("role","ADMIN").eq("active",true);
    return count||0;
  };
  if(b.action==="create"){
    const email=String(b.email||"").trim().toLowerCase(),full_name=String(b.full_name||"").trim(),password=String(b.password||"");
    if(!email||!email.includes("@")||password.length<12||!ROLES.includes(b.role))return out(req,{error:"Datos no válidos. La contraseña debe tener al menos 12 caracteres."},400);
    const {data,error}=await admin.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{full_name}});
    if(error)return out(req,{error:error.message},400);
    const {error:pe}=await admin.from("profiles").update({full_name,role:b.role,active:true}).eq("id",data.user.id);
    if(pe){await admin.auth.admin.deleteUser(data.user.id);return out(req,{error:"No se pudo crear el perfil del usuario."},400)}
    return out(req,{ok:true});
  }
  if(b.action==="list"){
    const {data:ps}=await admin.from("profiles").select("id,full_name,role,active,created_at").order("full_name");
    const {data:au}=await admin.auth.admin.listUsers({page:1,perPage:1000});
    const data=(ps||[]).map((x:any)=>{const u=au?.users?.find((z:any)=>z.id===x.id);return {...x,email:u?.email||"",last_sign_in_at:u?.last_sign_in_at||null}});
    return out(req,{data});
  }
  if(b.action==="update"){
    if(!b.id||!ROLES.includes(b.role))return out(req,{error:"Datos no válidos"},400);
    const {data:target}=await admin.from("profiles").select("id,role,active").eq("id",b.id).single();
    if(!target)return out(req,{error:"Usuario no encontrado"},404);
    if(b.id===user.id&&(b.active===false||b.role!=="ADMIN"))return out(req,{error:"No puedes desactivar ni retirar el rol ADMIN de tu propia cuenta."},400);
    if(target.role==="ADMIN"&&target.active&&(b.role!=="ADMIN"||!b.active)&&(await activeAdminCount())<=1)return out(req,{error:"Debe permanecer al menos un ADMIN activo."},400);
    const {error}=await admin.from("profiles").update({full_name:String(b.full_name||"").trim(),role:b.role,active:!!b.active}).eq("id",b.id);
    return out(req,error?{error:error.message}:{ok:true},error?400:200);
  }
  if(b.action==="reset"||b.action==="reset_password"){
    const password=String(b.password||"");
    if(!b.id||password.length<12)return out(req,{error:"Contraseña mínima: 12 caracteres"},400);
    const {error}=await admin.auth.admin.updateUserById(b.id,{password});
    return out(req,error?{error:error.message}:{ok:true},error?400:200);
  }
  if(b.action==="delete"){
    if(!b.id)return out(req,{error:"Usuario no válido"},400);
    if(b.id===user.id)return out(req,{error:"No puedes eliminar tu propia cuenta"},400);
    const {data:target}=await admin.from("profiles").select("id,role,active").eq("id",b.id).single();
    if(!target)return out(req,{error:"Usuario no encontrado"},404);
    if(target.role==="ADMIN"&&target.active&&(await activeAdminCount())<=1)return out(req,{error:"Debe permanecer al menos un ADMIN activo."},400);
    const refs:[string,string[]][]=[
      ["shipments",["requested_by","warehouse_by","prepared_by","reception_by","delivered_by","corrected_by"]],
      ["events",["actor_id"]],
      ["incidents",["actor_id"]],
      ["request_batches",["created_by"]],
      ["stock_imports",["imported_by"]],
      ["shipment_proofs",["uploaded_by"]]
    ];
    for(const [t,cols] of refs)for(const c of cols){
      const {count,error}=await admin.from(t).select("*",{count:"exact",head:true}).eq(c,b.id);
      if(error)return out(req,{error:"No se pudo verificar el historial del usuario."},400);
      if((count||0)>0)return out(req,{error:"Este usuario tiene actividad histórica. Desactívalo para conservar la trazabilidad."},400);
    }
    const {error}=await admin.auth.admin.deleteUser(b.id);
    if(error)return out(req,{error:error.message},400);
    return out(req,{ok:true});
  }
  return out(req,{error:"Acción desconocida"},400);
});
