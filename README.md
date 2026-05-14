# DBAegis Community

DBAegis Community is a self-hosted database backup and restore control plane for small teams, labs, and evaluators.

Community focuses on local logical backup and restore for:

- PostgreSQL
- MySQL
- MongoDB

It includes the DBAegis web UI, FastAPI backend, installer, local metadata store, backup history, restore jobs, schedules, and DBAegis-local storage.

## Community Limits

Community is intentionally smaller than the paid editions:

| Area | Community |
|---|---:|
| License | No license required |
| Local users | 1 admin |
| Active connections | 3 |
| Schedules | 3 |
| Storage | DBAegis-local only |
| Backup type | Logical only |
| Restore source | DBAegis-local backups |
| Email, webhooks, LDAP, MFA, RBAC, reports | Not included |

For the full edition comparison, see [docs/PRODUCT_EDITIONS.md](docs/PRODUCT_EDITIONS.md).

## Download

Latest release:

https://github.com/ILOGICSOFT/dbaegis-community/releases/tag/v1.0.0

Release assets:

- `community-v1.0.0.tar.gz`
- `community-v1.0.0.manifest.json`
- `SHA256SUMS`

## Quick Install

Run these commands on the VM that will host DBAegis:

```bash
curl -L -O https://github.com/ILOGICSOFT/dbaegis-community/releases/download/v1.0.0/community-v1.0.0.tar.gz
curl -L -O https://github.com/ILOGICSOFT/dbaegis-community/releases/download/v1.0.0/community-v1.0.0.manifest.json
curl -L -O https://github.com/ILOGICSOFT/dbaegis-community/releases/download/v1.0.0/SHA256SUMS

sha256sum -c SHA256SUMS

tar -xzf community-v1.0.0.tar.gz
cd community-v1.0.0

sudo DBAEGIS_EDITION=community \
  DBAEGIS_LICENSE_REQUIRED=false \
  DBAEGIS_USER=dbaegis \
  bash bin/install.sh --fresh
```

The installer creates the runtime under `/opt/dbaegis`, installs service files, creates the metadata database, and seeds the first local admin user.

## First Login

The default bootstrap username is `admin`.

Fresh installs generate a unique bootstrap password unless you set `BOOTSTRAP_ADMIN_PASSWORD` before install. On the DBAegis VM, view the generated credentials with:

```bash
sudo grep -E '^BOOTSTRAP_ADMIN_USER=|^BOOTSTRAP_ADMIN_PASSWORD=' /opt/dbaegis/conf/dbaegis.conf
```

After logging in, change the admin password from the UI.

If the only local admin password is lost:

```bash
sudo -u dbaegis /opt/dbaegis/bin/dbaegis reset-admin-password
```

## Basic Workflow

1. Log in to the DBAegis web UI.
2. Add a PostgreSQL, MySQL, or MongoDB connection.
3. Run a manual logical backup to DBAegis-local storage.
4. Verify the backup appears in backup history.
5. Start a restore job from a selected local backup.
6. Add a schedule if you want recurring backups.

Detailed engine and restore notes are in [docs/BACKUP_RESTORE_SUPPORT.md](docs/BACKUP_RESTORE_SUPPORT.md).

## Runtime Paths

The installer uses these main paths:

| Path | Purpose |
|---|---|
| `/opt/dbaegis` | Installed application |
| `/opt/dbaegis/conf/dbaegis.conf` | Local configuration and bootstrap credentials |
| `/opt/dbaegis/data` | SQLite metadata database |
| `/opt/dbaegis/backups` | DBAegis-local backup artifacts |
| `/opt/dbaegis/logs` | Service logs |

Do not store test databases or unrelated files inside `/opt/dbaegis`. Use a separate path such as `/opt/testdatabases`.

## Documentation

| Topic | Document |
|---|---|
| Install, upgrade, rollback, uninstall | [docs/INSTALL_UPGRADE_UNINSTALL.md](docs/INSTALL_UPGRADE_UNINSTALL.md) |
| Edition comparison and limits | [docs/PRODUCT_EDITIONS.md](docs/PRODUCT_EDITIONS.md) |
| Backup and restore support | [docs/BACKUP_RESTORE_SUPPORT.md](docs/BACKUP_RESTORE_SUPPORT.md) |
| Control-plane disaster recovery | [docs/CONTROL_PLANE_DISASTER_RECOVERY.md](docs/CONTROL_PLANE_DISASTER_RECOVERY.md) |
| Customer handbook | [docs/DBAEGIS_HANDBOOK.pdf](docs/DBAEGIS_HANDBOOK.pdf) |

## Package Contents

The community release package includes:

- Community runtime under `app/community/`
- Community-safe compatibility services under `app/services/`
- Web UI under `ui/`
- Installer and utility scripts under `bin/`
- Configuration template under `conf/`
- Required customer documentation under `docs/`
- Dependency constraints under `requirements/`
- Release metadata in `release.json` and `PACKAGE_CONTENTS.json`

It does not include paid runtime overlays, Enterprise webhook transport code, license issuer private keys, runtime databases, logs, backups, TLS keys, virtual environments, or customer secrets.

## Upgrade

Download the new release package, unpack it, and run:

```bash
sudo DBAEGIS_EDITION=community \
  DBAEGIS_LICENSE_REQUIRED=false \
  DBAEGIS_USER=dbaegis \
  bash bin/install.sh --upgrade
```

The installer preserves the existing configuration, SQLite metadata, and backup artifacts. Review [docs/INSTALL_UPGRADE_UNINSTALL.md](docs/INSTALL_UPGRADE_UNINSTALL.md) before production upgrades.

## License

DBAegis Community is distributed under the license in [LICENSE](LICENSE).

Professional and Enterprise editions are distributed separately through `ILOGICSOFT/DBAEGIS`.
