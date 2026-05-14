# DBAegis Community 1.0.0 Release Notes

Release commit: `ac319b80677b9d50b804bddb83428ad368410d58`

## What This Release Includes

DBAegis Community 1.0.0 is the first public Community package.

Community includes:

- Self-hosted DBAegis web UI and FastAPI backend.
- Community runtime under `app/community/`.
- Local logical backup and restore for PostgreSQL, MySQL, and MongoDB.
- DBAegis-local backup storage.
- Backup history, restore jobs, basic schedules, and basic retention.
- One local admin user, up to three active connections, and up to three schedules.
- Installer, upgrade, rollback, and uninstall scripts.
- Community documentation and release metadata.

## Community Scope

This release does not include paid-edition capabilities such as:

- Cloud backup or cloud restore destinations.
- DB-server-local storage.
- Physical backups, physical restores, or PITR.
- Oracle RMAN, SQL Server PITR, Neo4j, Cassandra, Couchbase, ClickHouse, Snowflake, Redis, SQLite, or other paid-engine runtime support.
- Email notifications, webhook notifications, daily summaries, LDAP, MFA, RBAC, audit exports, CSV reports, or self-backup.

Those capabilities belong to Professional or Enterprise packages.

## Validation

Before broad use, validate the Community-supported paths:

- Fresh install with `DBAEGIS_EDITION=community` and `DBAEGIS_LICENSE_REQUIRED=false`.
- `/health` and `/api/version`.
- First admin login.
- PostgreSQL logical backup and restore.
- MySQL logical backup and restore.
- MongoDB logical backup and restore.
- Schedule creation within the Community limit.
- Upgrade and rollback on a non-production VM.

## Release Assets

- `community-v1.0.0.tar.gz`
- `community-v1.0.0.manifest.json`
- `SHA256SUMS`

Use `sha256sum -c SHA256SUMS` before install.
