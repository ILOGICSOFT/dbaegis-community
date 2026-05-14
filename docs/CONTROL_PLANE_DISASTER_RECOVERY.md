# Control-Plane Disaster Recovery Runbook

Date: `2026-05-04`

This runbook covers recovery of the DBAegis control plane: the web/API service, metadata database, configuration, license files, TLS material, self-backups, schedules, saved connections, storage destinations, notification settings, and restore-job history. It does not replace the normal database backup/restore procedures for customer databases.

## Recovery Scope

Recover these items together:

| Item | Default path | Required for |
|---|---|---|
| Metadata DB | `/opt/dbaegis/data/dbaegis.db` | Users, roles, sessions, connections, schedules, backup history, restore jobs, storage destinations, settings |
| Active config | `/opt/dbaegis/conf/dbaegis.conf` | Runtime paths, ports, auth settings, license settings, `DBAEGIS_SECRET_KEY` |
| Secret key | `DBAEGIS_SECRET_KEY` in operator secret store and active config | Decrypting saved passwords, connection options, storage credentials, SMTP, LDAP, local-user MFA enrollment, webhooks, restore-option secrets |
| Self-backup archives | `/backups/self/selfbackup_*.zip` by default | Metadata/config snapshots for point-in-time control-plane restore |
| License material | `/opt/dbaegis/license` | Commercial/private license enforcement |
| TLS material | `/opt/dbaegis/tls` or configured nginx/service paths | HTTPS endpoint recovery |
| Local backup artifacts | `/backups` by default | Restoring databases whose artifacts were stored on the DBAegis VM |
| Logs | `/opt/dbaegis/logs` and journal logs | Incident investigation and audit evidence |

Treat `/opt/dbaegis/conf/dbaegis.conf`, the metadata DB, license files, TLS private keys, and local backup artifacts as sensitive data.

## Secret-Key Rules

`DBAEGIS_SECRET_KEY` is the recovery-critical control-plane secret. DBAegis self-backup archives include the metadata DB, but the archived `dbaegis.conf` redacts sensitive values, including `DBAEGIS_SECRET_KEY`. A self-backup alone is not enough to fully recover saved secrets.

Required policy:

- Store the active `DBAEGIS_SECRET_KEY` in an operator-controlled secret manager outside the DBAegis VM.
- Keep retired keys until every self-backup and offline copy encrypted under those retired keys has expired or been intentionally destroyed.
- Record key rotation timestamps in the secret manager so operators can match old self-backups to the key that encrypted their metadata.
- Never paste `DBAEGIS_SECRET_KEY` into Git, tickets, chat, CI variables for this repository, shell scripts, or command lines that will be saved in shell history.
- Rotate with `bin/dbaegis rotate-secret-key`; do not edit `DBAEGIS_SECRET_KEY` directly in `dbaegis.conf` on a live metadata DB.

If the key for a restored metadata DB is unavailable, DBAegis can still recover metadata and history, but encrypted saved credentials cannot be decrypted. Operators must re-enter connection passwords, storage credentials, SMTP settings, LDAP bind credentials, local-user MFA enrollments, webhooks, and any restore-option secrets before affected workflows can run.

## Production Backup Policy

Minimum production policy:

- Enable automatic self-backups and set `self_backup_auto_cron` to match the control-plane RPO. Daily is the default baseline; use hourly or more frequent snapshots for high-change environments.
- Keep `self_backup_retention_count` large enough to cover the rollback window, key-rotation window, and change-management requirements.
- Copy self-backup archives off the DBAegis VM to protected storage. Local `/backups/self` snapshots do not protect against VM loss.
- Back up `conf/dbaegis.conf`, `/opt/dbaegis/license`, `/opt/dbaegis/tls`, and `/backups` if DBAegis-local database backups are used.
- Store the active and retired `DBAEGIS_SECRET_KEY` values only in the external secret manager, not in the self-backup archive.
- Take a manual self-backup before upgrades, secret-key rotations, bulk connection changes, RBAC changes, storage-destination changes, and restore-policy changes.

Operator evidence to retain for each snapshot cycle:

- DBAegis version.
- Self-backup archive path and checksum.
- Metadata DB path.
- Config backup path.
- Secret-manager key version or label, not the secret value.
- Off-host copy location.
- Restore drill result and timestamp.

## Incident Triage

1. Declare whether this is metadata corruption, failed upgrade, lost VM, lost storage, lost secret key, or suspected compromise.
2. Stop DBAegis if the current VM is still running and the metadata DB may be corrupt.

```bash
sudo systemctl stop dbaegis
```

3. Preserve evidence before changing files.

