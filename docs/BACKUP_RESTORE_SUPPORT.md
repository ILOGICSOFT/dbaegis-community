# DBAegis Backup and Restore Support Matrix

This matrix lists only supported DBAegis backup targets and restore sources.

Community packages expose only the PostgreSQL, MySQL, and MongoDB DBAegis-local
logical backup/restore subset. The broader matrix below applies to the
Professional and Enterprise paid runtime where the relevant feature, database,
and storage entitlements are available.

`DBAegis local file` means the backup artifact is stored on, or restored from, the DBAegis server filesystem.

`DB server local` means the backup artifact is written by the database server or a database-native tool to a path visible to the database server. For client-tool engines, DBAegis enables this only when SSH remote execution is configured for the connection, because DBAegis must run the backup command on the DB host. Managed DBaaS engines normally do not expose a DB-server filesystem, so use DBAegis-local logical export, cloud object storage, or provider-native backups for those systems.

DBAegis assumes the DBAegis VM and database VM are separate. `DBAegis local file` describes where the finished backup artifact is stored, not necessarily where the backup tool runs. A backup is considered direct-to-DBAegis only when DBAegis can create the artifact over a database/client/API protocol without reading DB server filesystem paths. Physical modes that need DB host files or host-local tools must use DB-server execution, usually SSH, even if the final artifact is copied back to DBAegis storage.

Cloud targets are object-storage paths. DBAegis uses direct streaming/native cloud APIs where the database engine supports that safely. For engines that require a database-host filesystem artifact, DBAegis uses a DB server staging artifact, uploads it to cloud storage, records the cloud URI, and removes the temporary file after upload or restore. Managed-service/client-only paths such as Azure SQL use DBAegis-side scratch space because there is no customer DB VM staging path; Snowflake can use provider-stage restore directly from object storage when stage access is configured, otherwise it falls back to DBAegis-side scratch space. For cloud restores where the database engine must read a server-visible file, DBAegis can download the cloud object over SSH to a user-provided DB server temp path, run the restore from that path, then remove the temp file.

If a database/mode is not listed for `AWS S3`, `Azure Blob`, or `GCS`, DBAegis does not currently have a safe generic cloud path for that mode.

The storage destination `Test` action validates the saved provider settings and performs a temporary remote write/delete probe for AWS S3, Google Cloud Storage, and Azure Blob destinations. The probe uses the configured bucket/container and prefix, writes a small `.dbaegis-precheck/` object, then deletes it. Connection precheck uses the same remote cloud-storage probe when a connection's backup destination points to an active cloud storage destination.

## Restore UI Mode Selection

The restore dialogs select `Restore Type` before `Connection`. DBAegis filters the target connection list by the connection's configured `backup_type`: logical restore mode shows only logical connections, and physical restore mode shows only physical connections. This prevents starting a physical restore against a connection configured for logical backups, or a logical restore against a physical-only connection.

Changing restore type or connection resets stale restore options and redraws the database-specific parameter panel. Databases with both restore modes expose different logical and physical parameter panels: PostgreSQL, MySQL/MariaDB, MongoDB, SQLite, Redis / Valkey, Neo4j, Microsoft SQL Server, Oracle, and Cassandra. SQLite logical restore shows the primary database-file restore settings; SQLite physical restore adds WAL/SHM sidecar and DB VM staging controls.

PostgreSQL, MySQL/MariaDB, Microsoft SQL Server, and Oracle physical restore
expose PITR fields in the restore options area. For PostgreSQL, use `PITR
Target Time` for the desired recovery timestamp and `Copied WAL / Log Source`
for the directory that contains the copied WAL/archive log chain. The legacy
PostgreSQL field names `recovery_target_time` and `wal_source` remain accepted
for API compatibility. For MySQL/MariaDB, use `PITR Target Time` /
`binlog_stop_datetime` or `binlog_stop_position` and provide `binlog_source` /
`pitr_log_source` for the copied binary-log chain. For SQL Server, use `PITR
Target Time / STOPAT`, provide `log_backup_source` or ordered
`log_backup_files` for the transaction-log chain, and optionally provide
`differential_backup_file` before replaying logs. For Oracle, use `PITR Target
Time` or `PITR Target SCN` and provide a copied archive-log source only when
the selected RMAN backup does not already include the required archived redo
logs. Oracle timestamp targets should be entered in the Oracle database/server
time context.

Cloud restore source selection is also type-scoped. Select the cloud storage type first, then select a matching active `Cloud Storage Location`. `Cloud Folder Prefix` is only a listing scope for the file browser inside the selected bucket/container. `Selected Cloud File URI` is the exact object URI that the restore job will read. Changing the selected storage location clears the previous file URI so an object from one provider or prefix cannot be reused accidentally after switching storage.

The file browser can select DBAegis-generated backups or external objects that were uploaded outside DBAegis. External objects must still use the expected suffix and content for the selected engine, such as `.sql`/`.sql.gz`, `.archive`/`.archive.gz`, `.json`/`.json.gz`, `.csv`/`.csv.gz`, `.bacpac`, `.bak`, `.trn`, `.dmp`, `.rdb`, `.aof`, `.dump`, `.backup`, `.tar`, `.tar.gz`, or `.tgz` according to the restore matrix below.

## Connection Precheck

Each saved connection has a `Precheck` action in the UI. It runs a non-mutating readiness check for the connection's configured backup/restore mode and returns `OK`, `Warning`, `Failed`, or `Skipped` rows.

The precheck verifies:

- database connectivity and the server version when the engine test can report it
- whether DB VM SSH execution is required for the selected engine, backup type, and destination
- SSH reachability and the effective run-as user when SSH is configured
- DB VM temp/staging path creation, probe-file write/delete access, and free disk space
- required engine tools on the execution host, such as `pg_basebackup`, `mysqldump`, `mongodump`, `redis-cli`, `neo4j-admin`, `nodetool`, `sqlcmd`, `expdp`, `rman`, `cbbackupmgr`, or `clickhouse-client`
- non-interactive `sudo` availability as an advisory check; a configured SSH run-as user must be executable non-interactively
- whether physical restore is implemented for the engine, whether managed/serverless deployment settings make physical restore unsafe, and whether required saved physical-mode parameters are present

A failed SSH, temp path, disk, required-tool, unsupported physical-restore, or missing required physical parameter check blocks a safe DB VM workflow. A warning means the operation may still be possible, but the operator must review it first. `Physical restore safety` reports `OK` only when the engine supports physical restore, managed/serverless restrictions do not apply, DB VM execution prerequisites pass where required, and required saved connection parameters are present. Physical restore is normally destructive/offline; use an isolated target or stop the database service before replacing data files. The precheck does not perform a restore. Source backup paths and target restore paths that are entered in the restore dialog are validated again when the restore job is submitted.

Troubleshooting:

- `Precheck failed: Not Found` means the UI reached an API process that did not have the precheck route loaded, or the selected connection row no longer exists. First verify the connection still appears in the Connections list. If the connection exists and DBAegis was just updated, restart the service and refresh the browser:

```bash
sudo systemctl restart dbaegis
```

- `Precheck failed: Not authenticated` means the browser session expired; sign in again and retry.
- A precheck result of `Failed` or `Warning` after the modal opens is an actual readiness result from the connection checks, not a missing API route.
- `Database connection` failures from a precheck are live connectivity/authentication results from the saved connection payload. Re-test after changing the database password, username, TLS settings, host, port, SSH tunnel settings, or DB VM temp path.
- `target connection details are required` during restore means the restore worker could not load the saved target connection row. Verify the connection still exists, confirm `DBAEGIS_DB_PATH` points at the active metadata DB, restart DBAegis after any config/path change, and check authenticated `/api/health` for the metadata DB path.

## Cloud Storage Identifiers

DBAegis normalizes storage destination types and remote backup/restore URI schemes before execution. Canonical provider names are `s3`, `gcs`, and `azure`.

Accepted aliases include:

| Canonical Provider | Accepted Storage Type / URI Scheme Aliases |
|---|---|
| `s3` | `s3`, `aws`, `amazon`, `s3compatible`, `s3-compatible`, `minio` |
| `gcs` | `gcs`, `google`, `google_cloud_storage`, `google-cloud-storage`, `gcp`, `gs` |
| `azure` | `azure`, `az`, `azblob`, `azureblob`, `azure_blob`, `azure-blob`, `blob` |

Generated backup URIs use canonical provider schemes where possible. Restore source URIs and older stored destination payloads may still use aliases such as `gs://...`, `az://...`, `aws`, or `azblob`; DBAegis resolves those to the canonical provider before comparing the source URI with the selected storage destination.

## Saved Secret Security

AWS S3, Google Cloud Storage, Azure Blob, connection option, SMTP, LDAP, local-user MFA enrollment, webhook, and restore-option secrets are encrypted at rest before they are written to DBAegis metadata. The encrypted values use key material derived from `DBAEGIS_SECRET_KEY`.

Encrypted storage fields include:

- AWS access keys and secret keys
- GCS service account JSON and private key aliases
- Azure connection strings, account keys, SAS tokens, and related aliases
- generic client secrets, API keys, and tokens used by storage-destination payloads
- connection option SSH passwords/private keys and legacy cloud fields
- SMTP passwords, LDAP bind passwords, local-user MFA enrollment secrets, webhook URLs, sensitive webhook headers, and sensitive restore-option fields

The backend decrypts credentials only for operations that need them, such as upload, download, delete, retention cleanup, storage tests, SMTP/LDAP/webhook tests, local-user MFA verification, backup, and restore. UI/API read responses redact these fields with `***redacted***`. Update requests can send the redacted marker to preserve the existing encrypted value.

Preserve `DBAEGIS_SECRET_KEY` across upgrades. To change it, stop DBAegis, then rotate the database and update the service-user-owned config as the DBAegis service user with `bin/dbaegis rotate-secret-key --generate-new-key --update-conf`. Editing the config value without rotating the database prevents previously encrypted saved secrets from decrypting.

Self-backup restores follow the same rule. Self-backup archives include the DBAegis metadata DB, but sensitive config values such as `DBAEGIS_SECRET_KEY` are redacted from archived `dbaegis.conf`. Restore is currently a DBAegis VM shell operation: stop DBAegis with root/sudo, then run the safety copy, archive extraction, and database replacement as the DBAegis service user when default ownership is in place. Extract `dbaegis.db` from the selected `/backups/self/selfbackup_*.zip`, install it back to `/opt/dbaegis/data/dbaegis.db`, preserve the live config secret key, and restart DBAegis. If you restore a self-backup created before a key rotation, encrypted saved secrets in that restored DB still require the old key or a follow-up `bin/dbaegis rotate-secret-key --old-key-env DBAEGIS_OLD_KEY --new-key-env DBAEGIS_CURRENT_KEY` run while DBAegis is stopped. If the old key is unavailable, restore can recover metadata/history, but saved credentials must be re-entered.

## Time And Failure Handling

DBAegis stores operator-facing timestamps in the VM local timezone. Backup history, restore jobs, schedule `last_run_at`, self-backups, auth audit fields, storage/webhook metadata, daily summary windows, and `dbaegis.log` all follow the host clock. JSON fields that need timezone context, such as webhook `sent_at`, support-matrix `generated_at`, and restore discovery `mtime`, include the VM local offset.

Backup and restore failures are written to both the job record and `dbaegis.log` with sensitive values redacted. Each backup row can include command text, exit code, stdout, stderr, and engine log content; each restore row keeps the restore log and final error message.

DBAegis classifies common disk and storage failures before saving the error:

- local or DB-server `No space left on device`, quota, file-too-large, and related errors are reported as filesystem full/quota failures at the DBAegis filesystem, DB server filesystem, or DB server staging filesystem
- S3, GCS, and Azure Blob authentication/authorization failures are reported as cloud storage access failures with the affected target/source URI when available
- restore failures while reading cloud sources use the same cloud access checks and record the failure before the job exits

These checks do not retry or prune automatically. Operators must free space, increase quotas, fix credentials or policies, or choose a different DB VM/DBAegis temp path before rerunning the job.

## Report Exports

Enterprise admins can export operational reports from the DBAegis UI under
`Reports`. Each report is available as CSV and accepts a date range. Community
and Professional keep the Reports surface visible where supported, but CSV
export requires the Enterprise `reports.csv` or `audit.export` entitlement.

Available report exports:

- `Backup Status`: one row per connection with latest successful backup, latest run status, success rate, destination, size, and status for the selected date range.
- `Restore Status`: one row per connection with latest successful restore, latest restore result, restore mode, success rate, and verification state for the selected date range.
- `Schedule Status`: one row per connection with active/paused schedule counts, latest schedule run status, next run, retention settings, and schedule health.
- `Audit Events`: one row per audited admin/API event with actor, action, object, result, source, and redacted metadata.

The CSV endpoints are admin-only API routes under `/api/reports/{report-name}/csv`, where `{report-name}` is `backup-status`, `restore-status`, `schedule-status`, or `audit-events`. The report date range defaults to the last 30 days and can be changed with `date_from=YYYY-MM-DD` and `date_to=YYYY-MM-DD`. Add `tag=<tag-name>` to connection-scoped reports to export only connections with that tag.

