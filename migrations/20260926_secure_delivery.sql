-- Additive migration. Existing shipments, users and evidence remain intact.
CREATE TABLE private.delivery_key (
 id smallint PRIMARY KEY CHECK(id=1), key_value text NOT NULL
);
ALTER TABLE private.delivery_key ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.delivery_key FROM PUBLIC,anon,authenticated;
INSERT INTO private.delivery_key VALUES(1,encode(extensions.gen_random_bytes(32),'hex'));

CREATE TABLE private.delivery_identity (
 shipment_id uuid PRIMARY KEY REFERENCES public.shipments(id),
 encrypted_dni bytea NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE private.delivery_identity ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.delivery_identity FROM PUBLIC,anon,authenticated;

CREATE TABLE public.delivery_signatures (
 shipment_id uuid PRIMARY KEY REFERENCES public.shipments(id),
 storage_path text NOT NULL UNIQUE,
 created_by uuid NOT NULL REFERENCES public.profiles(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.delivery_signatures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.delivery_signatures FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.delivery_signatures TO authenticated;
CREATE POLICY delivery_signatures_read ON public.delivery_signatures FOR SELECT TO authenticated
 USING(EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=(SELECT auth.uid()) AND p.active AND p.role IN ('ADMIN','RECEPCION')));

INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 VALUES('signatures','signatures',false,15000,ARRAY['image/webp']);
CREATE POLICY signatures_upload ON storage.objects FOR INSERT TO authenticated
 WITH CHECK(bucket_id='signatures' AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=(SELECT auth.uid()) AND p.active AND p.role IN ('ADMIN','RECEPCION'))
 AND EXISTS(SELECT 1 FROM public.shipments s WHERE s.id::text=split_part(name,'/',1) AND s.status='EN_RECEPCION'));
CREATE POLICY signatures_read ON storage.objects FOR SELECT TO authenticated
 USING(bucket_id='signatures' AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=(SELECT auth.uid()) AND p.active AND p.role IN ('ADMIN','RECEPCION'))
 AND EXISTS(SELECT 1 FROM public.delivery_signatures d WHERE d.storage_path=name));

-- Definer required only to access private encryption material. Identity and role
-- are verified inside every public entrypoint; search_path is fixed.
CREATE FUNCTION public.complete_delivery_secure(p_id uuid,p_name text,p_dni text,p_path text,p_expected_updated_at timestamptz)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,private,extensions AS $$
DECLARE uid uuid:=auth.uid(); shipment public.shipments%rowtype; secret text;
BEGIN
 IF uid IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=uid AND active AND role IN ('ADMIN','RECEPCION')) THEN RAISE EXCEPTION 'Entrega no autorizada'; END IF;
 IF length(btrim(p_name)) NOT BETWEEN 2 AND 300 OR length(btrim(p_dni)) NOT BETWEEN 5 AND 32 THEN RAISE EXCEPTION 'Nombre o identificación no válidos'; END IF;
 IF p_name IS NULL OR p_dni IS NULL OR p_path IS NULL OR p_expected_updated_at IS NULL THEN RAISE EXCEPTION 'Faltan datos de entrega'; END IF;
 SELECT * INTO shipment FROM public.shipments WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Envío no encontrado'; END IF;
 IF shipment.status='ENTREGADO' AND EXISTS(SELECT 1 FROM public.delivery_signatures WHERE shipment_id=p_id AND storage_path=p_path AND created_by=uid) THEN RETURN jsonb_build_object('ok',true,'already_saved',true); END IF;
 IF shipment.status<>'EN_RECEPCION' OR shipment.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'El envío ha cambiado. Actualiza la pantalla'; END IF;
 IF split_part(p_path,'/',1)<>p_id::text OR NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='signatures' AND o.name=p_path AND o.owner_id=uid::text AND o.metadata->>'mimetype'='image/webp' AND (o.metadata->>'size')::bigint BETWEEN 1 AND 15000) THEN RAISE EXCEPTION 'La firma no existe o no pertenece al usuario'; END IF;
 SELECT key_value INTO secret FROM private.delivery_key WHERE id=1;
 INSERT INTO private.delivery_identity(shipment_id,encrypted_dni) VALUES(p_id,extensions.pgp_sym_encrypt(btrim(p_dni),secret,'cipher-algo=aes256,compress-algo=0'));
 INSERT INTO public.delivery_signatures(shipment_id,storage_path,created_by) VALUES(p_id,p_path,uid);
 UPDATE public.shipments SET status='ENTREGADO',recipient_name=btrim(p_name),recipient_id=NULL,delivered_by=uid,delivered_at=now() WHERE id=p_id;
 INSERT INTO public.events(shipment_id,actor_id,event_type,detail) VALUES(p_id,uid,'FIRMA_GUARDADA','Firma e identificación cifrada vinculadas a la entrega');
 RETURN jsonb_build_object('ok',true);
