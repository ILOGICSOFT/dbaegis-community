# DBAegis Install, Upgrade, and Uninstall Guide

This guide describes the current DBAegis install and lifecycle flow as implemented by:

- [bin/install.sh](../bin/install.sh)
- [bin/uninstall.sh](../bin/uninstall.sh)

## Install Modes

DBAegis supports these lifecycle modes:

- `--fresh`
  Creates a new installation layout and writes a new `dbaegis.conf`.
- `--upgrade`
  Updates application/runtime files in place and preserves the existing `dbaegis.conf`.
- `--rollback`
  Restores the latest pre-upgrade runtime snapshot and preserves the active `dbaegis.conf` and SQLite metadata database.

If you run the installer with `--upgrade` and a config already exists, the installer:

- keeps the current `/opt/dbaegis/conf/dbaegis.conf`
- writes a new template to `conf/dbaegis.conf.new`
- preserves the active SQLite database
- preserves the configured backup directory
- creates a pre-upgrade runtime snapshot under `/opt/dbaegis/rollback`
- reconciles `DBAEGIS_EDITION` and `DBAEGIS_LICENSE_REQUIRED` from the official package manifest or explicit installer environment so paid-edition upgrades cannot keep Community license enforcement by accident and Community downgrades return to license-free operation

## Fresh Install

Run a fresh install as root:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --fresh
```

Prechecks before running the installer:

- confirm the install base is acceptable:
  - default: `/opt/dbaegis`
- confirm the SQLite metadata path is acceptable:
  - default: `/opt/dbaegis/data/dbaegis.db`
- confirm the backup artifact directory is acceptable:
  - default: `/backups`
- confirm the DBAegis temporary work directory is acceptable:
  - default: `/opt/dbaegis/tmp`
- confirm the embedded Python runtime directory is acceptable:
  - default: `/opt/dbaegis/python`
- if using a custom Python runtime with `DBAEGIS_PYTHON_BIN` or `DBAEGIS_PYTHON_DOWNLOAD=skip`, confirm it is Python 3.12 or newer
- review the core Python dependency list printed by the installer; these packages are installed into `/opt/dbaegis/venv` and import-checked before the service is started
- confirm the release payload includes `requirements/install-constraints.txt`; the installer uses exact direct package pins plus this constraints file for reproducible Python dependency resolution and copies it into the installed tree for future upgrades
- review optional Python dependency warnings after install; optional database drivers and cloud clients are installed best-effort and import-checked with warnings when a provider-specific feature may need more packages
- confirm the selected API and UI ports are free:
  - defaults: `8000` and `3000`
- avoid placing persistent metadata or backup paths under `/tmp`
- if you need DB-server-local password-auth backups or restores, make sure the host can install `sshpass`

If the default paths do not match the host, override them at install time:

```bash
sudo DBAEGIS_USER=dbaegis \
  DBAEGIS_BASE=/opt/dbaegis \
  DBAEGIS_DB_PATH=/data/dbaegis/dbaegis.db \
  DBAEGIS_BACKUP_DIR=/srv/backups \
  DBAEGIS_TEMP_DIR=/srv/dbaegis-tmp \
  DBAEGIS_PYTHON_DIR=/opt/dbaegis/python \
  bash bin/install.sh --fresh