## Direct Backup To DBAegis VM

This table answers which backups can be created directly on the DBAegis VM when the database runs on a separate VM.

| Database | Logical direct to DBAegis VM | Physical direct to DBAegis VM | Required non-direct path |
|---|---|---|---|
| PostgreSQL | Yes | No | Physical uses `pg_basebackup` on the DB VM in the standard split-VM workflow, then copies or streams the staged tarball to DBAegis or cloud storage. |
| MySQL | Yes | No | Physical must run on the DB VM with `ssh_remote_tool` or use a DB-host snapshot-safe source. |
| MariaDB | Yes | No | Physical must run on the DB VM with `ssh_remote_tool` or use a DB-host snapshot-safe source. |
| MongoDB | Yes | No | Physical `dbPath` copy must run on the DB VM. |
| Redis / Valkey | Yes | No | Physical RDB/AOF file backup must run on or read from the DB VM. |
| SQLite | No | No | SQLite is a DB file; when the DB VM is separate, use SSH or an explicit shared mount. |
| CouchDB | Yes | No | HTTP logical export is direct; host-level physical backup is not supported. |
| Couchbase | Yes | No | Logical/API backup is direct; physical/archive tooling must run where `cbbackupmgr` and data access exist. |
| Neo4j | Yes | No | Physical `neo4j-admin` backup must run on the DB VM. |
| Microsoft SQL Server | Yes | No | Logical BACPAC export uses `sqlpackage` from the DBAegis VM; physical `.bak`/`.trn` artifacts are SQL Server-visible storage on the DB VM. |
| Oracle | No | No | Data Pump and RMAN require Oracle server-visible directories/tools on the DB VM. |
| Cassandra | Yes | No | Physical `nodetool snapshot` must run on the DB VM. |
| ClickHouse | Yes | No | Logical archive uses `clickhouse-client`; physical filesystem backups are not implemented. |
| Snowflake | Yes | Not applicable | Logical export only. |
| Cosmos DB | Yes | Not applicable | API export only. |
| DynamoDB | Yes | Not applicable | API export only. |
| Firestore | Yes | Not applicable | API export only. |
| Azure SQL | Yes | No | BACPAC is supported; physical backup is provider-managed. |

## Cloud Backup DB VM Staging By Provider

This table answers whether cloud backups to AWS S3, Azure Blob, or GCS need a staging location on the database VM when DBAegis and the database always run on separate VMs. `Direct` means no DB VM staging is required because the backup stream can go to object storage without first creating a database-host file artifact. File-based backups that must create an artifact before upload use the DB VM temp/staging location.

| Database | Mode | AWS S3 | Azure Blob | GCS | DB VM staging required? | Notes |
|---|---|---|---|---|---|---|
| PostgreSQL | Logical | Direct | Direct | Direct | No | Streams `pg_dump` from the DBAegis VM to object storage. |
| PostgreSQL | Physical | DB VM staging | DB VM staging | DB VM staging | Yes | Runs `pg_basebackup` over SSH on the DB VM, creates the temporary tarball under `db_vm_temp_dir`, then streams it to object storage. |
| MySQL | Logical | Direct | Direct | Direct | No | Streams `mysqldump` from the DBAegis VM to object storage. |
| MySQL | Physical | DB VM staging | DB VM staging | DB VM staging | Yes | Physical backup tools or datadir copies must run against DB-host files, usually with `physical_options.execution_mode=ssh_remote_tool` and `db_vm_temp_dir`. |
| MariaDB | Logical | Direct | Direct | Direct | No | Streams `mysqldump` from the DBAegis VM to object storage. |
| MariaDB | Physical | DB VM staging | DB VM staging | DB VM staging | Yes | Physical backup tools or datadir copies must run against DB-host files, usually with `physical_options.execution_mode=ssh_remote_tool` and `db_vm_temp_dir`. |
| MongoDB | Logical | Direct | Direct | Direct | No | Streams `mongodump --archive` from the DBAegis VM to object storage. |
| MongoDB | Physical | DB VM staging | DB VM staging | DB VM staging | Yes | `dbPath` archive/copy must run where the MongoDB data files are visible. |
| Redis / Valkey | Logical | Direct | Direct | Direct | No | Exports supported key types through the Redis protocol from the DBAegis VM. |
| Redis / Valkey | Physical | DB VM staging | DB VM staging | DB VM staging | Yes | RDB/AOF file capture must run on, or read files from, the DB VM. |
| SQLite | Logical | DB VM copy/staging | DB VM copy/staging | DB VM copy/staging | Yes | A split-VM SQLite database file must be copied over SSH or exposed through an explicit shared mount before DBAegis can upload it. Logical mode restores the primary database file. |
| SQLite | Physical | DB VM copy/staging | DB VM copy/staging | DB VM copy/staging | Yes | Physical mode uses the same database-file artifact path and can include WAL/SHM sidecars when requested. |
| CouchDB | Logical | Direct | Direct | Direct | No | Exports through the CouchDB HTTP API. |
| Couchbase | Logical | Enterprise native or DB VM staging | Enterprise native or DB VM staging | Enterprise native or DB VM staging | Yes for default/community fallback | Enterprise native object-store mode is available when explicitly requested. The default/community path creates the `cbbackupmgr` archive under `db_vm_temp_dir` on the DB VM and streams the tarball to object storage over SSH. The Couchbase Backup Type selector can force `--full-backup`; incremental/default leaves `cbbackupmgr` to continue the archive chain. |
| Neo4j | Logical | Direct | Direct | Direct | No | Exports through Bolt/Cypher from the DBAegis VM. |
| Neo4j | Physical | DB VM staging | DB VM staging | DB VM staging | Yes | `neo4j-admin` dump must run on the DB VM in the standard split-VM deployment. |
| Microsoft SQL Server | Logical | Direct | Direct | Direct | No DB VM | BACPAC export uses `sqlpackage` from the DBAegis VM, so DB VM staging is not applicable. |
| Microsoft SQL Server | Physical | DB VM `.bak`/`.trn` path | DB VM `.bak`/`.trn` path | DB VM `.bak`/`.trn` path | Yes | Native backup writes a SQL Server-visible full/differential/copy-only `.bak` or transaction-log `.trn` under the configured DB VM temp/staging directory, then DBAegis streams it to object storage over SSH. The SQL Server Backup Type selector supports full, differential (`DIFFERENTIAL`), copy-only (`COPY_ONLY`), and transaction-log (`BACKUP LOG`) backups. |
| Oracle | Logical | DB VM staging | DB VM staging | DB VM staging | Yes | Data Pump writes Oracle DIRECTORY/server-side dump files under `db_vm_temp_dir`. |
| Oracle | Physical | DB VM staging | DB VM staging | DB VM staging | Yes | RMAN writes backup pieces under `db_vm_temp_dir` before DBAegis streams the archive to object storage. The Oracle RMAN Backup Type selector supports full, incremental level 0, level 1 differential, and level 1 cumulative backups. |
| Cassandra | Logical | Direct | Direct | Direct | No | Exports table data through the Cassandra driver from the DBAegis VM. |
| Cassandra | Physical | DB VM staging | DB VM staging | DB VM staging | Yes | `nodetool snapshot` and SSTable archive creation must run on the DB VM. |
| ClickHouse | Logical | Direct | Direct | Direct | No | Exports table DDL plus `JSONEachRow` data through `clickhouse-client` from the DBAegis VM. |
| Snowflake | Logical | Direct | Direct | Direct | No | Exports through SnowSQL/service APIs; DBAegis may use local temp for the generated artifact. |
| Cosmos DB | Logical | Direct | Direct | Direct | No | Exports through service APIs. |
| DynamoDB | Logical | Direct | Direct | Direct | No | Exports through service APIs. |
| Firestore | Logical | Direct | Direct | Direct | No | Exports through service APIs. |
| Azure SQL | Logical | Direct | Direct | Direct | No DB VM | Azure SQL is a managed service path; BACPAC export uses `sqlpackage` from the DBAegis VM, so DB VM staging is not applicable. |
| Azure SQL | Physical | Not applicable | Not applicable | Not applicable | Not applicable | Physical backups are provider-managed. |

## Logical Export Scope Controls

Logical backup scope is normalized around these option fields:

- `include_targets` / `exclude_targets`: database-like scope such as database, schema, keyspace, bucket, collection group, or Redis DB index depending on engine.
- `include_objects` / `exclude_objects`: object-like scope such as table, collection, container, ClickHouse table, Couchbase data path, or Redis key pattern depending on engine.
- Engine-specific aliases such as `schemas`, `tables`, `table_name`, `collection_ids`, `bucket_include`, `include_data`, `keyspace`, and `table` remain supported.

Logical backup `extra_args` is shown only for native-tool export paths where DBAegis appends the values to the generated command, such as PostgreSQL, MySQL/MariaDB, MongoDB, Couchbase, Oracle, Snowflake, Azure SQL, Microsoft SQL Server, and ClickHouse. API/file-copy/driver exports such as SQLite, Redis logical, Cassandra logical, Neo4j logical, CouchDB, Cosmos DB, DynamoDB, and Firestore do not expose a no-op extra-args field; use their first-class scope/query fields instead.

Physical backup `extra_args` is shown only where the current physical implementation appends the values to a real tool command: PostgreSQL, MySQL/MariaDB, Redis / Valkey, Microsoft SQL Server, Oracle RMAN, Neo4j, and Cassandra. File-copy physical paths such as MongoDB dbPath copy and SQLite file copy do not expose a no-op extra-args field.

Command-style `extra_args` are shell-split with quote handling. Parse errors and shell control tokens such as statement separators or newlines are rejected instead of being silently ignored. Engine-specific exceptions are validated as SQL/RMAN clauses rather than process arguments: SQL Server physical backup/restore accepts optional leading `WITH` and appends the values as native `WITH` clauses, and Oracle RMAN physical backup/restore appends a single validated RMAN clause to the generated `BACKUP DATABASE` or `RESTORE DATABASE` command. Snowflake password authentication remains in `SNOWSQL_PWD`; Snowflake `extra_args` must not carry secrets and are checked before execution.

Partial restore from a larger full logical backup is not universal. Prefer creating a scoped backup when the target is known. Restore-time filtering is available only where the native restore format can filter safely.

## Native Backup Type Controls

DBAegis exposes a backup-type dropdown only where the selected database tool has a native, supported backup-mode flag. Engines without a real full/differential selector keep their existing options instead of showing a no-op control.

| Database / Mode | Dropdown Choices | Native Effect |
|---|---|---|
| Couchbase logical / `cbbackupmgr` | Incremental/default, full | Full adds `--full-backup`; incremental/default lets `cbbackupmgr` continue the archive chain. |
| Neo4j physical | Dump, full online, differential with full fallback, online default | Dump uses `neo4j-admin database dump`; full uses `neo4j-admin database backup --type=FULL`; differential with full fallback uses `--type=AUTO`. |
| Microsoft SQL Server physical | Full, differential, copy-only, transaction log | Differential adds `DIFFERENTIAL`; copy-only adds `COPY_ONLY`; full adds neither clause; transaction log switches the command to `BACKUP LOG` and writes a `.trn` artifact. |
| Oracle physical / RMAN | Full, incremental level 0, incremental level 1 differential, incremental level 1 cumulative | Level selections add RMAN `INCREMENTAL LEVEL` clauses; full runs the normal RMAN database backup. |

## Restore Remap Controls

Restore target names can be overridden with `target_database`/`target_db`, `target_schema`, and `target_table`. Mapping aliases are also supported where the engine can safely apply them:

- `remap_database`: accepts `source:target`, `source=>target`, `source=target`, a JSON object, or a list of mappings.
- `remap_schema`: accepts the same mapping shapes, or `source_schema` plus `target_schema`.
- `remap_table`: accepts the same mapping shapes, or `source_table` plus `target_table`. Qualified names such as `schema.table` or `database.table` are supported where the database engine supports them.

The restore UI exposes one clear target/source field set per engine, such as `target_database`, `target_schema`, `source_table`, and `target_table`. The `remap_*` names remain accepted API aliases for automation. Use the first-class fields or the `remap_*` aliases, not both in the same restore job. `extra_args` is available on native-tool restore paths and is appended after DBAegis-generated restore arguments; SQL Server physical restore is the exception, where `extra_args` is appended as additional `RESTORE DATABASE ... WITH` clauses such as `STATS=10` or `CHECKSUM`. API/file-copy restores such as Cosmos DB, DynamoDB, Firestore, SQLite, Redis logical/physical restore, and MongoDB physical restore do not expose a no-op `extra_args` field. Do not pass native remap switches through `extra_args` when DBAegis fields already describe the same remap.

The restore popup includes a summary strip for database type, target connection, source type, and restore mode. PostgreSQL physical restore groups target PGDATA and DB VM staging separately from copied-WAL PITR fields and recovery behavior. MySQL/MariaDB physical restore groups target datadir, copied-binlog PITR fields, and recovery behavior. SQL Server physical restore groups target/staging fields with `STOPAT`, log backup source/files, and optional differential inputs. Oracle physical restore groups RMAN staging/target fields, PITR/archive-log inputs, and RMAN execution controls. Restore job cards show the inferred phase, elapsed time, shortened source path, and a PITR badge when a point-in-time target, SCN, restore point, binlog stop target, or SQL Server log-chain target is present.

