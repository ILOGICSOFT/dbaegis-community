# DBAegis 1.0.0 Release Notes

Commit: `ac319b80677b9d50b804bddb83428ad368410d58`

## Validation

- Run the package lifecycle smoke before broad deployment.
- Verify `/health` and `/api/version` after fresh install, upgrade, and rollback.
- Verify restore workflows for the target customer database and storage combinations.

## Recent Changes

- `ac319b8 Polish notification summaries`
- `49d0a8a Document PITR validation coverage`
- `f093bb0 Fix GCS streaming temp handling`
- `751a4e5 Fix Neo4j overwrite restores from GCS`
- `23fb69a Fix Oracle RMAN remote artifact packaging`
- `f6ee45e Include Oracle archivelogs in RMAN artifacts`
- `780ab8b Add SQL Server PITR support`
- `27c3115 Align backup restore history status handling`
- `0beb2ea Add audited restore dismiss and retry window`
- `158cba7 Update docs for login logo`
