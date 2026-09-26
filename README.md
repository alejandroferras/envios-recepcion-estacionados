# Estacionados · versión 48

Producción: https://envios-recepcion-estacionados.alejandro-ferras-cttexpress.workers.dev/

## Uso

Entra con tu cuenta existente. Recepción registra solicitudes y confirma la recepción. Estacionados localiza, prepara y transfiere. La entrega final exige nombre, identificación y firma. Administración mantiene los usuarios y consulta informes.

La firma nueva se guarda en un contenedor privado; los enlaces de consulta caducan a los dos minutos. Las identificaciones nuevas se cifran y se consultan individualmente con registro de auditoría. Los expedientes anteriores conservan sus datos y justificantes originales.

## Cambios

- Firma WebP de hasta 15.000 bytes y entrega atómica con control de cambios simultáneos.
- DNI nuevo cifrado con AES-256 mediante pgcrypto. La clave queda en una tabla privada sin permisos para clientes; comparte la base con el cifrado y no sustituye un gestor externo de claves.
- Inventario paginado; verificados 2.359 registros.
- Actualización incremental y carga de todos los pendientes. El histórico inicial muestra los 1.000 cambios recientes; buscar por número exacto recupera expedientes antiguos. Los informes y CSV actuales se calculan sobre los expedientes cargados, no sobre todo el histórico.
- Compresión de fotografías a WebP, máximo 500 KB. Los PDF mayores deben comprimirse antes de subirlos.
- Comprobación de permisos cerrada ante fallos de conexión.

## Servicios y conservación

Se conserva la arquitectura autorizada sin tarjeta: Cloudflare Workers Static Assets y el proyecto existente de Supabase para Auth, base de datos y archivos privados. No se activó R2 ni se migró a Neon.

La cuota gratuita de archivos aceptada es 1 GB. No cubre cinco años de firmas a 300 entregas diarias: 547.500 × 15 KB = 8,21 GB, sin justificantes. Se requieren copias externas verificadas y gestión manual de capacidad. Esta versión no incluye exportación masiva de documentos ni purga automática. El CSV no es una copia de firmas, DNI cifrados o justificantes. Antes de cualquier purga, exportar base de datos, material de descifrado y archivos a almacenamiento cifrado, y probar su recuperación. No se ha borrado ningún dato.

Supabase Free puede pausar proyectos por inactividad. No se contrataron planes de pago. La conservación durante cinco años es un requisito indicado por el usuario, no una conclusión jurídica de esta implementación.

## Validación realizada

- 15 pruebas de permisos, firma obligatoria, cifrado, concurrencia y reintentos en PostgreSQL local con pgcrypto y los disparadores existentes.
- 6 pruebas de interfaz: paginación, caché, datos obligatorios, permisos y ausencia de descarga masiva de DNI.
- 5 comprobaciones contra producción: página, versión, cabeceras, coincidencia del código y bloqueo de accesos anónimos.
- Flujo SQL completo en la base real dentro de una transacción revertida: solicitud → localización → preparación → transferencia → recepción → entrega; descifrado y auditoría comprobados. El objeto de firma de esa prueba era metadato temporal, no una subida real a Storage.
- Pendiente: login, persistencia, logout, captura y subida de firma desde una sesión real del navegador. No había una sesión ni contraseña disponible. No se afirma una verificación completa de extremo a extremo.

El asesor de seguridad conserva la advertencia de protección frente a contraseñas filtradas desactivada: https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection . También identifica las funciones SECURITY DEFINER accesibles a autenticados; es intencional, con validación interna de usuario activo y rol, permisos anónimos revocados y search_path fijo: https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable . Las dos tablas privadas no tienen políticas RLS porque deben denegar todo acceso directo de clientes: https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy .

## Mantenimiento

Node.js 22 o superior y pnpm. `pnpm install --frozen-lockfile`, `pnpm build`, `pnpm test`. `node tests/live.test.mjs` comprueba el despliegue sin autenticarse. `pnpm deploy` publica únicamente public/ en el Worker existente.

Las dos migraciones SQL incluidas ya están aplicadas al proyecto actual. No ejecutarlas otra vez. En una copia compatible, aplicar primero secure_delivery y después delivery_audit_types. No retroceder el frontend a la versión 47: carece del flujo de firma que la base exige ahora.

El paquete contiene código y pruebas, no una copia de los datos de producción. Las credenciales de Wrangler y los registros privados están excluidos.