```

## Install and Upgrade Parameters

Pass installer parameters as environment variables before the install command:

```bash
sudo DBAEGIS_USER=dbaegis DBAEGIS_DB_PATH=/data/dbaegis/dbaegis.db bash bin/install.sh --fresh
```

Fresh install behavior:

- environment overrides seed the generated `conf/dbaegis.conf`
- path, network, TLS, auth, and logging settings are written to the new config
- generated secrets are stored in `conf/dbaegis.conf`

Upgrade behavior:

- `--upgrade` preserves the existing `conf/dbaegis.conf`
- most path, network, TLS, auth, and logging environment overrides do not replace existing config values during upgrade
- use the same `DBAEGIS_BASE`, `DBAEGIS_CONF`, and `DBAEGIS_USER` values needed to locate and manage a non-default install
- to change a persisted setting after install, edit `conf/dbaegis.conf` and restart `dbaegis`
- release metadata parameters can still be used during upgrade for custom CI/package pipelines, but official packages use the packaged `release.json`

Installer modes:

| Mode | Behavior |
| --- | --- |
| `--fresh` | Create a new install layout and write a new `dbaegis.conf`. Use on a new VM or clean install path. |
| `--upgrade` | Update application/runtime files, preserve `dbaegis.conf`, SQLite metadata, and backup artifacts. |
| `--rollback` | Restore application/UI/bin/venv runtime files and the systemd unit from a pre-upgrade snapshot. |
| `--auto` or no mode | Use upgrade when an existing install is detected, otherwise use fresh install. |

Core install parameters:

| Parameter | Default | Use |
| --- | --- | --- |
| `DBAEGIS_USER` | invoking sudo user | Linux service account that owns and runs DBAegis. Create this OS user before install if it does not already exist. |
| `DBAEGIS_BASE` | `/opt/dbaegis` | Base install directory. Pass the same value on upgrades for non-default installs. |
| `DBAEGIS_CONF` | `$DBAEGIS_BASE/conf/dbaegis.conf` | Advanced custom config file path. The service user must be able to read it. |
| `DBAEGIS_DB_PATH` | `$DBAEGIS_BASE/data/dbaegis.db` | SQLite metadata database path for fresh installs. On upgrades, edit `dbaegis.conf` to move the DB. |
| `DBAEGIS_SQLITE_BUSY_TIMEOUT_MS` | `30000` | Optional SQLite metadata DB lock wait timeout in milliseconds. Runtime clamps values to `1000` through `300000`. |
| `DBAEGIS_MONGODB_INSTALL_ROOT` | `/opt/dbaegis-tools/mongodb` | Optional MongoDB Database Tools and mongosh install root. Keep this outside `$DBAEGIS_BASE` when separating product files from tool payloads. |
| `DBAEGIS_BACKUP_DIR` | `/backups` | Backup artifact directory for fresh installs. On upgrades, edit `BACKUP_DIR` in `dbaegis.conf`. |
| `DBAEGIS_TEMP_DIR` | `$DBAEGIS_BASE/tmp` | DBAegis VM temporary work directory for backup/restore staging. |
| `DBAEGIS_LOG_BACKUP_COUNT` | `9` | Number of rotated `dbaegis.log`, `nginx-access.log`, and `nginx-error.log` files to keep. |
| `DBAEGIS_SERVICE_PRIVATE_TMP` | `no` | systemd `PrivateTmp` isolation. Default is `no` so paths under `/tmp` remain visible to local backup/restore workflows. |
| `DBAEGIS_OS_PACKAGE_MODE` | `install` | Process all named prerequisite OS packages through `dnf`, `yum`, or `apt` by default so they can be installed or upgraded when needed for compatibility. Set to `missing-only` only when you intentionally want to skip packages that are already installed. |
| `DBAEGIS_ROLLBACK_DIR` | `$DBAEGIS_BASE/rollback` | Root directory for pre-upgrade runtime snapshots. The installer keeps this directory owned by the DBAegis service user so upgrades, rollback metadata, and ownership audits stay consistent. |
| `DBAEGIS_ROLLBACK_SNAPSHOT` | latest snapshot | Optional snapshot name or absolute path to use with `--rollback`. |

Network and TLS parameters:

| Parameter | Default | Use |
| --- | --- | --- |
| `DBAEGIS_API_PORT` | `8000` | FastAPI backend port written to `API_PORT`. |
| `DBAEGIS_UI_PORT` | `3000` | HTTP UI port written to `UI_PORT`. |
| `DBAEGIS_HTTPS_PORT` | `3443` | HTTPS UI/API port when TLS is enabled. |
| `DBAEGIS_TLS_MODE` | `off` | TLS mode: `off`, `self_signed`, or `customer_provided`. |
| `DBAEGIS_HTTP_BEHAVIOR` | `both` | HTTP behavior when TLS is enabled: `both`, `redirect`, or `https_only`. |
| `DBAEGIS_TLS_SERVER_NAME` | `localhost` | Server name used in the nginx TLS server config. |
| `DBAEGIS_TLS_CERT_PATH` | `$DBAEGIS_BASE/tls/server.crt` | TLS certificate path when TLS is enabled. |
| `DBAEGIS_TLS_KEY_PATH` | `$DBAEGIS_BASE/tls/server.key` | TLS private key path when TLS is enabled. |
| `DBAEGIS_TLS_CHAIN_PATH` | `$DBAEGIS_BASE/tls/chain.crt` | TLS trusted chain path when TLS is enabled. |

Port `3443` is the default DBAegis HTTPS port. Keep it when it fits the organization network policy, or set `DBAEGIS_HTTPS_PORT` to a site-approved port during install.

These installer TLS parameters configure the DBAegis web UI/API HTTPS endpoint through nginx. They do not configure database-client TLS for PostgreSQL, MySQL, MongoDB, Redis, SQL Server, or other database connections. Database TLS and client certificate paths are saved per connection under `tls_options`; certificate files must already exist on the DBAegis VM or DB server where the backup/restore client tool runs. The backup and restore support guide describes database TLS and certificate options.

For production, use `DBAEGIS_TLS_MODE=customer_provided` with trusted certificates and set `DBAEGIS_HTTP_BEHAVIOR=redirect` or `DBAEGIS_HTTP_BEHAVIOR=https_only`.

Python runtime parameters:

| Parameter | Default | Use |
| --- | --- | --- |
| `DBAEGIS_PYTHON_DIR` | `$DBAEGIS_BASE/python` | Embedded Python runtime directory. |
| `DBAEGIS_PYTHON_BIN` | `$DBAEGIS_PYTHON_DIR/bin/python3` | Python executable used to create and run the virtualenv. Custom runtimes must be Python 3.12 or newer. |
| `DBAEGIS_PYTHON_URL` | architecture-specific release URL | Override the embedded Python tarball URL. |
| `DBAEGIS_PYTHON_SHA256` | pinned for installer defaults | SHA256 checksum required for custom embedded Python URLs or version/release/triplet overrides. |
| `DBAEGIS_PYTHON_DOWNLOAD` | `auto` | Set to `skip`, `false`, or `no` to use system `python3` instead of downloading the embedded runtime. System Python must be 3.12 or newer. |
| `DBAEGIS_PYTHON_RELEASE` | installer default | Advanced package-build override for the embedded Python release date. |
| `DBAEGIS_PYTHON_VERSION` | installer default | Advanced package-build override for the embedded Python version. |
| `DBAEGIS_PYTHON_TRIPLET` | host architecture default | Advanced override for the embedded Python platform triplet. |
| `PYTHON_CONSTRAINTS_FILE` | `<release-or-install-root>/requirements/install-constraints.txt` | Advanced override for the pip constraints file. Production release packages should include the default constraints file and use it for fresh installs and installed-tree upgrades. |

Release packages do not include the installed `python/` runtime directory or
`venv/`. Those are runtime artifacts created on the target host for Community,
Professional, and Enterprise. For disconnected installs, preinstall a supported
Python runtime and set `DBAEGIS_PYTHON_BIN` or provide an approved internal
`DBAEGIS_PYTHON_URL` with its matching SHA256.

Authentication and secret parameters:

| Parameter | Default | Use |
| --- | --- | --- |
| `BOOTSTRAP_ADMIN_PASSWORD` | generated unique password | Initial local admin password for fresh installs. It is used only when the metadata `users` table is empty. |
| `DBAEGIS_SECRET_KEY` | generated unique key | Encryption secret for saved connection, storage, notification, LDAP, Microsoft Authenticator MFA, webhook, and restore-option secrets. Preserve it across restores and upgrades. Use `dbaegis rotate-secret-key`, not direct env replacement, to rotate it after install. |
| `AUTH_ENABLED` | `true` | API/UI authentication guard. Keep enabled in production. |
| `SESSION_COOKIE_NAME` | `dbaegis_session` | Browser session cookie name. |
| `SESSION_TTL_HOURS` | `12` | Session lifetime in hours. Runtime clamps values to `1` through `168`. |
| `SESSION_COOKIE_SECURE` | `auto` | `auto` sets Secure cookies for HTTPS requests or trusted `X-Forwarded-Proto: https`. Set `true` when the public endpoint is HTTPS-only but the backend cannot reliably detect HTTPS. |

License parameters:

| Parameter | Default | Use |
| --- | --- | --- |
| `DBAEGIS_EDITION` | packaged `release.json` edition, otherwise `community` | Package entitlement default. Use `community` for public installs. `professional` and `enterprise` always require a signed token. |
| `DBAEGIS_LICENSE_REQUIRED` | `false` | Set to `true` to require a valid signed license before normal API use. Professional and Enterprise force this behavior even if this value is omitted or `false`; official Community installs and downgrades set it back to `false` unless an explicit installer environment override is supplied. |
| `DBAEGIS_LICENSE_DIR` | `$DBAEGIS_BASE/license` | Directory for license token, public key, and related license metadata. |
| `DBAEGIS_LICENSE_KEY_FILE` | `$DBAEGIS_BASE/license/dbaegis.license` | Path to the issued license token. |
| `DBAEGIS_LICENSE_PUBLIC_KEY_FILE` | `$DBAEGIS_BASE/license/license_public.pem` | Path to the public verification key. |
| `DBAEGIS_LICENSE_INSTANCE_ID` | unset | Optional stable identifier for host-bound licenses. When supplied during install or upgrade, the installer writes it to `dbaegis.conf`; when omitted, an existing configured value is preserved. |

Use this guide's edition upgrade/downgrade section for customer activation, renewal, migration, and replacement handling. Signed-license token issuing and custody procedures are internal release-operations material and are not part of customer packages.

Release metadata parameters:

Official release packages include `release.json`, so normal production installs do not need release metadata parameters.

| Parameter | Default | Use |
| --- | --- | --- |
| `DBAEGIS_BUILD_CHANNEL` | packaged `release.json`, otherwise `development` | Custom CI/package channel such as `stable`, `rc`, or `nightly` when no packaged manifest exists. |
| `DBAEGIS_RELEASE_NAME` | `DBAegis <version>` when a non-development channel exists | Optional display name for custom release metadata. |
| `DBAEGIS_BUILD_TIME` | unset | Optional build timestamp. `auto` or `now` writes the current UTC timestamp. |
| `DBAEGIS_GIT_COMMIT` | git checkout or manifest value | Optional build identifier. `GIT_COMMIT` is also accepted as a fallback. |

Examples:

```bash
# Fresh install with non-default data and backup paths.
sudo DBAEGIS_USER=dbaegis \
  DBAEGIS_DB_PATH=/data/dbaegis/dbaegis.db \
  DBAEGIS_BACKUP_DIR=/srv/backups \
  DBAEGIS_TEMP_DIR=/srv/dbaegis-tmp \
  bash bin/install.sh --fresh

# Fresh install with customer-provided TLS paths.
sudo DBAEGIS_USER=dbaegis \
  DBAEGIS_TLS_MODE=customer_provided \
  DBAEGIS_TLS_CERT_PATH=/etc/pki/dbaegis/server.crt \
  DBAEGIS_TLS_KEY_PATH=/etc/pki/dbaegis/server.key \
  DBAEGIS_TLS_CHAIN_PATH=/etc/pki/dbaegis/chain.crt \
  bash bin/install.sh --fresh

# Upgrade an existing default install. Existing dbaegis.conf is preserved.
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

Step-by-step fresh install from a new release package:

1. Move to a working directory.

```bash
cd /tmp
```

2. Extract the release package.

```bash
tar xzf EDITION-vVERSION.tar.gz
```

3. Enter the extracted release directory.

```bash
cd EDITION-vVERSION
```

4. Run the installer.

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --fresh
```

On a new VM, the default `DBAEGIS_OS_PACKAGE_MODE=install` processes every named prerequisite package through the OS package manager. This lets `dnf`, `yum`, or `apt` install missing packages and upgrade already-installed prerequisite packages when the configured OS repositories provide a newer compatible version. Use `DBAEGIS_OS_PACKAGE_MODE=missing-only` only when the VM has already been validated and you intentionally want to skip installed packages.

If you need non-default paths, use the same step with overrides:

```bash
sudo DBAEGIS_USER=dbaegis \
  DBAEGIS_DB_PATH=/data/dbaegis/dbaegis.db \
  DBAEGIS_BACKUP_DIR=/srv/backups \
  DBAEGIS_TEMP_DIR=/srv/dbaegis-tmp \
  bash bin/install.sh --fresh