For DR or test refreshes, the source backup connection and restore target
connection do not need to be the same saved connection. They must be compatible:
the selected restore type must match the target connection mode, and the target
engine must be able to consume the selected artifact. Logical backups are the
recommended cross-connection DR path because they are more portable and can use
the target/remap controls below. Physical backups are for same-engine DR only
and require compatible engine versions, native tools, filesystem layout,
permissions, and DB VM SSH/staging access.

The connection and restore parameter surfaces are covered by static smoke tests. The tests compare UI option defaults and restore allow-lists against backend metadata, validate representative connection payloads for every supported backup mode, verify a connection-test handler exists for every supported database, and round-trip restore option metadata for every supported restore mode. These tests do not perform live database backups or destructive restores; live coverage remains tracked in the dated smoke reports.

| Database | Database/keyspace remap | Schema remap | Table/container remap | Notes |
|---|---|---|---|---|
| PostgreSQL | Target database selection | `ALTER SCHEMA ... RENAME` after logical import | `ALTER TABLE ... RENAME`, with qualified target schema handling | Applies after `psql`/`pg_restore` succeeds. |
| MySQL / MariaDB | Target database selection and SQL dump retargeting for local/cloud streaming paths | Not applicable | `RENAME TABLE ... TO ...` after logical import | Qualified `database.table` names are supported. |
| MongoDB | `mongorestore --nsFrom/--nsTo` database mapping | Not applicable | Collection mapping through `source_collection`/`target_collection` or `remap_table` | Explicit `ns_from`/`ns_to` still takes precedence. |
| Oracle | Not applicable to Data Pump target database | Data Pump `REMAP_SCHEMA` | Data Pump `REMAP_TABLE` | `remap_tablespace` remains supported. |
| Cassandra | Target keyspace through `keyspace`, `target_keyspace`, `target_database`, or `remap_database` | Not applicable | Target table through `table` | `target_table` and `remap_table` remain accepted API aliases, but the UI exposes only `table` to avoid duplicate target-table fields. Restore still requires the target table layout to be valid for CSV/SSTable import. |
| ClickHouse | Target database through `target_database` or `remap_database` | Not applicable | Per-table target through `target_table` or `remap_table` | `target_table` is accepted only for single-table restore selection. |
| Snowflake | Target database through `target_database` or `remap_database` | Target schema through `target_schema` or `remap_schema` | Target table through `target_table` or `remap_table` | Applies to query/CSV restore manifests and SQL replay target context. |
| Cosmos DB | Target database through `target_database` or `remap_database` | Not applicable | Container target through `target_container`, `target_table`, or `remap_table` | API restore imports documents into the selected target. |
| DynamoDB | Not applicable | Not applicable | Target table through `target_table` or `remap_table` | API restore imports items into one table. |
| CouchDB | Target database through `target_database`, `target_db`, or `remap_database` | Not applicable | Not applicable | Documents are imported into the selected database. |
| Neo4j, SQL Server, Azure SQL | Target database selection | Not normalized | Not normalized | Object-level remap depends on custom Cypher/SQL/BACPAC tooling outside DBAegis generic aliases. |

| Database | Scoped Logical Backup | Restore From Full Backup To Subset | Notes |
|---|---|---|---|
| PostgreSQL | Schema and table filters with `include_targets`/`exclude_targets` and `include_objects`/`exclude_objects`; database comes from the connection. | Limited for DBAegis-generated plain SQL backups; restore targets a database, not an extracted schema/table subset. | Create a schema/table-scoped backup when a partial PostgreSQL restore is needed. |
| MySQL / MariaDB | Database filters with `include_targets`; table filters with `include_objects` when exactly one database is selected; table excludes with `exclude_objects`. | Limited for generated SQL dumps; restore replays the SQL artifact. | Multi-database table filters are rejected because `mysqldump` cannot safely express that as one simple command. |
| MongoDB | Database and collection namespace filters with `include_targets` and `include_objects`. | Supported with restore options such as `ns_include` / `ns_exclude`. | Collection names are combined with selected databases when both fields are set. |
| Redis / Valkey | DB index filters with `include_targets`/`exclude_targets`; key pattern filters with `include_objects`/`exclude_objects`. | Limited; JSON logical restore applies the keys present in the artifact. | DB indexes can be comma-separated or ranges such as `0-2`. |
| CouchDB | One database per backup, selected by connection database or `include_targets`. | Limited; restore imports the document set in the artifact. | Document-level export filters are not normalized. |
| Couchbase | Bucket/scope/collection filters with `include_data`, `bucket_include`, `include_targets`, or `include_objects`; matching exclude aliases are supported. | Supported by `cbbackupmgr restore` data filters such as `bucket_include` / `bucket_exclude`. | Include and exclude data filters are mutually exclusive. Restore defaults `force_updates=true` to avoid successful restores that skip older mutations behind newer target tombstones. |
| Neo4j | One database per logical export, selected by connection database or `include_targets`. | Limited; restore replays the Cypher artifact. | Label/type filtering is not normalized. |
| Oracle | Data Pump `FULL`, `SCHEMAS`, or `TABLES` modes; `include_targets` maps to schemas and `include_objects` maps to tables. | Possible through Data Pump options/extra args, but not normalized as generic restore fields. | Full, schema, and table export modes are mutually exclusive. |
| Cassandra | One `keyspace.table` per logical backup; `include_targets` maps to keyspace and `include_objects` maps to table. | Not applicable as a full logical artifact; restore loads one CSV into one table. | Use separate backups for each table. |
| ClickHouse | One or more databases with `include_targets`, one or more tables with `include_objects`, and optional `where` row filter. | Supported for table subsets with restore `include_objects` / `include_tables` and target database options. | Fully qualified table names can span databases. |
| Snowflake | A custom `query`, or one table with database/schema/table selectors. | Restore targets one table; arbitrary subset restore requires the backup query to contain that subset. | Use `query` for row-level or complex exports. |
| Cosmos DB | One database/container, plus optional `query`; `include_targets` maps to database and `include_objects` maps to container. | Limited; restore imports the documents in the artifact to the selected target. | Use query-scoped backups for partial document sets. |
| DynamoDB | One table per backup, selected by `table_name`, `table`, or `include_targets`. | Limited; restore imports all items in the artifact to one target table. | Multi-table export should be scheduled as separate backups. |
| Firestore | Collections with `collection_ids`, `include_targets`, and `exclude_targets`. | Limited; restore imports the documents in the artifact. | Document/field filtering is not normalized. |
| Microsoft SQL Server | Whole database BACPAC export, selected by connection database or `include_targets`/`database_name`. | No generic schema/table subset restore from a BACPAC. | Existing `.sql` script restore can replay a custom script, but DBAegis-generated logical backups are BACPAC files. |
| Azure SQL | Whole database BACPAC export. | No generic schema/table subset restore from a BACPAC. | Use database-native or tool-specific flows outside DBAegis for object-level Azure SQL export. |
| SQLite | Whole database file copy. | No table-level restore filtering. | Use external SQLite dump commands for table-only workflows. |

Physical backup execution modes in the UI are intentionally DB-host oriented. Server databases expose `SSH on DB Host` or database-native modes; the old generic local-source choice is no longer shown. SQLite keeps a SQLite-specific file-copy mode because its physical artifact is the database file itself.

