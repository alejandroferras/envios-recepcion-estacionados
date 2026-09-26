CREATE OR REPLACE FUNCTION public.audit_shipment_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  uid uuid:=auth.uid();
  typ text;
  det text;
begin
  if uid is null then raise exception 'Auditoría sin usuario autenticado'; end if;

  if tg_op='INSERT' then
    insert into public.events(shipment_id,actor_id,event_type,detail)
    values(new.id,uid,'SOLICITUD_CREADA',
      case when new.stock_snapshot is not null then 'Solicitud registrada desde stock de almacén'
           else 'Solicitud registrada' end);
    return new;
  end if;

  if new.status is distinct from old.status then
    typ:=null; det:=null;
    if new.status='INCIDENCIA' then
      insert into public.incidents(shipment_id,actor_id,detail)
      values(new.id,uid,new.incident_reason);
      typ:='INCIDENCIA'; det:=new.incident_reason;
    elsif old.status='INCIDENCIA' and new.status='LOCALIZANDO' then
      update public.incidents
      set resolved=true,resolved_at=now()
      where shipment_id=new.id and resolved=false;
      typ:='INCIDENCIA_RESUELTA'; det:='Incidencia resuelta';
    elsif old.status='SOLICITADO' and new.status='LOCALIZANDO' then
      typ:='LOCALIZANDO'; det:='Envío en localización';
    elsif old.status='LOCALIZANDO' and new.status='PREPARADO' then
      typ:='PREPARADO'; det:='Envío preparado en Estacionados';
    elsif old.status in ('PREPARADO','INCIDENCIA') and new.status='PENDIENTE_RECEPCION' then
      typ:='ENTREGADO_POR_ESTACIONADOS'; det:='Pendiente de confirmación de Recepción';
    elsif old.status='PENDIENTE_RECEPCION' and new.status='EN_RECEPCION' then
      typ:='RECIBIDO_EN_RECEPCION'; det:='Custodia confirmada en Recepción';
    elsif old.status='EN_RECEPCION' and new.status='ENTREGADO' then
      typ:='ENTREGA_FINAL'; det:='Entregado a '||coalesce(new.recipient_name,'')||
        case when nullif(new.recipient_id,'') is not null then ' · ID '||new.recipient_id else '' end;
    else
      typ:='CAMBIO_MASIVO'; det:='Cambio de '||old.status||' a '||new.status;
    end if;
    insert into public.events(shipment_id,actor_id,event_type,detail)
    values(new.id,uid,typ,det);
  end if;

  if new.corrected_at is distinct from old.corrected_at and new.corrected_at is not null then
    insert into public.events(shipment_id,actor_id,event_type,detail)
    values(new.id,uid,'CORRECCION_ADMIN',
      'Corrección administrativa · Motivo: '||coalesce(new.correction_reason,'No indicado'));
  end if;

  if new.archived is distinct from old.archived then
    insert into public.events(shipment_id,actor_id,event_type,detail)
    values(new.id,uid,
      case when new.archived then 'EXPEDIENTE_ARCHIVADO' else 'EXPEDIENTE_RESTAURADO' end,
      coalesce(nullif(new.archive_reason,''),case when new.archived then 'Expediente archivado' else 'Expediente restaurado' end));
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.enforce_shipment_update_security()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  uid uuid := auth.uid();
  r text;
  active_user boolean;
  oldj jsonb := to_jsonb(old);
  newj jsonb;
begin
  select p.role,p.active into r,active_user from public.profiles p where p.id=uid;
  if uid is null or active_user is distinct from true then raise exception 'Usuario no autorizado'; end if;

  if new.status='INCIDENCIA' and old.status<>'ENTREGADO' and nullif(btrim(new.incident_reason),'') is not null then
    new.updated_at:=now(); newj:=to_jsonb(new);
    if (newj-array['status','incident_reason','updated_at']) is not distinct from (oldj-array['status','incident_reason','updated_at']) then return new; end if;
  end if;

  if old.status='INCIDENCIA' and new.status='LOCALIZANDO' and new.incident_reason is null then
    new.updated_at:=now(); newj:=to_jsonb(new);
    if (newj-array['status','incident_reason','updated_at']) is not distinct from (oldj-array['status','incident_reason','updated_at']) then return new; end if;
  end if;

  if r in ('ESTACIONADOS','ADMIN') then
    if old.status='SOLICITADO' and new.status='LOCALIZANDO' then
      new.updated_at:=now(); newj:=to_jsonb(new);
      if (newj-array['status','updated_at']) is not distinct from (oldj-array['status','updated_at']) then return new; end if;
    end if;
    if old.status='LOCALIZANDO' and new.status='PREPARADO' then
      new.prepared_by:=uid; new.prepared_at:=now(); new.updated_at:=now(); newj:=to_jsonb(new);
      if (newj-array['status','prepared_by','prepared_at','updated_at']) is not distinct from (oldj-array['status','prepared_by','prepared_at','updated_at']) then return new; end if;
    end if;
    if old.status in ('PREPARADO','INCIDENCIA') and new.status='PENDIENTE_RECEPCION' then
      new.warehouse_by:=uid; new.warehouse_at:=now(); new.handoff_at:=now(); new.updated_at:=now(); newj:=to_jsonb(new);
      if (newj-array['status','warehouse_by','warehouse_at','handoff_at','updated_at']) is not distinct from (oldj-array['status','warehouse_by','warehouse_at','handoff_at','updated_at']) then return new; end if;
    end if;
  end if;

  if r in ('RECEPCION','ADMIN') then
    if old.status='PENDIENTE_RECEPCION' and new.status='EN_RECEPCION' then
      new.reception_by:=uid; new.reception_at:=now(); new.reception_confirmed_at:=now(); new.updated_at:=now(); newj:=to_jsonb(new);
      if (newj-array['status','reception_by','reception_at','reception_confirmed_at','updated_at']) is not distinct from (oldj-array['status','reception_by','reception_at','reception_confirmed_at','updated_at']) then return new; end if;
    end if;
    if old.status='EN_RECEPCION' and new.status='ENTREGADO' and nullif(btrim(new.recipient_name),'') is not null then
      new.delivered_by:=uid; new.delivered_at:=now(); new.updated_at:=now(); newj:=to_jsonb(new);
      if (newj-array['status','recipient_name','recipient_id','delivered_by','delivered_at','updated_at']) is not distinct from (oldj-array['status','recipient_name','recipient_id','delivered_by','delivered_at','updated_at']) then return new; end if;
    end if;
  end if;

  if r='ADMIN' and new.status=old.status then
    if new.corrected_by=uid and new.corrected_at is not null and nullif(btrim(new.correction_reason),'') is not null then
      new.updated_at:=now(); newj:=to_jsonb(new);
      if (newj-array['customer_name','package_location','notes','external_reference','priority','corrected_at','corrected_by','correction_reason','updated_at'])
         is not distinct from
         (oldj-array['customer_name','package_location','notes','external_reference','priority','corrected_at','corrected_by','correction_reason','updated_at'])
      then return new; end if;
    end if;

    if new.archived is distinct from old.archived and nullif(btrim(new.archive_reason),'') is not null then
      if new.archived and old.status<>'ENTREGADO' then raise exception 'Solo se pueden archivar envíos entregados'; end if;
      new.updated_at:=now(); newj:=to_jsonb(new);
      if (newj-array['archived','archive_reason','updated_at']) is not distinct from (oldj-array['archived','archive_reason','updated_at'])
      then return new; end if;
    end if;
  end if;

  raise exception 'Actualización o transición no autorizada para este perfil';
end;
$function$;