```

5. Verify the service is running.

```bash
systemctl status dbaegis --no-pager
journalctl -u dbaegis -n 50 --no-pager
```

6. Verify the local endpoints.

```bash
curl -I http://127.0.0.1:3000/
curl -I http://127.0.0.1:8000/api/version
```

The version endpoint returns product, API, database schema, build channel, build time, Git commit, Python, and platform metadata. The CLI uses the same source:

```bash
dbaegis version
curl http://127.0.0.1:8000/api/version
```

7. If TLS is enabled, verify HTTPS too.

```bash
curl -k -I https://127.0.0.1:3443/
```

What the installer does:

1. Installs and processes base OS packages such as nginx, sqlite, curl/wget, SSH/sshpass, tar/gzip/bzip2/xz/unzip/zip, `tzdata`, PostgreSQL client tools, MySQL/MariaDB client tools where available, Redis/Valkey client tools where available, and build/TLS libraries needed by Python wheels. By default, the OS package manager processes every named prerequisite so installed packages can be upgraded when needed for compatibility; set `DBAEGIS_OS_PACKAGE_MODE=missing-only` only when you intentionally want to skip already-installed packages. Optional vendor client tools are installed only when their explicit `DBAEGIS_INSTALL_*` flags are set.
2. Creates the DBAegis directory structure under `/opt/dbaegis` by default.
3. Writes `/opt/dbaegis/conf/dbaegis.conf` as the DBAegis service user and group with mode `0640`.
4. Downloads and extracts an embedded Python runtime under `/opt/dbaegis/python` by default, or validates that a custom/system Python runtime is Python 3.12 or newer.
5. Creates a Python virtual environment under `/opt/dbaegis/venv` from the embedded runtime.
6. Installs Python dependencies. Core dependencies fail the install if missing; optional database drivers and cloud clients are installed best-effort and import-checked with warnings.
7. Copies application, UI, service, and maintenance command files into place.
8. Writes the `dbaegis.service` systemd unit.
9. Enables and starts `dbaegis.service`.

Versioning notes:

- `app/version.py` is the source of truth for product, API, and current metadata schema versions.
- `/api/version`, OpenAPI metadata, startup logs, the sidebar status, and `dbaegis version` all read from that module.
- Release builds may add `/opt/dbaegis/release.json` or set `DBAEGIS_RELEASE_MANIFEST` with optional `git_commit`, `build_time`, `build_channel`, `release_name`, and `edition` fields.
- `DBAEGIS_GIT_COMMIT`, `DBAEGIS_BUILD_TIME`, and `DBAEGIS_BUILD_CHANNEL` can stamp CI/CD build metadata without changing runtime code, but the preferred production path is a packaged `release.json`.

Production release metadata:

- Official production release archives include `release.json` at the package root. Do not pass `DBAEGIS_BUILD_CHANNEL=stable` for normal production installs from an official release package.

```json
{
  "build_channel": "stable",
  "edition": "professional"
}
```

- Install or upgrade normally; no build-channel parameter is required:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --fresh
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

- The installer copies the packaged manifest to `/opt/dbaegis/release.json`, owned by the DBAegis service user, so `/api/version` reports `build_channel: stable` and the packaged `edition` after the service restart.
- During fresh install and upgrade, the packaged `edition` seeds `DBAEGIS_EDITION`; Professional and Enterprise packages force `DBAEGIS_LICENSE_REQUIRED=true`, and Community packages set `DBAEGIS_LICENSE_REQUIRED=false`, while leaving runtime paths, secrets, database settings, and backup settings unchanged.
- The installer always copies `app/community/`. Community installs then remove installed `app/professional`, `app/enterprise`, `app/webhook_security.py`, `ui/professional`, and `ui/enterprise` remnants; Professional installs add `app/professional/` and remove Enterprise remnants including `app/enterprise` and `app/webhook_security.py`.
- `product`, `version`, and `release_name` are optional in the package manifest. `/api/version` derives missing release-name details from `app/version.py`, for example `DBAegis 1.0.0`.
- Verify the installed metadata with:

```bash
curl http://127.0.0.1:8000/api/version
```

If TLS is enabled, verify HTTPS too:

```bash
curl -k https://127.0.0.1:3443/api/version
```

- Custom CI/package pipelines can still set build metadata explicitly with `DBAEGIS_BUILD_TIME=auto`, `DBAEGIS_GIT_COMMIT=<sha>`, or `DBAEGIS_BUILD_CHANNEL=<channel>` when no package manifest exists.
- If no release manifest and no build-channel environment variable exist, `/api/version` reports `build_channel: development`. Removing `/opt/dbaegis/release.json` returns the install to that default unless the channel is set in the service environment.

System health status after install:

The UI sidebar `System Status` uses authenticated `/api/health` for admin diagnostics. Public `/health` is a minimal liveness endpoint for load balancers and does not include local paths or detailed checks.

```bash
curl http://127.0.0.1:8000/health
```

If TLS is enabled, verify HTTPS too:

```bash
curl -k https://127.0.0.1:3443/health
```

The public liveness response only reports that the API process is answering. Admin diagnostic status values:

- `Healthy`: all health checks passed.
- `Warning`: the API is reachable and critical checks passed, but a non-critical local backup path check failed.
- `Unhealthy`: a critical check failed, such as metadata DB access, config readability, log directory writes, or temp directory writes.
- `Unknown`: the UI could not reach the health endpoint or the health request timed out.

The `/api/health` response includes per-check details for:

- metadata DB path and SQLite `quick_check`
- `dbaegis.conf` readability and `DBAEGIS_SECRET_KEY` presence
- log directory write access
- DBAegis temp directory write access
- backup directory write access
- system-backup directory write access

Authentication notes after install:

- local authentication is enabled by default
- a bootstrap local admin is created from:
  - `BOOTSTRAP_ADMIN_USER`
  - `BOOTSTRAP_ADMIN_PASSWORD`
- fresh installs generate a unique bootstrap admin password unless `BOOTSTRAP_ADMIN_PASSWORD` is supplied in the environment
- the initial username and password are written to `/opt/dbaegis/conf/dbaegis.conf`; view them on the DBAegis VM with:
  ```bash
  sudo grep -E '^BOOTSTRAP_ADMIN_USER=|^BOOTSTRAP_ADMIN_PASSWORD=' /opt/dbaegis/conf/dbaegis.conf
  ```
- `BOOTSTRAP_ADMIN_PASSWORD` is used only when the DBAegis metadata `users` table is empty
- after the admin exists, changing the password in the UI updates the SQLite password hash; restarting DBAegis does not reset that password from `BOOTSTRAP_ADMIN_PASSWORD`
- `BOOTSTRAP_ADMIN_PASSWORD` may remain in `conf/dbaegis.conf`; commenting it out after the first admin exists does not affect normal restarts
- if the metadata database is empty or replaced, DBAegis needs a non-default `BOOTSTRAP_ADMIN_PASSWORD` to seed the first admin again; rerunning the installer may generate or set one if the value is missing or default
- if the only local admin password is lost, reset that account from the DBAegis VM shell:
  ```bash
  sudo -u dbaegis /opt/dbaegis/bin/dbaegis reset-admin-password
  ```
- `reset-admin-password` updates only the targeted local admin row, clears only that user's sessions, and refuses LDAP-managed or non-admin users; pass `--username USER` when multiple local admins exist
- LDAP / Active Directory authentication and LDAP group mapping are Enterprise-only features. Community and Professional installs show LDAP as unavailable and block LDAP settings until an Enterprise license is installed.
- LDAP is configured from the DBAegis admin UI/API under `Access Control`, not loaded live from `dbaegis.conf`, when the Enterprise `auth.ldap` entitlement is present.
- installer output also reminds operators whether LDAP is available for the selected edition.
- admins can edit local user username, role, and active status from `Access Control` > `Users`
- Professional and Enterprise admins can enable or disable local-user MFA from `Access Control` > `MFA`; Community shows MFA as edition locked
- Professional and Enterprise admins can create custom roles from `Access Control` > `Roles`, select backup/restore permissions, and assign database connections or connection tags to those roles
- Enterprise admins can map LDAP groups to built-in or custom roles from `Access Control` > `LDAP`; the same mappings remain visible on each editable role record
- built-in connection-scoped operator roles are `backup_operator`, `restore_operator`, and `db_operator`
- LDAP user roles are read-only in DBAegis because they come from LDAP group mapping
- DBAegis prevents removing the last active admin by role change, disable, or delete

MFA notes after install:

- MFA requires Professional or Enterprise and is a local-user TOTP feature compatible with Microsoft Authenticator and other standard authenticator apps.
- MFA is configured from `Access Control` > `MFA`; there is no installer environment variable that forces it on during setup.
- Enrollment is managed per local user from `Access Control` > `Users`; LDAP users are not enrolled or reset by DBAegis MFA.
- User enrollment/setup is available only while global MFA is enabled. If global MFA is disabled, existing enrollments are preserved but bypassed, and the UI disables new setup/reset actions until MFA is enabled again.
- Setting up or disabling MFA signs out the user's other active sessions. When a user sets up or disables MFA for their own account, the current browser session stays active so the setup QR/code page can finish cleanly.
- The setup QR code is generated by DBAegis as a local SVG data URI from the `otpauth://` payload. No external QR-code service is contacted.
- MFA enrollment secrets are encrypted in the metadata DB with `DBAEGIS_SECRET_KEY`.
- Disabling global MFA bypasses existing local-user enrollments without deleting those enrollment records.

