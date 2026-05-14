# DBAegis Product Editions

This document defines the intended DBAegis packaging and entitlement model for public and commercial releases. It uses three editions: Community, Professional, and Enterprise.

The current license foundation supports signed offline license tokens, edition claims, feature claims, default limits, database coverage, expiry, and host/instance binding. Professional and Enterprise force signed-license enforcement even if `DBAEGIS_LICENSE_REQUIRED` is omitted or set to `false`. Backend entitlement checks now enforce the high-value API paths for database type, backup/restore mode, backup/restore storage, schedules, users, storage destinations, reports, audit events, notifications, LDAP, MFA, RBAC, and self-backup. Install-time activation and edition upgrade/downgrade operations are documented in `INSTALL_UPGRADE_UNINSTALL.md`.

## Edition Summary

| Edition | Audience | License | Distribution | Primary Goal |
|---|---|---|---|---|
| Community | Individual DBAs, labs, small teams, evaluators | No license required | Restricted source-protected Community package | Local logical backup/restore for PostgreSQL, MySQL, and MongoDB without paid source code |
| Professional | Production DBA and platform teams | Signed license required | Signed self-hosted package | Supported production backups, cloud storage, audit collection, notifications, and team controls |
| Enterprise | Regulated, large, or mission-critical teams | Signed license required, optionally host-bound/offline | Signed private package, offline bundle, or customer-scoped package | Scale, compliance, certified support, and enterprise deployment terms |

## Packaging Runtime Note

Edition packages contain application source payload, UI assets, installer files,
dependency constraints, release metadata, and customer-facing documentation for
that edition. They do not contain the installed `python/` runtime directory or
`venv/`. For all editions, the installer downloads and SHA256-verifies the
pinned embedded Python runtime by default, then creates `/opt/dbaegis/venv` on
the target VM. Operators can instead set `DBAEGIS_PYTHON_BIN` or
`DBAEGIS_PYTHON_DOWNLOAD=skip` to use a preinstalled Python 3.12+ runtime.

Enterprise offline bundle support means a controlled offline delivery process
can provide required artifacts, mirrors, or custom URLs. It does not mean the
standard Community, Professional, or Enterprise tarballs include a prebuilt
Python runtime or virtualenv.

Professional packages include the paid runtime under `app/professional/`.
Enterprise packages include all Professional files plus Enterprise-only
implementation overlays under `app/enterprise/` for LDAP / Active Directory,
webhooks, and CSV report exports. The Enterprise webhook transport/security
helper `app/webhook_security.py` is excluded from Community and Professional
packages.

## Feature Matrix

| Capability | Community | Professional | Enterprise |
|---|---:|---:|---:|
| Web UI and API | Yes | Yes | Yes |
| Local users | 1 admin | Up to licensed limit | Licensed/unlimited |
| Connections | 3 | 50 default | Licensed/unlimited |
| Schedules | Limited | Yes | Yes |
| Retention policies | Basic | Yes | Yes |
| Manual backups | Yes, local logical only | Yes | Yes |
| Logical backups | PostgreSQL, MySQL, MongoDB | Yes | Yes |
| Local DBAegis storage | Yes | Yes | Yes |
| DB server local storage | No | Yes | Yes |
| AWS S3, Google Cloud Storage, Azure Blob | No | Yes | Yes |
| Restore from cloud storage | No | Yes | Yes |
| Physical backups | No | Yes | Yes |
| Physical restores | No | Yes | Yes |
| Physical PITR | No | PostgreSQL, Oracle, MySQL, MariaDB, SQL Server | PostgreSQL, Oracle, MySQL, MariaDB, SQL Server plus contracted certification |
| Email notifications | No | Yes | Yes |
| Webhooks | No | No | Yes |
| Daily summaries | No | Yes | Yes |
| LDAP / Active Directory auth | No | No | Yes, with assisted policy guidance |
| Backup/restore/schedule CSV reports | No | No | Yes |
| Audit event table | No | Yes | Yes |
| Audit CSV export | No | No | Yes |
| RBAC and roles | No | Yes | Yes |
| MFA | No | Yes | Yes |
| Self-backup | No | Yes | Yes |
| Release packages | Community package | Signed package | Signed private/offline package |
| Support | None | Limited | Full |
| Certified support matrix | Public best effort | Release-certified paths | Contract-certified paths |
| Air-gapped install support | No | Optional | Yes |
| Custom limits/features | No | Optional | Yes |

Community can keep shared UI navigation visible for MFA, but local-user MFA
enrollment and enforcement are locked until a Professional or Enterprise
license is active.

Audit support:

- Community keeps audit-related paid views locked.
- Professional records administrative/API audit events in the local SQLite
  `audit_events` table for operator review.
- Enterprise includes the same audit trail and adds audit CSV export for
  compliance evidence, offline review, and support packages.