| Database | Mode | Supported Backup Targets | Supported Restore Sources | Notes |
|---|---|---|---|---|
| PostgreSQL | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `pg_dump` / `psql`; DB server local backup runs `pg_dump` over SSH, and DB server local restore can import a DB-host `.sql` or `.sql.gz` file over SSH. |
| PostgreSQL | Physical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | `pg_basebackup` runs over SSH on the DB host for split-VM physical backups. DBAegis-local and cloud targets stage the temporary tarball under `db_vm_temp_dir` on the DB VM, stream/copy it to the selected destination, then delete the temp artifact. Physical restore can extract a local, cloud-staged, or DB-host tarball into `target_pgdata`. PostgreSQL copied-log PITR is supported by restoring a physical base backup with `pitr_target_time` or `recovery_target_time` and a complete copied WAL directory supplied through `pitr_log_source` or `wal_source`. |
| MySQL | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `mysqldump` / `mysql`; cloud restore streams SQL from object storage into `mysql`. DB server local backup runs `mysqldump` over SSH, and DB server local restore can import a DB-host `.sql` or `.sql.gz` file over SSH. |
| MySQL | Physical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `xtrabackup` when available, or an offline/snapshot-safe datadir tarball when `physical_options.data_dir` is provided. DBAegis rejects datadir paths that look like live InnoDB/MariaDB data directories unless `physical_options.consistency` is set to `snapshot-safe`; use that only when the path points to a frozen filesystem snapshot or offline copy. Cloud targets stage the temporary artifact under `db_vm_temp_dir` on the DB VM and stream it to object storage over SSH. Physical restore can unpack and prepare a local, cloud-staged, or DB-host backup path into `target_datadir`. MySQL PITR is supported by restoring a physical base backup and replaying a copied binary-log chain with `mysqlbinlog`; the restore needs `pitr_target_time` or `binlog_stop_position` plus `binlog_source` / `pitr_log_source`. |
| MariaDB | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `mysqldump` / `mysql`; cloud restore streams SQL from object storage into `mysql`. DB server local backup runs `mysqldump` over SSH, and DB server local restore can import a DB-host `.sql` or `.sql.gz` file over SSH. |
| MariaDB | Physical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `mariadb-backup` / `mariabackup` when available, or an offline/snapshot-safe datadir tarball when `physical_options.data_dir` is provided. DBAegis rejects datadir paths that look like live InnoDB/MariaDB data directories unless `physical_options.consistency` is set to `snapshot-safe`; use that only when the path points to a frozen filesystem snapshot or offline copy. Cloud targets stage the temporary artifact under `db_vm_temp_dir` on the DB VM and stream it to object storage over SSH. Physical restore can unpack and prepare a local, cloud-staged, or DB-host backup path into `target_datadir`. MariaDB PITR is supported by restoring a physical base backup and replaying a copied binary-log chain with `mysqlbinlog`/compatible tooling; the restore needs `pitr_target_time` or `binlog_stop_position` plus `binlog_source` / `pitr_log_source`. |
| MongoDB | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `mongodump --archive`; cloud restore streams archives from object storage into `mongorestore --archive`. DB server local backup runs `mongodump` over SSH, and DB server local restore can run `mongorestore` against a DB-host archive/path over SSH. |
| MongoDB | Physical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Creates a `.tar.gz` copy of the MongoDB `dbPath` for self-managed deployments. Cloud targets stage the temporary artifact under `db_vm_temp_dir` on the DB VM and stream it to object storage over SSH. Physical restore extracts the local, cloud-staged, or DB-host archive into `target_dbpath`; stop `mongod` yourself before restore. |
| Redis / Valkey | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis-local/cloud/DB-server-local logical export supported key types as JSON; DB-server-local writes the JSON.GZ artifact to the DB host over SSH. |
| Redis / Valkey | Physical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `redis-cli --rdb` or `valkey-cli --rdb` to create an RDB snapshot. Cloud targets stage the temporary RDB under `db_vm_temp_dir` on the DB VM and stream it to object storage over SSH. Physical restore reloads the local, cloud-staged, or DB-host RDB into a self-managed target. |
| SQLite | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Streams or copies the SQLite database file. In split-VM deployments, cloud and DB-server-local backup/restore copy the file over SSH on the DB host or require an explicit shared mount. |
| SQLite | Physical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses the database-file artifact path and can restore optional WAL/SHM sidecar files. The restore UI shows DB VM staging controls for split-VM physical/file restores. |
| CouchDB | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `_all_docs` export and `_bulk_docs` restore; DB server local backup and restore can run the HTTP export/import on the DB host over SSH. |
| Couchbase | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | `cbbackupmgr` creates archive directories for local targets. For cloud targets, Enterprise native object-store mode is available when explicitly requested; default/community mode stages the archive under `db_vm_temp_dir` on the DB VM and streams a tarball to object storage. The Couchbase Backup Type selector offers incremental/default and full; full maps to `--full-backup`, while incremental/default lets `cbbackupmgr` continue the existing archive chain. Cloud restore of staged tarballs downloads to the DB VM and runs `cbbackupmgr restore` there. Restore uses `--force-updates` by default so same-bucket point-in-time restores recover documents deleted after backup; set `force_updates=false` to keep native conflict resolution. |
| Neo4j | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses Cypher export/import; DB server local backup stages the Cypher export on DBAegis and uploads it to the DB host over SSH, and DB server local restore can fetch a DB-host Cypher file over SSH before import. |
| Neo4j | Physical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | `neo4j-admin` dump can run on DBAegis or over SSH on the DB host. In split-VM deployments, cloud targets stage the dump under `db_vm_temp_dir` on the DB VM and stream it to object storage over SSH. Physical restore can load a local, cloud-staged, or DB-host dump path, but Neo4j Community should restore into the configured/default database rather than a second database name. |
| Microsoft SQL Server | Logical | DBAegis local file, AWS S3, Azure Blob, GCS | DBAegis local file, AWS S3, Azure Blob, GCS | Uses `sqlpackage` BACPAC export/import from the DBAegis VM. DB-server-local backup is not supported for this mode because the logical artifact is created client-side on the DBAegis VM. Existing `.sql` script restore remains supported. |
| Microsoft SQL Server | Physical | DBAegis local file, DB server local, AWS S3, Azure Blob, GCS | DB server local, AWS S3, Azure Blob, GCS | Native backup/restore requires SQL Server-visible files. DBAegis-local and cloud backups write full/differential/copy-only `.bak` files or transaction-log `.trn` files under `db_vm_temp_dir` on the DB VM, stream/copy them to the selected destination over SSH, then delete the temp file by default. The SQL Server Backup Type selector supports full, differential (`WITH DIFFERENTIAL`), copy-only (`WITH COPY_ONLY`), and transaction-log (`BACKUP LOG`) native backups. SQL Server PITR is supported by restoring a physical full `.bak` base backup with optional `differential_backup_file`, ordered `log_backup_files` or `log_backup_source`, and `pitr_target_time` / `stopat`; DBAegis restores the base and differential with `NORECOVERY`, replays log backups with `RESTORE LOG`, and applies `STOPAT` plus `RECOVERY` on the final log. The legacy alias `remote_backup_output_path` is still accepted by the API. Cloud restore downloads the selected base object to `db_vm_temp_dir`/`server_temp_dir` on the DB VM over SSH before running `RESTORE DATABASE`; log-chain files must be supplied as SQL Server-visible paths or an ordered list. |
| Oracle | Logical | DBAegis local file, DB server local, AWS S3, Azure Blob, GCS | DB server local, AWS S3, Azure Blob, GCS | Uses Oracle Data Pump `expdp` / `impdp`; dump files are Oracle DIRECTORY/server-side artifacts. DBAegis-local and cloud backups run `expdp` on the DB VM over SSH, write to `db_vm_temp_dir`, stream/copy the dump to the selected destination, then delete the temp dump. The legacy alias `oracle_db_temp_dir` is still accepted by the API. Cloud restore downloads the object to `db_vm_temp_dir`/`server_temp_dir` on the DB VM over SSH, auto-creates the configured Oracle DIRECTORY by default, runs `impdp` over SSH, and removes the temp dump/logs. |
| Oracle | Physical | DBAegis local file, DB server local, AWS S3, Azure Blob, GCS | DB server local, AWS S3, Azure Blob, GCS | Uses Oracle RMAN backup sets and restore/recover workflows. DBAegis-local and cloud backups run RMAN on the DB VM over SSH, write backup pieces under `db_vm_temp_dir`, stream/copy a `.tar.gz` archive to the selected destination, then delete the temp pieces. RMAN target/catalog connect strings are sent inside the RMAN stdin script rather than as process arguments. RMAN online backup does not require a separate manual BEGIN/END BACKUP option in the UI; archive log inclusion is controlled by `Include archive logs`. The Oracle RMAN Backup Type selector supports full, incremental level 0, level 1 differential, and level 1 cumulative backups; legacy API fields `incremental_level` and `incremental_type` remain accepted. Oracle RMAN PITR is supported by restoring a physical backup with `pitr_target_time`, `pitr_target_scn`, `recovery_target_time`, or `restore_point`; DBAegis writes RMAN `SET UNTIL TIME` or `SET UNTIL SCN` inside the RMAN `RUN` block, restores archived logs, runs `RECOVER DATABASE`, and opens with `RESETLOGS` unless validate-only mode is selected. Oracle timestamp targets should use the Oracle database/server time context. Use `pitr_log_source` or `archive_log_source` when the selected backup did not include the required archived redo logs. The legacy alias `oracle_db_temp_dir` is still accepted by the API. Cloud restore downloads the RMAN archive to `db_vm_temp_dir`/`server_temp_dir` on the DB VM, safely extracts backup pieces there, runs RMAN over SSH, then deletes the temp file and extraction directory by default. |
| Cassandra | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses the Python Cassandra driver to export one table as CSV.GZ; cloud restore streams CSV/CSV.GZ from object storage into the driver importer. DB server local backup stages that CSV.GZ on the DB host over SSH, and restore can fetch a DB-host CSV/CSV.GZ over SSH before importing into an existing table. |
| Cassandra | Physical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `nodetool snapshot` for one keyspace/table. In production split-VM deployments, DBAegis runs Cassandra physical backup with `physical_options.execution_mode=ssh_remote_tool` so `nodetool` runs on the DB VM where the Cassandra files exist. The UI exposes SSH on DB Host for this mode. The backup stores snapshot SSTables as a `.tar.gz`, and restore copies SSTables into the table directory followed by `nodetool refresh`. Cloud targets stage the snapshot archive under `db_vm_temp_dir` on the DB VM and stream it to object storage over SSH. |
| ClickHouse | Logical | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | DBAegis local file, DB server local with SSH, AWS S3, Azure Blob, GCS | Uses `clickhouse-client` to export table DDL and table rows into a DBAegis `.clickhouse.json.gz` archive. Cloud restore downloads the archive to DBAegis temp, gunzips the JSON manifest, recreates databases/tables, and streams rows back with `INSERT ... FORMAT JSONEachRow`. DB-server-local restore can fetch a DB-host archive over SSH before import. |
| Snowflake | Logical | DBAegis local file, AWS S3, Azure Blob, GCS | DBAegis local file, AWS S3, Azure Blob, GCS | Uses `snowsql` export with embedded DBAegis manifest metadata in the `.csv.gz` or `.csv` artifact. Cloud restore can use Snowflake provider-stage `COPY INTO` directly from S3, GCS, or Azure Blob when a Snowflake storage integration, public storage, or explicitly allowed COPY credentials are configured; otherwise it falls back to a temporary DBAegis file. Password auth uses `SNOWSQL_PWD`; OAuth tokens are materialized only in a short-lived `0600` SnowSQL config file during command execution. |
| Cosmos DB | Logical | DBAegis local file, AWS S3, Azure Blob, GCS | DBAegis local file, AWS S3, Azure Blob, GCS | Connects to the live Cosmos DB service and exports/imports JSON documents. |
| DynamoDB | Logical | DBAegis local file, AWS S3, Azure Blob, GCS | DBAegis local file, AWS S3, Azure Blob, GCS | Connects to the live DynamoDB service and exports/imports table items as JSON. |
| Firestore | Logical | DBAegis local file, AWS S3, Azure Blob, GCS | DBAegis local file, AWS S3, Azure Blob, GCS | Connects to the live Firestore service and exports/imports documents as JSON. |
| Azure SQL | Logical | DBAegis local file, AWS S3, Azure Blob, GCS | DBAegis local file, AWS S3, Azure Blob, GCS | Uses `sqlpackage` BACPAC export/import for Azure SQL managed-service databases; DB VM staging is not applicable. |

### Backup Artifact Compression

Logical backups that write DBAegis-managed gzip-capable artifacts expose a `Compression Level` option in connection/schedule settings and manual backup runs. The choices are:

- `Auto`: default gzip behavior for that engine.
- `None`: write the plain, uncompressed equivalent when the engine path supports it.
- `Fast`: gzip with a faster compression level.
- `Best`: gzip with the highest compression level.

This option applies to logical PostgreSQL, MySQL, MariaDB, MongoDB, Redis / Valkey, CouchDB, Cassandra, Snowflake, ClickHouse, Cosmos DB, DynamoDB, and Firestore. Oracle logical backup exposes native Data Pump compression choices instead: `Auto`, `None`, and `Data Pump All`; it does not show gzip `Fast` because Data Pump does not provide a distinct matching behavior in this path. Physical backups and native formats such as SQL Server/Azure SQL BACPAC, SQL Server `.bak`/`.trn`, Neo4j dump/backup, Couchbase native archives, Redis RDB/AOF, and tar-based physical artifacts keep their native format behavior.

Restore decompression is detected from the source filename suffix whenever DBAegis streams, downloads, or stages a backup. Mixed compressed and uncompressed logical backups can therefore be restored through the same restore path. For MongoDB logical restore, `.archive.gz` uses `mongorestore --gzip`, `.archive` does not, and the UI's `Force gzip for custom archive` option is only for unusual custom paths that lack a useful suffix.

### Default Compression By Database

This table lists every configured database family exposed by DBAegis and the default artifact compression behavior for its supported backup modes.

| Configured Database | Supported Backup Modes | Default Logical Backup Compression | Default Physical Backup Compression | Compression Setting Exposed |
|---|---|---|---|---|
| PostgreSQL | Logical, physical | Gzip SQL dump: `.sql.gz`. `None` writes `.sql`. | Gzip tar archive: `.tar.gz`. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| MySQL | Logical, physical | Gzip SQL dump: `.sql.gz`. `None` writes `.sql`. | Gzip tar archive: `.tar.gz`. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| MariaDB | Logical, physical | Gzip SQL dump: `.sql.gz`. `None` writes `.sql`. | Gzip tar archive: `.tar.gz`. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| MongoDB | Logical, physical | Gzip `mongodump` archive: `.archive.gz`. `None` writes `.archive`. | Gzip tar archive of `dbPath`: `.tar.gz`. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| Redis / Valkey | Logical, physical | Gzip JSON export: `.json.gz`. `None` writes `.json`. | Native RDB/AOF artifact; no DBAegis gzip by default. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| SQLite | Logical, physical | Database file copy as-is: usually `.sqlite3`. | Database file copy as-is: usually `.sqlite3`. | None. Restore can still read custom `.sqlite3.gz` sources by suffix. |
| CouchDB | Logical | Gzip JSON document export: `.json.gz`. `None` writes `.json`. | No physical DBAegis mode. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| Couchbase | Logical | Native `cbbackupmgr` archive. Default/community cloud staging packages it as `.cbarchive.tar.gz`. | No physical DBAegis mode. | Native backup type controls full/incremental behavior; no generic gzip level. |
| Neo4j | Logical, physical | Cypher export as-is: `.cypher`. | Native `.dump` by default, or `.backup` for selected online backup types. | None. Restore can read custom `.cypher.gz` sources by suffix. |
| Microsoft SQL Server | Logical, physical | Native BACPAC: `.bacpac`; no DBAegis gzip. | Native SQL Server backup: `.bak` for full/differential/copy-only, `.trn` for transaction logs; no DBAegis gzip. | Native SQL Server backup type controls full/differential/copy-only/log behavior. |
| Oracle | Logical, physical | Native Data Pump dump: `.dmp`. `Auto` leaves Data Pump defaults; `None` emits `COMPRESSION=NONE`; `Data Pump All` emits `COMPRESSION=ALL`. | Native RMAN pieces; DBAegis-local/cloud staged copies are packaged as `.tar.gz`. | Logical Data Pump compression: `Auto`, `None`, `Data Pump All`. Physical has no generic gzip level. |
| Cassandra | Logical, physical | Gzip CSV export: `.csv.gz`. `None` writes `.csv`. | Gzip tar archive of snapshot files: `.tar.gz`. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| ClickHouse | Logical | Gzip DBAegis JSON archive: `.clickhouse.json.gz`. `None` writes `.clickhouse.json`. | No physical DBAegis mode. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| Snowflake | Logical | Gzip CSV manifest archive: `.csv.gz`. `None` writes `.csv`. | No physical DBAegis mode. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| Cosmos DB | Logical | Gzip JSON export: `.json.gz`. `None` writes `.json`. | No physical DBAegis mode. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| DynamoDB | Logical | Gzip JSON export: `.json.gz`. `None` writes `.json`. | No physical DBAegis mode. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| Firestore | Logical | Gzip JSON export: `.json.gz`. `None` writes `.json`. | No physical DBAegis mode. | Logical `Compression Level`: `Auto`, `None`, `Fast`, `Best`. |
| Azure SQL | Logical | Native BACPAC: `.bacpac`; no DBAegis gzip. | No physical DBAegis mode. | None. |