Retention notes after install:

- normal backup retention is configured from the DBAegis UI on schedules or per manual backup run; manual backup retention defaults to `0`/disabled and only runs cleanup when an operator enters a non-zero value
- self-backup retention is separate and uses `self_backup_retention_count`
- for supported cloud targets, retention deletes the remote object as well as the local metadata row

Security notes after install:

- `DBAEGIS_SECRET_KEY` is used to derive the encryption key for stored connection passwords, connection option secrets, cloud storage destination credentials, SMTP passwords, LDAP bind passwords, Microsoft Authenticator MFA enrollment secrets, webhook secrets, and sensitive restore options.
- fresh install generates `DBAEGIS_SECRET_KEY` in `conf/dbaegis.conf`; upgrade preserves the existing value and adds one to older configs that do not have it yet.
- preserve `DBAEGIS_SECRET_KEY` across upgrades and service rebuilds; changing it without `bin/dbaegis rotate-secret-key` prevents DBAegis from decrypting existing saved secrets.
- AWS S3, GCS, Azure Blob, SMTP, LDAP, local-user MFA enrollment, webhook, restore-option, and connection option secrets are stored encrypted in SQLite and are redacted in UI/API responses.
- keep `conf/dbaegis.conf`, `tls/`, `venv/`, SQLite metadata, logs, backups, and temporary files out of Git.
- rotate credentials if any real config, TLS private key, or cloud key was ever committed or shared outside the VM.

Rotate `DBAEGIS_SECRET_KEY`:

```bash
sudo systemctl stop dbaegis
sudo -u dbaegis /opt/dbaegis/bin/dbaegis rotate-secret-key --generate-new-key --update-conf
sudo systemctl start dbaegis
```

The rotation command can run as the DBAegis service user because default installs own `/opt/dbaegis/conf/dbaegis.conf` and `/opt/dbaegis/data/dbaegis.db` as that user. If you are already logged in as the DBAegis service user, omit `sudo -u dbaegis`. If you want to provide the replacement key explicitly instead of generating it, avoid putting the secret directly on the command line. For example, read it into an environment variable and pass the variable name:

```bash
read -r -s DBAEGIS_NEW_KEY
export DBAEGIS_NEW_KEY
sudo --preserve-env=DBAEGIS_NEW_KEY -u dbaegis /opt/dbaegis/bin/dbaegis rotate-secret-key --new-key-env DBAEGIS_NEW_KEY --update-conf
unset DBAEGIS_NEW_KEY
```

The raw `--old-key OLD_KEY --new-key NEW_KEY` flags are valid for controlled lab use, but they can expose secrets through shell history or process listings. The rotation command reads the current key from `conf/dbaegis.conf` or from the explicit `--old-key`/`--old-key-env` input, re-encrypts saved connection passwords, connection option secrets, AWS/GCS/Azure storage destination secrets, SMTP/LDAP secrets, local-user MFA enrollment secrets, webhook secrets, and restore-option secrets with the new key, creates timestamped metadata/config backups, and updates `conf/dbaegis.conf` only after the database write succeeds. Use `--dry-run` first to validate the old key and count affected rows without writing changes. If the old key is already lost, encrypted saved secrets cannot be recovered and must be re-entered.

Restoring self-backups across secret-key rotations:

- DBAegis self-backup archives include the metadata DB, but sensitive config values such as `DBAEGIS_SECRET_KEY` are redacted from archived `dbaegis.conf`
- restoring a self-backup created before a secret-key rotation restores the old metadata DB, not the old secret key
- encrypted saved secrets in that restored DB require the `DBAEGIS_SECRET_KEY` that was active when the snapshot was created
- if you still have the old key, stop DBAegis and either start the restored system with that old key or rotate the restored DB forward with `bin/dbaegis rotate-secret-key --old-key-env DBAEGIS_OLD_KEY --new-key-env DBAEGIS_CURRENT_KEY`
- if the old key is unavailable, the metadata/history can still be restored, but encrypted saved credentials must be re-entered

System backup notes after install:

- DBAegis self-backups are stored separately from normal database backups
- Self-backup creation and settings require Professional or Enterprise; Community preserves existing self-backup metadata as locked/read-only after downgrade
- default snapshot location is `/backups/self`
- self-backups protect DBAegis metadata/config state, not the managed databases themselves
- self-backups can be created manually from the UI/API and may also be created automatically on selected metadata changes
- self-backups do not preserve the plaintext `DBAEGIS_SECRET_KEY`; keep the active and retired keys in an operator-controlled secret store if old snapshots may need to be restored later

System backup restore process:

The default install owns `/opt/dbaegis/data`, `/opt/dbaegis/data/dbaegis.db`, and `/backups/self` as the DBAegis service user. Use root/sudo to stop and start the service, then run file restore steps as the service user. If the install used a different service user, replace `dbaegis` in the commands below with that user.

1. Choose the snapshot to restore.

```bash
sudo -u dbaegis ls -lh /backups/self/selfbackup_*.zip
```

2. Stop DBAegis.

```bash
sudo systemctl stop dbaegis
```

3. Take a safety copy of the current metadata DB.

```bash
sudo -u dbaegis cp -a /opt/dbaegis/data/dbaegis.db /opt/dbaegis/data/dbaegis.db.pre-self-restore.$(date +%Y%m%d-%H%M%S)
```

4. Extract and install the selected snapshot database.

```bash
tmpdir="$(sudo -u dbaegis mktemp -d /opt/dbaegis/tmp/selfrestore.XXXXXX)"
sudo -u dbaegis unzip /backups/self/selfbackup_YYYYMMDD_HHMMSS_NNNNNNNNN.zip -d "$tmpdir"
sudo -u dbaegis install -m 640 "$tmpdir/dbaegis.db" /opt/dbaegis/data/dbaegis.db
sudo -u dbaegis rm -rf "$tmpdir"
```

5. Keep the active config secret key.

Do not overwrite `/opt/dbaegis/conf/dbaegis.conf` with the archived `conf/dbaegis.conf` as-is because self-backup archives redact `DBAEGIS_SECRET_KEY`. If other non-secret config values must be recovered, merge them manually and keep the live `DBAEGIS_SECRET_KEY`.

6. Start DBAegis and validate access.

```bash
sudo systemctl start dbaegis
sudo systemctl status dbaegis --no-pager
```

After restore, validate UI login, local-user MFA status, saved connections, storage destinations, LDAP, SMTP, and webhooks. If the restored snapshot was created before a `DBAEGIS_SECRET_KEY` rotation, either start with the old key that encrypted the restored metadata or rotate the restored DB forward with `bin/dbaegis rotate-secret-key --old-key-env DBAEGIS_OLD_KEY --new-key-env DBAEGIS_CURRENT_KEY` while DBAegis is stopped. If the old key is unavailable, re-enter saved credentials after login.

Default important paths:

- Install base: `/opt/dbaegis`
- Config: `/opt/dbaegis/conf/dbaegis.conf`
- SQLite DB: `/opt/dbaegis/data/dbaegis.db`
- Backups: `/backups`
- Temp: `/opt/dbaegis/tmp` for all DBAegis VM temporary backup/restore staging
- Logs: `/opt/dbaegis/logs`

Log and time notes after install:

- DBAegis uses the VM local timezone for backup history, restore jobs, schedules, self-backups, daily summaries, and `dbaegis.log`.
- Change timezone at the operating-system level, confirm `tzdata` is installed, then restart `dbaegis.service`.
- `dbaegis.log` records application/API/backup/restore/scheduler entries at `INFO`, `WARNING`, and `ERROR`.
- `nginx-access.log` and `nginx-error.log` are written by the DBAegis-managed nginx process under the same `LOG_DIR`.
- `LOG_BACKUP_COUNT` controls rotated copies for `dbaegis.log`, `nginx-access.log`, and `nginx-error.log`; the default is `9` rotated copies plus the active file.
- `run/nginx/conf/nginx.conf`, `run/nginx/conf/nginx-main.conf`, and `run/nginx/conf/nginx-tls-servers.conf` are generated runtime files. The installer writes placeholders, and `bin/dbaegis-stack` renders the active nginx config from `dbaegis.conf` each time the service starts. Do not treat these files as source templates.

If you change the defaults:

- make sure the parent directory for `DBAEGIS_DB_PATH` exists and is writable by the DBAegis service user
- make sure `BACKUP_DIR` exists and is writable by the DBAegis service user
- make sure `DBAEGIS_TEMP_DIR` exists and is writable by the DBAegis service user
- re-run the installer with the desired env vars on a fresh host, or edit `conf/dbaegis.conf` and restart the service

## Upgrade

Run an in-place upgrade as root:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

Step-by-step upgrade when the current installation already exists at `/opt/dbaegis`:

1. Move to a working directory.

```bash
cd /tmp
```

2. Extract the new release package.

```bash
tar xzf EDITION-vVERSION.tar.gz
```

3. Enter the extracted release directory.

```bash
cd EDITION-vVERSION
```

4. Back up the current config. On default installs, this file is owned by the DBAegis service user.

```bash
sudo -u dbaegis cp -a /opt/dbaegis/conf/dbaegis.conf /opt/dbaegis/conf/dbaegis.conf.pre-upgrade.$(date +%Y%m%d-%H%M%S)
```

5. Back up the current SQLite metadata database. On default installs, this file is owned by the DBAegis service user, so the copy does not need to run as root. Replace `dbaegis` if the install uses a different service user.

```bash
sudo -u dbaegis cp -a /opt/dbaegis/data/dbaegis.db /opt/dbaegis/data/dbaegis.db.pre-upgrade.$(date +%Y%m%d-%H%M%S)
```

6. Run the in-place upgrade.

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

7. Compare the live config with the new template.

```bash
sudo -u dbaegis diff -u /opt/dbaegis/conf/dbaegis.conf /opt/dbaegis/conf/dbaegis.conf.new
```

8. Restart the service after manual code updates or config changes. The installer starts/restarts the service during normal `--upgrade`, but a manual Git pull or file copy does not reload FastAPI routes until the service restarts.

```bash
sudo systemctl restart dbaegis
```

Upgrade security notes:

- upgrade mode preserves the active `conf/dbaegis.conf`; verify the preserved `DBAEGIS_SECRET_KEY` is still present before starting the upgraded service.
- startup migration encrypts any existing plaintext connection option, storage destination, SMTP, LDAP, local-user MFA, webhook, and restore-option secrets when a valid `DBAEGIS_SECRET_KEY` and `cryptography` are available.
- after upgrading from a version that tracked runtime files, confirm `conf/dbaegis.conf`, `tls/`, and `venv/` are not tracked by Git and rotate any secrets that were pushed to a shared remote.

9. Verify the upgraded service.

```bash
systemctl status dbaegis --no-pager
journalctl -u dbaegis -n 50 --no-pager
curl -I http://127.0.0.1:3000/
curl -I http://127.0.0.1:8000/api/version
```

10. If TLS is enabled, verify HTTPS too.

```bash
curl -k -I https://127.0.0.1:3443/
```

If the UI shows a new button or view but the API returns `Not Found`, the browser is likely using updated UI files while the running backend process still has an older route table. Restart `dbaegis.service`, refresh the browser, and retry the action.

If login, scheduled backup cleanup, or notification work reports `database is locked`, confirm the upgraded service is the only running DBAegis process and that no external `sqlite3` or maintenance session is holding the metadata DB open. Current builds apply a SQLite busy timeout to primary, auth, restore, and notification metadata DB connections, and retention cleanup releases DB transactions before deleting old backup artifacts.

If a restore job reports `target connection details are required` after an upgrade or metadata DB move, verify that `DBAEGIS_DB_PATH` in `/opt/dbaegis/conf/dbaegis.conf` points to the active SQLite DB, restart `dbaegis.service`, and check authenticated `/api/health` for the reported metadata DB path.

Supported upgrade execution locations:

- from an extracted release payload
- from the installed script under `/opt/dbaegis/bin/install.sh`

What upgrade preserves:

- current `dbaegis.conf`, except for package-controlled license edition fields described below
- current `DBAEGIS_DB_PATH`
  Older installs using `DB_PATH` or `VAULT_DB_PATH` still work because the runtime accepts those as fallback names.
- current `BACKUP_DIR`
- current `DBAEGIS_LICENSE_DIR`
- current runtime data
- current backup artifacts

What upgrade snapshots before it changes runtime files:

- `app/`
- `ui/`
- `bin/`
- `docs/`
- `venv/`
- `release.json`
- `UPGRADE_AND_INSTALL.txt`
- `/etc/systemd/system/dbaegis.service`
- manifest checksums for the active config and SQLite metadata DB

What upgrade refreshes:

- application Python files
- UI files
- helper scripts
- customer documentation under `docs/`
- `requirements/install-constraints.txt`
- packaged `release.json`, `DBAEGIS_EDITION`, and paid-edition `DBAEGIS_LICENSE_REQUIRED=true`
- generated nginx runtime config files
- systemd unit
- virtualenv packages

LDAP-specific upgrade note:

- upgrade preserves live LDAP configuration because it is stored in DBAegis system settings inside the metadata database
- installer-generated LDAP keys in `dbaegis.conf.new` are documentation placeholders, not the active runtime source for LDAP settings

Recommended upgrade workflow:

1. Take a backup of the current SQLite DB and config.
2. Take a self-backup or export of any important DBAegis metadata if required by your process.
3. Run `bin/install.sh --upgrade`.
4. Compare `conf/dbaegis.conf.new` with the live `conf/dbaegis.conf`.
5. Merge only the settings you actually want to adopt.
6. Restart DBAegis if you changed config after the installer completed.

Retention-specific upgrade note:

- backup retention settings are stored in DBAegis metadata
- schedule retention settings are preserved across upgrade because they live in the SQLite metadata database
- self-backup retention count is also preserved across upgrade

Self-backup upgrade note:

- existing self-backup snapshot files under `/backups/self` are preserved during upgrade unless an operator removes them manually
- self-backup metadata stored in the DBAegis SQLite database is preserved across normal upgrade

## Edition Upgrade and Downgrade

Edition changes use the same `--upgrade` installer mode, but the release package and the license token must agree. The package controls which edition-specific files are installed. The license controls paid runtime entitlement. Do not treat a manual edit to `DBAEGIS_EDITION` as a substitute for installing the correct edition package.

Supported edition changes:

| Change | Package Required | License Required | Notes |
|---|---|---|---|
| Community to Professional | Professional package | Professional signed token | Enables paid runtime, email notifications, MFA/RBAC, self-backup, cloud storage, and broader database coverage. |
| Professional to Enterprise | Enterprise package | Enterprise signed token | Adds Enterprise-only entitlements such as webhooks, LDAP / Active Directory, CSV report exports, audit export, offline bundle, and certified-matrix terms. |
| Community to Enterprise | Enterprise package | Enterprise signed token | Direct upgrade is supported when the customer skips Professional. |
| Enterprise to Professional | Professional package | Professional signed token | Enterprise-only settings remain in metadata but are locked or ignored by the lower edition. |
| Professional to Community | Community package | No token required | Paid settings and history remain in metadata; Community runtime exposes only PostgreSQL, MySQL, and MongoDB DBAegis-local logical backup/restore. |
| Enterprise to Community | Community package | No token required | Same as Professional to Community, plus Enterprise-only settings such as LDAP and webhooks become locked/inactive. |

Edition-change prechecks:

1. Confirm the active install state.

```bash
curl http://127.0.0.1:8000/api/version
curl http://127.0.0.1:8000/api/license/status
sudo -u dbaegis grep -E '^(DBAEGIS_EDITION|DBAEGIS_LICENSE_REQUIRED|DBAEGIS_LICENSE_DIR)=' /opt/dbaegis/conf/dbaegis.conf
```

