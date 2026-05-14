# DBAegis Community v1.0.0 Install, Upgrade, and Uninstall Steps

Package directory: `community-v1.0.0`

## Extract

```bash
tar -xzf community-v1.0.0.tar.gz
cd community-v1.0.0
```

## Fresh Install

Community can run without a customer license token.

Community packages are source-protected and do not include the paid Professional runtime overlay. They include the clean Community runtime under `app/community/` for PostgreSQL, MySQL, and MongoDB DBAegis-local logical backup/restore, limited schedules, and basic retention.

Release packages do not include the installed `python/` runtime directory or
`venv/`. The installer creates those runtime directories on the target host for
every edition by using the pinned embedded Python download by default, or by
validating a configured Python 3.12+ runtime.

```bash
sudo DBAEGIS_USER=dbaegis DBAEGIS_EDITION=community DBAEGIS_LICENSE_REQUIRED=false \
  bash bin/install.sh --fresh
```

## Upgrade

Run upgrades from the extracted package directory. The installer preserves
`/opt/dbaegis/conf/dbaegis.conf`, the SQLite metadata database, license files,
backup artifacts, and existing runtime data. It also creates a pre-upgrade
snapshot under `/opt/dbaegis/rollback`. Official packages carry the edition in
`release.json`; install and upgrade apply that edition to `DBAEGIS_EDITION`, and
Professional/Enterprise packages force `DBAEGIS_LICENSE_REQUIRED=true`.

```bash
sudo DBAEGIS_USER=dbaegis DBAEGIS_EDITION=community DBAEGIS_LICENSE_REQUIRED=false \
  bash bin/install.sh --upgrade
```

## Rollback

```bash
sudo DBAEGIS_USER=dbaegis bash /opt/dbaegis/bin/install.sh --rollback
```

## Uninstall

```bash
sudo bash /opt/dbaegis/bin/uninstall.sh
```

Review `docs/INSTALL_UPGRADE_UNINSTALL.md` for the full parameter reference,
optional client-tool flags, rollback details, and data-retention behavior.