| Database / Mode | Generated Artifact | Compression / Restore Behavior |
|---|---|---|
| PostgreSQL, MySQL, MariaDB logical | `.sql.gz` by default; `.sql` with Compression Level `None` | Restore gunzips `.sql.gz` while streaming into `psql`, `mysql`, or `mariadb`; plain `.sql` is streamed directly. |
| PostgreSQL, MySQL, MariaDB physical | `.tar.gz` | Physical backup output is stored as a gzip tar archive. Restore extracts the archive before the engine-specific physical restore/prepare step. |
| MongoDB logical | `.archive.gz` by default; `.archive` with Compression Level `None` | Restore streams archives to `mongorestore --archive`; `.archive.gz` adds `--gzip`, while `.archive` does not. |
| MongoDB physical | `.tar.gz` | MongoDB `dbPath` copy is stored as a gzip tar archive and extracted before replacing the target path. |
| Redis / Valkey logical | `.json.gz` by default; `.json` with Compression Level `None` | Restore gunzips `.json.gz` before applying keys; plain `.json` is read directly. |
| Redis / Valkey physical | `.rdb` | Native RDB snapshot. Restore uses the RDB file as-is. |
| SQLite logical/physical | `.sqlite3` | Database file copy with no DBAegis compression. Restore can also read custom `.sqlite3.gz` sources by suffix. |
| CouchDB logical | `.json.gz` by default; `.json` with Compression Level `None` | Restore gunzips `.json.gz` and posts `_bulk_docs`; plain `.json` is read directly. |
| Couchbase logical | Native archive directory or `.cbarchive.tar.gz` for staged/community cloud paths | `cbbackupmgr` consumes the native archive. The backup type selector can create a forced full archive with `--full-backup` or continue the default incremental chain. Staged/community cloud restore extracts the tarball before running `cbbackupmgr restore`. |
| Neo4j logical | `.cypher` | Cypher text export. Restore replays it with `cypher-shell`; custom `.cypher.gz` sources are gunzipped by suffix. |
| Neo4j physical | `.dump` by default; `.backup` when the Neo4j Backup Type option selects full, differential with full fallback, or auto online backup | Default physical backup uses native `neo4j-admin database dump` and restore uses `neo4j-admin database load`. Selecting full online backup generates `neo4j-admin database backup --type=FULL`. Selecting differential with full fallback generates `--type=AUTO`, so Neo4j creates a full backup when no valid chain exists and differential backups when possible. Optional Backup Service Address generates `--from=<host:6362>`, and `.backup` artifacts restore with `neo4j-admin database restore`. Advanced `extra_args` remain available for flags such as `--prefer-diff-as-parent`. |
| Oracle logical | `.dmp` | Native Data Pump dump. `Data Pump All` requests `COMPRESSION=ALL COMPRESSION_ALGORITHM=BASIC`; `None` requests `COMPRESSION=NONE`; `Auto` leaves Data Pump defaults unchanged. Restore uses `impdp` as-is. |
| Oracle physical | RMAN backup pieces; DBAegis-local/cloud staged copies use `.tar.gz` | RMAN creates native backup pieces. The backup type selector maps to full or RMAN incremental level 0/1 clauses. Staged restore extracts the tarball before running RMAN. RMAN PITR catalogs the selected backup pieces plus any copied archive-log source before issuing `SET UNTIL TIME` or `SET UNTIL SCN` inside the RMAN `RUN` block. |
| Cassandra logical | `.csv.gz` by default; `.csv` with Compression Level `None` | Restore gunzips `.csv.gz` and imports into the selected table; plain `.csv` is read directly. |
| Cassandra physical | `.tar.gz` | `nodetool snapshot` output is stored as a gzip tar archive. Restore extracts SSTables before `nodetool refresh`. |
| ClickHouse logical | `.clickhouse.json.gz` by default; `.clickhouse.json` with Compression Level `None` | Restore gunzips `.clickhouse.json.gz` before replaying rows as `JSONEachRow`; plain `.clickhouse.json` is read directly. |
| Snowflake logical | `.csv.gz` by default; `.csv` with Compression Level `None` | Restore reads the embedded DBAegis manifest from compressed or plain CSV and uses the matching SnowSQL/COPY file-format compression. |
| Cosmos DB, DynamoDB, Firestore logical | `.json.gz` by default; `.json` with Compression Level `None` | Restore gunzips `.json.gz` and imports through the provider/client API; plain `.json` is read directly. |
| SQL Server logical, Azure SQL logical | `.bacpac` | Native sqlpackage BACPAC. Restore imports it as-is. |
| SQL Server physical | `.bak` / `.trn` | Native SQL Server backup file. Full, differential, and copy-only selections produce `.bak` artifacts; transaction-log backups produce `.trn` artifacts. PITR restores use `RESTORE DATABASE` for the base/differential backups and `RESTORE LOG ... STOPAT` for the ordered log chain. |

### Backup Destination Selection

Connection defaults and manual backup runs group destinations by type first: DBAegis VM, DB server, AWS S3, Azure Blob, and GCS. DBAegis VM includes the built-in local path plus any active configured local storage destinations. Cloud types show a second dropdown containing only active configured destinations of the selected type. DB server uses the connection's DB-server backup path and requires SSH for modes that run server-side tools.

Large cloud artifacts use an extended provider transfer timeout. GCS and Azure uploads/downloads default to 900 seconds per SDK request. Storage destinations can override this with `upload_timeout_seconds`, `download_timeout_seconds`, or `transfer_timeout_seconds` when large Oracle RMAN archives, SQL Server `.bak`/`.trn` files, or other staged physical artifacts need more time to cross the network.

## Not Listed

If a target/source is not listed for a database and mode, DBAegis does not currently support that path. Provider-native backup features may still be preferable for point-in-time recovery, cross-region replication, or managed-service compliance workflows.

For cloud object backup targets specifically, unsupported cases are those not listed for `AWS S3`, `Azure Blob`, or `GCS` in the matrix above.

## Point-In-Time Restore

DBAegis-managed point-in-time restore is an engine-specific physical restore
workflow, not a replacement for provider-native PITR. In this release, DBAegis
supports PostgreSQL, Oracle, MySQL, MariaDB, and Microsoft SQL Server physical
PITR when these requirements are met.

PostgreSQL requirements:

- the source backup is a DBAegis PostgreSQL physical base backup
- the target restore uses physical mode and a valid `target_pgdata`
- the copied WAL/archive log chain fully covers the requested target time
- the restore request includes `pitr_target_time` or `recovery_target_time`
- the restore request or PITR catalog row includes `pitr_log_source` or
  `wal_source`, pointing to the copied WAL directory

When a PostgreSQL physical backup completes, DBAegis creates a `pitr_chains`
metadata row for the base backup. If the backup options included a WAL/log
source, the chain is marked available. If the WAL source is not known at backup
time, the chain is preserved as requiring a log source, and the operator must
enter the copied WAL path when starting the restore.

The PostgreSQL restore path writes PostgreSQL recovery settings during physical
restore. DBAegis creates `recovery.signal`, adds a `restore_command` that
copies WAL files from the configured source, and writes
`recovery_target_time` when a target time is supplied. DBAegis writes
`recovery_target_action = 'promote'` by default so a completed PITR restore
opens as a usable restored primary; set `recovery_target_action` explicitly to
`pause` or `shutdown` when an operator wants PostgreSQL's alternate recovery
target behavior. The restored PostgreSQL instance performs the actual WAL
replay during startup.

Oracle requirements:

- the source backup is a DBAegis Oracle physical RMAN backup
- the target restore uses physical mode and the database is in the Oracle state
  required for the selected RMAN restore/recover operation
- the RMAN backup includes archived redo logs, or the restore request includes
  `pitr_log_source` or `archive_log_source` pointing to copied archive logs
- the restore request includes `pitr_target_time`, `pitr_target_scn`,
  `recovery_target_time`, or `restore_point`
- target times use `YYYY-MM-DD HH:MM:SS`; target SCNs can be supplied as
  `SCN 1234567` or `1234567`
- Oracle RMAN evaluates timestamp targets in the Oracle database/server time
  context

When an Oracle physical backup completes, DBAegis creates a `pitr_chains`
metadata row for the backup. RMAN backups created with archive-log inclusion
are marked available for PITR. Backups created without archive logs are kept in
the PITR catalog but require a copied archive-log source at restore time.

The Oracle restore path writes the RMAN recovery workflow. DBAegis catalogs the
selected backup pieces, catalogs `pitr_log_source` or `archive_log_source` when
provided, emits `SET UNTIL TIME` or `SET UNTIL SCN` inside the RMAN `RUN`
block, restores archived logs, runs `RECOVER DATABASE`, and opens the database
with `RESETLOGS` unless validate-only mode is selected.

MySQL/MariaDB requirements:

- the source backup is a DBAegis MySQL or MariaDB physical base backup created
  by XtraBackup/MariaBackup, or an equivalent offline/snapshot-safe physical
  source
- the target restore uses physical mode and a valid `target_datadir`
- the copied binary-log chain fully covers the requested target time or stop
  position and is available on the node that runs restore replay
- the restore request includes `pitr_target_time` / `binlog_stop_datetime`, or
  `binlog_stop_position`
- the restore request or PITR catalog row includes `pitr_log_source` or
  `binlog_source`, pointing to the copied binary-log file or directory
- the restored base backup contains `xtrabackup_binlog_info` /
  `xtrabackup_slave_info`, or the restore request supplies `binlog_start_file`
  and `binlog_start_position`

When a MySQL/MariaDB physical backup completes, DBAegis creates a `pitr_chains`
metadata row for the base backup. If the backup or connection options include a
binary-log source, the chain is marked available. Otherwise the chain is kept
as requiring a log source, and the operator must enter the copied binary-log
path when starting the restore.

The MySQL/MariaDB restore path prepares the restored datadir, reads the base
backup's start binary-log file and position when present, then runs
`mysqlbinlog` or a configured compatible binlog decoder and streams the replay
into the configured `mysql`/`mariadb` client. Use tool binaries that match the
source server family and version; for example, MariaDB binary logs may require
MariaDB's native binlog decoder rather than a MySQL client package. For split-VM
restores, the copied binary logs and client tools must be available on the DB
server reached by SSH. For local restores, they must be available on the
DBAegis VM. The target MySQL/MariaDB instance must be reachable by the restore
connection when binlog replay runs.

SQL Server requirements:

- the source backup is a DBAegis SQL Server physical full `.bak` base backup
- the source database used the `FULL` or `BULK_LOGGED` recovery model before
  the log-chain backups were created
- the target restore uses physical mode and a target SQL Server database name
- the restore request includes `pitr_target_time` or `stopat`
- the restore request or PITR catalog row includes `pitr_log_source`,
  `log_backup_source`, or ordered `log_backup_files` covering the target time;
  directory sources are expanded when visible locally or over configured SSH,
  otherwise provide the ordered file list explicitly
- `differential_backup_file` is optional and is restored before the log chain
  when supplied

When a SQL Server full or copy-only physical backup completes, DBAegis creates
a `pitr_chains` metadata row for the base backup. If the backup or connection
options include a transaction-log source, the chain is marked available.
Otherwise the chain is kept as requiring a log source, and the operator must
enter the copied transaction-log path or ordered log file list when starting
the restore. Differential and transaction-log backup jobs remain in backup
history but are not treated as PITR base backups.

The SQL Server PITR restore path runs a native restore sequence through
`sqlcmd`: base `RESTORE DATABASE ... WITH NORECOVERY`, optional differential
`RESTORE DATABASE ... WITH NORECOVERY`, each intermediate `RESTORE LOG ... WITH
NORECOVERY`, and the final `RESTORE LOG ... WITH STOPAT = ... , RECOVERY`.
SQL Server evaluates `STOPAT` in the target SQL Server instance context.

In the UI, PostgreSQL PITR inputs appear in the physical restore panel under
`Point-in-Time Recovery`; MySQL/MariaDB PITR inputs appear in the physical
restore panel under `Point-in-Time Recovery`; SQL Server PITR inputs appear in
the physical restore panel as `PITR Target Time / STOPAT`, transaction-log
source/files, and optional differential backup file; Oracle PITR inputs appear
under `PITR and archive logs`. The Restore Jobs view marks submitted PITR
restores with a `PITR` badge and reports the running phase as PITR recovery.

DBAegis does not currently orchestrate PITR for managed PostgreSQL services,
managed Oracle services, managed MySQL/MariaDB services, managed SQL Server
provider-native PITR jobs, MongoDB oplog replay, or cloud-provider recovery
jobs. Use the provider or engine-native recovery workflow for those paths
unless DBAegis explicitly lists support for that engine and mode.

## Managed And Serverless Database Coverage

DBAegis treats managed and serverless databases as supported when the service exposes the same database protocol used by the matching logical backup and restore path. Configure the connection with the engine type, not the cloud product name. For example, Amazon RDS/Aurora MySQL uses `mysql`, Amazon RDS/Aurora PostgreSQL uses `postgresql`, Amazon DocumentDB uses `mongodb`, Azure SQL Database uses `azuresql`, and managed SQL Server endpoints use `mssql`. DBAegis also accepts common aliases such as `aurora_mysql`, `amazon_aurora_mysql`, `aurora_postgresql`, `amazon_aurora_postgresql`, `sqlserver`, `microsoft_sql_server`, `azure_sql`, and `azure_sql_database`, then normalizes them to the supported engine key. Do not use physical or DB-server-local backup/restore modes for managed/serverless products unless the provider gives you a real host filesystem and SSH/tool access.

For restore, use the same logical artifact type produced by the matching engine path: `.sql`/`.sql.gz` for MySQL-family and PostgreSQL-family logical restores, MongoDB archives for managed MongoDB-compatible endpoints, JSON/API artifacts for managed key/document services, and BACPAC for Azure SQL or SQL Server logical restores. DBAegis rejects managed/serverless physical restores and DB-server-local restores before invoking engine tools.

