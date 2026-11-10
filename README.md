# AuraQR · Laboratorio de 16 KB

El laboratorio ejecuta un ensayo manual en Ubuntu 24.04 x86-64. Usa un AAB aprobado como entrada, comprueba su SHA-256 y deriva splits para el AVD API 36 con bundletool 1.18.3 y una firma efímera. El resultado acredita instalación y dos arranques en ese entorno si se cumplen todos los controles.

## Configuración posterior a la aprobación

1. Publicar únicamente estos cuatro archivos en `auralabsdev-code/aura-qr-16kb-qa`. Proteger `main` y limitar quién puede modificar el workflow. El YAML solo acepta `workflow_dispatch` desde `main` en ese repositorio y omite reintentos.
2. Crear el entorno `private-aab`, restringirlo a `main` y usar aprobación de un revisor cuando esté disponible. Configurar sus secretos `AURAQR_SOURCE_REPOSITORY`, `AURAQR_SOURCE_RUN`, `AURAQR_SOURCE_ARTIFACT` y `AURAQR_SOURCE_COMMIT` con los datos privados aprobados. No introducirlos como parámetros del lanzamiento.
3. Justo antes del despacho, crear un **fine-grained personal access token** con el propietario del repositorio fuente como resource owner. En **Only select repositories**, seleccionar únicamente el repositorio fuente. Conceder **Actions: read** como único permiso configurable; el permiso **Metadata: read** se añade automáticamente. Elegir la caducidad más corta disponible. Guardar el PAT como secreto de entorno `AURAQR_ARTIFACT_PAT` en `private-aab` y revocarlo al completar o abandonar definitivamente todas las ejecuciones autorizadas. El permiso de lectura abarca Actions en el repositorio seleccionado y GitHub no permite limitarlo a un solo artefacto.
4. Despachar una vez desde `main` y verificar el resultado. El artefacto privado debe seguir disponible. Si caducó, se requiere un canal privado aprobado para recuperar los mismos bytes. El AAB y los APK no se incluyen en el repositorio ni en los artefactos públicos.

## Requisitos y criterio de resultado

- Runner hospedado público `ubuntu-24.04` con KVM. El preflight exige 4 vCPU, 6 GiB disponibles y espacio para el SDK y la imagen. El AVD usa 3 vCPU y 4 GiB.
- SDK Android del runner, Java con `keytool`, `apksigner` 36.0.0, Python 3, Bash, jq, curl, openssl, unzip y herramientas GNU. El script instala las herramientas Android que falten y la imagen oficial `system-images;android-36;google_apis_ps16k;x86_64`. Registra su revisión y valida el entorno efectivo.
- Se detiene ante falta de KVM, hash incorrecto, tamaño de página distinto de 16384, compatibilidad activa, aislamiento no acreditado o ANR. Verifica el bloqueo IPv4 e IPv6 antes de instalar y durante los dos arranques.
- El artefacto de evidencia contiene únicamente estado, hashes, versión y muestras de estabilidad. Los logs crudos, capturas y binarios quedan fuera del artefacto público. La firma temporal solo acredita la instalación de laboratorio.
- La lectura QR y el tráfico AdMob quedan fuera del ensayo sin ventana y sin Internet. El resultado se limita a API 36 x86_64.