- A Professional or Enterprise token with an explicit custom feature list must
  include `audit.events`; otherwise audit storage and the audit-events API are
  locked.
- Audit metadata is scrubbed before storage so secrets such as passwords,
  tokens, license keys, and credential fields are not written as plaintext
  audit values.

Air-gapped install support:

- Community packages are not positioned for air-gapped customer delivery.
- Professional can be delivered into restricted networks when contracted or
  prepared by the customer, but required OS packages, Python packages, database
  client tools, and cloud/vendor tools must be available through internal
  repositories or approved media.
- Enterprise can include a private/offline bundle with package checksums,
  dependency inventory, and customer-scoped validation evidence.
- Offline bundles must not include customer runtime data, TLS private keys,
  license issuer private keys, local license tokens, or backup artifacts.

## Database Coverage

The source-protected Community package ships a clean Community runtime under
`app/community/`. It supports DBAegis-local logical backup and restore for
PostgreSQL, MySQL, and MongoDB only. The full paid runtime remains under
`app/professional/` and starts with Professional and Enterprise packages.

| Database | Community | Professional | Enterprise |
|---|---:|---:|---:|
| PostgreSQL | Yes | Yes | Yes |
| MySQL | Yes | Yes | Yes |
| MariaDB | No | Yes | Yes |
| MongoDB | Yes | Yes | Yes |
| SQLite | No | Yes | Yes |
| Redis / Valkey | No | Yes | Yes |
| SQL Server | No | Yes | Yes |
| Azure SQL | No | Yes | Yes |
| Oracle | No | Yes | Yes |
| Snowflake | No | Yes | Yes |
| Cassandra | No | Yes | Yes |
| Neo4j | No | Yes | Yes |
| CouchDB | No | Yes | Yes |
| Couchbase | No | Yes | Yes |
| ClickHouse | No | Yes | Yes |
| DynamoDB | No | Yes | Yes |
| Firestore | No | Yes | Yes |
| Cosmos DB | No | Yes | Yes |

Professional includes supported production paths for the paid engines. Enterprise can certify a customer-scoped subset, add deployment runbooks, and include custom validation evidence.

Managed database services are covered through the matching logical protocol/API path when reachable and permitted by the provider. Examples: Amazon RDS/Aurora MySQL uses `mysql`, Amazon RDS/Aurora PostgreSQL uses `postgresql`, Amazon DocumentDB uses `mongodb`, Azure SQL Database uses `azuresql`, and managed SQL Server endpoints use `mssql`. Physical and DB-server-local modes are for self-managed hosts unless a provider exposes real host filesystem and SSH/tool access. The backup and restore support appendix includes the managed and serverless database coverage details.

Physical PITR is available in Professional and Enterprise for supported
self-managed database engines. PostgreSQL PITR requires a PostgreSQL physical
base backup and a complete copied WAL/archive log chain. Oracle PITR uses RMAN
physical backups and requires archived redo logs from the packaged RMAN backup
or a copied archive-log source supplied during restore. Oracle target
timestamps should be entered in the Oracle database/server time context.
MySQL and MariaDB PITR are supported for self-managed physical restores when
the base backup was created by XtraBackup/MariaBackup or an equivalent
snapshot-safe source and a complete copied binary-log chain is supplied during
restore.
SQL Server PITR is supported for self-managed physical restores when a full
`.bak` base backup, optional differential `.bak`, and ordered transaction-log
`.trn` chain are available and the source database used a log-chain-capable
recovery model before the log backups were created.
Community does not include PITR because Community is limited to local logical
backup and restore for PostgreSQL, MySQL, and MongoDB.

## Default Limits

| Limit | Community | Professional | Enterprise |
|---|---:|---:|---:|
| Active connections | 3 | 50 | Licensed/unlimited |
| Users | 1 admin | 5 | Licensed/unlimited |
| Schedules | 3 | 100 | Licensed/unlimited |
| Storage destinations | DBAegis local only | 10 | Licensed/unlimited |
| DBAegis instances per license | Not applicable | 1-3 | Contracted |

Count active protected objects, not deleted history rows. If a limit is exceeded, DBAegis should keep history, logs, health, license status, and restore visibility available, but block creating or re-enabling objects that would exceed the licensed limit.

## Changing Editions

Changing editions is an install/package operation plus a license operation:

- install the target edition package with `bin/install.sh --upgrade`
- use the target package `release.json` to set the installed edition
- use a matching paid token for Professional or Enterprise
- disable license enforcement for normal Community installs
- preserve the SQLite metadata DB, backup artifacts, config, users, roles, schedules, storage destinations, notification settings, self-backup metadata, restore history, and audit history
- keep relevant UI surfaces visible as locked or upgrade-required where supported, and block execution paths that are outside the current edition instead of deleting saved configuration