| Managed / serverless service | DBAegis db_type | Supported DBAegis path | Not supported in DBAegis | Notes |
|---|---|---|---|---|
| Amazon Aurora MySQL, including Aurora Serverless v2 | `mysql` | Logical backup/restore with `mysqldump` / `mysql` to DBAegis local, AWS S3, Azure Blob, or GCS | Physical backup/restore, DB-server-local backup/restore | Use the Aurora cluster endpoint, database credentials, network access, and TLS options as needed. |
| Amazon RDS for MySQL | `mysql` | Logical backup/restore with `mysqldump` / `mysql` | Physical backup/restore, DB-server-local backup/restore | RDS host files are not exposed to DBAegis. |
| Google Cloud SQL for MySQL | `mysql` | Logical backup/restore with `mysqldump` / `mysql` | Physical backup/restore, DB-server-local backup/restore, provider-native serverless export/import orchestration | DBAegis uses client tools over the MySQL protocol; Cloud SQL's own export jobs are separate provider-native operations. |
| Azure Database for MySQL Flexible Server | `mysql` | Logical backup/restore with `mysqldump` / `mysql` | Physical backup/restore, DB-server-local backup/restore | Use the Flexible Server endpoint and required TLS/network settings. |
| Amazon Aurora PostgreSQL, including Aurora Serverless v2 | `postgresql` | Logical backup/restore with `pg_dump` / `psql` / `pg_restore` | Physical backup/restore, DB-server-local backup/restore | Use provider-native snapshots/PITR for DR-style backups. |
| Amazon RDS for PostgreSQL, Google Cloud SQL for PostgreSQL, Azure Database for PostgreSQL | `postgresql` | Logical backup/restore with PostgreSQL client tools | Physical backup/restore, DB-server-local backup/restore | Same protocol-level support rule as self-managed PostgreSQL logical backups. |
| Azure SQL Database | `azuresql` | Logical BACPAC backup/restore with `sqlpackage` | Physical backup/restore | Use `azuresql`, not `mssql`, for Azure SQL Database. |
| AWS RDS for SQL Server or other managed SQL Server endpoints | `mssql` | Logical BACPAC backup/restore with `sqlpackage` when the endpoint permits it | DBAegis native `.bak`/`.trn` physical backup/restore unless SQL Server can write/read a DBAegis-accessible server-visible path | Provider-native SQL Server backup-to-object-storage features are outside the DBAegis self-managed physical path. |
| Amazon DocumentDB | `mongodb` | Logical backup/restore with `mongodump` / `mongorestore` when the endpoint and MongoDB Database Tools version are compatible | Physical `dbPath` backup/restore, DB-server-local backup/restore | Use the DocumentDB cluster endpoint, required TLS/CA settings, and provider-native snapshots/PITR for DR. Mark the connection as managed with `managed_service=documentdb` or `is_managed=true` if using API/import workflows. |
| MongoDB Atlas or compatible managed MongoDB | `mongodb` | Logical backup/restore with `mongodump` / `mongorestore` when the endpoint permits it | Physical `dbPath` backup/restore, DB-server-local backup/restore | Use provider-native snapshots for DR. |
| ElastiCache / Memorystore / Redis Enterprise Cloud | `redis` | Logical key export/import | Physical RDB/AOF backup/restore | DBAegis intentionally blocks managed Redis physical paths. |
| ClickHouse Cloud | `clickhouse` | Logical archive with `clickhouse-client` when reachable | Physical filesystem backup/restore | Review cluster-specific DDL, engines, and settings before restore. |
| Snowflake, Cosmos DB, DynamoDB, Firestore | `snowflake`, `cosmosdb`, `dynamodb`, `firestore` | Native logical/API export/import paths | Physical backup/restore | These are managed-service logical paths by design. |

## Cloud Restore Execution

Cloud restore sources are supported for all cloud-listed logical modes, but execution differs by engine:

| Restore execution | Databases |
|---|---|
| Streamed from object storage into the restore tool or driver | PostgreSQL, MySQL, MariaDB, MongoDB, Neo4j, Cassandra |
| Loaded as JSON payload from object storage and applied through APIs | Redis / Valkey, CouchDB, Cosmos DB, DynamoDB, Firestore |
| Database-native object-store restore with metadata-only local staging | Couchbase Enterprise when explicitly requested |
| Temporary DB VM archive tarball fallback | Couchbase Community / default Couchbase cloud tarball path |
| Temporary DB VM file artifact fallback | PostgreSQL physical, MySQL physical, MariaDB physical, MongoDB physical, Redis / Valkey physical, SQLite file, Cassandra physical, Neo4j physical |
| Temporary DB server file over SSH | Oracle logical, Oracle physical, Microsoft SQL Server physical |
| Temporary DBAegis file still required | ClickHouse, Azure SQL BACPAC, Microsoft SQL Server BACPAC; Snowflake only when provider-stage restore is unavailable |

### Cloud Restore Artifact Handling

For cloud restores, DBAegis preserves the object basename when it downloads or streams the object to DBAegis temp or DB VM temp. The restore engine then starts the database restore only after the engine-specific preparation step succeeds.

| Artifact Type | Handling Before Restore |
|---|---|
| `.sql.gz`, `.cypher.gz`, `.csv.gz`, `.json.gz` | Gunzipped while streaming into the restore tool or API importer. |
| `.sql`, `.cypher`, `.csv`, `.json` | Streamed or read directly without gunzip when the selected engine supports that logical format. |
| `.clickhouse.json.gz` | Downloaded to DBAegis temp for cloud restores, gunzipped as a manifest, then replayed through `clickhouse-client` with `JSONEachRow` inserts. |
| `.clickhouse.json` | Downloaded to DBAegis temp and read directly as the ClickHouse manifest/row archive. |
| `.archive.gz` MongoDB logical archives | Streamed to `mongorestore --archive --gzip` without expanding to a directory. |
| `.archive` MongoDB logical archives | Streamed to `mongorestore --archive` without `--gzip`. |
| `.tar`, `.tar.gz`, `.tgz` physical/file archives | Downloaded or copied to temp, safely extracted with `tar`/`tarfile`, then restored from the extracted directory or files. |
| Couchbase community/default `.cbarchive.tar.gz` | Downloaded to DB VM temp, safely extracted, then restored with `cbbackupmgr restore`. |
| Oracle RMAN `.tar`, `.tar.gz`, `.tgz` | Downloaded to DB VM temp, safely extracted under `oracle_rman_restore_<label>/`, then RMAN restore runs against the extracted backup pieces. |
| Oracle Data Pump `.dmp`, SQL Server `.bak`/`.trn`, SQL Server `.bacpac`, Azure SQL `.bacpac`, Redis `.rdb`/`.aof`, SQLite files | Downloaded or copied as single files; SQL Server physical files and Oracle Data Pump consume server-visible files, while BACPAC imports run from the DBAegis VM with `sqlpackage`. |

Use the generated backup file names when possible because they include the suffix DBAegis uses for format detection. For custom cloud objects, keep the expected suffix or set `options.server_temp_filename` / `options.server_temp_file` so the DB VM staged copy keeps a compatible extension before restore starts.

### Restore Start Security

Every manual restore start requires a user with `restores:run` access to the target connection, a restore reason, and password re-authorization before the backend creates or reruns the job. This includes dry-run restore jobs.

High-risk restores additionally require typing the target name exactly. DBAegis flags a restore as high risk when it is physical or when destructive options such as overwrite, replace existing, clean/drop/truncate before restore, recreate database, restore users/roles, or stop service before restore are enabled.

The restore job record keeps the requester, reason, target confirmation, and security flags for audit review.

### DBAegis VM Temporary Paths

All DBAegis VM temporary backup/restore staging uses the global `DBAEGIS_TEMP_DIR` from `conf/dbaegis.conf` (default `/opt/dbaegis/tmp`). This path is set during DBAegis setup, can be changed by editing `DBAEGIS_TEMP_DIR` in `dbaegis.conf`, and requires a DBAegis service restart. There is no per-connection DBAegis VM temp path.

This applies to internal DBAegis service scratch space such as local restore decompression/preparation, temporary SSH key files, Snowflake/Azure SQL client-side managed-service artifacts, and explicit API-only Couchbase native object-store staging. DB VM temporary staging is separate because it lives on the database server; use the canonical DB-server option `db_vm_temp_dir`. Legacy aliases such as `remote_staging_path`, `server_temp_dir`, `remote_backup_output_path`, `oracle_db_temp_dir`, and `couchbase_db_temp_dir` are still accepted where they already existed.

For staged backups that need DB VM files, set `logical_options.db_vm_temp_dir` or `physical_options.db_vm_temp_dir` according to the backup mode, or use the matching engine-specific alias. DBAegis creates a temporary work directory under that DB VM path, copies or streams the finished artifact to the selected DBAegis-local or cloud destination, records the final location, and deletes the DB VM temp artifact after upload/copy. For physical/file restores that need DB VM files, set `options.db_vm_temp_dir` or `options.server_temp_dir` to choose the DB VM temp/staging path. For cloud sources, DBAegis streams the object to that DB VM path. For DBAegis-local sources, DBAegis copies the local artifact to that DB VM path over SSH. It then runs the DB-server restore path from that temporary file and deletes the temp file by default. Logical protocol restores still stream directly from object storage without DB VM temp.

### DB Server Temporary Restore Paths

For Oracle logical, Oracle physical, and Microsoft SQL Server physical restores, the restore popup exposes `DB VM Temp / Staging Location` and always uses DB VM staging because the restore tools require server-visible files. DBAegis streams cloud objects or copies DBAegis-local artifacts to `<db_vm_temp_dir>/<object-name>` over SSH, runs the restore from that server-side file, then deletes the temp file by default. Oracle logical restores run `impdp` over SSH and can auto-create the configured Oracle DIRECTORY to point at the selected DB VM temp directory. Oracle physical restores also extract RMAN archive contents under `<db_vm_temp_dir>/oracle_rman_restore_<label>/` and remove that extraction directory after RMAN exits.

For PostgreSQL, MySQL, MariaDB, MongoDB, Redis / Valkey, SQLite, Cassandra, and Neo4j physical/file restores, the restore popup exposes `DB VM Temp / Staging Location` for DBAegis-local sources and exposes `Cloud Temp Location` plus the same DB VM path for cloud sources. Split-VM deployments default cloud file restores to `DB VM temp over SSH`. That path downloads/copies the artifact to the DB VM, then runs the existing DB-server-local restore path from that temporary file. `DBAegis VM temp` remains selectable for explicit shared-mount/local cloud restore cases and uses `<DBAEGIS_TEMP_DIR>/dbaegis-restore-cache/`. DB VM temp requires SSH remote execution on the target connection.

The target connection must have SSH execution configured. The temp directory must be an absolute Linux path writable by the SSH/run-as user. `server_temp_file_mode` defaults to `0644` so the database service can read the downloaded file; tighten this only when the database service user can still read it.

### DB Server Temporary Backup Paths

The add/edit connection backup options expose `DB VM Temp / Staging Location` for backup modes that must build a file on the DB VM before DBAegis copies it to DBAegis local storage or streams it to AWS S3, Azure Blob, or GCS. This includes physical/file backups for PostgreSQL, MySQL, MariaDB, MongoDB, Redis / Valkey, SQLite, Microsoft SQL Server, Cassandra, Neo4j, and Oracle, plus SQLite/Oracle logical file-based backups and Couchbase cloud fallback. The value is stored as `physical_options.db_vm_temp_dir` or `logical_options.db_vm_temp_dir`; existing aliases such as `remote_staging_path`, `remote_backup_output_path`, `oracle_db_temp_dir`, and `couchbase_db_temp_dir` remain accepted for API/backward compatibility but are not the recommended UI path.

Oracle cloud backups use DB server temporary staging instead of a DBAegis VM staging file. If blank, DBAegis uses `/var/tmp/dbaegis-oracle` on the DB VM. Logical backups also expose an Oracle DIRECTORY object setting; by default DBAegis creates or replaces `DBAEGIS_BACKUP_DIR` to point at that temp directory before running `expdp`.

Oracle logical restore additionally needs the selected Oracle DIRECTORY object to point to the same server directory. Oracle physical restore needs RMAN and the Oracle environment available to the SSH/run-as user, and the database must already be in the state required by the selected RMAN restore/recover workflow. SQL Server logical backup/restore needs `sqlpackage` on the DBAegis VM. SQL Server physical restore needs the SQL Server service account to read the `.bak` base/differential path and any `.trn` log-chain paths, commonly under `/var/opt/mssql/backups` on SQL Server for Linux.

### Couchbase Community Temporary Paths

When Couchbase uses the cloud fallback, DBAegis stages temporary files on the DB VM. `logical_options.couchbase_temp_location` now defaults to `db_vm`; older values such as `dbaegis_vm` are treated as `db_vm` for split-VM cloud backup/restore.

Set `logical_options.db_vm_temp_dir` to choose the DB VM path (default `/var/tmp/dbaegis-couchbase`). This requires SSH remote execution on the connection. Backup creates and compresses the archive on the DB VM, then streams the tarball through DBAegis to object storage; restore downloads the cloud tarball to the DB VM and runs `cbbackupmgr restore` there. Temporary DB VM files are removed after upload or restore. The legacy alias `logical_options.couchbase_db_temp_dir` is still accepted by the API.

