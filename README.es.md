# plesk-s3-backup

Copias de seguridad diarias de un servidor **Plesk** en **S3** (o cualquier
almacenamiento compatible con S3), con **rotación automática** de las copias
guardadas en el bucket.

[Read in English](README.md)

- **Bases de datos**: todos los días, un `mysqldump` comprimido por cada base
  de datos (y opcionalmente otro con todas juntas). Cada volcado se comprueba
  antes de subirlo.
- **Ficheros**: un `tar.gz` por cada suscripción de Plesk
  (`/var/www/vhosts/<dominio>`) los días de la semana que elijas. Los dominios
  se **detectan automáticamente** desde Plesk, así que los sitios nuevos
  entran en la copia sin tocar nada.
- **Rotación en S3**: copias diarias durante 2 meses, después una cada 15 días
  hasta los 6 meses, una al mes hasta el año y una al año a partir de ahí.
- **Limpieza local** de copias locales y logs antiguos.
- **Un único punto de entrada**, que lanza un timer de systemd una vez al día,
  y **un único email de informe** por ejecución: un panel en HTML con el
  resultado de cada base de datos y dominio, las copias que se conservan en
  cada nivel de retención, el espacio ocupado en S3 y lo que ha tardado. El
  log completo va adjunto.

Este proyecto es la evolución de
[mysql_backup](https://github.com/DRodero/mysql_backup), que solo copiaba las
bases de datos. Mantiene su comprobación de los volcados y el informe por
email, y añade la copia de ficheros, la rotación en S3 y un instalador con
systemd.

## Cómo funciona la rotación

Cada ejecución se guarda bajo una carpeta con la fecha:

```
s3://bucket/servidor/BD/2026/11/02/<bd>/<bd>_2026-11-02-03.30.00.sql.gz
s3://bucket/servidor/Files/2026/11/01/<dominio>/2026-11-01-03.45.12-files-<dominio>.tar.gz
```

Cada carpeta de fecha es un *conjunto de copias*. Todos los días la rotación
lista los conjuntos y decide cuáles conservar según su antigüedad:

| Antigüedad        | Se conserva                                   |
|-------------------|-----------------------------------------------|
| 0 – 60 días       | todos                                         |
| 60 – 180 días     | uno por quincena (días 1–15 y 16–fin de mes)  |
| 180 – 365 días    | uno por mes natural                           |
| más de 365 días   | uno por año natural (para siempre, o N años)  |

En cada intervalo se conserva el conjunto **más antiguo**. Los intervalos
encajan unos dentro de otros (quincena ⊂ mes ⊂ año), así que la copia que
sobrevive en un nivel es la misma que sobrevive en el siguiente, y una copia
conservada nunca se sustituye por otra más nueva con el paso del tiempo. En
régimen estable son unos 75 conjuntos de BD y 23 de ficheros semanales, más
uno por año.

Salvaguardas:

- Nunca se borran los `KEEP_MIN_RECENT` conjuntos más recientes (7 por
  defecto): si las copias dejan de funcionar, la rotación no puede vaciar el
  histórico.
- Si la copia de un tipo (BD o ficheros) ha fallado hoy, no se rota ese tipo.
- Un conjunto solo se borra si existe otro más antiguo del mismo intervalo,
  así que un listado incompleto de S3 solo puede hacer que se conserve más,
  nunca menos.
- `ROTATE_DRY_RUN=yes` (valor por defecto en la configuración de ejemplo) solo
  informa de lo que borraría.
- Las copias que ya existan con la estructura `PREFIJO/AAAA/MM/DD/` también se
  rotan.

Todos los umbrales se pueden cambiar en la configuración.

## Requisitos

- Servidor Linux con Plesk y systemd (Ubuntu, Debian, AlmaLinux, Rocky…),
  ejecutado como root.
- `s3cmd` configurado con acceso al bucket (`s3cmd --configure`).
- `mysql`/`mysqldump`, `tar`, `gzip`, `flock` (vienen en cualquier servidor
  Plesk).
- `sendmail` (el Postfix/qmail de Plesk) o `mail` para el informe por email.

## Instalación

```bash
# 1. Descargar el código
git clone https://github.com/DRodero/plesk-s3-backup.git /opt/plesk-s3-backup

# 2. Instalar: crea /etc/plesk-s3-backup/backup.conf (chmod 600),
#    los directorios de datos y el servicio y timer de systemd
/opt/plesk-s3-backup/install.sh

# 3. Configurar
nano /etc/plesk-s3-backup/backup.conf

# 4. Comprobar configuración, MySQL, acceso a S3 y dominios detectados
plesk-s3-backup check

# 5. Primera ejecución a mano, siguiendo el log
systemctl start plesk-s3-backup.service
journalctl -u plesk-s3-backup -f

# 6. Activar la ejecución diaria (03:30 por defecto)
systemctl enable --now plesk-s3-backup.timer
systemctl list-timers plesk-s3-backup.timer
```

Dónde queda cada cosa:

| Ruta | Qué |
|------|-----|
| `/opt/plesk-s3-backup` | el código (un clon de git) |
| `/usr/local/sbin/plesk-s3-backup` | enlace a `backup.sh` |
| `/etc/plesk-s3-backup/backup.conf` | configuración (solo root) |
| `/var/backups/plesk-s3-backup/` | copias locales (se guardan `LOCAL_KEEP_DAYS` días) |
| `/var/log/plesk-s3-backup/` | un log por ejecución (se guardan `LOG_KEEP_DAYS` días) |
| `/var/lib/plesk-s3-backup/` | bloqueo y cola de subidas pendientes de reintentar |

Para cambiar la hora: `systemctl edit plesk-s3-backup.timer` y añadir

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 02:00:00
```

### Actualizar

```bash
git -C /opt/plesk-s3-backup pull
/opt/plesk-s3-backup/install.sh
```

La configuración nunca se sobrescribe. Compárala con `backup.conf.example`
para ver si hay opciones nuevas.

### Sin systemd (cron)

```bash
echo '30 3 * * * root /opt/plesk-s3-backup/backup.sh run > /dev/null 2>&1' > /etc/cron.d/plesk-s3-backup
```

### Desinstalar

```bash
/opt/plesk-s3-backup/install.sh --uninstall
```

Se conservan la configuración, los logs y las copias locales; bórralos a mano
si quieres.

## Migrar desde tus propios scripts de cron

1. Instala siguiendo los pasos de arriba, **sin** activar todavía el timer.
2. En `backup.conf`, pon en `S3_DB_PREFIX` y `S3_FILES_PREFIX` las mismas
   rutas que usabas, si ya seguían el esquema `AAAA/MM/DD/<nombre>/`: así tus
   copias antiguas entran también en la rotación.
3. Si ya tenías un fichero `[client]` de MySQL, apúntalo en
   `MYSQL_DEFAULTS_FILE` (o muévelo a `/etc/plesk-s3-backup/mysql.cnf` con
   `chmod 600`).
4. `plesk-s3-backup check` y `plesk-s3-backup list` para revisar qué haría la
   rotación.
5. Quita las líneas antiguas del crontab (`crontab -e`) y activa el timer.
6. Deja `ROTATE_DRY_RUN=yes` unos días, revisa los emails y cámbialo a `no`.

## Uso

```
plesk-s3-backup [--config FICHERO] [--dry-run] COMANDO

  run                 punto de entrada diario (lo que lanza el timer)
  db                  copia de las bases de datos ahora
  files [DOMINIO...]  copia de ficheros ahora (todos o los indicados)
  cleanup             borra copias locales y logs antiguos
  rotate [db|files]   aplica la política de retención en S3
  list [db|files]     muestra qué copias se conservan o se borrarían, y por qué
  check               comprueba configuración, dependencias, MySQL y S3
```

`run` hace, en este orden: reintentar las subidas que fallaron otros días,
bases de datos, ficheros (solo los días de `FILES_WEEKDAYS`), limpieza local,
rotación de BD y de ficheros, e informe por email. Si algo falla termina con
código distinto de cero, así que `systemctl status plesk-s3-backup` también
muestra las ejecuciones fallidas.

## Configuración

Mira [`backup.conf.example`](backup.conf.example); todas las opciones están
comentadas. Las más importantes:

| Opción | Por defecto | |
|--------|-------------|---|
| `S3_DB_PREFIX`, `S3_FILES_PREFIX` | — | dónde se guardan las copias |
| `MYSQL_DEFAULTS_FILE` | vacío | fichero `[client]` de MySQL; vacío = cuenta admin de Plesk |
| `FILES_WEEKDAYS` | `7` | días de copia de ficheros (1=lunes … 7=domingo) |
| `DOMAINS` | `auto` | `auto` = todas las suscripciones de Plesk, o una lista |
| `DOMAINS_EXCLUDE` | `()` | suscripciones que no se copian |
| `KEEP_*` | 60 / 180 / 365 / siempre | umbrales de la rotación |
| `ROTATE_DRY_RUN` | `yes` | ponlo a `no` cuando te fíes del plan |

## Email de informe

Al final de cada `run` se envía un email a `MAIL_TO` con:

- estado (OK / WARNING / ERROR), duración y hora de inicio;
- bases de datos y dominios copiados, con tamaño, tiempo y estado de cada uno
  (los fallos primero);
- los días sin copia de ficheros, los dominios protegidos por la última copia
  de ficheros y los dominios nuevos que aún no están en ella;
- copias que se conservan en S3 por nivel de retención, cuántas se han
  borrado (o se borrarían) y la copia más antigua;
- espacio ocupado en S3;
- errores y avisos, y el log completo adjunto.

Pon `MAIL_FORMAT=text` para recibirlo en texto plano, o `MAIL_ON_SUCCESS=no`
para recibirlo solo cuando algo falle.

### Si no llega el email

Gmail, Outlook y otros rechazan el correo de servidores no autenticados. El
informe se envía con `MAIL_FROM` como remitente del sobre, así que:

1. Usa en `MAIL_FROM` una dirección del propio hostname del servidor, por
   ejemplo `backup@servidor.ejemplo.com`.
2. Crea un registro SPF para ese hostname:
   `servidor.ejemplo.com TXT "v=spf1 a -all"`.
3. Configura el DNS inverso (PTR) de la IP del servidor con ese hostname, en
   el panel de tu proveedor.

El log de correo dice por qué se rechazó un mensaje:
`grep -i gmail /var/log/maillog` (RHEL/Alma) o `/var/log/mail.log` (Debian/Ubuntu).

## Restaurar

```bash
# Ver qué hay disponible
s3cmd ls s3://bucket/servidor/BD/2026/11/02/

# Una base de datos
s3cmd get s3://bucket/servidor/BD/2026/11/02/mibd/mibd_2026-11-02-03.30.00.sql.gz
gunzip < mibd_2026-11-02-03.30.00.sql.gz | MYSQL_PWD=$(cat /etc/psa/.psa.shadow) mysql -uadmin mibd

# Los ficheros de un dominio (extrae primero en otra carpeta y copia lo que necesites)
s3cmd get s3://bucket/servidor/Files/2026/11/01/ejemplo.com/2026-11-01-03.45.12-files-ejemplo.com.tar.gz
mkdir /root/restore && tar -xzf 2026-11-01-*-files-ejemplo.com.tar.gz -C /root/restore
```

## Seguridad

- Las copias se suben **privadas**. No uses nunca `s3cmd put -P`: las copias
  de ficheros contienen `wp-config.php`, `.env` y otras credenciales. Para
  poner privados objetos subidos antes:
  `s3cmd setacl --acl-private --recursive s3://bucket/prefijo/`
- Usa una clave de S3 que solo tenga acceso al bucket de copias.
- Valora activar versionado u object lock en el bucket si necesitas
  protegerte de que un servidor comprometido borre sus propias copias.

## Tests

```bash
bash tests/test_retention.sh
```

Comprueban la aritmética de fechas, casos fijos de retención, y simulan 2,5
años de copias diarias y semanales para verificar el resultado y que la
rotación es estable.

## Licencia

[MIT](LICENSE)
