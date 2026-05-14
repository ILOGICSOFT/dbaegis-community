from __future__ import annotations

import importlib
import json
import os
import sys
from dataclasses import dataclass
from typing import Any


DEFAULT_LICENSE_DIR = "/opt/dbaegis/license"
DEFAULT_LICENSE_KEY_FILE = f"{DEFAULT_LICENSE_DIR}/dbaegis.license"
DEFAULT_LICENSE_PUBLIC_KEY_FILE = f"{DEFAULT_LICENSE_DIR}/license_public.pem"
LICENSE_EDITIONS = {"community", "professional", "enterprise"}

_PROFESSIONAL_DATABASES = {
    "postgresql",
    "mysql",
    "mariadb",
    "oracle",
    "mssql",
    "sqlite",
    "mongodb",
    "redis",
    "couchdb",
    "couchbase",
    "neo4j",
    "cassandra",
    "snowflake",
    "cosmosdb",
    "dynamodb",
    "firestore",
    "azuresql",
    "clickhouse",
}

EDITION_DEFAULT_FEATURES = {
    "community": {
        "backups.local",
        "restores.local",
        "schedules",
        "retention",
    },
    "professional": {
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
        "self_backup",
    },
    "enterprise": {
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
        "notifications.webhooks",
        "audit.events",
        "rbac",
        "mfa",
        "self_backup",
        "auth.ldap",
        "reports.csv",
        "audit.export",
        "enterprise.offline_bundle",
        "enterprise.lts",
        "enterprise.certified_matrix",
    },
}

EDITION_DEFAULT_LIMITS = {
    "community": {
        "connections": 3,
        "users": 1,
        "schedules": 3,
        "storage_destinations": 1,
    },
    "professional": {
        "connections": 50,
        "users": 5,
        "schedules": 100,
        "storage_destinations": 10,
    },
    "enterprise": {
        "connections": None,
        "users": None,
        "schedules": None,
        "storage_destinations": None,
    },
}

EDITION_DEFAULT_DATABASES = {
    "community": {"postgresql", "mysql", "mongodb"},
    "professional": set(_PROFESSIONAL_DATABASES),
    "enterprise": set(_PROFESSIONAL_DATABASES),
}

DB_TYPE_ALIASES = {
    "postgres": "postgresql",
    "pgsql": "postgresql",
    "aurora_postgresql": "postgresql",
    "aurora-postgresql": "postgresql",
    "aurora_postgres": "postgresql",
    "aurora-postgres": "postgresql",
    "aurora_mysql": "mysql",
    "aurora-mysql": "mysql",
    "documentdb": "mongodb",
    "docdb": "mongodb",
    "mongo": "mongodb",
    "sqlserver": "mssql",
    "sql_server": "mssql",
    "sql-server": "mssql",
    "azure_sql": "azuresql",
    "azure-sql": "azuresql",
}

FEATURE_ALIASES = {
    "self.backup": "self_backup",
    "storage.db.server.local": "storage.db_server_local",
    "enterprise.offline.bundle": "enterprise.offline_bundle",
    "enterprise.certified.matrix": "enterprise.certified_matrix",
}

_PAID_BACKEND_UNAVAILABLE = "Signed license verification is not included in this edition package"


