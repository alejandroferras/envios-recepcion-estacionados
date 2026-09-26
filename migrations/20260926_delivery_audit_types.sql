CREATE OR REPLACE FUNCTION public.validate_event_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  uid uuid := auth.uid();
  r text;
  active_user boolean;
  s public.shipments%rowtype;
begin
  select role,active into r,active_user from public.profiles where id=uid;
  if uid is null or active_user is distinct from true or new.actor_id is distinct from uid then raise exception 'Evento no autorizado'; end if;
  select * into s from public.shipments where id=new.shipment_id;
  if not found then raise exception 'Expediente no válido'; end if;
  if new.event_type not in ('SOLICITUD_CREADA','SOLICITUD_IMPORTADA','LOCALIZANDO','PREPARADO','ENTREGADO_POR_ESTACIONADOS','RECIBIDO_EN_RECEPCION','ENTREGA_FINAL','INCIDENCIA','INCIDENCIA_RESUELTA','JUSTIFICANTE_ADJUNTO','CAMBIO_MASIVO','CORRECCION_ADMIN','EXPEDIENTE_ARCHIVADO','EXPEDIENTE_RESTAURADO','FIRMA_GUARDADA','IDENTIFICACION_CONSULTADA') then raise exception 'Tipo de evento no autorizado'; end if;

  if new.event_type='FIRMA_GUARDADA' then
    if r not in ('RECEPCION','ADMIN') or s.status<>'ENTREGADO' or not exists(select 1 from public.delivery_signatures d where d.shipment_id=s.id and d.created_by=uid) then raise exception 'Firma no vinculada a una entrega autorizada'; end if;
  elsif new.event_type='IDENTIFICACION_CONSULTADA' then
    if r not in ('RECEPCION','ADMIN') or s.status<>'ENTREGADO' then raise exception 'Consulta de identidad no autorizada'; end if;
  elsif new.event_type in ('SOLICITUD_CREADA','SOLICITUD_IMPORTADA') then
    if r not in ('RECEPCION','ADMIN') or s.requested_by is distinct from uid then raise exception 'Evento de solicitud incoherente'; end if;
  elsif new.event_type='LOCALIZANDO' then
    if r not in ('ESTACIONADOS','ADMIN') or s.status<>'LOCALIZANDO' then raise exception 'Evento incoherente con el estado'; end if;
  elsif new.event_type='PREPARADO' then
    if r not in ('ESTACIONADOS','ADMIN') or s.status<>'PREPARADO' or (r<>'ADMIN' and s.prepared_by is distinct from uid) then raise exception 'Evento incoherente con preparación'; end if;
  elsif new.event_type='ENTREGADO_POR_ESTACIONADOS' then
    if r not in ('ESTACIONADOS','ADMIN') or s.status<>'PENDIENTE_RECEPCION' or (r<>'ADMIN' and s.warehouse_by is distinct from uid) then raise exception 'Evento incoherente con transferencia'; end if;
  elsif new.event_type='RECIBIDO_EN_RECEPCION' then
    if r not in ('RECEPCION','ADMIN') or s.status<>'EN_RECEPCION' or (r<>'ADMIN' and s.reception_by is distinct from uid) then raise exception 'Evento incoherente con recepción'; end if;
  elsif new.event_type='ENTREGA_FINAL' then
    if r not in ('RECEPCION','ADMIN') or s.status<>'ENTREGADO' or (r<>'ADMIN' and s.delivered_by is distinct from uid) then raise exception 'Evento incoherente con entrega final'; end if;
  elsif new.event_type='INCIDENCIA' then
    if s.status<>'INCIDENCIA' then raise exception 'Evento incoherente con incidencia'; end if;
  elsif new.event_type='INCIDENCIA_RESUELTA' then
    if s.status<>'LOCALIZANDO' then raise exception 'Evento incoherente con resolución'; end if;
  elsif new.event_type='JUSTIFICANTE_ADJUNTO' then
    if r not in ('RECEPCION','ADMIN') or s.status<>'ENTREGADO' or not exists(
      select 1 from public.shipment_proofs sp where sp.shipment_id=s.id and sp.uploaded_by=uid and sp.uploaded_at > now()-interval '10 minutes'
    ) then raise exception 'Evento incoherente con justificante'; end if;
  elsif new.event_type='CAMBIO_MASIVO' then
    if r='ESTACIONADOS' and not (
      (s.status='LOCALIZANDO') or
      (s.status='PREPARADO' and s.prepared_by=uid) or
      (s.status='PENDIENTE_RECEPCION' and s.warehouse_by=uid)
    ) then raise exception 'Cambio masivo incoherente'; end if;
    if r='RECEPCION' and not (s.status='EN_RECEPCION' and s.reception_by=uid) then raise exception 'Cambio masivo incoherente'; end if;
  elsif new.event_type in ('CORRECCION_ADMIN','EXPEDIENTE_ARCHIVADO','EXPEDIENTE_RESTAURADO') and r<>'ADMIN' then
    raise exception 'Evento reservado a ADMIN';
  end if;
  return new;
end;
$function$;