2. Back up the active config and metadata DB.

```bash
sudo -u dbaegis cp -a /opt/dbaegis/conf/dbaegis.conf /opt/dbaegis/conf/dbaegis.conf.pre-edition-change.$(date +%Y%m%d-%H%M%S)
sudo -u dbaegis cp -a /opt/dbaegis/data/dbaegis.db /opt/dbaegis/data/dbaegis.db.pre-edition-change.$(date +%Y%m%d-%H%M%S)
```

3. For Professional or Enterprise targets, stage the target license token and public verification key before or immediately after the package upgrade. Replace `dbaegis` if the installation uses a different service user.

```bash
sudo install -d -m 0750 -o dbaegis -g dbaegis /opt/dbaegis/license
sudo install -m 0644 -o dbaegis -g dbaegis /tmp/license_public.pem /opt/dbaegis/license/license_public.pem
sudo install -m 0640 -o dbaegis -g dbaegis /tmp/dbaegis.license /opt/dbaegis/license/dbaegis.license
```

4. Verify the staged token with the installed public key when the CLI is available.

```bash
dbaegis license verify \
  --license-key-file /opt/dbaegis/license/dbaegis.license \
  --public-key-file /opt/dbaegis/license/license_public.pem
```

Upgrade to a higher edition:

1. Extract the target edition release package on the DBAegis VM.

```bash
cd /tmp
tar xzf enterprise-vVERSION.tar.gz
cd enterprise-vVERSION
```

2. Run the target package installer in upgrade mode.

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

Official packages carry the target `edition` in `release.json`. During upgrade, the installer refreshes `/opt/dbaegis/release.json`, updates `DBAEGIS_EDITION`, forces `DBAEGIS_LICENSE_REQUIRED=true` for Professional and Enterprise, and sets `DBAEGIS_LICENSE_REQUIRED=false` for Community. Runtime paths, `DBAEGIS_SECRET_KEY`, database settings, backup directories, and existing license paths are preserved. If a host-bound paid license needs a stable instance identifier, pass `DBAEGIS_LICENSE_INSTANCE_ID=...` during the install or upgrade so the value is written into `dbaegis.conf`.

3. Restart DBAegis if any license files or config were changed after the installer completed.

```bash
sudo systemctl restart dbaegis
```

4. Verify the target edition.

```bash
curl http://127.0.0.1:8000/api/version
curl http://127.0.0.1:8000/api/license/status
systemctl status dbaegis --no-pager
```

5. Smoke test the upgraded edition:

- log in with a local admin user
- confirm the sidebar and status area show the target edition/version
- check that existing connections, backups, schedules, storage destinations, users, roles, notification settings, self-backup settings, and audit history are still visible
- for paid targets, run a small licensed backup/restore path and confirm the license status is `valid`
- for Enterprise, verify Enterprise-only surfaces such as LDAP and webhooks only when the license contains those entitlements

Downgrade to a lower edition:

1. Extract the lower edition package and run the installer in upgrade mode.

```bash
cd /tmp
tar xzf community-vVERSION.tar.gz
cd community-vVERSION
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

2. Apply the correct license state for the lower edition.

- Downgrade to Professional: install a Professional token whose `edition`, `features`, limits, and database coverage match the Professional contract.
- Downgrade to Community: keep or remove existing files under `/opt/dbaegis/license` as an operator choice, but set the effective edition to Community and disable license enforcement. Official Community packages do this from `release.json` and installer policy.

3. Restart and verify.

```bash
sudo systemctl restart dbaegis
curl http://127.0.0.1:8000/api/version
curl http://127.0.0.1:8000/api/license/status
```

Downgrade behavior:

- Metadata, backup artifacts, restore history, users, roles, schedules, storage destinations, self-backup metadata, notification settings, and audit history are preserved.
- Out-of-edition configuration is not deleted. The UI should keep relevant sections visible as locked or upgrade-required where the current edition supports that view.
- Enterprise-only webhooks and LDAP settings remain stored but cannot be used in Professional or Community.
- Paid-edition email notification settings, self-backup settings, MFA/RBAC, paid database definitions, and cloud storage settings remain stored but cannot be used in Community.
- Community runtime exposes the Community-supported surface: one admin user, three active connections, three schedules, DBAegis-local storage, and PostgreSQL/MySQL/MongoDB logical backup/restore.
- If existing metadata exceeds the lower edition limits, DBAegis should preserve history but block creating or re-enabling objects that would exceed the lower limit.

Edition downgrade versus rollback:

- Use edition downgrade when the customer intentionally moves to a lower edition.
- Use `--rollback` when a runtime upgrade failed and you need to restore the previous runtime snapshot.
- Rollback restores application/UI/bin/docs/venv files and the systemd unit from a snapshot, but it preserves the active config and metadata DB. If the rollback changes the effective edition, verify that the installed package, `DBAEGIS_EDITION`, `DBAEGIS_LICENSE_REQUIRED`, and the license token still match.

## Rollback

Every `--upgrade` creates a pre-upgrade runtime snapshot under:

```text
/opt/dbaegis/rollback/<timestamp>
```

Rollback is intended for a failed application/runtime upgrade. It restores runtime files and the systemd unit from a snapshot, then starts the service again.

Run rollback as root:

```bash
sudo DBAEGIS_USER=dbaegis bash /opt/dbaegis/bin/install.sh --rollback
```

To select a specific snapshot:

```bash
sudo DBAEGIS_USER=dbaegis \
  DBAEGIS_ROLLBACK_SNAPSHOT=20260428-005407 \
  bash /opt/dbaegis/bin/install.sh --rollback