END $$;
REVOKE ALL ON FUNCTION public.complete_delivery_secure(uuid,text,text,text,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.complete_delivery_secure(uuid,text,text,text,timestamptz) TO authenticated;

CREATE FUNCTION private.require_delivery_signature() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,private AS $$
BEGIN
 IF new.status='ENTREGADO' AND old.status IS DISTINCT FROM new.status THEN
  IF NOT EXISTS(SELECT 1 FROM public.delivery_signatures WHERE shipment_id=new.id AND created_by=auth.uid()) OR NOT EXISTS(SELECT 1 FROM private.delivery_identity WHERE shipment_id=new.id) THEN RAISE EXCEPTION 'La entrega requiere firma e identificación cifrada'; END IF;
  IF new.recipient_id IS NOT NULL THEN RAISE EXCEPTION 'La identificación debe almacenarse cifrada'; END IF;
 END IF;
 RETURN new;
END $$;
REVOKE ALL ON FUNCTION private.require_delivery_signature() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER require_delivery_signature BEFORE UPDATE ON public.shipments FOR EACH ROW EXECUTE FUNCTION private.require_delivery_signature();

CREATE FUNCTION public.get_delivery_identity(p_id uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,private,extensions AS $$
DECLARE result text; secret text; uid uuid:=auth.uid();
BEGIN
 IF uid IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=uid AND active AND role IN ('ADMIN','RECEPCION')) THEN RAISE EXCEPTION 'Acceso no autorizado'; END IF;
 SELECT key_value INTO secret FROM private.delivery_key WHERE id=1;
 SELECT extensions.pgp_sym_decrypt(encrypted_dni,secret) INTO result FROM private.delivery_identity WHERE shipment_id=p_id;
 IF NOT FOUND THEN SELECT recipient_id INTO result FROM public.shipments WHERE id=p_id; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.shipments WHERE id=p_id) THEN RAISE EXCEPTION 'Envío no encontrado'; END IF;
 INSERT INTO public.events(shipment_id,actor_id,event_type,detail) VALUES(p_id,uid,'IDENTIFICACION_CONSULTADA','Consulta individual de identificación');
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_delivery_identity(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_delivery_identity(uuid) TO authenticated;

CREATE FUNCTION public.get_capacity_status() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,storage AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND role='ADMIN') THEN RAISE EXCEPTION 'Acceso no autorizado'; END IF;
 RETURN jsonb_build_object('database_bytes',pg_database_size(current_database()),'files_bytes',(SELECT coalesce(sum((metadata->>'size')::bigint),0) FROM storage.objects WHERE bucket_id IN ('proofs','signatures')),'files_count',(SELECT count(*) FROM storage.objects WHERE bucket_id IN ('proofs','signatures')));
END $$;
REVOKE ALL ON FUNCTION public.get_capacity_status() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_capacity_status() TO authenticated;