```bash
sudo -u dbaegis mkdir -p /opt/dbaegis/tmp/dr-evidence
sudo -u dbaegis cp -a /opt/dbaegis/data/dbaegis.db /opt/dbaegis/tmp/dr-evidence/dbaegis.db.before-dr
sudo -u dbaegis cp -a /opt/dbaegis/conf/dbaegis.conf /opt/dbaegis/tmp/dr-evidence/dbaegis.conf.before-dr
sudo journalctl -u dbaegis --no-pager | sudo -u dbaegis tee /opt/dbaegis/tmp/dr-evidence/dbaegis.journal.before-dr.log >/dev/null
```

4. Select the restore point. Prefer the newest self-backup taken before the incident, unless the incident was a bad configuration or bad metadata write.
5. Retrieve the matching `DBAEGIS_SECRET_KEY` from the external secret manager. Use the key that was active when the selected metadata snapshot was created.

## Restore On The Same Host

Use this path for bad upgrades, bad configuration changes, accidental metadata changes, or metadata corruption when the original VM is still usable.

1. List available self-backups.

```bash
sudo -u dbaegis ls -lh /backups/self/selfbackup_*.zip
```

2. Stop DBAegis.

```bash
sudo systemctl stop dbaegis
```

3. Take a safety copy of current metadata and config.

```bash
stamp="$(date +%Y%m%d-%H%M%S)"
sudo -u dbaegis cp -a /opt/dbaegis/data/dbaegis.db "/opt/dbaegis/data/dbaegis.db.pre-dr.${stamp}"
sudo -u dbaegis cp -a /opt/dbaegis/conf/dbaegis.conf "/opt/dbaegis/conf/dbaegis.conf.pre-dr.${stamp}"
```

4. Extract the selected self-backup and restore only the metadata DB.

```bash
snapshot="/backups/self/selfbackup_YYYYMMDD_HHMMSS_NNNNNNNNN.zip"
tmpdir="$(sudo -u dbaegis mktemp -d /opt/dbaegis/tmp/controlplane-restore.XXXXXX)"
sudo -u dbaegis unzip "$snapshot" -d "$tmpdir"
sudo -u dbaegis install -m 640 "$tmpdir/dbaegis.db" /opt/dbaegis/data/dbaegis.db
sudo -u dbaegis rm -rf "$tmpdir"
```

5. Preserve the live `DBAEGIS_SECRET_KEY`. Do not copy the archived `conf/dbaegis.conf` over the active config as-is because self-backup archives redact sensitive values.

6. If the snapshot was created before a secret-key rotation, rotate the restored DB forward before starting DBAegis. Prefer environment variables over literal command-line keys.

```bash
read -rsp "Old DBAEGIS_SECRET_KEY: " DBAEGIS_OLD_KEY_FROM_SECRET_MANAGER
echo
read -rsp "Current DBAEGIS_SECRET_KEY: " DBAEGIS_CURRENT_KEY_FROM_SECRET_MANAGER
echo
export DBAEGIS_OLD_KEY_FROM_SECRET_MANAGER DBAEGIS_CURRENT_KEY_FROM_SECRET_MANAGER
sudo --preserve-env=DBAEGIS_OLD_KEY_FROM_SECRET_MANAGER,DBAEGIS_CURRENT_KEY_FROM_SECRET_MANAGER -u dbaegis \
  /opt/dbaegis/bin/dbaegis rotate-secret-key \
  --old-key-env DBAEGIS_OLD_KEY_FROM_SECRET_MANAGER \
  --new-key-env DBAEGIS_CURRENT_KEY_FROM_SECRET_MANAGER \
  --update-conf
unset DBAEGIS_OLD_KEY_FROM_SECRET_MANAGER DBAEGIS_CURRENT_KEY_FROM_SECRET_MANAGER
```

7. Start DBAegis.

```bash
sudo systemctl start dbaegis
sudo systemctl status dbaegis --no-pager
```

8. Run validation checks from the post-restore section.

## Restore On A Replacement Host

Use this path when the DBAegis VM is lost or must be rebuilt.

1. Provision a host with the supported operating system, network access, DNS, firewall rules, service account model, and storage mounts.
2. Install the same DBAegis release that created the selected self-backup, or install the target release and review release notes for metadata migrations before starting the service.
3. Stop DBAegis before replacing runtime state.

```bash
sudo systemctl stop dbaegis
```

4. Restore required directories and files from infrastructure backup or configuration management:

- `/opt/dbaegis/conf/dbaegis.conf`, with the correct `DBAEGIS_SECRET_KEY` restored from the secret manager.
- `/opt/dbaegis/license`, if license enforcement is enabled.
- `/opt/dbaegis/tls`, if local TLS material is used.
- `/backups/self` self-backup archives.
- `/backups` local database backup artifacts, if DBAegis-local backup storage is used.

5. Restore the selected metadata DB from the self-backup archive.

```bash
snapshot="/backups/self/selfbackup_YYYYMMDD_HHMMSS_NNNNNNNNN.zip"
tmpdir="$(sudo -u dbaegis mktemp -d /opt/dbaegis/tmp/controlplane-restore.XXXXXX)"
sudo -u dbaegis unzip "$snapshot" -d "$tmpdir"
sudo -u dbaegis install -m 640 "$tmpdir/dbaegis.db" /opt/dbaegis/data/dbaegis.db
sudo -u dbaegis rm -rf "$tmpdir"
```