| Operation | Temporary VM path | Cleanup |
|---|---|---|
| Cloud object name | `<cloud-prefix>/<generated-name>.cbarchive.tar.gz` | Retained in cloud as the backup artifact |
| DB VM backup archive before upload | `<db_vm_temp_dir>/dbaegis-cloud-work/<generated-name>.cbarchive` | Removed after upload succeeds or fails |
| DB VM restore download cache | `<db_vm_temp_dir>/dbaegis-restore-cache/<generated-name>.cbarchive.tar.gz` | Removed after restore succeeds or fails |
| DB VM restore extraction directory | `<db_vm_temp_dir>/couchbase_restore_<generated-name>/` | Removed after restore succeeds or fails |

`logical_options.couchbase_cloud_mode` can be `auto` (default), `staged`, or `community` for the DB VM staged tarball path. API callers that explicitly set `native` still request Couchbase Enterprise native object-store mode.

## Edition Support Guidance

This section describes database-vendor editions, not DBAegis product editions. DBAegis can operate Community/Open Source and Enterprise editions of a database engine where the selected backup or restore path uses the same protocol or native tool in both vendor editions. Vendor edition-specific features are only used when explicitly selected.

| Database | Community / Open Source Path | Enterprise / Commercial Path | Edition-Specific Notes |
|---|---|---|---|
| PostgreSQL | Supported with `pg_dump`, `psql`, and `pg_basebackup` | Supported for PostgreSQL-compatible commercial distributions when those tools/protocols are available | Physical backup still depends on replication permissions and compatible server/tool versions. |
| MySQL | Supported with `mysqldump`, `mysql`, and XtraBackup/datadir physical paths | Supported with the same paths when compatible tools are available | DBAegis does not require MySQL Enterprise Backup; physical backup tooling must match the server. |
| MariaDB | Supported with `mysqldump`, `mysql`, `mariadb-backup`, or `mariabackup` | Supported with the same paths when compatible tools are available | Physical backup tooling must match the server. |
| MongoDB | Logical and self-managed `dbPath` physical paths are supported | Enterprise/self-managed uses the same paths; managed service deployments should use logical backup | Physical `dbPath` backup is only for self-managed hosts where files are visible. |
| Redis / Valkey | Logical backup/restore and self-managed RDB/AOF physical paths are supported | Logical backup/restore is supported; Enterprise/managed physical backup is intentionally not supported | Use logical backup for Redis Enterprise, ElastiCache, Memorystore, or other managed Redis-compatible services. |
| SQLite | File backup/restore is supported | Not applicable | SQLite has no Enterprise path in DBAegis. |
| CouchDB | HTTP logical backup/restore is supported | CouchDB-compatible commercial deployments use the same HTTP logical path | Host-level physical backup is not supported. |
| Couchbase | Default/community cloud mode uses DB VM staged `cbbackupmgr` tarballs | Explicit `logical_options.couchbase_cloud_mode=native` uses Enterprise native object-store archives | `auto`, `staged`, and `community` use the DB VM staged fallback and require SSH. |
| Neo4j | Logical backup/restore is supported; physical restore targets the configured/default database | Enterprise can use the same paths and supports intended multi-database physical restore workflows | Neo4j Community physical restore should restore into the configured/default database. |
| Microsoft SQL Server | Express/Developer/Standard paths support BACPAC logical export/import and native `.bak`/`.trn` backup/restore | Enterprise uses the same BACPAC and native SQL Server physical paths | BACPAC logical backup/restore uses `sqlpackage` from the DBAegis VM; native full/differential `.bak` plus log `.trn` remains the DR/PITR-oriented physical path. |
| Oracle | XE/SE deployments can use Data Pump/RMAN when tools and permissions exist | Enterprise uses the same Data Pump/RMAN paths | DBAegis does not require Enterprise-only backup features, but Oracle licensing and feature availability remain the operator's responsibility. |
| Cassandra | Apache Cassandra logical and self-managed `nodetool snapshot` paths are supported | Enterprise-compatible Cassandra distributions use the same driver/`nodetool` paths when available | Physical snapshots require self-managed server file access. |
| ClickHouse | Community logical backup/restore is supported through `clickhouse-client` | Enterprise/Cloud-compatible deployments use the same native protocol when reachable | Physical filesystem backup is not implemented; use logical DBAegis archives or vendor-native backup for cluster/PITR needs. |
| Snowflake | Not applicable | Managed-service logical path is supported | DBAegis uses SnowSQL/service APIs, not host-level backup. |
| Cosmos DB | Not applicable | Managed-service logical path is supported | DBAegis uses service APIs. |
| DynamoDB | Not applicable | Managed-service logical path is supported | DBAegis uses service APIs. |
| Firestore | Not applicable | Managed-service logical path is supported | DBAegis uses service APIs. |
| Azure SQL | Not applicable | Managed-service BACPAC path is supported | Physical backup is provider-managed and not exposed through DBAegis. |

## Retention

DBAegis backup retention supports:

- age-based pruning with `retention_days`
- count-based pruning with `retention_count`

Retention is applied per connection after backup completion.

Current retention behavior:

- `DBAegis local file`: deletes old local backup artifacts and their backup-history rows
- `DB server local with SSH`: deletes old server-local filesystem artifacts over SSH when they are tracked under the configured backup root, and deletes their backup-history rows
- `AWS S3`, `Azure Blob`, `GCS`: deletes the remote object and the corresponding backup-history row

Retention can be set on:

- schedules
- manual backup runs as optional cleanup after that run

Manual backup runs default `retention_days=0` and `retention_count=0`, which means no cleanup. If an operator enters a non-zero value, retention is applied per connection after the backup finishes and can delete older local artifacts, DB-server-local artifacts DBAegis can remove, or cloud objects recorded for that connection.

Self-backup retention is separate from normal database backup retention.

## Backup Tool Location Guidance

DBAegis does not use one fixed bundled backup executable for every engine. The required binary depends on the selected backup target or restore source.

- `DBAegis local file`, `AWS S3`, `Azure Blob`, and `GCS` usually run the native tool on the DBAegis host.
- `DB server local with SSH` runs the native tool on the database server over SSH, so the tool must exist on the DB host unless the notes say otherwise.
- API-driven engines do not require a database-host executable.

Use the following rule of thumb:

| Database | Mode | Tool on DBAegis host | Tool on DB server |
|---|---|---|---|
| PostgreSQL | Logical | `pg_dump`, `psql`, `pg_restore` | `pg_dump`, `psql`, `pg_restore` for DB-server-local backup/restore |
| PostgreSQL | Physical | `pg_basebackup` | `pg_basebackup` for DB-server-local backup |
| MySQL | Logical | `mysqldump`, `mysql` | `mysqldump`, `mysql` for DB-server-local backup/restore |
| MySQL | Physical | `xtrabackup` | `xtrabackup` for DB-server-local backup, and for DB-server-local restore when the backup needs `--prepare` |
| MariaDB | Logical | `mysqldump`, `mysql` | `mysqldump`, `mysql` for DB-server-local backup/restore |
| MariaDB | Physical | `mariadb-backup` or `mariabackup` | `mariadb-backup` or `mariabackup` for DB-server-local backup, and for DB-server-local restore when the backup needs `--prepare` |
| MongoDB | Logical | `mongodump`, `mongorestore` | `mongodump`, `mongorestore` for DB-server-local backup/restore |
| Redis / Valkey | Logical | `redis-cli` or `valkey-cli` for some local restore/test paths | `redis-cli` or `valkey-cli` for DB-server-local RDB backup/restore |
| SQLite | Logical / Physical | No native backup tool required | No native backup tool required |
| CouchDB | Logical | No native backup tool required | No native backup tool required |
| Couchbase | Logical | `cbbackupmgr` | `cbbackupmgr` for DB-server-local backup/restore |
| Neo4j | Logical | `cypher-shell` for logical `.cypher` restore | No DB-server logical backup binary required; DBAegis exports locally and uploads over SSH |
| Neo4j | Physical | `neo4j-admin` | `neo4j-admin` for DB-server-local backup/restore |
| Microsoft SQL Server | Logical | `sqlpackage` | Not applicable |
| Microsoft SQL Server | Physical | Not the primary path | SQL Server native backup on DB-server-visible storage |
| Oracle | Logical | Not the primary path unless explicitly configured | `expdp`, `impdp` |
| Oracle | Physical | Not the primary path unless explicitly configured | `rman` |
| Cassandra | Logical | No external binary required for driver CSV backup/restore; `cqlsh` is installed best-effort in the DBAegis venv for raw `.cql` restore | No external binary required for driver CSV backup/restore; raw `.cql` restore still runs `cqlsh` on the DBAegis VM |
| Cassandra | Physical | `nodetool` | `nodetool` for DB-server-local backup/restore |
| ClickHouse | Logical | `clickhouse-client` | No DB-server logical backup binary required; DBAegis exports locally and uploads over SSH for DB-server-local backup |
| Snowflake | Logical | `snowsql`; the installer-managed path is `/usr/local/bin/snowsql` when `DBAEGIS_INSTALL_SNOWSQL=1` is used | Not applicable |
| Cosmos DB | Logical | No native backup tool required | Not applicable |
| DynamoDB | Logical | No native backup tool required | Not applicable |
| Firestore | Logical | No native backup tool required | Not applicable |
| Azure SQL | Logical | `sqlpackage` | Not applicable |

### Destination-aware tool path notes

The connection UI shows tool-path fields only when they apply to the selected execution location. A field that explicitly says `DBAegis VM` is a DBAegis-host path and is hidden when `DB server` destination is selected. A field that says `Remote`, `DB VM`, or `DB server` is expected to exist on the database host reached over SSH.

| Database | DBAegis VM / cloud destination | DB server destination with SSH | Notes |
|---|---|---|---|
| PostgreSQL | `pg_dump`, `psql`, and `pg_restore` run from the DBAegis VM unless a cloud/DB-VM staged mode is selected. | `pg_dump`/`psql`/`pg_restore` are checked on the DB server for DB-server-local logical workflows. | Use `logical_options.remote_tool_path` for a DB-server `pg_dump` override; use `logical_options.psql_path` / `logical_options.pg_restore_path` when restore tools are in nonstandard locations. |
| MySQL | `mysqldump` and `mysql` run from the DBAegis VM. | `mysqldump` and the SQL client run on the DB server for DB-server-local logical workflows. | Use `logical_options.remote_tool_path` for DB-server dump tool overrides and `logical_options.mysql_path` / `logical_options.mariadb_path` for SQL import/client overrides. |
| MariaDB | `mysqldump`/`mariadb-dump` and `mysql`/`mariadb` run from the DBAegis VM. | Dump and SQL client tools run on the DB server for DB-server-local logical workflows. | MariaDB can use `mariadb-dump`, `mariadb`, `mariadb-backup`, or `mariabackup` depending on mode. |
| MongoDB | `mongodump`, `mongorestore`, and optional `mongosh` run from the DBAegis VM. | MongoDB Database Tools run on the DB server for DB-server-local backup/restore. | Use the Remote Tool Path field when the DB server tools are not in `PATH`. |
| Redis / Valkey | Logical DBAegis/cloud backups use the DBAegis JSON export path; some restore/test paths may use `redis-cli` or `valkey-cli` on DBAegis. | DB-server destination uses `redis-cli`/`valkey-cli` over SSH for server-side RDB workflows. | DB-server logical mode is intentionally server-side/RDB-oriented for compatibility. |
| SQLite | DBAegis reads/writes the configured SQLite file path directly when accessible from the DBAegis VM. | SSH is used when the SQLite file is on the DB server filesystem. | No native database binary is required, but file paths must be reachable from the selected execution location. |
| CouchDB | DBAegis talks to CouchDB over HTTP, using `curl` where needed. | DB-server destination checks `curl` on the DB server when the workflow is executed over SSH. | No CouchDB-native filesystem backup binary is required. |
| Couchbase | `cbbackupmgr` runs from the DBAegis VM for DBAegis-hosted workflows. | `cbbackupmgr` runs on the DB server for DB-server-local/staged workflows. | Cloud/staged workflows may need a DB VM temp directory and SSH. |
| Neo4j | Logical restore of `.cypher` files uses `cypher-shell` on the DBAegis VM. Physical workflows use `neo4j-admin` where selected. | Logical DB-server workflows do not require a DB-server logical backup binary; physical workflows require `neo4j-admin` on the DB server. | `cypher_shell_path` is a logical restore-side path, not a physical backup path. |
| SQL Server | Logical BACPAC workflows use `sqlpackage` and optional `sqlcmd` from the DBAegis VM. | Physical workflows use SQL Server-native backup/restore access and `sqlcmd` where required. | SQL Server logical DB-server-local destination is not exposed; use DBAegis/cloud logical or SQL Server-native physical workflows. |
| Oracle | DBAegis-host execution is not the normal Oracle path unless explicitly configured. | Logical uses `expdp`/`impdp`/`sqlplus`; physical uses `rman`/`sqlplus` on the DB server. | Oracle workflows generally require SSH and an Oracle home/tooling on the DB server. |
| Cassandra | Driver-based logical backup and CSV restore do not need an external binary. Raw `.cql` restore uses `cqlsh` on the DBAegis VM. | DB-server logical backup/CSV restore does not need or show a `cqlsh` path. Physical mode uses `nodetool` on the DB server. | `cqlsh Path (Optional, DBAegis VM)` is hidden for `SSH + DB server` because it is not a DB-server tool. |
| ClickHouse | `clickhouse-client` is used for logical archive export/restore when DBAegis connects directly. | DB-server destination uses SSH staging and checks `clickhouse-client` according to the selected connection mode. | Physical filesystem backup is not implemented. |
| Snowflake | `snowsql` runs from the DBAegis VM when configured; the installer-managed command path is `/usr/local/bin/snowsql`. | Not applicable. | Snowflake does not expose DB-server-local backup storage. Password auth uses `SNOWSQL_PWD`; OAuth uses `logical_options.authenticator=oauth` with `logical_options.oauth_token`, which is encrypted with other connection-option secrets and written only to a short-lived `0600` SnowSQL config file while the command runs. |
| Cosmos DB | Uses cloud/API clients from the DBAegis VM. | Not applicable. | No database-host executable is required. |
| DynamoDB | Uses cloud/API clients from the DBAegis VM. | Not applicable. | No database-host executable is required. |
| Firestore | Uses cloud/API clients from the DBAegis VM. | Not applicable. | No database-host executable is required. |
| Azure SQL | `sqlpackage` runs from the DBAegis VM. | Not applicable. | Azure SQL logical export/import does not use DB-server filesystem access. |