class LicenseError(ValueError):
    def __init__(self, status: str, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


@dataclass(frozen=True)
class LicenseValidation:
    required: bool
    valid: bool
    status: str
    message: str
    claims: dict[str, Any]
    fingerprint: str

    def public_dict(self) -> dict[str, Any]:
        data = {
            "required": self.required,
            "valid": self.valid,
            "status": self.status,
            "message": self.message,
            "edition": license_edition(self),
        }
        if self.fingerprint:
            data["fingerprint"] = self.fingerprint
        if self.claims:
            data["license"] = _public_claims(self.claims)
        if entitlements_enforced() or self.claims:
            data["entitlements"] = license_entitlements(self)
        return data


def _bool_env(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None or str(raw).strip() == "":
        return default
    return str(raw).strip().lower() in {"1", "true", "yes", "on", "required"}


def license_required() -> bool:
    if configured_edition() in {"professional", "enterprise"}:
        return True
    return _bool_env("DBAEGIS_LICENSE_REQUIRED", False)


def configured_edition() -> str:
    raw = str(os.environ.get("DBAEGIS_EDITION") or os.environ.get("DBAEGIS_PRODUCT_EDITION") or "").strip().lower()
    return raw if raw in LICENSE_EDITIONS else ""


def entitlements_enforced() -> bool:
    return license_required() or bool(configured_edition())


def _status_entitlements_enforced(status: LicenseValidation | None = None) -> bool:
    return entitlements_enforced() or bool(getattr(status, "claims", None))


def _paid_license_backend():
    try:
        return importlib.import_module("app.professional.license")
    except ModuleNotFoundError as exc:
        if exc.name in {"app.professional", "app.professional.license"}:
            return None
        raise


def license_fingerprint(license_key: str) -> str:
    import hashlib

    raw = str(license_key or "").strip().encode("utf-8")
    if not raw:
        return ""
    return hashlib.sha256(raw).hexdigest()[:16]


def current_license_status() -> LicenseValidation:
    required = license_required()
    if not required:
        return LicenseValidation(
            required=False,
            valid=True,
            status="not_required",
            message="License enforcement is disabled",
            claims={},
            fingerprint="",
        )
    backend = _paid_license_backend()
    if backend is None:
        return LicenseValidation(
            required=True,
            valid=False,
            status="unavailable",
            message=_PAID_BACKEND_UNAVAILABLE,
            claims={},
            fingerprint=license_fingerprint(os.environ.get("DBAEGIS_LICENSE_KEY") or ""),
        )
    try:
        return backend.current_license_status()
    except LicenseError as exc:
        return LicenseValidation(
            required=True,
            valid=False,
            status=exc.status,
            message=exc.message,
            claims={},
            fingerprint=license_fingerprint(os.environ.get("DBAEGIS_LICENSE_KEY") or ""),
        )


def _public_claims(claims: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "license_id",
        "customer",
        "edition",
        "databases",
        "features",
        "limits",
        "issued_at",
        "not_before",
        "expires_at",
        "max_instances",
        "hosts",
        "instance_ids",
    }
    return {k: claims[k] for k in sorted(allowed) if k in claims and claims[k] not in (None, "", [], {})}


def _normalize_edition(value: Any) -> str:
    text = str(value or "").strip().lower()
    return text if text in LICENSE_EDITIONS else "community"


def _normalize_feature(value: Any) -> str:
    key = str(value or "").strip().lower().replace("-", ".")
    return FEATURE_ALIASES.get(key, key)


def _normalize_db_type(value: Any) -> str:
    key = str(value or "").strip().lower().replace("-", "_")
    return DB_TYPE_ALIASES.get(key, key)


def license_edition(status: LicenseValidation | None = None) -> str:
    status = status or current_license_status()
    if getattr(status, "valid", False) and status.claims:
        return _normalize_edition(status.claims.get("edition"))
    return configured_edition() or "community"


def license_features(status: LicenseValidation | None = None) -> set[str]:
    status = status or current_license_status()
    if not _status_entitlements_enforced(status):
        return {"*"}
    if not getattr(status, "valid", False):
        return set()
    edition = license_edition(status)
    raw_features = (status.claims or {}).get("features") if status.claims else None
    if isinstance(raw_features, str):
        raw_features = [item.strip() for item in raw_features.split(",")]
    features = {
        _normalize_feature(item)
        for item in (raw_features or [])
        if _normalize_feature(item)
    }
    return features or set(EDITION_DEFAULT_FEATURES.get(edition, EDITION_DEFAULT_FEATURES["community"]))


def license_feature_enabled(feature: str, status: LicenseValidation | None = None) -> bool:
    feature = _normalize_feature(feature)
    if not feature:
        return True
    features = license_features(status)
    if "*" in features or feature in features:
        return True
    parts = feature.split(".")
    return any(".".join(parts[:idx]) + ".*" in features for idx in range(1, len(parts) + 1))


def _limit_candidates(name: str) -> tuple[str, ...]:
    key = str(name or "").strip().lower().replace("-", "_")
    aliases = {
        "connections": ("connections", "active_connections", "max_connections"),
        "users": ("users", "active_users", "max_users"),
        "schedules": ("schedules", "active_schedules", "max_schedules"),
        "storage_destinations": ("storage_destinations", "storage", "active_storage_destinations", "max_storage_destinations"),
    }
    return aliases.get(key, (key,))


def _coerce_limit(value: Any) -> int | None:
    if value in (None, "", False):
        return None
    text = str(value).strip().lower()
    if text in {"unlimited", "none", "null", "-1"}:
        return None
    try:
        parsed = int(text)
    except Exception:
        return None
    return None if parsed < 0 else parsed


def license_limit(name: str, status: LicenseValidation | None = None) -> int | None:
    status = status or current_license_status()
    if not _status_entitlements_enforced(status):
        return None
    if not getattr(status, "valid", False):
        return 0
    edition = license_edition(status)
    claims = status.claims or {}
    limits = claims.get("limits") if isinstance(claims.get("limits"), dict) else {}
    for key in _limit_candidates(name):
        if key in limits:
            return _coerce_limit(limits.get(key))
        claim_key = f"max_{key}"
        if claim_key in claims:
            return _coerce_limit(claims.get(claim_key))
    for key in _limit_candidates(name):
        if key in EDITION_DEFAULT_LIMITS.get(edition, {}):
            return EDITION_DEFAULT_LIMITS[edition][key]
    return None


def license_databases(status: LicenseValidation | None = None) -> set[str]:
    status = status or current_license_status()
    if not _status_entitlements_enforced(status):
        return {"*"}
    if not getattr(status, "valid", False):
        return set()
    features = license_features(status)
    if "*" in features or "databases.*" in features or "database.*" in features:
        return {"*"}
    claims = status.claims or {}
    raw = claims.get("databases")
    if isinstance(raw, str):
        raw = [item.strip() for item in raw.split(",")]
    configured = {_normalize_db_type(item) for item in (raw or []) if _normalize_db_type(item)}
    configured.update(
        _normalize_db_type(item.split(".", 1)[1])
        for item in features
        if item.startswith("database.") and item.count(".") == 1
    )
    configured.update(
        _normalize_db_type(item.split(".", 1)[1])
        for item in features
        if item.startswith("databases.") and item.count(".") == 1
    )
    if configured:
        return configured
    return set(EDITION_DEFAULT_DATABASES.get(license_edition(status), EDITION_DEFAULT_DATABASES["community"]))


def license_database_enabled(db_type: str, status: LicenseValidation | None = None) -> bool:
    db_key = _normalize_db_type(db_type)
    if not db_key:
        return True
    databases = license_databases(status)
    return "*" in databases or db_key in databases


def license_entitlements(status: LicenseValidation | None = None) -> dict[str, Any]:
    status = status or current_license_status()
    return {
        "enforced": _status_entitlements_enforced(status),
        "edition": license_edition(status),
        "features": sorted(license_features(status)),
        "databases": sorted(license_databases(status)),
        "limits": {
            "connections": license_limit("connections", status),
            "users": license_limit("users", status),
            "schedules": license_limit("schedules", status),
            "storage_destinations": license_limit("storage_destinations", status),
        },
    }


def main(argv: list[str] | None = None) -> int:
    backend = _paid_license_backend()
    if backend is not None:
        return int(backend.main(argv))

    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args == ["status"]:
        status = current_license_status()
        print(json.dumps(status.public_dict(), sort_keys=True, indent=2))
        return 0 if status.valid else 2
    if args in (["-h"], ["--help"]):
        print("usage: dbaegis license status")
        print("")
        print(_PAID_BACKEND_UNAVAILABLE + ".")
        return 0
    print(f"unavailable: {_PAID_BACKEND_UNAVAILABLE}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