6. Fix ownership and permissions if files were restored by root or backup tooling.

```bash
sudo chown -R dbaegis:dbaegis /opt/dbaegis/data /opt/dbaegis/conf /opt/dbaegis/logs /opt/dbaegis/tmp /backups
sudo chmod 640 /opt/dbaegis/data/dbaegis.db /opt/dbaegis/conf/dbaegis.conf
```

7. If the restored metadata DB was encrypted under an older key, rotate it forward as shown in the same-host restore path.
8. Start DBAegis and validate.

```bash
sudo systemctl start dbaegis
sudo systemctl status dbaegis --no-pager
```

## Post-Restore Validation

Run these checks before declaring recovery complete:

1. Open the DBAegis UI and confirm admin login works.
2. Confirm the DBAegis version and license status.
3. Confirm users, roles, LDAP mappings, sessions policy, and connection-scoped permissions.
4. Run connection tests for representative saved connections that use encrypted passwords or SSH options.
5. Run storage destination tests for AWS S3, Google Cloud Storage, Azure Blob, and configured local paths.
6. Confirm SMTP, LDAP bind, local-user MFA status, webhooks, and daily summary settings decrypt and test successfully.
7. Confirm schedules, backup history, restore-job history, self-backup history, and retention settings are present.
8. Run a non-destructive backup smoke or dry-run restore where supported by the target environment.
9. Review `/opt/dbaegis/logs/dbaegis.log` and `journalctl -u dbaegis` for startup migration, decryption, permission, or scheduler errors.
10. Take a new manual self-backup after validation and copy it off-host.

Acceptance criteria:

- DBAegis starts cleanly.
- Saved secrets decrypt without errors.
- At least one representative connection and one representative storage destination test successfully.
- Schedules and retention settings match the expected restore point.
- Operators can create a new self-backup and verify its off-host copy.

## Rollback After A Failed Restore

If validation fails and the previous local DB/config were usable, stop DBAegis and restore the safety copies created before the DR attempt.

```bash
sudo systemctl stop dbaegis
sudo -u dbaegis install -m 640 /opt/dbaegis/data/dbaegis.db.pre-dr.YYYYMMDD-HHMMSS /opt/dbaegis/data/dbaegis.db
sudo -u dbaegis install -m 640 /opt/dbaegis/conf/dbaegis.conf.pre-dr.YYYYMMDD-HHMMSS /opt/dbaegis/conf/dbaegis.conf
sudo systemctl start dbaegis
```

If the safety copy is not usable, repeat the restore with the next older self-backup and matching secret key.

## Lost Or Compromised Secret Key

If the secret-manager copy of the active key is lost but the installed `dbaegis.conf` is still intact, immediately take an incident snapshot. Generate and store a replacement key in the external secret manager first, then rotate the metadata DB and config to that replacement key.

```bash
sudo systemctl stop dbaegis
read -rsp "Replacement DBAEGIS_SECRET_KEY from secret manager: " DBAEGIS_REPLACEMENT_KEY
echo
export DBAEGIS_REPLACEMENT_KEY
sudo --preserve-env=DBAEGIS_REPLACEMENT_KEY -u dbaegis \
  /opt/dbaegis/bin/dbaegis rotate-secret-key \
  --new-key-env DBAEGIS_REPLACEMENT_KEY \
  --update-conf
unset DBAEGIS_REPLACEMENT_KEY
sudo systemctl start dbaegis
```

If the key is compromised, rotate it, rotate any upstream credentials that may have been exposed, and keep the compromised key in a restricted incident record only as long as old self-backups require it for recovery. If policy requires destroying the compromised key immediately, old metadata snapshots encrypted under that key can no longer recover saved secrets.

If the key is lost and no trusted copy exists:

- restore can recover users, roles, schedules, history, and non-secret metadata
- saved connection passwords and connection option secrets must be re-entered
- storage destination credentials must be re-entered before cloud backup/restore can run
- SMTP, LDAP bind credentials, local-user MFA enrollments, webhook secrets, and sensitive restore options must be re-entered
- after re-entry, take a fresh self-backup and store the new active key in the secret manager

## DR Drill Schedule

Run a control-plane DR drill before broad production rollout and after major release, installer, auth, storage, or secret-management changes.

Minimum drill:

1. Copy a production-like self-backup and matching secret key into an isolated recovery environment.
2. Restore the metadata DB on a replacement host.
3. Validate login, RBAC, connection tests, storage tests, notifications, schedules, and a non-destructive backup/restore smoke.
4. Record RTO, RPO, snapshot name, DBAegis version, key version label, validation evidence, and next actions.

Do not run a DR drill against production targets unless the change window, target isolation, and restore authorization are explicitly approved.