### Database TLS and certificate options

Database TLS is optional by default. A connection does not require database certificates unless the target database or company policy requires TLS, CA validation, or client certificate authentication.

These settings are database-client TLS settings. They are separate from the DBAegis web UI/API HTTPS certificate configured by installer variables such as `DBAEGIS_TLS_CERT_PATH` and `DBAEGIS_TLS_KEY_PATH`.

The Add/Edit Connection modal exposes `Database TLS / Certificates` for PostgreSQL, MySQL/MariaDB, MongoDB, Redis/Valkey, Cassandra, Neo4j, CouchDB, Couchbase, ClickHouse, SQL Server, and Azure SQL. The values are stored under top-level `tls_options` on the connection:

```json
{
  "tls_options": {
    "enabled": true,
    "verify_cert": true,
    "verify_identity": false,
    "ca_cert_path": "/etc/dbaegis/certs/db-ca.pem",
    "client_cert_path": "/etc/dbaegis/certs/client.pem",
    "client_key_path": "/etc/dbaegis/certs/client-key.pem",
    "ssl_mode": "verify-full"
  }
}
```

Certificate path rules:

- DBAegis does not upload or distribute database certificate files. Operators must place CA/client certificate files on the correct host before running backup, restore, or precheck.
- Certificate paths must exist on the host where the database client tool runs.
- For DBAegis-local and direct-cloud workflows, database client tools run on the DBAegis VM, so `ca_cert_path`, `client_cert_path`, `client_key_path`, and `tls_config_file` must be paths on the DBAegis VM.
- For DB-server-local or DB-VM-staged workflows over SSH, database client tools run on the database server, so those paths must be paths on the DB server.
- The DBAegis service user needs read access to certificates used on the DBAegis VM. For SSH workflows, the configured remote run-as user needs read access to certificates on the DB server.
- Keep private keys readable only by the service/run-as user where possible, for example mode `0600`. CA certificate bundles can usually be `0644`.
- If `client_key_password` is configured, DBAegis stores it as an encrypted connection secret and redacts it in UI/API read responses.

Example DBAegis-VM certificate layout for direct backup/restore workflows:

```bash
sudo mkdir -p /opt/dbaegis/certs
sudo chown dbaegis:dbaegis /opt/dbaegis/certs
sudo chmod 750 /opt/dbaegis/certs
sudo install -o dbaegis -g dbaegis -m 0644 db-ca.pem /opt/dbaegis/certs/db-ca.pem
sudo install -o dbaegis -g dbaegis -m 0600 client-key.pem /opt/dbaegis/certs/client-key.pem
sudo install -o dbaegis -g dbaegis -m 0600 client.pem /opt/dbaegis/certs/client.pem
```

Use equivalent paths and ownership on the database server when the connection uses SSH/DB-server execution.

| Database | How `tls_options` is applied |
|---|---|
| PostgreSQL | Sets `PGSSLMODE`, `PGSSLROOTCERT`, `PGSSLCERT`, and `PGSSLKEY` for `psql`, `pg_dump`, `pg_restore`, and `pg_basebackup`. |
| MySQL / MariaDB | Adds SSL flags such as `--ssl`, `--ssl-mode`, `--ssl-ca`, `--ssl-cert`, and `--ssl-key` to `mysql`, `mysqldump`, and physical backup tools. |
| MongoDB | Adds `--tls`, `--tlsCAFile`, and client certificate options to `mongodump`, `mongorestore`, and `mongosh` paths. |
| Redis / Valkey | Adds `--tls`, `--cacert`, `--cert`, `--key`, or `--insecure` to `redis-cli` / `valkey-cli` paths. |
| Cassandra | Builds an SSL context for the Cassandra Python driver used by logical backup/restore and precheck paths. |
| Neo4j | Switches Bolt URIs to `bolt+s` when certificates are verified or `bolt+ssc` when self-signed/unverified certificates are allowed. |
| CouchDB | Uses `https://` and curl CA/client certificate flags. |
| Couchbase | Uses `https://` cluster URLs and passes supported `cbbackupmgr` certificate flags. |
| ClickHouse | Adds `--secure`; optional client config can be supplied through `tls_options.tls_config_file`. |
| SQL Server / Azure SQL | Uses existing SQL Server client trust/encryption flags through `tls_options.trust_server_certificate` and `tls_options.encrypt_connection`. |

For Oracle, use the Oracle client connect string, wallet/TNS configuration, and `ORACLE_HOME`/tool environment expected by the installed Oracle tools. DBAegis does not currently translate top-level `tls_options` into Oracle wallet settings.

Per-connection tool-path overrides are supported through `logical_options` and `physical_options`. This allows different database VMs to use different executable paths.

Common override fields:

- `logical_options.tool_path`
- `logical_options.remote_tool_path`
- `logical_options.db_vm_temp_dir`
- `physical_options.tool_path`
- `physical_options.remote_tool_path`
- `physical_options.db_vm_temp_dir`

Engine-specific overrides also exist where needed, including:

- `logical_options.mongodump_path`
- `logical_options.mongorestore_path`
- `logical_options.psql_path`
- `logical_options.pg_restore_path`
- `logical_options.mysql_path`
- `logical_options.mariadb_path`
- `logical_options.cypher_shell_path`
- `logical_options.cbbackupmgr_path`
- `logical_options.clickhouse_client_path`
- `logical_options.clickhouse_client_args`
- `logical_options.couchbase_cloud_mode`
- `logical_options.couchbase_temp_location`
- `logical_options.cqlsh_path`
- `logical_options.expdp_path`
- `logical_options.impdp_path`
- `logical_options.sqlplus_path`
- `logical_options.directory_object`
- `logical_options.create_directory_object`
- `physical_options.nodetool_path`
- `physical_options.rman_path`
- `physical_options.cleanup_db_vm_temp_after_backup`
- `logical_options.sqlpackage_path`
- `logical_options.sqlcmd_path`
- `logical_options.sqlpackage_trust_server_certificate`
- `logical_options.sqlcmd_trust_server_certificate`
- `physical_options.sqlcmd_path`
- `physical_options.sqlcmd_trust_server_certificate`
- `tls_options.enabled`
- `tls_options.verify_cert`
- `tls_options.verify_identity`
- `tls_options.ca_cert_path`
- `tls_options.client_cert_path`
- `tls_options.client_key_path`
- `tls_options.client_key_password`
- `tls_options.ssl_mode`
- `tls_options.server_name`
- `tls_options.tls_config_file`
- `tls_options.trust_server_certificate`
- `tls_options.encrypt_connection`

Legacy compatibility aliases accepted by the API:

- `logical_options.couchbase_db_temp_dir`
- `logical_options.oracle_db_temp_dir`
- `physical_options.oracle_db_temp_dir`
- `physical_options.remote_staging_path`
- `physical_options.remote_backup_output_path`

Examples:

PostgreSQL logical backup on two different DB servers:

```json
{
  "logical_options": {
    "remote_tool_path": "/usr/pgsql-16/bin/pg_dump"
  }
}
```

```json
{
  "logical_options": {
    "remote_tool_path": "/opt/postgresql/15/bin/pg_dump"
  }
}
```

MySQL physical backup with an explicit local or remote XtraBackup path:

```json
{
  "physical_options": {
    "tool_path": "/usr/bin/xtrabackup"
  }
}
```

```json
{
  "physical_options": {
    "remote_tool_path": "/opt/percona/bin/xtrabackup"
  }
}
```

Cassandra physical backup with a custom `nodetool` path:

```json
{
  "physical_options": {
    "nodetool_path": "/opt/cassandra/bin/nodetool"
  }
}
```

Cassandra raw `.cql` restore with a custom DBAegis VM `cqlsh` path:

```json
{
  "logical_options": {
    "cqlsh_path": "/opt/cassandra/bin/cqlsh"
  }
}
```

On a fresh install, DBAegis installs the standalone Python `cqlsh` package into the DBAegis virtualenv on a best-effort basis. When a Cassandra logical connection is saved with DBAegis local storage selected, DBAegis auto-fills `logical_options.cqlsh_path` with the detected local `cqlsh` path if the field is blank. The UI shows the `cqlsh` path field only for DBAegis-hosted destinations; DB-server destination backups keep that field hidden because it is not a DB-server tool path. Override it only when `cqlsh` is installed somewhere else. For strict Cassandra version matching, point `logical_options.cqlsh_path` at the `cqlsh` shipped with that Cassandra release.

Restore-side tool paths can be set at the connection level when the binary is not in the service `PATH`:

```json
{
  "logical_options": {
    "psql_path": "/usr/pgsql-16/bin/psql",
    "pg_restore_path": "/usr/pgsql-16/bin/pg_restore"
  }
}
```

```json
{
  "logical_options": {
    "mysql_path": "/usr/bin/mysql"
  }
}
```

If no override is set, DBAegis falls back to the default command name or the local `PATH`, depending on the backup and restore mode.

## Version Compatibility Guidance

DBAegis generally delegates backup and restore compatibility to the underlying database engine and its native tools. DBAegis itself does not currently enforce or validate a cross-version compatibility matrix.

In practice:

- Logical backups are usually the right choice for migrations or upgrades across database versions.
- Physical backups are usually the right choice for same-version disaster recovery, not version upgrades.

Use the following rule of thumb:

| Database | Logical Across Versions | Physical Across Versions | Guidance |
|---|---|---|---|
| PostgreSQL | Usually OK across nearby versions | Same version strongly recommended | Use logical for upgrades, physical for DR only. |
| MySQL | Usually OK across nearby versions | Same version or tightly compatible tooling only | Use logical for upgrades. |
| MariaDB | Usually OK across nearby versions | Same version or tightly compatible tooling only | Use logical for upgrades. |
| MongoDB | Usually OK, but major-version jumps still need care | Self-managed `dbPath` copies are version- and storage-engine-sensitive | Use logical for upgrades and physical for DR only. |
| Redis / Valkey | Logical JSON is generally portable | RDB/AOF compatibility depends on engine/version | Prefer logical for migrations. |
| SQLite | File copy depends on SQLite file/runtime compatibility | Same file-format family recommended | Treat file backup like physical. |
| CouchDB | JSON/doc export is generally portable | Not applicable | Logical is the safe path. |
| Couchbase | `cbbackupmgr` compatibility depends on Couchbase version | Archive compatibility is version-sensitive | Prefer same version or vendor-documented upgrade paths. |
| Neo4j | Cypher logical is the most portable | `neo4j-admin` physical is version-sensitive | Use logical for version changes. |
| Microsoft SQL Server | BACPAC is usually the migration path when `sqlpackage` supports both versions | `.bak` compatibility depends on SQL Server rules | Use logical for migrations; use same-version physical restore for DR. |
| Oracle | Data Pump logical is usually the migration path | RMAN physical is version-sensitive | Use logical for upgrades. |
| Cassandra | CSV logical is portable at table/schema level | Snapshot physical is version- and schema-sensitive | Use logical for migrations. |
| ClickHouse | `JSONEachRow` logical data is portable when target schema/engines are compatible | Not supported in DBAegis | Use logical DBAegis archive for migrations; review table engines, codecs, and cluster-specific DDL before restore. |
| Snowflake | Logical export/import is usually portable when schema matches | Not applicable | Logical is the intended path. |
| Cosmos DB | JSON logical is generally portable | Not applicable | Logical is portable. |
| DynamoDB | JSON logical is generally portable | Not applicable | Logical is portable. |
| Firestore | JSON logical is generally portable | Not applicable | Logical is portable. |
| Azure SQL | BACPAC/logical-style export is the migration path | Not applicable | Use logical-style export for version changes. |

DBAegis supports backup and restore across multiple database versions where the underlying engine, native tool, or logical export format supports it. DBAegis does not guarantee cross-version compatibility for physical backups.
