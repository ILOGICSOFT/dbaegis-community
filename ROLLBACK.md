# DBAegis 1.0.0 Rollback Instructions

DBAegis installer rollback restores application runtime files and the systemd unit
from the latest pre-upgrade snapshot while preserving the active config, SQLite
metadata database, backup artifacts, license files, and `DBAEGIS_SECRET_KEY`.

## Before Upgrade

Run upgrades through the installer:

```bash
sudo DBAEGIS_USER=dbaegis bash bin/install.sh --upgrade
```

The installer writes a pre-upgrade snapshot under the configured rollback
directory, normally `/opt/dbaegis/rollback/<timestamp>`.

## Roll Back Latest Snapshot

```bash
sudo DBAEGIS_USER=dbaegis bash /opt/dbaegis/bin/install.sh --rollback
```

## Roll Back Specific Snapshot

```bash
sudo DBAEGIS_USER=dbaegis \
  DBAEGIS_ROLLBACK_SNAPSHOT=YYYYMMDD-HHMMSS \
  bash /opt/dbaegis/bin/install.sh --rollback
```

## Validate

```bash
systemctl status dbaegis --no-pager
curl -fsS http://127.0.0.1:8000/health
curl -fsS http://127.0.0.1:8000/api/version
```

Rollback does not downgrade operating-system packages or restore an older SQLite
metadata database. Use a matching control-plane self-backup when a database
schema rollback is required.
