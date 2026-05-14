# DBAegis

DBAegis is a database resilience platform with a web UI, FastAPI backend, backup history, restore jobs, storage destinations, and support for logical, physical, and disaster-recovery validation workflows.

The current VM layout keeps DBAegis tool files under `/opt/dbaegis`. Test databases and throwaway database files should be kept outside the tool tree, under `/opt/testdatabases`.

## Current Highlights

- Web UI served through nginx with a FastAPI backend.
- Community, Professional, and Enterprise edition features are tracked in [docs/PRODUCT_EDITIONS.md](docs/PRODUCT_EDITIONS.md).
- Commercial/private builds require signed license keys for paid editions; edition behavior and install-time license settings are documented in [docs/PRODUCT_EDITIONS.md](docs/PRODUCT_EDITIONS.md) and [docs/INSTALL_UPGRADE_UNINSTALL.md](docs/INSTALL_UPGRADE_UNINSTALL.md).
- Release packages include a `PACKAGE_CONTENTS.json` audit and exclude developer packaging scripts, tests, CI configuration, runtime state, keys, logs, backups, generated secrets, internal planning docs, and validation evidence from customer artifacts.
- Community release packages use an additional restricted payload profile so paid/private overlay paths are not shipped.
- Community packages include the clean `app/community/` runtime for PostgreSQL, MySQL, and MongoDB DBAegis-local logical backup/restore.
- Paid-edition MFA, RBAC, email notification delivery, self-backup, the full product runtime, and paid backup/restore engine implementations are isolated under `app/professional/` and excluded from Community packages.
- Enterprise-only LDAP / Active Directory, webhook delivery, and report export implementations are isolated under `app/enterprise/` and excluded from Community and Professional packages.
- Release packages do not bundle the installed Python runtime or virtualenv. All editions use the installer to download and checksum-verify the pinned embedded Python runtime by default, or to validate a configured Python 3.12+ runtime.
- The customer handbook PDF is available at [docs/DBAEGIS_HANDBOOK.pdf](docs/DBAEGIS_HANDBOOK.pdf). Professional and Enterprise packages also include operations and production monitoring guides.
- Control-plane disaster recovery is documented in [docs/CONTROL_PLANE_DISASTER_RECOVERY.md](docs/CONTROL_PLANE_DISASTER_RECOVERY.md).
- Connection manager with backup type, destination, tags, and engine-specific options.
- Backup history records `backup_type` so logical and physical backups are clearly separated.
- Logical backups expose compression choices where supported, and restore accepts both compressed and uncompressed artifact suffixes.
- Restore jobs support dry run, overwrite/create options, engine logs, reason capture, password re-authorization, and typed high-risk confirmation.
- Restore can select a configured cloud storage type/location, browse a prefix, and restore an exact selected object URI, including compatible externally uploaded files.
- Backup and restore execution runs in DBAegis server-side background workers, so jobs continue after the user logs out or closes the browser as long as the DBAegis service remains running.
- AWS S3, Google Cloud Storage, and Azure Blob storage destinations are supported for backup and restore paths that can stream directly or safely stage required file artifacts; Couchbase supports Enterprise native object-store mode when explicitly selected and Community/default DB VM staged archive tarball fallback.
- AWS S3, Google Cloud Storage, and Azure Blob storage destination credentials are encrypted at rest in the DBAegis metadata database using `DBAEGIS_SECRET_KEY` and are redacted in API/UI responses.
- Professional and Enterprise local users can use Microsoft Authenticator-compatible MFA, managed from `Access Control` and encrypted with `DBAEGIS_SECRET_KEY`; Community shows MFA as edition locked.
- Global and per-connection notifications can be filtered to start, success, failure, or daily summary events. Professional supports email delivery; Enterprise adds active webhooks with a last-24-hours daily summary report window.
- Enterprise admin report exports are available as CSV for backup status, restore status, schedule status, and audit events. Connection status reports support optional tag filtering.
- Backup history, restore jobs, schedules, self-backups, daily summaries, and operator logs use the VM local timezone.
- Repository cleanup excludes runtime files, license files, virtualenvs, logs, caches, backups, test databases, and temporary `.bak`, `.old`, `.bad`, and `.new` files.

## Product File And Folder Structure

The GitHub repository contains the DBAegis source, web UI, config templates, documentation, release metadata, and automated tests. Installer-created runtime state such as the active SQLite metadata DB, license files, logs, TLS material, virtual environments, rollback snapshots, and backup artifacts is intentionally kept out of git.

Representative tracked product structure:

```text
.
|-- README.md
|-- release.json
|-- app/
|   |-- main.py
|   |-- main_auth_roles.py
|   |-- auth_step1_append.py
|   |-- version.py
|   |-- license.py
|   |-- webhook_security.py
|   |-- community/
|   |   |-- __init__.py
|   |   `-- runtime.py
|   |-- professional/
|   |   |-- auth_mfa.py
|   |   |-- backup_engine.py
|   |   |-- global_notifications.py
|   |   |-- main_auth_roles.py
|   |   |-- main_runtime.py
|   |   |-- notifications.py
|   |   |-- rbac.py
|   |   |-- restore_engine.py
|   |   |-- restore_options.py
|   |   `-- self_backup.py
|   |-- enterprise/
|   |   |-- __init__.py
|   |   |-- auth_ldap.py
|   |   |-- reports.py
|   |   `-- webhooks.py
|   `-- services/
|       |-- backup_engine.py
|       |-- restore_engine.py
|       |-- restore_options.py
|       `-- global_notifications.py
|-- bin/
|   |-- install.sh
|   |-- uninstall.sh
|   |-- dbaegis
|   |-- dbaegis-stack
|   |-- rotate_dbaegis_secret_key.py
|   |-- reset_admin_password.py
|   `-- install_auth_roles.sh
|-- conf/
|   `-- dbaegis.conf.example
|-- requirements/
|   |-- dependency-inventory.json
|   `-- install-constraints.txt
|-- scripts/
|   |-- package_release.py
|   |-- backup_restore_support_audit.py
|   |-- check_dependency_updates.py
|   |-- control_plane_dr_drill.py
|   `-- control_plane_load_test.py
|-- docs/
|   |-- PRODUCT_EDITIONS.md
|   |-- INSTALL_UPGRADE_UNINSTALL.md
|   |-- BACKUP_RESTORE_SUPPORT.md
|   |-- CONTROL_PLANE_DISASTER_RECOVERY.md
|   |-- DBAEGIS_HANDBOOK.pdf
|   |-- PRODUCT_OPERATIONS_RUNBOOK.md
|   `-- PRODUCTION_MONITORING_ALERTING.md
|-- tests/
|   `-- test_*.py
`-- ui/
    |-- index.html
    |-- index_auth_roles.html
    |-- index_auth_ui_roles.html
    |-- favicon.svg
    `-- db-logos/
        `-- *.svg
```

Path details:

- `app/main.py`: edition dispatcher. Source checkouts and paid packages load the full Professional runtime from `app/professional/main_runtime.py`; Community packages without that overlay load `app/community/runtime.py`.
- `app/community/`: Community-safe FastAPI runtime for PostgreSQL, MySQL, and MongoDB DBAegis-local logical backup/restore, limited schedules, and basic retention.
- `app/main_auth_roles.py` and `app/auth_step1_append.py`: legacy compatibility modules retained for tests and older access-control packaging flows. `main_auth_roles.py` is now a compatibility shim for the Professional overlay; the supported service entry point is `app/main.py`.
- `app/professional/`: paid-edition implementation overlays, including the full FastAPI runtime, paid backup/restore implementation, and signed license verification/issuer backend. Community packages exclude this path.
- `app/enterprise/`: Enterprise-only implementation overlays for LDAP / Active Directory, webhook delivery, and CSV report exports. Community and Professional packages exclude this path.
- `app/services/`: compatibility shims for backup execution, restore execution/options, and global notification delivery. Their paid implementations live under `app/professional/`.
- `app/version.py`: product version source of truth used by the API, CLI, logs, and UI.
- `app/license.py`: Community-safe license status, edition entitlement, and CLI facade. Paid signed-token verification and issuer commands are implemented in `app/professional/license.py` and are not included in Community packages.
- `app/webhook_security.py`: Enterprise-only webhook signing, validation, SSRF guard, and delivery helper. Community and Professional packages exclude this file.
- `bin/install.sh`: supported installer and upgrade entry point. It creates required runtime folders, config, service files, prechecks, dependencies, and rollback snapshots.
- `bin/uninstall.sh`: uninstall helper for DBAegis service/runtime cleanup.
- `bin/dbaegis` and `bin/dbaegis-stack`: CLI/service wrappers for running the application stack.
- `bin/rotate_dbaegis_secret_key.py`: offline secret-key rotation utility used by `dbaegis rotate-secret-key`.
- `bin/reset_admin_password.py`: shell recovery utility used by `dbaegis reset-admin-password` to reset one local admin password.
- `conf/dbaegis.conf.example`: sanitized configuration template for manual deployments and config-management systems. The active `conf/dbaegis.conf` is generated locally and is not committed.
- `requirements/install-constraints.txt`: pinned Python dependency constraints used by the installer for reproducible venv creation. The installer copies this file into the installed tree so future installed-tree upgrades keep using the same constraints.
- `requirements/dependency-inventory.json`: reviewed dependency and optional tool inventory used by the offline dependency checker.
- `scripts/package_release.py`: repeatable edition package builder and package-protection guard.
- `scripts/backup_restore_support_audit.py`: generated support-matrix/audit validation helper.
- `scripts/check_dependency_updates.py`: dependency inventory checker for online review and offline CI validation.
- `scripts/control_plane_dr_drill.py` and `scripts/control_plane_load_test.py`: control-plane disaster-recovery and load-test helpers.
- `ui/index.html`: main single-page DBAegis web UI.
- `ui/index_auth_roles.html` and `ui/index_auth_ui_roles.html`: legacy redirect shims retained for older bookmarks/package layouts. The supported UI entry point is `ui/index.html`.
- `ui/db-logos/`: database/provider icons used by connection and restore screens.
- `docs/`: customer documentation for install/upgrade/uninstall, backup/restore support, edition behavior, control-plane disaster recovery, product operations, and production monitoring. Customer packages include only the required docs for the selected edition; internal planning, license-issuing, validation, screenshot, and security-assessment docs remain source-only.
- `docs/PRODUCT_EDITIONS.md`: Community, Professional, and Enterprise feature matrix, limits, database coverage, and entitlement feature keys.
- `docs/INSTALL_UPGRADE_UNINSTALL.md`: install, upgrade, rollback, uninstall, and edition-change operations.
- `docs/BACKUP_RESTORE_SUPPORT.md`: supported backup targets, restore sources, database engines, storage destinations, and PITR support notes.
- `docs/CONTROL_PLANE_DISASTER_RECOVERY.md`: recovery procedures for DBAegis metadata, config, license files, TLS material, self-backups, and local artifacts.
- `docs/DBAEGIS_HANDBOOK.pdf`: complete customer handbook with UI screenshots and day-to-day product guidance.
- `docs/PRODUCT_OPERATIONS_RUNBOOK.md`: Professional and Enterprise operations guide for lifecycle, management, troubleshooting, support, incident, and recovery workflows.
- `docs/PRODUCTION_MONITORING_ALERTING.md`: Professional and Enterprise monitoring, alerting, dashboard, and response practices.
- `tests/`: focused Python tests for backup options, connection/restore parameter smoke coverage, restore logic, cloud dispatch, connection preflight, version metadata, webhook routes, and restore security.
- `release.json`: packaged release metadata. Official production archives include this file so `/api/version` reports the stable release channel.

Runtime paths created or populated on an installed VM:

- `conf/dbaegis.conf`: active local configuration, owned by the DBAegis service user.
- `data/`: SQLite metadata database and related local state.
- `logs/`: application and nginx logs.
- `license/`: issued license token, public verification key, and related local license metadata.
- `run/`: process/socket/runtime files, including generated nginx config under `run/nginx/conf/`.
- `backups/`: DBAegis-local backup artifacts when that destination is selected.
- `tmp/`: temporary restore, upload, cloud, and SSH working files.
- `tls/`: generated or installed TLS certificates.
- `rollback/`: installer rollback snapshots created during upgrades.
- `python/` and `venv/`: installed Python runtime and virtual environment content. These are runtime artifacts created by the installer and are not shipped inside release tarballs.
- `vendor/`: optional DBAegis-managed client tooling that belongs with the installed app. MongoDB client tools default to `/opt/dbaegis-tools/mongodb`, and local test database runtimes such as MySQL Oracle should live under `/opt/testdatabases`, not inside the product tree.

## Version Metadata

`app/version.py` is the product version source of truth. The FastAPI app metadata, `/api/version`, `dbaegis version`, startup logs, and UI sidebar all read from that module.

Release packaging can add optional build metadata with `/opt/dbaegis/release.json`, `DBAEGIS_RELEASE_MANIFEST`, or CI/CD environment variables such as `DBAEGIS_GIT_COMMIT`, `DBAEGIS_BUILD_TIME`, and `DBAEGIS_BUILD_CHANNEL`.

Official production release archives include a `release.json` file at the package root. Operators do not need to pass `DBAEGIS_BUILD_CHANNEL=stable` during normal production installs.

```json
{
  "build_channel": "stable"
}
```

Then install normally:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --fresh
```

The installer copies the packaged manifest to `/opt/dbaegis/release.json`. `/api/version` reads the channel from that manifest and derives missing product, version, and release-name details from `app/version.py`, so it reports `build_channel: stable` and a release name such as `DBAegis 1.0.0`.

Verify after install:

```bash
curl http://127.0.0.1:8000/api/version
```

If TLS is enabled, verify HTTPS too:

```bash
curl -k https://127.0.0.1:3443/api/version
```

Port `3443` is the default DBAegis HTTPS port. Keep it when it fits the organization network policy, or override it with `DBAEGIS_HTTPS_PORT` during install.

`DBAEGIS_BUILD_CHANNEL`, `DBAEGIS_BUILD_TIME`, and `DBAEGIS_GIT_COMMIT` are for custom CI/package pipelines when a package manifest is not available. If no release manifest or build-channel environment variable is present, `/api/version` intentionally reports `build_channel: development`.

## Install and Upgrade Parameters

Run a normal production install from an official package without release metadata overrides:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --fresh
```

Common fresh-install overrides:

```bash
sudo DBAEGIS_USER=dbaegis \
  DBAEGIS_DB_PATH=/data/dbaegis/dbaegis.db \
  DBAEGIS_BACKUP_DIR=/srv/backups \
  DBAEGIS_TEMP_DIR=/srv/dbaegis-tmp \
  bash bin/install.sh --fresh
```

Use `--upgrade` to update application files while preserving the existing `conf/dbaegis.conf`, SQLite metadata, and backup artifacts:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

Each upgrade creates a pre-upgrade runtime snapshot under `/opt/dbaegis/rollback`. To roll back application/runtime files while preserving the active config and SQLite metadata DB:

```bash
sudo DBAEGIS_USER=dbaegis bash /opt/dbaegis/bin/install.sh --rollback
```

Edition upgrades and downgrades are package changes plus license changes. Install the target edition package with `bin/install.sh --upgrade`, install a matching Professional or Enterprise token when the target edition is paid, and preserve metadata/history while locking out-of-edition features. Full procedure: [Edition Upgrade and Downgrade](docs/INSTALL_UPGRADE_UNINSTALL.md#edition-upgrade-and-downgrade).

Full parameter reference: [Install and Upgrade Parameters](docs/INSTALL_UPGRADE_UNINSTALL.md#install-and-upgrade-parameters).

## Supported Databases

DBAegis includes connection/test and backup/restore support for these database families:

Community packages expose only PostgreSQL, MySQL, and MongoDB with DBAegis-local
logical backup/restore. Professional and Enterprise packages add the broader
paid runtime coverage listed below.

- PostgreSQL
- MySQL
- MariaDB
- MongoDB
- Redis / Valkey
- SQLite
- Neo4j
- CouchDB
- Couchbase
- Microsoft SQL Server
- Oracle
- Cassandra
- ClickHouse
- Cloud/provider systems surfaced in the UI, including DynamoDB, Firestore, Azure SQL, Cosmos DB, and Snowflake where applicable

Actual backup and restore capability depends on the local database client tools installed on the VM and the selected backup mode.

## Backup Modes

### Logical Backups

Logical backups export data through database client tools or APIs.

Examples:

- PostgreSQL: `pg_dump`
- MySQL / MariaDB: `mysqldump`
- MongoDB: `mongodump --archive`
- Redis / Valkey: key scan/export using `redis-cli` or `valkey-cli`
- SQLite: database file stream/copy
- Neo4j: Cypher export through Bolt
- Cassandra: table export through the Python Cassandra driver
- CouchDB: `_all_docs` export
- ClickHouse: `clickhouse-client` schema plus `JSONEachRow` logical archive (`.clickhouse.json.gz`)
- Microsoft SQL Server / Azure SQL: `sqlpackage` BACPAC export/import

Logical backup is the preferred mode for object-storage workflows.

Logical backups that write DBAegis-managed gzip-capable artifacts expose a `Compression Level` option. `Auto`, `Fast`, and `Best` write compressed artifacts, while `None` writes the plain equivalent. For example, PostgreSQL/MySQL/MariaDB logical backups can be `.sql.gz` or `.sql`, MongoDB logical backups can be `.archive.gz` or `.archive`, API/document exports can be `.json.gz` or `.json`, Cassandra/Snowflake exports can be `.csv.gz` or `.csv`, and ClickHouse archives can be `.clickhouse.json.gz` or `.clickhouse.json`. Restore detects gzip/tar handling from the artifact suffix, so mixed compressed and uncompressed logical backups can be restored from the same UI. Native formats such as `.bacpac`, `.bak`, `.dmp`, `.dump`, `.backup`, and `.rdb` remain native files; Oracle Data Pump exposes native `Auto`, `None`, and `Data Pump All` choices while still writing `.dmp`. The per-database default compression table is in [docs/BACKUP_RESTORE_SUPPORT.md](docs/BACKUP_RESTORE_SUPPORT.md#default-compression-by-database).

### Physical Backups

Physical backups capture database files, dumps, or engine-native backup artifacts. DBAegis supports physical workflows for engines such as PostgreSQL, SQL Server, Oracle RMAN, Neo4j, and other database families where the engine can produce or consume physical backup artifacts.

Where the native tool supports a real backup-mode flag, DBAegis exposes a backup-type selector instead of requiring raw extra arguments. Current selectors cover Couchbase `cbbackupmgr` full vs incremental/default archives, Neo4j dump/full/differential online backups, SQL Server full/differential/copy-only `.bak` backups, and Oracle RMAN full or incremental level 0/1 backups.

Advanced `extra_args` are reserved for native tool paths that can safely append engine-specific arguments. Command-style `extra_args` are shell-split with quote handling, and malformed values or shell control tokens are rejected instead of ignored. SQL Server physical backup and restore treat `extra_args` as additional `WITH` clauses such as `STATS=10` or `CHECKSUM`; Oracle RMAN physical backup/restore treats `extra_args` as a single RMAN clause and rejects statement separators.

Oracle RMAN target and catalog connect strings are sent inside the RMAN command script over stdin, not as `rman target ... catalog ...` process arguments. This keeps RMAN credentials out of the operating-system process list while preserving the same backup and restore options.

Professional and Enterprise also support engine-specific physical PITR for
self-managed PostgreSQL, Oracle, MySQL, MariaDB, and Microsoft SQL Server.
PostgreSQL PITR restores a physical base backup, writes `restore_command`,
`recovery_target_time`, and by default `recovery_target_action = 'promote'`,
then lets PostgreSQL replay copied WAL to the requested target. Oracle PITR uses
RMAN physical backups, archived redo logs from the backup or a copied
archive-log source, and a target timestamp or SCN. DBAegis emits Oracle RMAN
`SET UNTIL` inside the RMAN `RUN` block, runs recovery, and opens with
`RESETLOGS` unless validate-only mode is selected. MySQL and MariaDB PITR
restore a physical base backup and replay copied binary logs with
`mysqlbinlog`; SQL Server PITR restores a full `.bak`, optional differential,
and ordered `.trn` log chain with `STOPAT`. Managed database services should
use provider-native PITR unless the provider exposes the real host filesystem
and native tooling required by DBAegis physical restore.

Physical backup tools usually require local/server-side staging or engine-native backup directories. In the standard split-VM workflow, direct cloud backup without DB VM staging is limited to logical stream/export workflows; PostgreSQL physical backup also stages a `pg_basebackup` tarball on the DB VM before DBAegis uploads or copies it. SQLite is treated as a DB VM file when the DBAegis VM and database VM are separate.

## Cloud Storage Behavior

DBAegis distinguishes **DBAegis local** from **DB server local** backup destinations. DBAegis local means the artifact is stored on the DBAegis VM. DB server local means a database-native tool writes the artifact to a path visible to the database server. For client-tool engines, DB server local requires SSH remote execution on the connection so DBAegis can run the backup command on the DB host.

DBAegis supports DBAegis-local backup destinations plus AWS S3, Google Cloud Storage, and Azure Blob Storage for database modes that can stream directly or stage required file artifacts on the DB VM. Couchbase supports Enterprise native object-store archives when explicitly selected and a Community/default DB VM staged archive tarball fallback because native Couchbase object-store archives are Enterprise-only.

Managed database endpoints such as Amazon RDS, Amazon Aurora, Amazon DocumentDB, Google Cloud SQL, Azure Database for MySQL/PostgreSQL, Azure SQL Database, MongoDB Atlas, ElastiCache, ClickHouse Cloud, Snowflake, Cosmos DB, DynamoDB, and Firestore are supported only through their matching logical protocol/API paths. Configure the DBAegis connection with the engine type, for example `mysql`, `postgresql`, `mongodb`, `azuresql`, or `mssql`. Do not use physical or DB-server-local modes for managed services unless the provider gives you real host filesystem and SSH/tool access. See the [managed and serverless database coverage](docs/BACKUP_RESTORE_SUPPORT.md#managed-and-serverless-database-coverage) table for details.

Connection defaults and manual backup runs select a destination type first, such as DBAegis VM, DB server, AWS S3, Azure Blob, or GCS. When the selected type has configured storage destinations, the UI then shows a dropdown of matching active destinations so the connection or run uses the exact configured path, bucket, container, or prefix.

Backup History keeps completed and failed backup rows for audit. Failed backup alerts can be dismissed from the failure guidance or history views after review; dismissal removes the row from needs-attention summaries while keeping the failed status, logs, artifact metadata, dismissal time, and dismissing user in history. The backup `Retry` action starts a new backup for the same connection with current settings; it does not rerun or mutate the old failed backup row.

Storage destination types are canonicalized before backup/restore execution. `s3`, `aws`, `amazon`, `s3compatible`, `s3-compatible`, and `minio` are treated as AWS S3-compatible storage; `gcs`, `google`, `google_cloud_storage`, `google-cloud-storage`, `gcp`, and `gs` are treated as Google Cloud Storage; `azure`, `az`, `azblob`, `azureblob`, `azure_blob`, `azure-blob`, and `blob` are treated as Azure Blob Storage. Remote backup and restore URIs use the same normalization, so `s3://`, `gcs://` or `gs://`, and `azure://` or `az://` sources resolve to the canonical `s3`, `gcs`, and `azure` providers.

Restore can use DBAegis-generated backups or external objects that were not created by DBAegis, as long as the file suffix and content match the selected database restore path. In the restore UI, choose a cloud storage type first, then a matching `Cloud Storage Location`. `Cloud Folder Prefix` scopes the object listing in the selected bucket/container, while `Selected Cloud File URI` is the exact object that will be restored. Changing the cloud storage location clears any previously selected file URI to avoid restoring from the wrong provider or prefix.

The storage `Test` action validates the saved configuration and performs a temporary remote write/delete probe for AWS S3, Google Cloud Storage, and Azure Blob destinations. The probe writes under the configured prefix using a `.dbaegis-precheck/` object and removes it immediately after upload.

For cloud destinations, supported backups write directly to object storage unless the engine requires an explicit fallback documented in the support matrix. Unsupported modes fail instead of silently creating unexpected temporary backup artifacts on the DBAegis VM.

Large cloud backup and restore artifacts use an extended provider transfer timeout. The default is 900 seconds per SDK request for GCS and Azure transfers, and a storage destination can override it with `upload_timeout_seconds`, `download_timeout_seconds`, or `transfer_timeout_seconds`. This is most useful for Oracle RMAN, SQL Server `.bak`, and other large staged artifacts.

Saved secrets are encrypted before they are written to DBAegis metadata. This includes connection passwords, connection option secrets such as SSH passwords/private keys, storage destination credentials, SMTP passwords, LDAP bind passwords, local-user MFA enrollment secrets, webhook URLs/sensitive headers, and sensitive restore options. DBAegis decrypts these fields only inside backend paths that need them. API/UI read responses return redacted values such as `***redacted***`, and update requests can send that redacted marker to keep the existing encrypted secret.

Database TLS/client certificate settings are optional per connection under `tls_options`. These database-client certificates are separate from the DBAegis web UI/API HTTPS certificate. Use database TLS options only when the database or company policy requires encrypted DB client connections, CA validation, or client certificate authentication. Certificate files are not uploaded by DBAegis; their paths must already exist on the host where the database client tool runs: the DBAegis VM for DBAegis-local/direct-cloud workflows, or the DB server for SSH/DB-server workflows. See [docs/BACKUP_RESTORE_SUPPORT.md](docs/BACKUP_RESTORE_SUPPORT.md#database-tls-and-certificate-options) for supported engines, fields, placement rules, and file-permission guidance.

Rotate `DBAEGIS_SECRET_KEY` with the offline maintenance command, not by editing the config directly. Stop DBAegis first. Stopping and starting the service normally requires root/sudo, but default installs own `dbaegis.conf` and the metadata DB as the DBAegis service user, so the rotation command itself can run as that user:

```bash
sudo systemctl stop dbaegis
sudo -u dbaegis /opt/dbaegis/bin/dbaegis rotate-secret-key --generate-new-key --update-conf
sudo systemctl start dbaegis
```

If you are already logged in as the DBAegis service user, omit `sudo -u dbaegis`. If you want to provide the replacement key explicitly instead of generating it, avoid putting the secret directly on the command line. For example, read it into an environment variable and pass the variable name:

```bash
read -r -s DBAEGIS_NEW_KEY
export DBAEGIS_NEW_KEY
sudo --preserve-env=DBAEGIS_NEW_KEY -u dbaegis /opt/dbaegis/bin/dbaegis rotate-secret-key --new-key-env DBAEGIS_NEW_KEY --update-conf
unset DBAEGIS_NEW_KEY
```

The raw `--old-key OLD_KEY --new-key NEW_KEY` flags are valid for controlled lab use, but they can expose secrets through shell history or process listings. The command decrypts saved connection passwords, connection option secrets, storage destination secrets, SMTP/LDAP secrets, local-user MFA enrollment secrets, webhook secrets, and restore-option secrets with the current key and re-encrypts them with the new key. The `--update-conf` path creates DB/config backups and updates `conf/dbaegis.conf` only after the database rotation succeeds. If the old key is lost, those encrypted secrets cannot be recovered and must be re-entered.

System backup/self-backup archives include the DBAegis metadata database, but their copy of `dbaegis.conf` has sensitive values such as `DBAEGIS_SECRET_KEY` redacted. If you restore a self-backup created before a key rotation, the restored metadata database still contains secrets encrypted with the old key. To fully use that restored metadata, either start DBAegis with the matching old `DBAEGIS_SECRET_KEY` or run `bin/dbaegis rotate-secret-key --old-key-env DBAEGIS_OLD_KEY --new-key-env DBAEGIS_CURRENT_KEY` against the restored database while DBAegis is stopped. If the old key is unavailable, the metadata/history can still be restored, but encrypted saved secrets must be re-entered.

All DBAegis VM temporary scratch space uses the global `DBAEGIS_TEMP_DIR` from `conf/dbaegis.conf` (default `/opt/dbaegis/tmp`). This remains an internal service setting for local restore preparation, temporary SSH key files, and managed-service/client-side artifacts such as Snowflake or Azure SQL. DB VM temporary staging uses `db_vm_temp_dir` on the connection/options, with aliases such as `remote_staging_path`, `server_temp_dir`, `remote_backup_output_path`, `oracle_db_temp_dir`, and `couchbase_db_temp_dir` accepted for engines that use DB-server files. The add/edit connection backup options expose `DB VM Temp / Staging Location` for physical/file backups and SQLite/Oracle logical backups that must build a DB-server file before DBAegis copies it to DBAegis local storage or streams it to AWS S3, Azure Blob, or GCS. Couchbase cloud fallback now defaults to DB VM staging with `logical_options.couchbase_temp_location=db_vm`; set `logical_options.couchbase_db_temp_dir` to choose the DB VM path. Temporary files are removed after upload or restore.

In the restore UI, choose `Restore Type` before choosing a target connection. DBAegis filters the connection list to connections configured with the same `backup_type`: logical restores show only logical connections, and physical restores show only physical connections. Changing restore type or connection clears stale restore parameters and redraws the engine-specific options. Dual-mode engines show separate logical and physical parameter panels; SQLite logical restores expose primary database-file restore settings, while SQLite physical restores additionally expose WAL/SHM sidecar and DB VM staging controls.

The restore popup shows a compact summary of database type, target connection, source type, and restore mode before the detailed fields. PostgreSQL physical restores group target PGDATA, PITR copied-WAL inputs, and recovery behavior separately. Oracle physical restores group RMAN target/staging fields, PITR/archive-log fields, and RMAN execution controls separately. Restore job cards show phase, elapsed time, shortened source path, and a PITR badge when a point-in-time target or restore point is present.

For disaster recovery, a backup created from one connection can be restored to another compatible target connection. Logical restores are the preferred path for DR drills, migrations, and test refreshes because they are more portable and can often target a different database, schema, table, collection, or container name through the restore target/remap fields. Physical restores are intended for same-engine DR and require compatible database versions, native tools, filesystem layout, permissions, and DB VM SSH/staging access. DBAegis blocks managed/serverless physical restore paths unless the provider exposes real host filesystem and tool access; use logical DBAegis restore or provider-native snapshots/PITR for those services.

See the [backup and restore support matrix](docs/BACKUP_RESTORE_SUPPORT.md) for the supported backup targets and restore sources for each database mode.

## Restore Start Security

Every manual restore start requires a user with `restores:run` access to the target connection, a restore reason, and password re-authorization before the backend creates or reruns the job. This includes dry-run restore jobs. The short-lived authorization token is one-time use and is not stored in job options.

Destructive or higher-risk restores require typing the target name exactly before the backend accepts the request. DBAegis treats these as high risk when the restore is physical or when options such as overwrite, replace existing, clean/drop/truncate before restore, recreate database, restore users/roles, or stop service before restore are enabled.

Restore job history records the requester, reason, target confirmation, and security flags for audit review.

## Time, Logs, And Failure Diagnostics

DBAegis uses the VM local timezone for operator-facing timestamps. This includes backup history, restore jobs, schedules, self-backups, users, storage destinations, webhooks, notification settings, daily summary windows, and `dbaegis.log`. JSON payload timestamps that leave the app, such as webhook `sent_at` and support-matrix `generated_at`, include the local UTC offset. Older UTC-naive rows are migrated once at startup so schedules and history stay aligned with the VM clock.

System Status uses authenticated `/api/health` for admin diagnostics and public `/health` only for minimal liveness. Admin diagnostics can report:

- `Healthy`: metadata DB, config, logs, temp, backup, and system-backup paths are available.
- `Warning`: core API is reachable, but a non-critical local backup path check failed.
- `Unhealthy`: a critical check failed, such as metadata DB access, config readability, log directory writes, or temp directory writes.
- `Unknown`: the UI could not reach the health endpoint or the health request timed out.

The `/api/health` response includes per-check details for the metadata DB, `dbaegis.conf`, log directory, temp directory, backup directory, and system backup directory. Public `/health` does not include local paths or detailed checks.

Logs are written under `LOG_DIR` (default `/opt/dbaegis/logs`):

- `dbaegis.log`: application, API, backup, restore, scheduler, notification, and migration messages at `INFO`, `WARNING`, and `ERROR`.
- `nginx-access.log`: UI/API reverse-proxy access log.
- `nginx-error.log`: nginx notices, warnings, and errors.

`dbaegis.log` rotates at 10 MB and keeps `LOG_BACKUP_COUNT` rotated files, default `9`. The DBAegis-managed nginx wrapper rotates `nginx-access.log` and `nginx-error.log` with the same count. That means there is one active file plus up to `LOG_BACKUP_COUNT` rotated files per log, not ten active access/error logs.

Backup and restore job records store command text, exit code, stdout/stderr snippets, and engine logs with sensitive values redacted. Disk-full and quota errors are detected and reported as DB server filesystem, DB server staging filesystem, or DBAegis filesystem failures depending on where the operation was writing. Cloud storage access failures are also detected for S3, GCS, and Azure Blob and recorded in the job error plus `dbaegis.log` with guidance to check credentials, IAM/KMS/SAS/service-account policy, bucket/container permissions, endpoint, and region.

Metadata DB diagnostics:

- DBAegis stores product state in the SQLite metadata DB configured by `DBAEGIS_DB_PATH`.
- Prefer the UI, API, and supported maintenance commands for metadata changes. If direct inspection is required, use read-only SQLite access and short timeouts.
- Runtime metadata DB connections use a bounded SQLite busy timeout. Scheduled retention cleanup deletes old backup artifacts after releasing the metadata DB transaction so slow file/cloud deletes do not hold the DB write lock.
- Restore jobs load saved target connection metadata from the configured `DBAEGIS_DB_PATH`, including helper/standalone restore paths and notification helpers. If a restore fails with `target connection details are required` after moving the metadata DB, verify `DBAEGIS_DB_PATH` in `/opt/dbaegis/conf/dbaegis.conf`, restart `dbaegis.service`, and confirm authenticated `/api/health` reports the expected metadata DB path.
- If login or backup work still reports `database is locked`, check for duplicate DBAegis service processes, long-running external `sqlite3` sessions, filesystem permission problems on the DB and parent directory, and stale maintenance scripts that keep the DB open.

## Backup Retention

DBAegis supports backup retention by:

- `retention_days`
- `retention_count`

Retention behavior:

- can be set on scheduled backups
- can also be passed on manual backup runs from the UI as an optional cleanup after that run
- is applied per connection
- removes old backup history rows after a newer backup completes

Target behavior:

- `DBAegis local`: old local backup files/directories are deleted
- `DB server local`: old server-local filesystem artifacts are deleted over SSH when they are tracked under the configured backup root, or locally when the path is available on the DBAegis VM
- `AWS S3`, `GCS`, `Azure Blob`: old remote objects are deleted along with the backup history row

Notes:

- retention is enforced after backup completion
- `retention_count=0` means do not prune by count
- `retention_days=0` means do not prune by age
- manual backup runs default both values to `0`, so no retention cleanup happens unless an operator enters a non-zero value
- if both are set, either rule can make an older backup eligible for deletion
- self-backup retention is separate and controlled by `self_backup_retention_count`

## Notifications

Professional and Enterprise notification settings are managed in the UI/API and stored in the metadata database. Global settings and per-connection overrides can subscribe to:

- `start`
- `success`
- `failure`
- `restore_start`
- `restore_success`
- `restore_failure`
- `daily_summary`

Email notifications use the configured SMTP settings. Enterprise webhooks can be configured as generic, Slack, Discord, or Teams targets and can independently subscribe to the same events.

Daily summary notifications report the last 24 hours of backup and restore activity for currently connected database connections. The scheduler sends at the configured local time once per day. The manual send action can force a last-24-hours summary to email, or to webhooks when the Enterprise webhook entitlement is present.

## System Backups

Professional and Enterprise support built-in system backups, referred to in the UI and API as self-backups. Community keeps preserved self-backup history visible as locked after downgrade but cannot create new self-backups.

These are separate from normal database backups.

What they include:

- DBAegis metadata database content
- configuration files needed to restore DBAegis tool state

What they are used for:

- protecting DBAegis configuration and history
- taking a snapshot before risky admin changes
- restoring DBAegis metadata after an operator mistake

Current behavior:

- stored under `/backups/self`
- tracked through `/api/self-backups`
- support `MANUAL` snapshots from the UI/API
- support `AUTO` snapshots for certain DBAegis metadata changes
- use separate retention via `self_backup_retention_count`

Restore process:

- the current UI/API creates, lists, and deletes system backup snapshots; restore is performed from the DBAegis VM shell
- stop DBAegis before replacing the metadata database; this normally requires root/sudo
- on default installs, `/opt/dbaegis/data` and `/backups/self` are owned by the DBAegis service user, so the safety copy, extract, and database replacement steps can run as `sudo -u dbaegis`
- take a safety copy of the current metadata database before restore
- extract the selected `/backups/self/selfbackup_*.zip` archive and restore `dbaegis.db` to `/opt/dbaegis/data/dbaegis.db`
- preserve the active `DBAEGIS_SECRET_KEY` in `/opt/dbaegis/conf/dbaegis.conf`; the archived config redacts that value and should not be copied over it as-is
- start DBAegis and validate login, connections, storage destinations, LDAP, SMTP, and webhook settings

Secret key rotation behavior:

- self-backup archives redact `DBAEGIS_SECRET_KEY` from the archived `dbaegis.conf`
- restoring an old self-backup restores the old metadata DB, not the old secret key
- encrypted saved secrets in that restored DB require the `DBAEGIS_SECRET_KEY` that was active when the snapshot was created, unless you rotate the restored DB forward with `bin/dbaegis rotate-secret-key --old-key-env DBAEGIS_OLD_KEY --new-key-env DBAEGIS_CURRENT_KEY`
- if the old key is lost, restore still brings back metadata/history, but saved credentials must be re-entered

Important distinction:

- self-backups do not replace normal database backups
- they protect DBAegis itself, not the external databases you manage with DBAegis

Logical backup support for DBAegis local, AWS S3, GCS, and Azure Blob currently includes:

- PostgreSQL
- MySQL
- MariaDB
- MongoDB
- Redis / Valkey
- SQLite
- CouchDB
- Couchbase
- Neo4j
- Cassandra
- ClickHouse
- Microsoft SQL Server
- Azure SQL
- Snowflake
- Cosmos DB
- DynamoDB
- Firestore

DB-server-local logical backup support currently includes:

- Oracle Data Pump
- PostgreSQL over SSH (`pg_dump`)
- MySQL over SSH (`mysqldump`)
- MariaDB over SSH (`mysqldump`)
- MongoDB over SSH (`mongodump`)
- Redis / Valkey over SSH (`redis-cli --rdb`)
- SQLite over SSH (database file copy)
- CouchDB over SSH (`curl` export)
- Couchbase over SSH (`cbbackupmgr`)
- ClickHouse over SSH (DBAegis archive copied to DB-server-local path)

Direct-to-DBAegis physical backup is not used in the standard split-VM workflow. Physical backups that create host artifacts stage on the DB VM before DBAegis copies or uploads the artifact.

DB-server-local physical backup support currently includes:

- MySQL / MariaDB physical backup tools or snapshot-safe datadir archive over SSH. Live InnoDB/MariaDB data directories are rejected unless `physical_options.consistency` is explicitly `snapshot-safe` and the configured path points to a frozen snapshot or offline copy.
- MongoDB `dbPath` archive over SSH
- Redis / Valkey RDB/AOF archive over SSH
- Cassandra `nodetool snapshot` over SSH
- Couchbase `cbbackupmgr` over SSH
- Neo4j `neo4j-admin` over SSH
- Microsoft SQL Server native `.bak`
- Oracle RMAN backup sets

PITR support currently applies to PostgreSQL physical backups with copied WAL,
Oracle RMAN physical backups with archived redo logs, MySQL/MariaDB physical
backups with copied binary logs, and SQL Server physical backups with an ordered
transaction-log chain.

DBAegis assumes the DBAegis VM and database VM are separate. Physical modes that require database host files or host-local tools are not considered direct DBAegis VM backups, even if the final artifact is copied back to `/backups` on the DBAegis VM.

Direct cloud physical backup without DB VM staging is not used for self-managed split-VM physical/file backup modes. Physical cloud backups for PostgreSQL, MySQL, MariaDB, MongoDB, Redis / Valkey, SQLite, Microsoft SQL Server, Cassandra, Neo4j, and Oracle use the configured DB VM temp/staging location and SSH to stream the temporary artifact to object storage.

Cloud restores stream or delegate the selected backup from S3, GCS, or Azure Blob directly into the target restore path for PostgreSQL, MySQL, MariaDB, MongoDB, Redis / Valkey, CouchDB, Neo4j, Cassandra, Cosmos DB, DynamoDB, and Firestore logical restores. File/physical restores for PostgreSQL, MySQL, MariaDB, MongoDB, Redis / Valkey, SQLite, Cassandra, Neo4j, Oracle, and SQL Server use DB VM temp over SSH in split-VM deployments; use `options.db_vm_temp_dir` or `options.server_temp_dir` to choose that staging path. For cloud sources DBAegis streams the object to the DB VM; for DBAegis-local sources DBAegis copies the local artifact to the DB VM before running the restore. DBAegis keeps the cloud object basename/suffix for staged restores, then gunzips or untars engine-specific artifacts before the native restore command starts. MySQL / MariaDB cloud restore can target a different database name than the source backup, and MongoDB cloud restore can remap the restored namespace into a different target database. CouchDB cloud restore accepts DBAegis `.json` and `.json.gz` logical backups and strips revision-only metadata before `_bulk_docs` import. ClickHouse cloud restore downloads the `.clickhouse.json.gz` or `.clickhouse.json` archive to DBAegis temp, reads the manifest, recreates databases/tables with `clickhouse-client`, and streams table rows back as `JSONEachRow`. Couchbase Community/default cloud tarball restore downloads the archive to DB VM temp, safely extracts it, and runs `cbbackupmgr restore` over SSH. Snowflake cloud restore can use provider-stage `COPY INTO` directly from S3, GCS, or Azure Blob when a Snowflake storage integration, public storage, or explicitly allowed COPY credentials are configured; otherwise it falls back to a temporary DBAegis file. SQL Server and Azure SQL BACPAC cloud restores download the object to DBAegis temp, then import it with `sqlpackage`.

## Runtime Paths

Default paths:

| Purpose | Path |
| --- | --- |
| DBAegis base | `/opt/dbaegis` |
| App backend | `/opt/dbaegis/app` |
| UI files | `/opt/dbaegis/ui` |
| Config | `/opt/dbaegis/conf/dbaegis.conf` |
| SQLite metadata | `/opt/dbaegis/data/dbaegis.db` |
| Logs | `/opt/dbaegis/logs` |
| Runtime files | `/opt/dbaegis/run` |
| TLS files | `/opt/dbaegis/tls` |
| Embedded Python runtime | `/opt/dbaegis/python` |
| Python virtualenv | `/opt/dbaegis/venv` |
| Default DBAegis-local backups | `/backups` |
| Test databases | `/opt/testdatabases` |

Do not store test databases under `/opt/dbaegis`. That tree is reserved for the DBAegis tool, runtime files, and configuration.

Release tarballs contain the installer, application files, UI, constraints, docs, and edition-specific source payload. They intentionally do not contain repo `scripts/`, `python/`, or `venv/`; Python is installed on the target VM for every edition.

## Install And Upgrade

Fresh install:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --fresh
```

Upgrade an existing installation:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

Rollback the latest pre-upgrade runtime snapshot:

```bash
sudo DBAEGIS_USER=dbaegis bash /opt/dbaegis/bin/install.sh --rollback
```

Notes:

- Upgrade mode preserves the existing `conf/dbaegis.conf`.
- Upgrade mode creates a runtime rollback snapshot under `/opt/dbaegis/rollback`.
- Rollback restores application/runtime files and preserves the active config, SQLite metadata DB, and backup artifacts.
- Default installs keep `conf/dbaegis.conf` owned by `dbaegis:dbaegis` with mode `0640`.
- Runtime SQLite data and existing backup files are preserved during upgrade.
- Use `conf/dbaegis.conf.example` as a sanitized template for new deployments.
- Fresh install generates `DBAEGIS_SECRET_KEY`; upgrade preserves the active value and adds one to older configs that do not have it yet.
- The release package carries dependency constraints, not a prebuilt Python runtime. The installer downloads and verifies the pinned embedded Python runtime by SHA256 for every edition unless `DBAEGIS_PYTHON_DOWNLOAD=skip` or `DBAEGIS_PYTHON_BIN` points to a custom Python 3.12+ runtime. It then uses exact direct Python package pins plus `requirements/install-constraints.txt` for reproducible venv creation, import-checks core dependencies, and warns about missing optional database or cloud Python clients after best-effort install.
- The DBAegis-managed nginx config files under `run/nginx/conf/nginx*.conf` are generated at install/service start from `dbaegis.conf`; do not edit or commit them as source templates.
- Use the connection `Precheck` action before production backup or restore work. It verifies database connectivity, DB VM SSH readiness, temp-path write access, disk space, required tools, sudo/run-as behavior, and physical-restore safety for the saved connection mode. Physical restore safety reports `OK` only when the engine supports physical restore, managed/serverless restrictions do not apply, DB VM prerequisites pass where required, and required saved physical-mode parameters are present.
- If application/UI files are updated manually from Git instead of through `bin/install.sh --upgrade`, restart `dbaegis.service` before using the UI. Otherwise the browser can load a new UI while the running FastAPI process still has the old route table, which can show errors such as `Precheck failed: Not Found`.

Detailed operator guide:

- [docs/INSTALL_UPGRADE_UNINSTALL.md](docs/INSTALL_UPGRADE_UNINSTALL.md)
- Restart after manual code updates or configuration changes:

```bash
sudo systemctl restart dbaegis
```

## Required Client Tools

The installer installs the baseline Linux runtime packages plus distro-packaged PostgreSQL, MySQL/MariaDB, and Redis/Valkey clients where available. Install the vendor tools below for the engines you want to operate when they are not provided by the base OS repositories:

- PostgreSQL: `pg_dump`, `pg_restore`, `psql`
- MySQL / MariaDB: `mysqldump`, `mysql`
- MongoDB: `mongodump`, `mongorestore`, `mongosh`
- Redis / Valkey: `redis-cli` or `valkey-cli`
- Neo4j: `cypher-shell`, `neo4j-admin`
- SQL Server: `sqlcmd` and SQL Server backup access
- CouchDB: `curl`
- Couchbase: `cbbackupmgr`
- ClickHouse: `clickhouse-client`
- SQL Server / Azure SQL logical: `sqlpackage`
- SQL Server physical: `sqlcmd` plus SQL Server-visible backup path access
- MySQL / MariaDB physical: `xtrabackup`, `mariabackup`, or a configured datadir copy path that is offline or snapshot-safe
- Oracle: `expdp`, `impdp`, `sqlplus`, and `rman` for the selected mode
- Cassandra logical raw `.cql` restore: `cqlsh` on the DBAegis VM; the installer installs the standalone Python `cqlsh` package into the DBAegis venv on a best-effort basis
- Cassandra physical: `nodetool`
- Snowflake: `snowsql` on the DBAegis VM. The installer can install the DBAegis-tested SnowSQL release when run with `DBAEGIS_INSTALL_SNOWSQL=1`; the managed command path is `/usr/local/bin/snowsql`. DBAegis passes password auth through `SNOWSQL_PWD`; OAuth tokens are written only to a short-lived `0600` SnowSQL config file instead of process arguments.

Optional vendor clients that are free to download but maintained outside DBAegis can be installed during setup with explicit flags:

```bash
sudo DBAEGIS_INSTALL_SNOWSQL=1 \
     DBAEGIS_INSTALL_SQLPACKAGE=1 \
     DBAEGIS_INSTALL_SQLCMD=1 \
     DBAEGIS_ACCEPT_MICROSOFT_EULA=Y \
     DBAEGIS_INSTALL_MONGODB_TOOLS=1 \
     DBAEGIS_INSTALL_CLICKHOUSE_CLIENT=1 \
     bash bin/install.sh --upgrade
```

These flags download from vendor sources at install time instead of bundling third-party binaries in the DBAegis source tree. Microsoft `sqlcmd` requires explicit EULA acceptance. Database-home/server-side tools such as Oracle `rman`, Neo4j `neo4j-admin`, Cassandra `nodetool`, Couchbase `cbbackupmgr`, and MySQL/MariaDB physical tools should still be installed with the matching database software on the host where those tools must run.

If these flags were missed during the fresh install, rerun `bin/install.sh --upgrade` with the needed flags. The upgrade path preserves the existing DBAegis config, metadata DB, backups, and service user while installing any missing optional client tools. SnowSQL, MongoDB Database Tools, and mongosh are version-checked when their install flags are set; other vendor tools are left in place unless you move to a pinned version using the matching `DBAEGIS_*_VERSION`, `DBAEGIS_*_URL`, or checksum override. Current tested optional-tool versions are tracked in [requirements/dependency-inventory.json](requirements/dependency-inventory.json).

Cloud storage support requires the matching Python provider package in the DBAegis venv and valid credentials configured in the DBAegis storage destination: `boto3` for S3-compatible storage, `google-cloud-storage` for GCS, and `azure-storage-blob` for Azure Blob.

For destination-specific tool placement, including which tools run on the DBAegis VM versus the DB server over SSH, see [Backup Tool Location Guidance](docs/BACKUP_RESTORE_SUPPORT.md#backup-tool-location-guidance).

## Configuration

Main config file:

```bash
/opt/dbaegis/conf/dbaegis.conf
```

Important settings:

- `DBAEGIS_BASE`
- `APP_DIR`
- `UI_DIR`
- `DBAEGIS_DB_PATH`
  Older `DB_PATH` and `VAULT_DB_PATH` are still accepted as compatibility fallbacks.
- `DBAEGIS_SQLITE_BUSY_TIMEOUT_MS`
  Optional SQLite metadata DB lock wait timeout in milliseconds. The default is `30000`, with runtime bounds from `1000` to `300000`.
- `BACKUP_DIR`
- `SELF_BACKUP_DIR`
- `DBAEGIS_TEMP_DIR`
- `LOG_DIR`
- `LOG_BACKUP_COUNT`
- `API_PORT`
- `UI_PORT`
- `DBAEGIS_EDITION`
- `DBAEGIS_LICENSE_REQUIRED`
- `DBAEGIS_LICENSE_DIR`
- `DBAEGIS_LICENSE_KEY_FILE`
- `DBAEGIS_LICENSE_PUBLIC_KEY_FILE`
- `DBAEGIS_LICENSE_INSTANCE_ID`
- `DBAEGIS_SECRET_KEY`
  Used to derive the encryption key for stored connection passwords, cloud storage destination credentials, notification secrets, LDAP secrets, webhook secrets, restore-option secrets, and local-user MFA enrollment secrets. Preserve this value across upgrades. To change it, use `bin/dbaegis rotate-secret-key`; editing the value directly prevents DBAegis from decrypting previously saved secrets.
- `AUTH_ENABLED`
- `BOOTSTRAP_ADMIN_USER`
- `BOOTSTRAP_ADMIN_PASSWORD`
  Fresh installs generate a unique bootstrap admin password unless this is supplied explicitly.
- `DBAEGIS_BACKUP_TIMEOUT`
  Older `BACKUP_TIMEOUT` and `VAULT_BACKUP_TIMEOUT` are still accepted as compatibility fallbacks.

DBAegis does not store a separate timezone setting. Set the VM timezone with the operating system, make sure `tzdata` is installed, and restart DBAegis after changing the host timezone.

Keep real secrets out of Git. Rotate credentials if they were ever committed, copied into chat, or shared outside the VM.

## License Enforcement

Community is intended to run without a customer license by using `DBAEGIS_EDITION=community` and `DBAEGIS_LICENSE_REQUIRED=false`. Professional and Enterprise deployments always require a signed license before normal API use; the runtime treats those editions as license-required even if `DBAEGIS_LICENSE_REQUIRED` is omitted or set to `false`. Keep issuer-only signing keys under `/opt/dbaegis_securekeys` by running `dbaegis license setup-issuer --key-dir /opt/dbaegis_securekeys` on a trusted issuer machine; never copy the private key to customer servers. Keep the issued customer license token, public verification key, and related runtime license metadata under `/opt/dbaegis/license`. Set `DBAEGIS_EDITION` to the purchased edition, set `DBAEGIS_LICENSE_REQUIRED=true`, point `DBAEGIS_LICENSE_KEY_FILE` at `/opt/dbaegis/license/dbaegis.license`, point `DBAEGIS_LICENSE_PUBLIC_KEY_FILE` at `/opt/dbaegis/license/license_public.pem`, and restart DBAegis. Backend API entitlement checks enforce edition feature keys, default limits, and database coverage. The CLI supports `dbaegis license setup-issuer`, `dbaegis license generate-keypair`, `dbaegis license issue`, `dbaegis license verify`, and `dbaegis license status`.

See [docs/INSTALL_UPGRADE_UNINSTALL.md#edition-upgrade-and-downgrade](docs/INSTALL_UPGRADE_UNINSTALL.md#edition-upgrade-and-downgrade) for edition change operations and [docs/PRODUCT_EDITIONS.md](docs/PRODUCT_EDITIONS.md) for edition features and entitlement keys.

## Authentication and Access Control

DBAegis supports both:

- local users stored in the DBAegis SQLite metadata database
- Enterprise LDAP-backed users authenticated against an external directory

The DBAegis admin UI groups `Users`, `Roles`, and `LDAP` settings under the `Access Control` section.

Access-control management:

- admins can edit local users from `Access Control` > `Users`, including username, role, and active status
- Professional and Enterprise admins can enable or disable local-user MFA globally from `Access Control` > `MFA`; Community shows MFA as edition locked
- Professional and Enterprise admins can create custom roles from `Access Control` > `Roles`, choose backup/restore permissions, and assign database connections or connection tags to those roles
- Enterprise admins can map LDAP groups to built-in or custom roles from `Access Control` > `LDAP`; the same mappings remain visible on each editable role record
- built-in operator roles are `backup_operator`, `restore_operator`, and `db_operator`; each is connection-scoped and can operate only on assigned connections or connections matching assigned tags
- LDAP user roles are read-only in DBAegis because they come from LDAP group mapping
- DBAegis prevents removing the last active admin by role change, disable, or delete
- DBAegis keeps one active login session per user; a new successful login invalidates older sessions for that same user

Local-user MFA:

- MFA requires Professional or Enterprise and is compatible with Microsoft Authenticator and other standard TOTP apps
- setup is available only for local DBAegis users, not LDAP-managed users
- admins enable the global MFA feature from `Access Control` > `MFA`, then create or reset an enrolled local user's MFA setup from `Access Control` > `Users`
- the setup response includes an `otpauth://` URI and a QR code rendered as a local SVG data URI; DBAegis does not call an external QR service
- MFA enrollment secrets are encrypted in the metadata DB with `DBAEGIS_SECRET_KEY`
- when global MFA is enabled and a local user is enrolled, password login returns an MFA challenge; the user must submit the current 6-digit code before a session is created
- disabling global MFA bypasses existing local-user enrollments without deleting their saved enrollment data

Bootstrap admin behavior:

- fresh installs create the initial local admin from `BOOTSTRAP_ADMIN_USER` and `BOOTSTRAP_ADMIN_PASSWORD`; the default username is `admin`
- the initial username and password are written to `/opt/dbaegis/conf/dbaegis.conf`; view them on the DBAegis VM with `sudo grep -E '^BOOTSTRAP_ADMIN_USER=|^BOOTSTRAP_ADMIN_PASSWORD=' /opt/dbaegis/conf/dbaegis.conf`
- `BOOTSTRAP_ADMIN_PASSWORD` is used only when the DBAegis metadata `users` table is empty
- after the admin exists, changing the password in the UI updates the password hash in the SQLite metadata database
- restarting DBAegis does not reset an existing admin password from `BOOTSTRAP_ADMIN_PASSWORD`
- `BOOTSTRAP_ADMIN_PASSWORD` may remain in `conf/dbaegis.conf`; commenting it out after the first admin exists does not affect normal restarts
- if the metadata database is empty or replaced, DBAegis needs a non-default `BOOTSTRAP_ADMIN_PASSWORD` to seed the first admin again; rerunning the installer may generate or set one if the value is missing or default
- if the only local admin password is lost, reset that account from the DBAegis VM shell with `sudo -u dbaegis /opt/dbaegis/bin/dbaegis reset-admin-password`; the command updates only the targeted local admin, clears only that user's sessions, and refuses LDAP-managed or non-admin users
- when multiple local admins exist, pass `--username USER`; use `--generate` for a generated recovery password or `--password-env ENV_VAR` for non-interactive automation

Enterprise LDAP behavior:

- local users continue to work when LDAP is enabled
- LDAP users are mapped to DBAegis roles from LDAP groups
- supported DBAegis roles are:
  - `admin`
  - `read_only`
  - `backup_operator`
  - `restore_operator`
  - `db_operator`
  - custom roles created by admins
- default LDAP group names are:
  - `admin`
  - `read_only`
- LDAP role precedence is admin first, then role-specific mappings, then read_only fallback
- LDAP chooses the DBAegis role only; connection assignments, tag assignments, and permissions still come from the DBAegis role configuration
- if a local DBAegis user already exists with the same username, LDAP login for that username is rejected to avoid ambiguity

Custom LDAP role mapping workflow:

1. Create the DBAegis application role from `Access Control` > `Roles`.
2. Select the role permissions, such as backup and restore access.
3. Assign the database connections or connection tags that role can operate on.
4. Create or confirm the matching LDAP group in your directory, outside DBAegis.
5. Map that LDAP group to the DBAegis role from `Access Control` > `LDAP` under `Role LDAP Mappings`.
6. Use `Test LDAP` with a user in that LDAP group and confirm the mapped DBAegis role.

DBAegis does not create LDAP directory groups. It creates local application roles and maps those roles to LDAP groups returned by your directory.

LDAP setup and testing:

- LDAP settings are managed from the DBAegis admin UI/API under `Access Control` > `LDAP`
- the UI includes a `Test LDAP` action
- `Test LDAP` supports two modes:
  - config-only test: validates server connection, bind, and a basic search using the current form values
  - user-auth test: validates a specific LDAP username/password and shows the mapped DBAegis role
- the LDAP settings screen also shows an inline result panel in addition to toast notifications

LDAP configuration is managed from the DBAegis admin UI/API and stored in DBAegis system settings, not read live from `dbaegis.conf`.

The installer and example config include LDAP placeholders only as deployment documentation for operators and config-management systems.

## Repository Hygiene

The repository intentionally ignores generated/runtime content:

- `venv/`
- `data/`
- `logs/`
- `run/`
- `backups/`
- `tmp/`
- `tls/`
- `__pycache__/`
- `*.pyc`
- `*.bak*`
- `*.old*`
- `*.bad*`
- `*.new`

The current GitHub repository has been cleaned of old backup files, Python bytecode caches, obsolete copied folders, and local runtime artifacts.