```

Rollback restores:

- application Python files
- UI files
- helper scripts under `bin/`
- customer documentation under `docs/`
- Python virtualenv under `venv/`
- packaged `release.json`
- `UPGRADE_AND_INSTALL.txt`
- the saved `dbaegis.service` unit when present in the snapshot

Rollback preserves:

- active `conf/dbaegis.conf`
- active SQLite metadata database
- backup artifacts
- self-backup artifacts
- OS packages installed or updated by the installer
- current DB schema

Important rollback limits:

- rollback does not downgrade OS packages such as `sudo`, `nginx`, or client tools
- rollback does not restore an older SQLite metadata DB; if an upgrade includes a DB schema change that must be reversed, restore the matching DBAegis system backup or pre-upgrade DB copy
- rollback keeps the runtime that was displaced during rollback under `/opt/dbaegis/rollback/displaced-runtime-<timestamp>` for troubleshooting

After rollback, verify:

```bash
systemctl status dbaegis --no-pager
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/api/version
```

If TLS is enabled, verify HTTPS too:

```bash
curl -k https://127.0.0.1:3443/health
curl -k https://127.0.0.1:3443/api/version
```

## Uninstall

Safe uninstall keeps the configured database, config, and backups:

```bash
sudo bash bin/uninstall.sh
```

Purge uninstall removes product metadata/config/license state and installed customer documentation, but still preserves database backup artifacts:

```bash
sudo bash bin/uninstall.sh --purge
```

What safe uninstall removes:

- `dbaegis.service`
- DBAegis app files
- UI files
- virtualenv
- logs
- `/usr/local/bin/dbaegis` symlink

What safe uninstall preserves:

- configured `DBAEGIS_DB_PATH`
- configured `dbaegis.conf`, including `DBAEGIS_SECRET_KEY`
- configured `BACKUP_DIR`
- configured `DBAEGIS_LICENSE_DIR` with issued license files and public verification keys
- configured `SELF_BACKUP_DIR` when it is outside `BACKUP_DIR`
- LDAP configuration stored in the metadata database at `DBAEGIS_DB_PATH`

What purge uninstall additionally removes:

- the configured SQLite database file
- the configured config file or install-base config directory
- TLS material under the install base
- the default data directory when the database lives under it
- DBAegis-managed optional tool directories such as `vendor/`, `/opt/dbaegis-tools/mongodb`, and `.snowsql/`
- DBAegis-managed `/usr/local/bin` wrappers that point back into the install base, such as `snowsql`, `sqlpackage`, and MongoDB tool wrappers

Backup artifact directories are preserved in every uninstall mode. DBAegis does not delete the configured `BACKUP_DIR`, the default `/backups`, or a separate `SELF_BACKUP_DIR` during uninstall because these paths can contain customer database backups and system backup snapshots. Remove backup directories only through an explicit operator-controlled filesystem cleanup after confirming retention and off-host copies.

## LDAP Setup

LDAP / Active Directory authentication is available only in Enterprise through the `auth.ldap` license entitlement. Community and Professional keep local users, RBAC where licensed, and MFA where licensed, but LDAP settings, LDAP sign-in, and LDAP group-to-role mappings remain blocked.

For Enterprise systems, DBAegis LDAP authentication is optional and works alongside local users. In the admin UI, user management, role mapping, and LDAP settings are grouped under `Access Control`.

LDAP role mapping:

- users in the configured administrator group are mapped to DBAegis `admin`
- users in the configured read-only group are mapped to DBAegis `read_only`
- users not found in either mapped group are denied login
- backup/restore operator access can be mapped from LDAP groups in `Access Control` > `LDAP`, while permissions, connection assignments, and tag assignments remain managed in DBAegis
- LDAP role precedence is admin first, then role-specific mappings, then read_only fallback
- current default group names are:
  - `admin`
  - `read_only`

Custom LDAP role mapping:

1. Create the DBAegis application role from `Access Control` > `Roles`.
2. Select the permissions that role should have.
3. Assign only the database connections or connection tags that role can back up, restore, or operate on.
4. Create or confirm the matching LDAP group in your directory.
5. Map the LDAP group to the DBAegis role from `Access Control` > `LDAP` under `Role LDAP Mappings`.
6. Use `Test LDAP` with a user in that LDAP group and confirm the mapped DBAegis role.

DBAegis does not create LDAP directory groups. It creates DBAegis roles and maps them to LDAP groups returned by the configured directory search.

LDAP configuration fields in the admin UI/API:

- `server_uri`
- `bind_dn`
- `bind_password`
- `user_base_dn`
- `user_filter`
- `group_base_dn`
- `admin_group`
- `read_only_group`
- `use_ssl`
- `start_tls`
- `verify_cert`
- `ca_cert_file`

Recommended LDAP rollout:

1. Keep the bootstrap local admin available while validating LDAP.
2. Configure LDAP in the DBAegis admin UI under `Access Control` > `LDAP`.
3. Use `Test LDAP` with no test username/password first to validate connection, bind, and search.
4. Use `Test LDAP` with one account expected to map to `admin`.
5. Use `Test LDAP` with one account expected to map to `read_only`.
6. Confirm real login from a private or incognito browser window.
7. Only after validation, decide whether additional local users are still needed.

Operational notes:

- LDAP users are shown in `Access Control` > `Users` with `auth_source=ldap`
- LDAP-managed users cannot have their password reset locally in DBAegis
- LDAP-managed usernames and roles are controlled by the directory and group mapping
- if a local DBAegis user already exists with the same username, LDAP login for that username is rejected to avoid ambiguity
- disabling an LDAP user in DBAegis still blocks that user even if directory authentication succeeds
- the `Access Control` > `LDAP` tab shows both toast notifications and an inline result panel for `Test LDAP`

## Config File

The main runtime config is:

- `/opt/dbaegis/conf/dbaegis.conf`

The tracked example template is:

- [conf/dbaegis.conf.example](../conf/dbaegis.conf.example)

Generated local nginx config files live under the runtime directory:

- `/opt/dbaegis/run/nginx/conf/nginx.conf`
- `/opt/dbaegis/run/nginx/conf/nginx-main.conf`
- `/opt/dbaegis/run/nginx/conf/nginx-tls-servers.conf`

They are rendered from `dbaegis.conf` and installer defaults, so changes should be made through `dbaegis.conf` or installer environment variables rather than by editing generated nginx files directly.

The most important settings for install and lifecycle operations are:

- `DBAEGIS_DB_PATH`
  Older `DB_PATH` and `VAULT_DB_PATH` names remain accepted for compatibility during upgrade transitions.
  Path to the SQLite metadata database.
- `BACKUP_DIR`
  Path where backup artifacts are stored.
- `SELF_BACKUP_DIR`
  Optional explicit path for DBAegis self-backup snapshots. If unset, self-backups default under the backup directory.
- `DBAEGIS_TEMP_DIR`
  DBAegis VM scratch directory for local restore preparation, temporary SSH key files, and managed-service/client-side artifacts.
- `DBAEGIS_PYTHON_DIR`
  Directory where the installer downloads and extracts the embedded Python runtime.
- `DBAEGIS_PYTHON_BIN`
  Python executable used by DBAegis and to create `/opt/dbaegis/venv`.
- `DBAEGIS_PYTHON_URL`
  Optional override for the embedded Python tarball URL. By default the installer selects a Linux `python-build-standalone` tarball for the host CPU architecture.
- Release artifacts do not carry `python/` or `venv/`; the installer creates
  them on the target host for every edition unless a supported custom Python
  runtime is configured.
- `SERVICE_PRIVATE_TMP`
  Controls systemd `PrivateTmp` isolation for the DBAegis service.
  Default install behavior is `no` so local backup or restore source paths under `/tmp` remain visible to the service.
- `LOG_DIR`
  Path used by the DBAegis runtime and DBAegis-managed nginx instance.
- `LOG_BACKUP_COUNT`
  Number of rotated files to keep for `dbaegis.log`, `nginx-access.log`, and `nginx-error.log`.
- `API_PORT`
  API listener port.
- `UI_PORT`
  HTTP UI listener port.
- `HTTPS_PORT`
  HTTPS listener port when TLS is enabled.
- `TLS_MODE`
  `off`, `self_signed`, or `customer_provided`.
- `HTTP_BEHAVIOR`
  `both`, `redirect`, or `https_only` when TLS is enabled.
- `DBAEGIS_EDITION`
  Package entitlement default, normally read from packaged `release.json`, otherwise `community`. Professional and Enterprise always require a signed token.
- `DBAEGIS_LICENSE_REQUIRED`
  Enables signed license enforcement when set to `true`. Professional and Enterprise force signed license enforcement regardless of this value; official Community installs and downgrades set it to `false`.
- `DBAEGIS_LICENSE_DIR`
  Directory for the license token, public verification key, and related license metadata.
- `DBAEGIS_LICENSE_KEY_FILE`
  Issued license token path.
- `DBAEGIS_LICENSE_PUBLIC_KEY_FILE`
  Public verification key path.
- `DBAEGIS_LICENSE_INSTANCE_ID`
  Optional stable host identifier for host-bound licenses.
- `AUTH_ENABLED`
  Enables or disables DBAegis authentication.
- `BOOTSTRAP_ADMIN_USER`
  Bootstrap local admin username used on first install.
- `BOOTSTRAP_ADMIN_PASSWORD`
  Bootstrap local admin password used only when the metadata `users` table is empty. Fresh installs generate one unless this is supplied explicitly. After the first admin exists, UI password changes are stored in SQLite and restarts do not reapply this value.

LDAP placeholder keys may also appear in `dbaegis.conf`, but current runtime LDAP settings are stored in DBAegis system settings through the admin UI/API.

## Validation After Install or Upgrade

Recommended validation steps:

```bash
systemctl status dbaegis
journalctl -u dbaegis -n 50 --no-pager
curl -I http://127.0.0.1:3000/
curl -I http://127.0.0.1:8000/api/version
```

If TLS is enabled:

```bash
curl -k -I https://127.0.0.1:3443/
```

Also verify in the UI:

- login works
- connections list loads
- backup history loads
- schedules load
- at least one connection test succeeds

For repository-level test validation, use the built-in unittest suite:

```bash
/opt/dbaegis/venv/bin/python -m unittest discover -s tests
```

`pytest` is not required by the installer.

## Packaging Notes

The installer assumes the release payload contains the expected app, UI, helper script, and dependency constraint files.

Required payload files include:

- `app/main.py`
- `app/community/runtime.py`
- `app/professional/main_runtime.py` for Professional and Enterprise packages
- `app/services/*.py`
- `ui/index.html`
- `bin/install.sh`
- `bin/uninstall.sh`
- `bin/dbaegis-stack`
- `bin/rotate_dbaegis_secret_key.py`
- `bin/reset_admin_password.py`
- `requirements/install-constraints.txt`
- `release.json` for official production release packages

Python dependency policy:

- direct installer packages are exact pinned versions, not open-ended `>=` ranges
- transitive dependencies are constrained by `requirements/install-constraints.txt`
- the installer copies the constraints file to `$DBAEGIS_BASE/requirements/install-constraints.txt`
- installed-tree upgrades use the copied constraints file unless `PYTHON_CONSTRAINTS_FILE` is explicitly overridden
- dependency refreshes should be separate, tested commits that update both the direct pins in `bin/install.sh` and the constraints file

Upgrade now supports both:

- running from a release payload directory
- running from the installed script tree

Even with that support, a real release should still be validated with:

1. one fresh install test
2. one in-place upgrade test
3. one safe uninstall test
4. one purge uninstall test in a disposable environment

Fresh/upgrade smoke note:

DBAegis has one global `dbaegis.service`. Even when `DBAEGIS_BASE` points at a temporary path, the installer writes and restarts `/etc/systemd/system/dbaegis.service`. Run temp-base smoke tests only on a disposable VM or during a maintenance window, then restore the intended install base with a normal upgrade.

Use the default `DBAEGIS_OS_PACKAGE_MODE=install` for release validation so prerequisite OS packages are installed or upgraded when needed. Use `DBAEGIS_OS_PACKAGE_MODE=missing-only` only for repeat smoke runs on a VM that has already passed full package validation.

Example contained fresh and upgrade smoke:

```bash
sudo env DBAEGIS_USER=dbaegis \
  DBAEGIS_BASE=/tmp/dbaegis-smoke-install \
  DBAEGIS_BACKUP_DIR=/tmp/dbaegis-smoke-backups \
  DBAEGIS_TEMP_DIR=/tmp/dbaegis-smoke-install/tmp \
  DBAEGIS_PYTHON_DIR=/opt/dbaegis/python \
  DBAEGIS_PYTHON_BIN=/opt/dbaegis/python/bin/python3 \
  DBAEGIS_API_PORT=18080 \
  DBAEGIS_UI_PORT=13080 \
  bash bin/install.sh --fresh

curl -fsS http://127.0.0.1:18080/health

cd /tmp/dbaegis-smoke-install
sudo env DBAEGIS_USER=dbaegis \
  DBAEGIS_BASE=/tmp/dbaegis-smoke-install \
  DBAEGIS_BACKUP_DIR=/tmp/dbaegis-smoke-backups \
  DBAEGIS_TEMP_DIR=/tmp/dbaegis-smoke-install/tmp \
  DBAEGIS_PYTHON_DIR=/opt/dbaegis/python \
  DBAEGIS_PYTHON_BIN=/opt/dbaegis/python/bin/python3 \
  DBAEGIS_API_PORT=18080 \
  DBAEGIS_UI_PORT=13080 \
  bash bin/install.sh --upgrade

curl -fsS http://127.0.0.1:18080/health
```

Restore the normal service after a temp-base smoke:

```bash
cd /opt/dbaegis
sudo env DBAEGIS_USER=dbaegis \
  DBAEGIS_BASE=/opt/dbaegis \
  DBAEGIS_PYTHON_DIR=/opt/dbaegis/python \
  DBAEGIS_PYTHON_BIN=/opt/dbaegis/python/bin/python3 \
  bash bin/install.sh --upgrade

curl -fsS http://127.0.0.1:8000/health
```

## Operational Caveats

- Optional vendor-native backup tools are not installed by default because they add external repositories/downloads, platform-specific binaries, or explicit license/EULA steps.
- The installer can install these DBAegis-VM client tools when explicitly requested:

```bash
sudo DBAEGIS_INSTALL_SNOWSQL=1 \
     DBAEGIS_INSTALL_SQLPACKAGE=1 \
     DBAEGIS_INSTALL_SQLCMD=1 \
     DBAEGIS_ACCEPT_MICROSOFT_EULA=Y \
     DBAEGIS_INSTALL_MONGODB_TOOLS=1 \
     DBAEGIS_INSTALL_CLICKHOUSE_CLIENT=1 \
     bash bin/install.sh --upgrade
```

- Snowflake logical backup/restore requires SnowSQL on the DBAegis VM. With `DBAEGIS_INSTALL_SNOWSQL=1`, the installer installs the DBAegis-tested SnowSQL version under `/opt/dbaegis/vendor/snowsql/bin` and exposes `/usr/local/bin/snowsql` as the stable command path. Override `DBAEGIS_SNOWSQL_VERSION`, `DBAEGIS_SNOWSQL_URL`, `DBAEGIS_SNOWSQL_SHA256`, `DBAEGIS_SNOWSQL_HOME`, `DBAEGIS_SNOWSQL_DEST`, or `DBAEGIS_SNOWSQL_LINK` only for controlled mirrors, custom install paths, or a different pinned SnowSQL release.
- SQL Server/Azure SQL BACPAC workflows require `sqlpackage`. Override `DBAEGIS_SQLPACKAGE_URL`, `DBAEGIS_SQLPACKAGE_SHA256`, or `DBAEGIS_SQLPACKAGE_DEST` only for controlled mirrors or pinned packages.
- DBAegis-managed vendor executables under `/opt/dbaegis/vendor` are owned by the `dbaegis` service user and readable/executable by the service process. Stable `/usr/local/bin` wrappers remain root-owned. Runtime state, config, logs, backups, rollback snapshots, license files, TLS material, and SnowSQL runtime config stay owned by the service user where applicable.
- SQL Server connection checks and restore/control paths require `sqlcmd`; installing `mssql-tools18` requires explicit `DBAEGIS_ACCEPT_MICROSOFT_EULA=Y`.
- MongoDB workflows require MongoDB Database Tools (`mongodump`, `mongorestore`) and `mongosh` for connection checks and physical lock/unlock paths. By default, optional MongoDB tools install under `/opt/dbaegis-tools/mongodb` so the product tree stays clean. Override `DBAEGIS_MONGODB_INSTALL_ROOT`, `DBAEGIS_MONGODB_TOOLS_VERSION`, `DBAEGIS_MONGODB_TOOLS_URL`, `DBAEGIS_MONGODB_TOOLS_SHA256`, `DBAEGIS_MONGOSH_VERSION`, `DBAEGIS_MONGOSH_URL`, or `DBAEGIS_MONGOSH_SHA256` for controlled mirrors, custom install roots, or pinned packages.
- ClickHouse logical backup/restore requires `clickhouse-client`. Override `DBAEGIS_CLICKHOUSE_VERSION` or `DBAEGIS_CLICKHOUSE_REPO_CHANNEL` only when pinning a specific ClickHouse package stream.
- If optional tool flags were missed during the original install, rerun `bin/install.sh --upgrade` with the needed flags. The installer preserves the active config, metadata DB, backups, and service user, then installs missing optional tools. SnowSQL, MongoDB Database Tools, and mongosh are version-checked against the requested DBAegis-tested versions when their install flags are set; other already installed vendor tools are left in place unless an explicit version/URL/checksum override requires reinstalling them.
- Install remaining database-host tools separately for the engines you plan to operate: MySQL/MariaDB physical tools such as `xtrabackup` or `mariabackup`, Couchbase `cbbackupmgr`, Oracle `expdp`/`impdp`/`sqlplus`/`rman`, Neo4j `neo4j-admin`, and Cassandra `nodetool`. Cassandra `cqlsh` is installed best-effort into the DBAegis venv for raw `.cql` restore; install or configure another `cqlsh` path only when you need a Cassandra-version-specific shell.
- Actual backup and restore capability still depends on the tooling required for each database type and whether the tool must run on the DBAegis VM or the database VM.
- Safe uninstall preserves `dbaegis.conf` so the active `DBAEGIS_SECRET_KEY` remains available for the preserved metadata database. It also preserves `/opt/dbaegis/license` by default so issued license files remain available. Purge uninstall removes the config, installed customer documentation, install-base TLS material, and DBAegis-managed optional tool directories/wrappers, including the configured MongoDB tools root. All uninstall modes preserve configured database backup artifacts and self-backup snapshots.
- If `DBAEGIS_DB_PATH` points outside `/opt/dbaegis/data`, safe uninstall still preserves it, and purge uninstall now removes that exact configured file.

## Quick Reference

Fresh install:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --fresh
```

Upgrade:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

Edition change:

```bash
# Run from the extracted target edition package.
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

For paid target editions, install the matching token under `/opt/dbaegis/license` and verify `/api/license/status`.

Safe uninstall:

```bash
sudo bash bin/uninstall.sh
```

Purge uninstall:

```bash
sudo bash bin/uninstall.sh --purge
```