Supported upgrade paths are Community to Professional, Professional to Enterprise, and Community directly to Enterprise. Supported downgrade paths are Enterprise to Professional, Professional to Community, and Enterprise directly to Community. Detailed operator commands are in this handbook's edition upgrade and downgrade section.

## Feature Keys

Use stable feature keys in the signed license `features` claim. Backend route checks should use these keys rather than hard-coding edition names.

| Feature Key | Purpose |
|---|---|
| `backups.local` | DBAegis-local logical backup support |
| `storage.db_server_local` | DB-server-local backup and restore storage |
| `backups.cloud` | Cloud storage backup destinations |
| `backups.physical` | Physical backup modes |
| `restores.local` | DBAegis-local restore support |
| `restores.cloud` | Restore from cloud storage |
| `restores.physical` | Physical restore modes |
| `schedules` | Scheduled backup jobs |
| `retention` | Retention policy enforcement |
| `notifications.email` | SMTP/email notifications |
| `notifications.webhooks` | Webhook notifications |
| `auth.ldap` | LDAP / Active Directory authentication and group mapping |
| `reports.csv` | CSV report exports |
| `audit.events` | Database-backed audit event trail |
| `audit.export` | Audit report export |
| `rbac` | Roles and permission checks beyond single-admin mode |
| `mfa` | Local-user MFA enrollment and enforcement |
| `self_backup` | DBAegis control-plane self-backup |
| `enterprise.offline_bundle` | Air-gapped/offline package entitlement |
| `enterprise.lts` | Enterprise/LTS release channel entitlement |
| `enterprise.certified_matrix` | Contract-certified support matrix |
| `database.<db_type>` | Optional per-database override, for example `database.postgresql` |
| `databases.*` | Optional all-database override for custom Enterprise contracts |

## Edition Defaults

Community default features:

```json
[
  "backups.local",
  "restores.local",
  "schedules",
  "retention"
]
```

Professional default features:

```json
[
  "backups.local",
  "storage.db_server_local",
  "backups.cloud",
  "backups.physical",
  "restores.local",
  "restores.cloud",
  "restores.physical",
  "schedules",
  "retention",
  "notifications.email",
  "audit.events",
  "rbac",
  "mfa",
  "self_backup"
]
```

Enterprise includes all Professional features plus webhook notifications, all report exports, audit export, LDAP / Active Directory, offline bundles, LTS channel, certified matrix, custom limits, and SLA support.

## License Claim Example

Professional:

```json
{
  "license_id": "acme-prod-2026",
  "customer": "Acme Corp",
  "edition": "professional",
  "features": [
    "backups.cloud",
    "storage.db_server_local",
    "backups.physical",
    "restores.cloud",
    "audit.events",
    "notifications.email",
    "rbac",
    "mfa",
    "self_backup"
  ],
  "expires_at": "2027-05-06",
  "instance_ids": ["dbaegis-inst-6f5c2e1b9a8d4c6e"]
}
```

Optional license claims can add a structured `limits` object for `connections`, `users`, `schedules`, and `storage_destinations`, plus an optional `databases` list for customer-scoped coverage. When omitted, DBAegis uses the edition defaults above. `max_instances` remains a contract/registry value; actual instance binding is still done with `instance_ids` or `hosts`.

## Enforcement Guidance

- Enforce paid features in backend APIs first; UI gating is secondary.
- Use central helpers such as `_require_license_feature("audit.export")` and `_enforce_license_limit("connections", next_count)`.
- Do not put private signing keys in the product, repository, package, or customer server.
- Keep Community license-free and source-protected.
- Keep Professional and Enterprise offline-capable.
- Support upgrades by installing the target edition package and replacing the signed license token, without resetting the metadata database.
- Keep paid edition files out of the public Community package. Commercial-only
  implementation must live in paid/private overlay paths so the Community
  package guard can physically exclude it.
- Community backup/restore implementation must stay in `app/community/` and
  remain limited to the documented three-engine, local-logical feature set.
- The full FastAPI product runtime, paid-edition MFA, RBAC, notification
  delivery, control-plane self-backup, backup/restore service compatibility,
  and legacy access-control implementations now live in the
  `app/professional/` overlay and are not part of Community packages.
- Enterprise LDAP / Active Directory, webhook delivery, and CSV report export
  implementations now live in the `app/enterprise/` overlay, with
  `app/webhook_security.py` as an Enterprise-only webhook helper. They are not
  part of Community or Professional packages.
- Preserve disabled or out-of-edition configuration and history on downgrade; block access instead of deleting data.
- Audit license events such as invalid license, expired license, feature denied, and license applied.
- Preserve operational safety during license issues: health, version, license status, logs/history visibility, and emergency restore policy should be explicit.
