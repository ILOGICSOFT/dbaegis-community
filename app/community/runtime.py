from __future__ import annotations

import base64
import gzip
import hashlib
import hmac
import json
import os
import secrets
import shutil
import sqlite3
import subprocess
import threading
import time
import urllib.parse
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse

try:
    from cryptography.fernet import Fernet
except Exception:
    Fernet = None

try:
    from croniter import croniter
except Exception:
    croniter = None

try:
    from app.license import current_license_status
except Exception:
    current_license_status = None

try:
    from app.version import DB_SCHEMA_VERSION, get_version_payload
except Exception:
    DB_SCHEMA_VERSION = 2
    get_version_payload = None


PRODUCT_EDITION = "community"
COMMUNITY_RUNTIME_MODE = "community-engine"
SUPPORTED_DB_TYPES = {"postgresql", "mysql", "mongodb"}
DB_TYPE_ALIASES = {
    "postgres": "postgresql",
    "pgsql": "postgresql",
    "mongo": "mongodb",
}
MAX_CONNECTIONS = 3
MAX_SCHEDULES = 3
PASSWORD_PREFIX = "enc:v1:"
SESSION_COOKIE_NAME = os.environ.get("SESSION_COOKIE_NAME") or os.environ.get("DBAEGIS_SESSION_COOKIE", "dbaegis_session")
SESSION_TTL_SECONDS = max(
    60,
    int(os.environ.get("SESSION_TTL_SECONDS") or os.environ.get("DBAEGIS_SESSION_TTL_SECONDS") or "28800"),
)
SESSION_COOKIE_SECURE_RAW = str(
    os.environ.get("SESSION_COOKIE_SECURE") or os.environ.get("DBAEGIS_COOKIE_SECURE") or "false"
).strip().lower()
AUTH_ENABLED = str(os.environ.get("AUTH_ENABLED") or os.environ.get("DBAEGIS_AUTH_ENABLED") or "true").strip().lower() not in {
    "0",
    "false",
    "no",
    "off",
}
BOOTSTRAP_ADMIN_USER = os.environ.get("BOOTSTRAP_ADMIN_USER") or os.environ.get("DBAEGIS_BOOTSTRAP_ADMIN_USER", "admin")
BOOTSTRAP_ADMIN_PASSWORD = os.environ.get("BOOTSTRAP_ADMIN_PASSWORD") or os.environ.get(
    "DBAEGIS_BOOTSTRAP_ADMIN_PASSWORD", ""
)
BACKUP_TIMEOUT_SECONDS = max(60, int(os.environ.get("DBAEGIS_BACKUP_TIMEOUT") or "14400"))
RESTORE_RETRY_WINDOW_SECONDS = 3 * 60 * 60

app = FastAPI(title="DBAegis Community API", version="1.0.0")
_SESSIONS: dict[str, dict[str, Any]] = {}
_SCHEDULER_THREAD: threading.Thread | None = None
_SCHEDULER_STOP = threading.Event()
_READY = False
_READY_LOCK = threading.Lock()


def _db_path() -> str:
    return (
        os.environ.get("DBAEGIS_DB_PATH")
        or os.environ.get("DB_PATH")
        or os.environ.get("VAULT_DB_PATH")
        or os.path.join(os.environ.get("DBAEGIS_BASE", "/opt/dbaegis"), "data", "dbaegis.db")
    )


def _backup_dir() -> str:
    return os.environ.get("BACKUP_DIR") or os.path.join(os.environ.get("DBAEGIS_BASE", "/opt/dbaegis"), "backups")


def _vm_timestamp(dt: datetime | None = None) -> str:
    return (dt or datetime.now()).replace(microsecond=0).strftime("%Y-%m-%d %H:%M:%S")


def _parse_vm_timestamp(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        return datetime.strptime(text[:19].replace("T", " "), "%Y-%m-%d %H:%M:%S")
    except Exception:
        return None


def _enforce_restore_retry_window(row: sqlite3.Row | dict[str, Any]) -> None:
    status = str(row["status"] if isinstance(row, sqlite3.Row) else row.get("status") or "").lower()
    if status not in {"failed", "error"}:
        return
    dismissed_at = row["dismissed_at"] if isinstance(row, sqlite3.Row) and "dismissed_at" in row.keys() else (
        row.get("dismissed_at") if isinstance(row, dict) else ""
    )
    if dismissed_at:
        raise HTTPException(status_code=400, detail="Dismissed restore jobs cannot be retried; create a new restore job")
    updated_at = row["updated_at"] if isinstance(row, sqlite3.Row) and "updated_at" in row.keys() else (
        row.get("updated_at") if isinstance(row, dict) else ""
    )
    created_at = row["created_at"] if isinstance(row, sqlite3.Row) and "created_at" in row.keys() else (
        row.get("created_at") if isinstance(row, dict) else ""
    )
    anchor = _parse_vm_timestamp(updated_at or created_at)
    if anchor is None or datetime.now() - anchor > timedelta(seconds=RESTORE_RETRY_WINDOW_SECONDS):
        raise HTTPException(status_code=400, detail="Restore retry window expired; create a new restore job")


def _json(value: Any, default: Any) -> Any:
    try:
        parsed = json.loads(value or "")
    except Exception:
        return default
    return parsed if parsed is not None else default


def _json_dict(value: Any) -> dict[str, Any]:
    parsed = _json(value, {})
    return parsed if isinstance(parsed, dict) else {}


def _db_conn() -> sqlite3.Connection:
    path = _db_path()
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path, timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=30000")
    return con


def _table_cols(con: sqlite3.Connection, table: str) -> set[str]:
    return {str(r["name"]) for r in con.execute(f"PRAGMA table_info({table})").fetchall()}


def _table_exists(con: sqlite3.Connection, table: str) -> bool:
    row = con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (table,)).fetchone()
    return row is not None


def _add_col(con: sqlite3.Connection, table: str, name: str, ddl: str) -> None:
    if name not in _table_cols(con, table):
        con.execute(f"ALTER TABLE {table} ADD COLUMN {ddl}")


def _ensure_tables(con: sqlite3.Connection | None = None) -> None:
    own = con is None
    if con is None:
        con = _db_conn()
    cur = con.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'admin',
            auth_source TEXT NOT NULL DEFAULT 'local',
            active INTEGER NOT NULL DEFAULT 1,
            created_at TEXT DEFAULT (datetime('now','localtime')),
            updated_at TEXT DEFAULT (datetime('now','localtime')),
            last_login_at TEXT
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS connections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            db_type TEXT NOT NULL,
            tags TEXT DEFAULT '',
            host TEXT,
            port INTEGER,
            username TEXT,
            password TEXT,
            database_name TEXT,
            backup_type TEXT DEFAULT 'logical',
            destination TEXT DEFAULT 'dbaegis_local',
            status TEXT DEFAULT 'unknown',
            options_json TEXT DEFAULT '{}',
            created_at TEXT DEFAULT (datetime('now','localtime')),
            updated_at TEXT DEFAULT (datetime('now','localtime'))
        )
        """
    )
    for name, ddl in (
        ("tags", "tags TEXT DEFAULT ''"),
        ("backup_type", "backup_type TEXT DEFAULT 'logical'"),
        ("destination", "destination TEXT DEFAULT 'dbaegis_local'"),
        ("status", "status TEXT DEFAULT 'unknown'"),
        ("options_json", "options_json TEXT DEFAULT '{}'"),
        ("created_at", "created_at TEXT"),
        ("updated_at", "updated_at TEXT"),
    ):
        _add_col(con, "connections", name, ddl)
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS backups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            connection_id INTEGER NOT NULL,
            status TEXT DEFAULT 'running',
            destination TEXT DEFAULT 'dbaegis_local',
            file_path TEXT,
            size_bytes INTEGER DEFAULT 0,
            error_msg TEXT,
            started_at TEXT DEFAULT (datetime('now','localtime')),
            finished_at TEXT,
            backup_type TEXT DEFAULT 'logical',
            notes TEXT DEFAULT '',
            engine_log TEXT DEFAULT '',
            stdout_log TEXT DEFAULT '',
            stderr_log TEXT DEFAULT '',
            command_text TEXT DEFAULT '',
            exit_code INTEGER,
            target_uri TEXT DEFAULT '',
            retention_days INTEGER DEFAULT 0,
            retention_count INTEGER DEFAULT 0,
            dismissed_at TEXT DEFAULT '',
            dismissed_by_user_id INTEGER,
            dismissed_by_username TEXT DEFAULT ''
        )
        """
    )
    for name, ddl in (
        ("stdout_log", "stdout_log TEXT DEFAULT ''"),
        ("stderr_log", "stderr_log TEXT DEFAULT ''"),
        ("command_text", "command_text TEXT DEFAULT ''"),
        ("exit_code", "exit_code INTEGER"),
        ("target_uri", "target_uri TEXT DEFAULT ''"),
        ("retention_days", "retention_days INTEGER DEFAULT 0"),
        ("retention_count", "retention_count INTEGER DEFAULT 0"),
        ("dismissed_at", "dismissed_at TEXT DEFAULT ''"),
        ("dismissed_by_user_id", "dismissed_by_user_id INTEGER"),
        ("dismissed_by_username", "dismissed_by_username TEXT DEFAULT ''"),
    ):
        _add_col(con, "backups", name, ddl)
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS restore_jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            connection_id INTEGER,
            target_connection_id INTEGER,
            db_type TEXT DEFAULT '',
            source_path TEXT DEFAULT '',
            backup_id INTEGER,
            restore_mode TEXT DEFAULT 'logical',
            options_json TEXT DEFAULT '{}',
            status TEXT DEFAULT 'pending',
            log TEXT DEFAULT '',
            error_msg TEXT DEFAULT '',
            created_at TEXT DEFAULT (datetime('now','localtime')),
            updated_at TEXT DEFAULT (datetime('now','localtime'))
        )
        """
    )
    _add_col(con, "restore_jobs", "target_connection_id", "target_connection_id INTEGER")
    _add_col(con, "restore_jobs", "dismissed_at", "dismissed_at TEXT DEFAULT ''")
    _add_col(con, "restore_jobs", "dismissed_by_user_id", "dismissed_by_user_id INTEGER")
    _add_col(con, "restore_jobs", "dismissed_by_username", "dismissed_by_username TEXT DEFAULT ''")
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS schedules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            connection_id INTEGER NOT NULL,
            name TEXT DEFAULT '',
            frequency TEXT DEFAULT 'daily',
            cron_expr TEXT,
            destination TEXT DEFAULT 'dbaegis_local',
            retention_days INTEGER DEFAULT 7,
            retention_count INTEGER DEFAULT 0,
            options_json TEXT DEFAULT '{}',
            active INTEGER DEFAULT 1,
            last_run_at TEXT,
            next_run_at TEXT,
            created_at TEXT DEFAULT (datetime('now','localtime')),
            updated_at TEXT DEFAULT (datetime('now','localtime'))
        )
        """
    )
    for name, ddl in (
        ("name", "name TEXT DEFAULT ''"),
        ("retention_count", "retention_count INTEGER DEFAULT 0"),
        ("options_json", "options_json TEXT DEFAULT '{}'"),
        ("last_run_at", "last_run_at TEXT"),
        ("next_run_at", "next_run_at TEXT"),
    ):
        _add_col(con, "schedules", name, ddl)
    try:
        current_version = con.execute("PRAGMA user_version").fetchone()[0]
        if int(current_version or 0) < int(DB_SCHEMA_VERSION):
            con.execute(f"PRAGMA user_version = {int(DB_SCHEMA_VERSION)}")
    except Exception:
        pass
    con.commit()
    if own:
        con.close()


def _secret_key() -> str:
    return str(os.environ.get("DBAEGIS_SECRET_KEY") or "").strip()


def _fernet():
    secret = _secret_key()
    if not secret or Fernet is None:
        return None
    key = base64.urlsafe_b64encode(hashlib.sha256(secret.encode("utf-8")).digest())
    return Fernet(key)


def _encrypt_secret(value: Any) -> str:
    if value in (None, ""):
        return ""
    text = str(value)
    if text.startswith(PASSWORD_PREFIX):
        return text
    f = _fernet()
    if f is None:
        return text
    return PASSWORD_PREFIX + f.encrypt(text.encode("utf-8")).decode("utf-8")


def _decrypt_secret(value: Any) -> str:
    if value in (None, ""):
        return ""
    text = str(value)
    if not text.startswith(PASSWORD_PREFIX):
        return text
    f = _fernet()
    if f is None:
        return ""
    try:
        return f.decrypt(text[len(PASSWORD_PREFIX) :].encode("utf-8")).decode("utf-8")
    except Exception:
        return ""


def _hash_password(password: str, salt: str | None = None, iterations: int = 390000) -> str:
    salt = salt or secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", str(password or "").encode("utf-8"), salt.encode("utf-8"), iterations)
    digest = base64.urlsafe_b64encode(dk).decode("ascii")
    return f"pbkdf2_sha256${iterations}${salt}${digest}"


def _verify_password(password: str, stored: str) -> bool:
    try:
        alg, iter_s, salt, digest = str(stored or "").split("$", 3)
        if alg != "pbkdf2_sha256":
            return False
        calc = _hash_password(password, salt=salt, iterations=int(iter_s)).split("$", 3)[3]
        return hmac.compare_digest(calc, digest)
    except Exception:
        return False


def _seed_admin_if_needed() -> None:
    if not AUTH_ENABLED or not BOOTSTRAP_ADMIN_PASSWORD:
        return
    con = _db_conn()
    try:
        _ensure_tables(con)
        row = con.execute("SELECT COUNT(*) AS c FROM users").fetchone()
        if int(row["c"] or 0) == 0:
            now = _vm_timestamp()
            con.execute(
                """
                INSERT INTO users(username, password_hash, role, auth_source, active, created_at, updated_at)
                VALUES (?, ?, 'admin', 'local', 1, ?, ?)
                """,
                (BOOTSTRAP_ADMIN_USER, _hash_password(BOOTSTRAP_ADMIN_PASSWORD), now, now),
            )
            con.commit()
    finally:
        con.close()


def _session_cookie_secure(request: Request) -> bool:
    if SESSION_COOKIE_SECURE_RAW in {"1", "true", "yes", "on"}:
        return True
    if SESSION_COOKIE_SECURE_RAW in {"0", "false", "no", "off"}:
        return False
    forwarded = str(request.headers.get("x-forwarded-proto") or "").split(",", 1)[0].strip().lower()
    return forwarded == "https" or request.url.scheme == "https"


def _public_user_from_row(row: sqlite3.Row | dict[str, Any], csrf_token: str = "") -> dict[str, Any]:
    role = str(row["role"] or "admin")
    user = {
        "id": int(row["id"]),
        "username": str(row["username"]),
        "role": role,
        "roles": [role],
        "permissions": ["community:read", "connections:manage", "backups:run", "restores:run", "schedules:manage"],
        "edition": PRODUCT_EDITION,
    }
    if csrf_token:
        user["csrf_token"] = csrf_token
    return user


def _bootstrap_user(csrf_token: str = "") -> dict[str, Any]:
    return {
        "id": 1,
        "username": BOOTSTRAP_ADMIN_USER or "admin",
        "role": "admin",
        "roles": ["admin"],
        "permissions": ["community:read", "connections:manage", "backups:run", "restores:run", "schedules:manage"],
        "edition": PRODUCT_EDITION,
        **({"csrf_token": csrf_token} if csrf_token else {}),
    }


def _authenticate_db_user(username: str, password: str) -> dict[str, Any] | None:
    con = _db_conn()
    try:
        _ensure_tables(con)
        row = con.execute(
            """
            SELECT id, username, password_hash, role, auth_source, active
              FROM users
             WHERE lower(username) = lower(?)
             LIMIT 1
            """,
            (username,),
        ).fetchone()
        if not row or not bool(row["active"]):
            return None
        if str(row["auth_source"] or "local").lower() != "local":
            return None
        if not _verify_password(password, row["password_hash"]):
            return None
        now = _vm_timestamp()
        try:
            con.execute("UPDATE users SET last_login_at=?, updated_at=? WHERE id=?", (now, now, row["id"]))
            con.commit()
        except Exception:
            pass
        return _public_user_from_row(row)
    finally:
        con.close()


def _cleanup_sessions() -> None:
    now = int(time.time())
    for token in [t for t, row in _SESSIONS.items() if int(row.get("expires_at", 0)) <= now]:
        _SESSIONS.pop(token, None)


def _drop_sessions_for_user(user: dict[str, Any]) -> None:
    user_id = str(user.get("id") or "").strip()
    username = str(user.get("username") or "").strip().lower()
    for token, row in list(_SESSIONS.items()):
        session_user = row.get("user") or {}
        session_user_id = str(session_user.get("id") or "").strip()
        session_username = str(session_user.get("username") or "").strip().lower()
        if (user_id and session_user_id == user_id) or (username and session_username == username):
            _SESSIONS.pop(token, None)


def _session_from_request(request: Request) -> dict[str, Any] | None:
    if not AUTH_ENABLED:
        return {"user": _bootstrap_user(), "csrf_token": ""}
    _cleanup_sessions()
    token = request.cookies.get(SESSION_COOKIE_NAME) or ""
    if not token:
        return None
    row = _SESSIONS.get(token)
    if not row:
        return None
    row["expires_at"] = int(time.time()) + SESSION_TTL_SECONDS
    return row


def _require_session(request: Request) -> dict[str, Any]:
    _ensure_ready()
    session = _session_from_request(request)
    if not session:
        raise HTTPException(status_code=401, detail="Authentication required")
    return session


def _community_payload() -> dict[str, Any]:
    return {"edition": PRODUCT_EDITION, "runtime": COMMUNITY_RUNTIME_MODE, "status": "ok"}


def _version_payload() -> dict[str, Any]:
    payload = dict(get_version_payload()) if get_version_payload else {"product": "DBAegis", "version": "1.0.0"}
    payload["edition"] = PRODUCT_EDITION
    payload["community_runtime"] = COMMUNITY_RUNTIME_MODE
    payload["community_databases"] = sorted(SUPPORTED_DB_TYPES)
    return payload


def _license_payload() -> dict[str, Any]:
    if current_license_status:
        try:
            status = current_license_status()
            payload = dict(status.public_dict()) if callable(getattr(status, "public_dict", None)) else dict(status)
        except Exception:
            payload = {}
    else:
        payload = {}
    payload.setdefault("required", False)
    payload.setdefault("valid", True)
    payload.setdefault("edition", PRODUCT_EDITION)
    payload.setdefault("features", ["backups.local", "restores.local", "schedules", "retention"])
    payload.setdefault("limits", {"connections": MAX_CONNECTIONS, "users": 1, "schedules": MAX_SCHEDULES, "storage_destinations": 1})
    payload.setdefault("databases", sorted(SUPPORTED_DB_TYPES))
    return payload


def _normalize_db_type(value: Any) -> str:
    db_type = str(value or "").strip().lower().replace("-", "_")
    db_type = DB_TYPE_ALIASES.get(db_type, db_type)
    if db_type not in SUPPORTED_DB_TYPES:
        raise HTTPException(status_code=400, detail="Community supports PostgreSQL, MySQL, and MongoDB only")
    return db_type


def _int_value(value: Any, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return default


def _default_port(db_type: str) -> int:
    return {"postgresql": 5432, "mysql": 3306, "mongodb": 27017}[db_type]


def _conn_from_row(row: sqlite3.Row | dict[str, Any], include_secret: bool = False) -> dict[str, Any]:
    options = _json(row["options_json"] if "options_json" in row.keys() else "{}", {})
    raw_db_type = str(row["db_type"] or "").strip().lower()
    db_type = DB_TYPE_ALIASES.get(raw_db_type, raw_db_type)
    community_supported = db_type in SUPPORTED_DB_TYPES
    password = _decrypt_secret(row["password"]) if include_secret else ""
    data = {
        "id": int(row["id"]),
        "name": row["name"],
        "db_type": db_type,
        "community_supported": community_supported,
        "tags": row["tags"] if "tags" in row.keys() else "",
        "host": row["host"] or "127.0.0.1",
        "port": row["port"] or (_default_port(db_type) if community_supported else 0),
        "username": row["username"] or "",
        "password": password,
        "has_password": bool(row["password"]),
        "database_name": row["database_name"] or "",
        "database": row["database_name"] or "",
        "backup_type": row["backup_type"] or "logical",
        "destination": row["destination"] or "dbaegis_local",
        "status": "unsupported" if not community_supported else (row["status"] or "unknown"),
        "options": options,
        "options_json": json.dumps(options),
        "created_at": row["created_at"] if "created_at" in row.keys() else "",
        "updated_at": row["updated_at"] if "updated_at" in row.keys() else "",
    }
    return data


def _get_connection(con: sqlite3.Connection, connection_id: int, include_secret: bool = False) -> dict[str, Any]:
    _ensure_tables(con)
    row = con.execute("SELECT * FROM connections WHERE id=?", (connection_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Connection not found")
    return _conn_from_row(row, include_secret=include_secret)


def _connection_payload(payload: dict[str, Any], existing: dict[str, Any] | None = None) -> dict[str, Any]:
    db_type = _normalize_db_type(payload.get("db_type") or payload.get("type") or (existing or {}).get("db_type"))
    database = str(payload.get("database_name") or payload.get("database") or (existing or {}).get("database_name") or "").strip()
    if not database:
        raise HTTPException(status_code=400, detail="Database name is required")
    backup_type = str(payload.get("backup_type") or (existing or {}).get("backup_type") or "logical").lower()
    if backup_type != "logical":
        raise HTTPException(status_code=400, detail="Community supports logical backups only")
    destination = str(payload.get("destination") or payload.get("default_destination") or (existing or {}).get("destination") or "dbaegis_local")
    if destination not in {"", "local", "dbaegis", "dbaegis_local"}:
        raise HTTPException(status_code=400, detail="Community supports DBAegis-local storage only")
    incoming_password = payload.get("password")
    if incoming_password in (None, "") and existing:
        stored_password = existing.get("_stored_password", "")
    else:
        stored_password = _encrypt_secret(incoming_password or "")
    return {
        "name": str(payload.get("name") or payload.get("connection_name") or (existing or {}).get("name") or database).strip(),
        "db_type": db_type,
        "tags": str(payload.get("tags") or (existing or {}).get("tags") or ""),
        "host": str(payload.get("host") or (existing or {}).get("host") or "127.0.0.1").strip(),
        "port": _int_value(payload.get("port") or (existing or {}).get("port"), _default_port(db_type)),
        "username": str(payload.get("username") or (existing or {}).get("username") or "").strip(),
        "password": stored_password,
        "database_name": database,
        "backup_type": "logical",
        "destination": "dbaegis_local",
        "options_json": json.dumps(payload.get("options") or payload.get("logical_options") or {}),
    }


def _redact_command(cmd: list[str]) -> str:
    redacted = []
    skip_next = False
    for part in cmd:
        if skip_next:
            redacted.append("******")
            skip_next = False
            continue
        text = str(part)
        if text in {"--password", "-p"}:
            redacted.append(text)
            skip_next = True
        elif "password=" in text.lower() or "://" in text and "@" in text:
            redacted.append("<redacted>")
        else:
            redacted.append(text)
    return " ".join(redacted)


def _tool_path(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"Required Community tool not found: {name}")
    return path


def _connection_env(conn: dict[str, Any]) -> dict[str, str]:
    env = os.environ.copy()
    password = conn.get("password") or ""
    if password and conn["db_type"] == "postgresql":
        env["PGPASSWORD"] = password
    if password and conn["db_type"] == "mysql":
        env["MYSQL_PWD"] = password
    return env


def _mongo_tool_env() -> dict[str, str]:
    env = os.environ.copy()
    home = os.environ.get("DBAEGIS_TEMP_DIR") or os.environ.get("TMPDIR") or "/tmp"
    Path(home).mkdir(parents=True, exist_ok=True)
    env["HOME"] = home
    return env


def _postgres_base_args(conn: dict[str, Any]) -> list[str]:
    args = ["--host", conn["host"], "--port", str(conn["port"])]
    if conn.get("username"):
        args += ["--username", conn["username"]]
    return args


def _mysql_base_args(conn: dict[str, Any]) -> list[str]:
    args = ["--host", conn["host"], "--port", str(conn["port"]), "--protocol", "tcp"]
    if conn.get("username"):
        args += ["--user", conn["username"]]
    return args


def _mongo_auth_args(conn: dict[str, Any]) -> list[str]:
    args = ["--host", conn["host"], "--port", str(conn["port"])]
    has_auth = bool(conn.get("username") or conn.get("password"))
    if conn.get("username"):
        args += ["--username", conn["username"]]
    if conn.get("password"):
        args += ["--password", conn["password"]]
    auth_db = (conn.get("options") or {}).get("auth_database") or "admin"
    if has_auth and auth_db:
        args += ["--authenticationDatabase", str(auth_db)]
    return args


def _backup_path(conn: dict[str, Any], payload: dict[str, Any]) -> Path:
    prefix = str(payload.get("filename_prefix") or "").strip()
    safe_name = "".join(ch if ch.isalnum() or ch in {"-", "_"} else "_" for ch in (prefix + conn["name"]))[:80]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    root = Path(_backup_dir()) / "community" / conn["db_type"]
    root.mkdir(parents=True, exist_ok=True)
    if conn["db_type"] == "mongodb":
        suffix = ".archive.gz"
    else:
        compression_level = str((payload.get("logical_options") or {}).get("compression_level") or "").strip().lower()
        no_compress = compression_level in {"none", "off", "0"}
        suffix = ".sql" if no_compress else ".sql.gz"
    return root / f"{safe_name}_{stamp}{suffix}"


def _stream_stdout_to_file(cmd: list[str], path: Path, env: dict[str, str], gzip_output: bool) -> tuple[int, str, str]:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    timer = threading.Timer(BACKUP_TIMEOUT_SECONDS, proc.kill)
    stderr_chunks: list[bytes] = []

    def read_stderr() -> None:
        if proc.stderr:
            stderr_chunks.append(proc.stderr.read())

    stderr_thread = threading.Thread(target=read_stderr, daemon=True)
    stderr_thread.start()
    timer.start()
    opener = gzip.open if gzip_output else open
    try:
        with opener(path, "wb") as fh:
            assert proc.stdout is not None
            for chunk in iter(lambda: proc.stdout.read(1024 * 1024), b""):
                fh.write(chunk)
        rc = proc.wait(timeout=BACKUP_TIMEOUT_SECONDS)
    except Exception:
        proc.kill()
        raise
    finally:
        timer.cancel()
        stderr_thread.join(timeout=2)
    stderr = b"".join(stderr_chunks).decode("utf-8", "replace")
    return rc, "", stderr


def _run_capture(cmd: list[str], env: dict[str, str] | None = None, stdin_file: Path | None = None) -> tuple[int, str, str]:
    if stdin_file:
        opener = gzip.open if str(stdin_file).endswith(".gz") else open
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        timer = threading.Timer(BACKUP_TIMEOUT_SECONDS, proc.kill)
        stdout_chunks: list[bytes] = []
        stderr_chunks: list[bytes] = []

        def read_stream(stream, chunks: list[bytes]) -> None:
            if stream:
                with stream:
                    chunks.append(stream.read())

        stdout_thread = threading.Thread(target=read_stream, args=(proc.stdout, stdout_chunks), daemon=True)
        stderr_thread = threading.Thread(target=read_stream, args=(proc.stderr, stderr_chunks), daemon=True)
        stdout_thread.start()
        stderr_thread.start()
        timer.start()
        try:
            with opener(stdin_file, "rb") as fh:
                assert proc.stdin is not None
                shutil.copyfileobj(fh, proc.stdin, length=1024 * 1024)
                proc.stdin.close()
            rc = proc.wait(timeout=BACKUP_TIMEOUT_SECONDS)
        except Exception:
            proc.kill()
            raise
        finally:
            timer.cancel()
            stdout_thread.join(timeout=2)
            stderr_thread.join(timeout=2)
        return (
            int(rc),
            b"".join(stdout_chunks).decode("utf-8", "replace"),
            b"".join(stderr_chunks).decode("utf-8", "replace"),
        )

    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=BACKUP_TIMEOUT_SECONDS)
    return (
        int(result.returncode),
        result.stdout.decode("utf-8", "replace"),
        result.stderr.decode("utf-8", "replace"),
    )


def _backup_command(conn: dict[str, Any], path: Path) -> tuple[list[str], dict[str, str], bool, bool]:
    if conn["db_type"] == "postgresql":
        cmd = [_tool_path("pg_dump"), *_postgres_base_args(conn), "--dbname", conn["database_name"]]
        return cmd, _connection_env(conn), str(path).endswith(".gz"), False
    if conn["db_type"] == "mysql":
        cmd = [_tool_path("mysqldump"), *_mysql_base_args(conn), "--single-transaction", "--routines", "--triggers", conn["database_name"]]
        return cmd, _connection_env(conn), str(path).endswith(".gz"), False
    if conn["db_type"] != "mongodb":
        raise RuntimeError("Community supports backups only for PostgreSQL, MySQL, and MongoDB")
    cmd = [
        _tool_path("mongodump"),
        *_mongo_auth_args(conn),
        "--db",
        conn["database_name"],
        f"--archive={path}",
        "--gzip",
    ]
    return cmd, _mongo_tool_env(), False, True


def _restore_command(conn: dict[str, Any], source_path: Path, overwrite: bool) -> tuple[list[str], dict[str, str], bool]:
    if conn["db_type"] == "postgresql":
        cmd = [_tool_path("psql"), *_postgres_base_args(conn), "--dbname", conn["database_name"], "--set", "ON_ERROR_STOP=on"]
        return cmd, _connection_env(conn), True
    if conn["db_type"] == "mysql":
        cmd = [_tool_path("mysql"), *_mysql_base_args(conn), conn["database_name"]]
        return cmd, _connection_env(conn), True
    if conn["db_type"] != "mongodb":
        raise RuntimeError("Community supports restores only for PostgreSQL, MySQL, and MongoDB")
    cmd = [_tool_path("mongorestore"), *_mongo_auth_args(conn), f"--archive={source_path}", "--gzip"]
    if overwrite:
        cmd.append("--drop")
    return cmd, _mongo_tool_env(), False


def _update_backup(backup_id: int, **fields: Any) -> None:
    con = _db_conn()
    try:
        assignments = ", ".join(f"{k}=?" for k in fields)
        con.execute(f"UPDATE backups SET {assignments} WHERE id=?", [*fields.values(), backup_id])
        con.commit()
    finally:
        con.close()


def _append_backup_log(backup_id: int, text: str) -> None:
    con = _db_conn()
    try:
        row = con.execute("SELECT engine_log FROM backups WHERE id=?", (backup_id,)).fetchone()
        current = row["engine_log"] if row else ""
        joined = (current + "\n" + text).strip() if current else text
        con.execute("UPDATE backups SET engine_log=? WHERE id=?", (joined, backup_id))
        con.commit()
    finally:
        con.close()


def _run_backup_job(backup_id: int) -> None:
    con = _db_conn()
    try:
        _ensure_tables(con)
        backup = con.execute("SELECT * FROM backups WHERE id=?", (backup_id,)).fetchone()
        if not backup:
            return
        conn = _get_connection(con, int(backup["connection_id"]), include_secret=True)
        payload = _json(backup["notes"], {})
    finally:
        con.close()
    path = _backup_path(conn, payload)
    try:
        cmd, env, gzip_output, direct_file = _backup_command(conn, path)
        _append_backup_log(backup_id, f"[{_vm_timestamp()}] Starting Community {conn['db_type']} logical backup")
        _update_backup(backup_id, file_path=str(path), target_uri=str(path), command_text=_redact_command(cmd))
        if direct_file:
            rc, stdout, stderr = _run_capture(cmd, env=env)
        else:
            rc, stdout, stderr = _stream_stdout_to_file(cmd, path, env, gzip_output=gzip_output)
        size = path.stat().st_size if path.exists() else 0
        status = "success" if rc == 0 else "failed"
        error = "" if rc == 0 else (stderr or stdout or f"Command exited with {rc}")[:4000]
        _update_backup(
            backup_id,
            status=status,
            size_bytes=size,
            error_msg=error,
            stdout_log=stdout[-12000:],
            stderr_log=stderr[-12000:],
            exit_code=rc,
            finished_at=_vm_timestamp(),
        )
        _append_backup_log(backup_id, f"[{_vm_timestamp()}] Backup {status}; size={size} bytes")
        if rc == 0:
            _apply_retention(conn["id"], int(backup["retention_days"] or 0), int(backup["retention_count"] or 0))
    except Exception as exc:
        _update_backup(backup_id, status="failed", error_msg=str(exc), finished_at=_vm_timestamp())
        _append_backup_log(backup_id, f"[{_vm_timestamp()}] Backup failed: {exc}")


def _apply_retention(connection_id: int, retention_days: int, retention_count: int) -> None:
    con = _db_conn()
    try:
        rows = con.execute(
            "SELECT id, file_path, started_at FROM backups WHERE connection_id=? AND status='success' ORDER BY id DESC",
            (connection_id,),
        ).fetchall()
        delete_ids: set[int] = set()
        if retention_count > 0:
            delete_ids.update(int(r["id"]) for r in rows[retention_count:])
        if retention_days > 0:
            cutoff = datetime.now() - timedelta(days=retention_days)
            for row in rows:
                try:
                    started = datetime.strptime(str(row["started_at"]), "%Y-%m-%d %H:%M:%S")
                except Exception:
                    continue
                if started < cutoff:
                    delete_ids.add(int(row["id"]))
        for row in rows:
            if int(row["id"]) not in delete_ids:
                continue
            path = row["file_path"] or ""
            if path and os.path.exists(path):
                try:
                    os.remove(path)
                except Exception:
                    pass
            con.execute("DELETE FROM backups WHERE id=?", (int(row["id"]),))
        con.commit()
    finally:
        con.close()


def _update_restore(job_id: int, **fields: Any) -> None:
    con = _db_conn()
    try:
        fields.setdefault("updated_at", _vm_timestamp())
        assignments = ", ".join(f"{k}=?" for k in fields)
        con.execute(f"UPDATE restore_jobs SET {assignments} WHERE id=?", [*fields.values(), job_id])
        con.commit()
    finally:
        con.close()


def _append_restore_log(job_id: int, text: str) -> None:
    con = _db_conn()
    try:
        row = con.execute("SELECT log FROM restore_jobs WHERE id=?", (job_id,)).fetchone()
        current = row["log"] if row else ""
        joined = (current + "\n" + text).strip() if current else text
        con.execute("UPDATE restore_jobs SET log=?, updated_at=? WHERE id=?", (joined, _vm_timestamp(), job_id))
        con.commit()
    finally:
        con.close()


def _run_restore_job(job_id: int) -> None:
    con = _db_conn()
    try:
        _ensure_tables(con)
        job = con.execute("SELECT * FROM restore_jobs WHERE id=?", (job_id,)).fetchone()
        if not job:
            return
        conn = _get_connection(con, int(job["target_connection_id"] or job["connection_id"]), include_secret=True)
        options = _json(job["options_json"], {})
    finally:
        con.close()
    source = Path(job["source_path"] or "")
    try:
        if not source.is_file():
            raise RuntimeError(f"Restore source file not found: {source}")
        cmd, env, stdin_file = _restore_command(conn, source, bool(options.get("overwrite") or options.get("overwrite_existing")))
        _append_restore_log(job_id, f"[{_vm_timestamp()}] Starting Community {conn['db_type']} logical restore")
        _append_restore_log(job_id, "Command: " + _redact_command(cmd))
        if stdin_file:
            rc, stdout, stderr = _run_capture(cmd, env=env, stdin_file=source)
        else:
            rc, stdout, stderr = _run_capture(cmd, env=env)
        status = "success" if rc == 0 else "failed"
        error = "" if rc == 0 else (stderr or stdout or f"Command exited with {rc}")[:4000]
        log = "\n".join(p for p in [stdout[-12000:], stderr[-12000:]] if p)
        _update_restore(job_id, status=status, error_msg=error, log=log or f"Restore {status}")
    except Exception as exc:
        _update_restore(job_id, status="failed", error_msg=str(exc))
        _append_restore_log(job_id, f"[{_vm_timestamp()}] Restore failed: {exc}")


def _backup_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": int(row["id"]),
        "connection_id": int(row["connection_id"]),
        "status": row["status"] or "running",
        "destination": row["destination"] or "dbaegis_local",
        "file_path": row["file_path"] or "",
        "target_uri": row["target_uri"] or row["file_path"] or "",
        "size_bytes": int(row["size_bytes"] or 0),
        "error_msg": row["error_msg"] or "",
        "started_at": row["started_at"] or "",
        "finished_at": row["finished_at"] or "",
        "completed_at": row["finished_at"] or "",
        "backup_type": row["backup_type"] or "logical",
        "engine_log": row["engine_log"] or "",
        "command_text": row["command_text"] or "",
        "exit_code": row["exit_code"],
        "dismissed_at": row["dismissed_at"] if "dismissed_at" in row.keys() else "",
        "dismissed_by_user_id": row["dismissed_by_user_id"] if "dismissed_by_user_id" in row.keys() else None,
        "dismissed_by_username": row["dismissed_by_username"] if "dismissed_by_username" in row.keys() else "",
    }


def _restore_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": int(row["id"]),
        "connection_id": row["connection_id"],
        "target_connection_id": row["target_connection_id"] if "target_connection_id" in row.keys() else row["connection_id"],
        "db_type": row["db_type"] or "",
        "source_path": row["source_path"] or "",
        "backup_id": row["backup_id"],
        "restore_mode": row["restore_mode"] or "logical",
        "status": row["status"] or "pending",
        "log": row["log"] or "",
        "error_msg": row["error_msg"] or "",
        "dismissed_at": row["dismissed_at"] if "dismissed_at" in row.keys() else "",
        "dismissed_by_user_id": row["dismissed_by_user_id"] if "dismissed_by_user_id" in row.keys() else None,
        "dismissed_by_username": row["dismissed_by_username"] if "dismissed_by_username" in row.keys() else "",
        "created_at": row["created_at"] or "",
        "updated_at": row["updated_at"] or "",
    }


def _schedule_next_run(cron_expr: str | None) -> str:
    text = str(cron_expr or "").strip()
    if not text or croniter is None:
        return ""
    try:
        return croniter(text, datetime.now().replace(second=0, microsecond=0)).get_next(datetime).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return ""


def _schedule_row(row: sqlite3.Row) -> dict[str, Any]:
    options = _json(row["options_json"], {})
    return {
        "id": int(row["id"]),
        "connection_id": int(row["connection_id"]),
        "name": row["name"] or "",
        "frequency": row["frequency"] or "daily",
        "cron_expr": row["cron_expr"] or "",
        "destination": row["destination"] or "dbaegis_local",
        "retention_days": int(row["retention_days"] or 0),
        "retention_count": int(row["retention_count"] or 0),
        "active": bool(row["active"]),
        "options": options,
        "options_json": json.dumps(options),
        "last_run_at": row["last_run_at"] or "",
        "next_run_at": row["next_run_at"] or "",
        "created_at": row["created_at"] or "",
        "updated_at": row["updated_at"] or "",
    }


def _start_backup(connection_id: int, payload: dict[str, Any]) -> dict[str, Any]:
    con = _db_conn()
    try:
        _ensure_tables(con)
        conn = _get_connection(con, connection_id, include_secret=False)
        backup_type = str(payload.get("backup_type") or conn.get("backup_type") or "logical").lower()
        if backup_type != "logical":
            raise HTTPException(status_code=400, detail="Community supports logical backups only")
        if str(payload.get("destination") or "dbaegis_local") not in {"", "local", "dbaegis", "dbaegis_local"}:
            raise HTTPException(status_code=400, detail="Community supports DBAegis-local storage only")
        now = _vm_timestamp()
        cur = con.execute(
            """
            INSERT INTO backups(connection_id, status, destination, started_at, backup_type, notes, retention_days, retention_count)
            VALUES (?, 'running', 'dbaegis_local', ?, 'logical', ?, ?, ?)
            """,
            (
                connection_id,
                now,
                json.dumps(payload),
                _int_value(payload.get("retention_days"), 0),
                _int_value(payload.get("retention_count"), 0),
            ),
        )
        con.commit()
        backup_id = int(cur.lastrowid)
    finally:
        con.close()
    threading.Thread(target=_run_backup_job, args=(backup_id,), daemon=True).start()
    return {"id": backup_id, "backup_id": backup_id, "status": "running", "detail": "Backup started"}


def _run_schedule_backup(schedule_id: int) -> dict[str, Any]:
    con = _db_conn()
    try:
        _ensure_tables(con)
        row = con.execute("SELECT * FROM schedules WHERE id=?", (schedule_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Schedule not found")
        payload = {
            "connection_id": int(row["connection_id"]),
            "destination": "dbaegis_local",
            "retention_days": int(row["retention_days"] or 0),
            "retention_count": int(row["retention_count"] or 0),
            **_json(row["options_json"], {}),
        }
        now = _vm_timestamp()
        next_run = _schedule_next_run(row["cron_expr"])
        con.execute("UPDATE schedules SET last_run_at=?, next_run_at=?, updated_at=? WHERE id=?", (now, next_run, now, schedule_id))
        con.commit()
    finally:
        con.close()
    return _start_backup(int(payload["connection_id"]), payload)


def _scheduler_loop() -> None:
    while not _SCHEDULER_STOP.wait(30):
        con = _db_conn()
        try:
            _ensure_tables(con)
            now = _vm_timestamp()
            rows = con.execute(
                "SELECT id FROM schedules WHERE active=1 AND cron_expr <> '' AND (next_run_at IS NULL OR next_run_at='' OR next_run_at <= ?)",
                (now,),
            ).fetchall()
        finally:
            con.close()
        for row in rows:
            try:
                _run_schedule_backup(int(row["id"]))
            except Exception:
                pass


def _ensure_ready() -> None:
    global _READY, _SCHEDULER_THREAD
    if _READY:
        return
    with _READY_LOCK:
        if _READY:
            return
        _ensure_tables()
        _seed_admin_if_needed()
        if _SCHEDULER_THREAD is None or not _SCHEDULER_THREAD.is_alive():
            _SCHEDULER_STOP.clear()
            _SCHEDULER_THREAD = threading.Thread(target=_scheduler_loop, daemon=True)
            _SCHEDULER_THREAD.start()
        _READY = True


@app.get("/")
def root():
    _ensure_ready()
    return _community_payload()


@app.get("/health")
def health():
    _ensure_ready()
    return _community_payload()


@app.get("/api/health")
def api_health():
    _ensure_ready()
    payload = _community_payload()
    payload["version"] = _version_payload().get("version")
    payload["database_path"] = _db_path()
    payload["backup_dir"] = _backup_dir()
    return payload


@app.get("/api/version")
def api_version():
    return _version_payload()


@app.get("/api/license/status")
def api_license_status():
    _ensure_ready()
    return _license_payload()


@app.get("/api/support/matrix")
def support_matrix():
    return {
        "edition": PRODUCT_EDITION,
        "databases": {
            "postgresql": {"backup": ["logical"], "restore": ["logical"], "storage": ["dbaegis_local"]},
            "mysql": {"backup": ["logical"], "restore": ["logical"], "storage": ["dbaegis_local"]},
            "mongodb": {"backup": ["logical"], "restore": ["logical"], "storage": ["dbaegis_local"]},
        },
        "unsupported": ["cloud storage", "db-server-local storage", "physical backup", "physical restore"],
    }


@app.post("/api/auth/login")
async def auth_login(request: Request, response: Response):
    if not AUTH_ENABLED:
        return {"authenticated": True, "auth_enabled": False, "user": _bootstrap_user()}
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    username = str(payload.get("username") or payload.get("user") or "")
    password = str(payload.get("password") or "")
    user = _authenticate_db_user(username, password)
    if user is None and BOOTSTRAP_ADMIN_PASSWORD:
        if hmac.compare_digest(username, BOOTSTRAP_ADMIN_USER) and hmac.compare_digest(password, BOOTSTRAP_ADMIN_PASSWORD):
            user = _bootstrap_user()
    if user is None:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = secrets.token_urlsafe(32)
    csrf_token = secrets.token_urlsafe(24)
    user["csrf_token"] = csrf_token
    _cleanup_sessions()
    _drop_sessions_for_user(user)
    _SESSIONS[token] = {"user": user, "csrf_token": csrf_token, "expires_at": int(time.time()) + SESSION_TTL_SECONDS}
    response.set_cookie(
        SESSION_COOKIE_NAME,
        token,
        httponly=True,
        secure=_session_cookie_secure(request),
        samesite="lax",
        max_age=SESSION_TTL_SECONDS,
    )
    return {"authenticated": True, "user": user, "csrf_token": csrf_token}


@app.get("/api/auth/me")
def auth_me(request: Request):
    session = _session_from_request(request)
    if not session:
        raise HTTPException(status_code=401, detail="Authentication required")
    return {"authenticated": True, "auth_enabled": AUTH_ENABLED, "user": session["user"]}


@app.post("/api/auth/logout")
def auth_logout(request: Request, response: Response):
    token = request.cookies.get(SESSION_COOKIE_NAME) or ""
    if token:
        _SESSIONS.pop(token, None)
    response.delete_cookie(SESSION_COOKIE_NAME)
    return {"authenticated": False}


@app.get("/api/auth/settings")
def auth_settings(request: Request):
    _require_session(request)
    return {"enabled": False, "provider": "local", "ldap_enabled": False, "edition": PRODUCT_EDITION}


@app.get("/api/auth/mfa/settings")
def mfa_settings(request: Request):
    _require_session(request)
    return {"enabled": False, "available": False, "edition": PRODUCT_EDITION}


@app.get("/api/connections")
@app.get("/api/connections/")
def list_connections(request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        _ensure_tables(con)
        rows = con.execute("SELECT * FROM connections ORDER BY id DESC").fetchall()
        return [_conn_from_row(row) for row in rows]
    finally:
        con.close()


@app.post("/api/connections")
@app.post("/api/connections/")
async def create_connection(request: Request):
    _require_session(request)
    payload = await request.json()
    con = _db_conn()
    try:
        _ensure_tables(con)
        count = int(con.execute("SELECT COUNT(*) AS c FROM connections").fetchone()["c"] or 0)
        if count >= MAX_CONNECTIONS:
            raise HTTPException(status_code=403, detail=f"Community is limited to {MAX_CONNECTIONS} active connections")
        data = _connection_payload(payload)
        now = _vm_timestamp()
        cur = con.execute(
            """
            INSERT INTO connections(name, db_type, tags, host, port, username, password, database_name, backup_type, destination, status, options_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'logical', 'dbaegis_local', 'unknown', ?, ?, ?)
            """,
            (
                data["name"],
                data["db_type"],
                data["tags"],
                data["host"],
                data["port"],
                data["username"],
                data["password"],
                data["database_name"],
                data["options_json"],
                now,
                now,
            ),
        )
        con.commit()
        return _get_connection(con, int(cur.lastrowid))
    finally:
        con.close()


@app.get("/api/connections/{connection_id:int}")
def get_connection(connection_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        return _get_connection(con, connection_id)
    finally:
        con.close()


@app.put("/api/connections/{connection_id:int}")
async def update_connection(connection_id: int, request: Request):
    _require_session(request)
    payload = await request.json()
    con = _db_conn()
    try:
        current = _get_connection(con, connection_id, include_secret=False)
        row = con.execute("SELECT password FROM connections WHERE id=?", (connection_id,)).fetchone()
        current["_stored_password"] = row["password"] if row else ""
        data = _connection_payload(payload, existing=current)
        now = _vm_timestamp()
        con.execute(
            """
            UPDATE connections
               SET name=?, db_type=?, tags=?, host=?, port=?, username=?, password=?, database_name=?,
                   backup_type='logical', destination='dbaegis_local', options_json=?, updated_at=?
             WHERE id=?
            """,
            (
                data["name"],
                data["db_type"],
                data["tags"],
                data["host"],
                data["port"],
                data["username"],
                data["password"],
                data["database_name"],
                data["options_json"],
                now,
                connection_id,
            ),
        )
        con.commit()
        return _get_connection(con, connection_id)
    finally:
        con.close()


@app.delete("/api/connections/{connection_id:int}")
def delete_connection(connection_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        _ensure_tables(con)
        con.execute("DELETE FROM connections WHERE id=?", (connection_id,))
        con.commit()
        return {"detail": "Connection deleted", "id": connection_id}
    finally:
        con.close()


def _test_connection_payload(payload: dict[str, Any]) -> dict[str, Any]:
    data = _connection_payload(payload)
    data["password"] = _decrypt_secret(data["password"])
    if data["db_type"] == "postgresql":
        cmd = [_tool_path("pg_isready"), *_postgres_base_args(data), "--dbname", data["database_name"]]
        rc, stdout, stderr = _run_capture(cmd, env=_connection_env(data))
    elif data["db_type"] == "mysql":
        cmd = [_tool_path("mysqladmin"), *_mysql_base_args(data), "ping"]
        rc, stdout, stderr = _run_capture(cmd, env=_connection_env(data))
    else:
        code = "db.runCommand({ping: 1})"
        uri = f"mongodb://{urllib.parse.quote(data['username'])}:{urllib.parse.quote(data['password'])}@{data['host']}:{data['port']}/{data['database_name']}" if data.get("username") else f"mongodb://{data['host']}:{data['port']}/{data['database_name']}"
        cmd = [_tool_path("mongosh"), uri, "--quiet", "--eval", code]
        rc, stdout, stderr = _run_capture(cmd, env=_mongo_tool_env())
    if rc != 0:
        raise HTTPException(status_code=400, detail=(stderr or stdout or "Connection test failed").strip())
    return {"detail": "Connection OK", "status": "connected", "stdout": stdout[-2000:]}


@app.post("/api/connections/test")
async def test_connection_payload(request: Request):
    _require_session(request)
    return _test_connection_payload(await request.json())


@app.post("/api/connections/{connection_id:int}/test")
def test_connection(connection_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        conn = _get_connection(con, connection_id, include_secret=True)
        result = _test_connection_payload(conn)
        con.execute("UPDATE connections SET status='connected', updated_at=? WHERE id=?", (_vm_timestamp(), connection_id))
        con.commit()
        return result
    except HTTPException:
        try:
            con.execute("UPDATE connections SET status='failed', updated_at=? WHERE id=?", (_vm_timestamp(), connection_id))
            con.commit()
        except Exception:
            pass
        raise
    finally:
        con.close()


@app.post("/api/connections/{connection_id:int}/precheck")
def precheck_connection(connection_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        conn = _get_connection(con, connection_id)
    finally:
        con.close()
    tools = {
        "postgresql": ["pg_dump", "psql", "pg_isready"],
        "mysql": ["mysqldump", "mysql", "mysqladmin"],
        "mongodb": ["mongodump", "mongorestore", "mongosh"],
    }[conn["db_type"]]
    checks = [{"name": tool, "status": "ok" if shutil.which(tool) else "failed", "message": shutil.which(tool) or "not found"} for tool in tools]
    return {"status": "ok" if all(c["status"] == "ok" for c in checks) else "warning", "checks": checks}


@app.get("/api/storage")
@app.get("/api/storage/")
@app.get("/api/storage-destinations")
@app.get("/api/storage-destinations/")
def list_storage(request: Request):
    _require_session(request)
    return [
        {
            "id": "dbaegis_local",
            "name": "DBAegis local",
            "storage_type": "dbaegis_local",
            "dest_type": "dbaegis_local",
            "active": True,
            "path": _backup_dir(),
        }
    ]


@app.get("/api/backups")
@app.get("/api/backups/")
def list_backups(request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        _ensure_tables(con)
        rows = con.execute("SELECT * FROM backups ORDER BY id DESC LIMIT 500").fetchall()
        return [_backup_row(row) for row in rows]
    finally:
        con.close()


@app.post("/api/backups")
@app.post("/api/backups/")
async def start_backup(request: Request):
    _require_session(request)
    payload = await request.json()
    connection_id = _int_value(payload.get("connection_id"), 0)
    if connection_id <= 0:
        raise HTTPException(status_code=400, detail="connection_id is required")
    return _start_backup(connection_id, payload)


@app.post("/api/connections/{connection_id:int}/backup")
async def start_connection_backup(connection_id: int, request: Request):
    _require_session(request)
    payload = await request.json()
    payload["connection_id"] = connection_id
    return _start_backup(connection_id, payload)


@app.get("/api/backups/{backup_id:int}/log")
def backup_log(backup_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        row = con.execute("SELECT * FROM backups WHERE id=?", (backup_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Backup not found")
        data = _backup_row(row)
        data["log"] = data["engine_log"] or data["stderr_log"] or data["stdout_log"] or f"Status: {data['status']}"
        return data
    finally:
        con.close()


@app.delete("/api/backups/{backup_id:int}")
def delete_backup(backup_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        row = con.execute("SELECT file_path FROM backups WHERE id=?", (backup_id,)).fetchone()
        if row and row["file_path"] and os.path.exists(row["file_path"]):
            try:
                os.remove(row["file_path"])
            except Exception:
                pass
        con.execute("DELETE FROM backups WHERE id=?", (backup_id,))
        con.commit()
        return {"detail": "Backup deleted", "id": backup_id}
    finally:
        con.close()


@app.post("/api/backups/{backup_id:int}/dismiss")
def dismiss_backup(backup_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        _ensure_tables(con)
        row = con.execute("SELECT id, status FROM backups WHERE id=?", (backup_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Backup not found")
        status = str(row["status"] or "").lower()
        if status not in {"failed", "error"}:
            raise HTTPException(status_code=400, detail="Only failed backup jobs can be dismissed")
        dismissed_at = _vm_timestamp()
        con.execute(
            "UPDATE backups SET dismissed_at=?, dismissed_by_username=? WHERE id=?",
            (dismissed_at, "operator", backup_id),
        )
        con.commit()
        return {
            "detail": "Failed backup job dismissed; audit history retained",
            "id": backup_id,
            "status": "failed",
            "dismissed_at": dismissed_at,
            "dismissed_by_username": "operator",
        }
    finally:
        con.close()


@app.get("/api/restore/jobs")
@app.get("/api/restore/jobs/")
def list_restore_jobs(request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        rows = con.execute("SELECT * FROM restore_jobs ORDER BY id DESC LIMIT 500").fetchall()
        return [_restore_row(row) for row in rows]
    finally:
        con.close()


@app.post("/api/restore")
@app.post("/api/restore/")
async def create_restore(request: Request):
    _require_session(request)
    payload = await request.json()
    con = _db_conn()
    try:
        _ensure_tables(con)
        backup_id = _int_value(payload.get("backup_id"), 0)
        source_path = str(payload.get("source_path") or payload.get("custom_file_path") or "")
        connection_id = _int_value(payload.get("target_connection_id") or payload.get("connection_id"), 0)
        if backup_id:
            backup = con.execute("SELECT * FROM backups WHERE id=?", (backup_id,)).fetchone()
            if not backup:
                raise HTTPException(status_code=404, detail="Backup not found")
            source_path = source_path or backup["file_path"]
            connection_id = connection_id or int(backup["connection_id"])
        if not source_path:
            raise HTTPException(status_code=400, detail="Restore source path is required")
        conn = _get_connection(con, connection_id)
        if str(payload.get("restore_mode") or "logical").lower() != "logical":
            raise HTTPException(status_code=400, detail="Community supports logical restores only")
        now = _vm_timestamp()
        cur = con.execute(
            """
            INSERT INTO restore_jobs(connection_id, target_connection_id, db_type, source_path, backup_id, restore_mode, options_json, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 'logical', ?, 'running', ?, ?)
            """,
            (connection_id, connection_id, conn["db_type"], source_path, backup_id or None, json.dumps(payload), now, now),
        )
        con.commit()
        job_id = int(cur.lastrowid)
    finally:
        con.close()
    threading.Thread(target=_run_restore_job, args=(job_id,), daemon=True).start()
    return {"id": job_id, "restore_id": job_id, "status": "running", "message": "Restore started"}


@app.post("/api/restore/jobs/{job_id:int}/run")
def run_restore_job(job_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        _ensure_tables(con)
        row = con.execute("SELECT * FROM restore_jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Restore job not found")
        _enforce_restore_retry_window(row)
    finally:
        con.close()
    _update_restore(
        job_id,
        status="running",
        dismissed_at="",
        dismissed_by_user_id=None,
        dismissed_by_username="",
    )
    threading.Thread(target=_run_restore_job, args=(job_id,), daemon=True).start()
    return {"id": job_id, "status": "running", "detail": "Restore job started"}


@app.get("/api/restore/jobs/{job_id:int}/log")
def restore_log(job_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        row = con.execute("SELECT * FROM restore_jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Restore job not found")
        data = _restore_row(row)
        data["restore_log"] = data["log"] or f"Status: {data['status']}"
        return data
    finally:
        con.close()


@app.delete("/api/restore/jobs/{job_id:int}")
def delete_restore_job(job_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        con.execute("DELETE FROM restore_jobs WHERE id=?", (job_id,))
        con.commit()
        return {"detail": "Restore job deleted", "id": job_id}
    finally:
        con.close()


@app.post("/api/restore/jobs/{job_id:int}/dismiss")
def dismiss_restore_job(job_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        _ensure_tables(con)
        row = con.execute("SELECT id, status FROM restore_jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Restore job not found")
        status = str(row["status"] or "").lower()
        if status not in {"failed", "error"}:
            raise HTTPException(status_code=400, detail="Only failed restore jobs can be dismissed")
        dismissed_at = _vm_timestamp()
        con.execute(
            "UPDATE restore_jobs SET dismissed_at=?, dismissed_by_username=?, updated_at=? WHERE id=?",
            (dismissed_at, "operator", dismissed_at, job_id),
        )
        con.commit()
        return {
            "detail": "Failed restore job dismissed; audit history retained",
            "id": job_id,
            "status": "failed",
            "dismissed_at": dismissed_at,
            "dismissed_by_username": "operator",
        }
    finally:
        con.close()


@app.get("/api/restore/discovered-backups")
def discovered_backups(request: Request, connection_id: int = 0, db_type: str = ""):
    _require_session(request)
    con = _db_conn()
    try:
        rows = con.execute(
            "SELECT * FROM backups WHERE (? = 0 OR connection_id = ?) AND status='success' ORDER BY id DESC LIMIT 200",
            (connection_id, connection_id),
        ).fetchall()
        return {"items": [_backup_row(row) for row in rows], "backups": [_backup_row(row) for row in rows]}
    finally:
        con.close()


@app.post("/api/restore/authorize")
async def restore_authorize(request: Request):
    _require_session(request)
    return {"authorized": True}


@app.get("/api/schedules")
@app.get("/api/schedules/")
def list_schedules(request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        rows = con.execute("SELECT * FROM schedules ORDER BY id DESC").fetchall()
        return [_schedule_row(row) for row in rows]
    finally:
        con.close()


def _schedule_payload(payload: dict[str, Any]) -> dict[str, Any]:
    connection_id = _int_value(payload.get("connection_id"), 0)
    if connection_id <= 0:
        raise HTTPException(status_code=400, detail="connection_id is required")
    cron_expr = str(payload.get("cron_expr") or payload.get("cron") or "").strip()
    frequency = str(payload.get("frequency") or "daily").strip().lower()
    if not cron_expr:
        cron_expr = {"hourly": "0 * * * *", "daily": "0 2 * * *", "weekly": "0 2 * * 0"}.get(frequency, "0 2 * * *")
    return {
        "connection_id": connection_id,
        "name": str(payload.get("name") or "").strip(),
        "frequency": frequency,
        "cron_expr": cron_expr,
        "destination": "dbaegis_local",
        "retention_days": _int_value(payload.get("retention_days"), 7),
        "retention_count": _int_value(payload.get("retention_count"), 0),
        "options_json": json.dumps(payload.get("options") or payload),
        "active": 1 if bool(payload.get("active", True)) else 0,
        "next_run_at": _schedule_next_run(cron_expr),
    }


@app.post("/api/schedules")
@app.post("/api/schedules/")
async def create_schedule(request: Request):
    _require_session(request)
    payload = await request.json()
    data = _schedule_payload(payload)
    con = _db_conn()
    try:
        _ensure_tables(con)
        count = int(con.execute("SELECT COUNT(*) AS c FROM schedules").fetchone()["c"] or 0)
        if count >= MAX_SCHEDULES:
            raise HTTPException(status_code=403, detail=f"Community is limited to {MAX_SCHEDULES} schedules")
        _get_connection(con, int(data["connection_id"]))
        now = _vm_timestamp()
        cur = con.execute(
            """
            INSERT INTO schedules(connection_id, name, frequency, cron_expr, destination, retention_days, retention_count, options_json, active, next_run_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'dbaegis_local', ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                data["connection_id"],
                data["name"],
                data["frequency"],
                data["cron_expr"],
                data["retention_days"],
                data["retention_count"],
                data["options_json"],
                data["active"],
                data["next_run_at"],
                now,
                now,
            ),
        )
        con.commit()
        row = con.execute("SELECT * FROM schedules WHERE id=?", (int(cur.lastrowid),)).fetchone()
        return _schedule_row(row)
    finally:
        con.close()


@app.put("/api/schedules/{schedule_id:int}")
async def update_schedule(schedule_id: int, request: Request):
    _require_session(request)
    data = _schedule_payload(await request.json())
    con = _db_conn()
    try:
        _get_connection(con, int(data["connection_id"]))
        con.execute(
            """
            UPDATE schedules
               SET connection_id=?, name=?, frequency=?, cron_expr=?, destination='dbaegis_local',
                   retention_days=?, retention_count=?, options_json=?, active=?, next_run_at=?, updated_at=?
             WHERE id=?
            """,
            (
                data["connection_id"],
                data["name"],
                data["frequency"],
                data["cron_expr"],
                data["retention_days"],
                data["retention_count"],
                data["options_json"],
                data["active"],
                data["next_run_at"],
                _vm_timestamp(),
                schedule_id,
            ),
        )
        con.commit()
        row = con.execute("SELECT * FROM schedules WHERE id=?", (schedule_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Schedule not found")
        return _schedule_row(row)
    finally:
        con.close()


@app.patch("/api/schedules/{schedule_id:int}/toggle")
def toggle_schedule(schedule_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        row = con.execute("SELECT active FROM schedules WHERE id=?", (schedule_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Schedule not found")
        active = 0 if bool(row["active"]) else 1
        con.execute("UPDATE schedules SET active=?, updated_at=? WHERE id=?", (active, _vm_timestamp(), schedule_id))
        con.commit()
        return {"id": schedule_id, "active": bool(active)}
    finally:
        con.close()


@app.post("/api/schedules/{schedule_id:int}/run")
def run_schedule(schedule_id: int, request: Request):
    _require_session(request)
    return _run_schedule_backup(schedule_id)


@app.delete("/api/schedules/{schedule_id:int}")
def delete_schedule(schedule_id: int, request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        con.execute("DELETE FROM schedules WHERE id=?", (schedule_id,))
        con.commit()
        return {"detail": "Schedule deleted", "id": schedule_id}
    finally:
        con.close()


@app.get("/api/self-backups")
def self_backups(request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        if not _table_exists(con, "self_backups"):
            return []
        cols = _table_cols(con, "self_backups")
        select_cols = ["id", "created_at", "file_path", "size_bytes", "notes"]
        trigger_expr = "trigger" if "trigger" in cols else "'MANUAL' AS trigger"
        rows = con.execute(
            "SELECT " + ", ".join(select_cols) + f", {trigger_expr} FROM self_backups ORDER BY id DESC"
        ).fetchall()
        out = []
        for row in rows:
            item = dict(row)
            file_path = str(item.get("file_path") or "")
            item["filename"] = Path(file_path).name
            item["note"] = item.get("notes") or "SQLite config/history snapshot"
            item["trigger"] = str(item.get("trigger") or "MANUAL").upper()
            item["locked"] = True
            item["upgrade_required"] = True
            out.append(item)
        return out
    finally:
        con.close()


@app.get("/api/self-backups/settings")
def self_backup_settings(request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        settings = {}
        if _table_exists(con, "system_settings"):
            rows = con.execute(
                "SELECT key, value FROM system_settings WHERE key IN "
                "('self_backup_retention_count', 'self_backup_base_path', 'self_backup_auto_enabled', 'self_backup_auto_cron')"
            ).fetchall()
            settings = {str(r["key"]): str(r["value"] or "") for r in rows}
        try:
            retain = max(1, min(int(settings.get("self_backup_retention_count") or "10"), 500))
        except Exception:
            retain = 10
        base_path = settings.get("self_backup_base_path") or str(Path(_backup_dir()) / "self")
        auto_enabled = str(settings.get("self_backup_auto_enabled") or "0").strip().lower() not in {
            "0",
            "false",
            "no",
            "off",
        }
        return {
            "enabled": False,
            "available": False,
            "locked": True,
            "upgrade_required": True,
            "required_edition": "professional",
            "retain_count": retain,
            "retention_count": retain,
            "base_path": base_path,
            "auto_enabled": auto_enabled,
            "auto_cron": settings.get("self_backup_auto_cron") or "0 0 * * *",
        }
    finally:
        con.close()


@app.get("/api/notifications/smtp")
def smtp_settings(request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        cfg = {}
        if _table_exists(con, "system_settings"):
            row = con.execute("SELECT value FROM system_settings WHERE key='smtp_config'").fetchone()
            cfg = _json_dict(row["value"] if row else "")
        return {
            "enabled": False,
            "available": False,
            "locked": True,
            "upgrade_required": True,
            "required_edition": "professional",
            "host": str(cfg.get("host") or ""),
            "port": int(cfg.get("port") or 587),
            "username": str(cfg.get("username") or ""),
            "from_address": str(cfg.get("from_address") or cfg.get("from_addr") or ""),
            "starttls": bool(cfg.get("starttls", True)),
            "ssl_tls": bool(cfg.get("ssl_tls") or cfg.get("ssl")),
            "ssl": bool(cfg.get("ssl") or cfg.get("ssl_tls")),
            "password": "",
        }
    finally:
        con.close()


@app.get("/api/notifications/global")
def global_notifications(request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        cfg = {}
        if _table_exists(con, "system_settings"):
            row = con.execute("SELECT value FROM system_settings WHERE key='global_notifications_config'").fetchone()
            cfg = _json_dict(row["value"] if row else "")
        events = cfg.get("events") if isinstance(cfg.get("events"), list) else ["failure"]
        return {
            "enabled": False,
            "available": False,
            "locked": True,
            "upgrade_required": True,
            "required_edition": "professional",
            "events": events,
            "recipients": str(cfg.get("recipients") or ""),
            "daily_summary_time": str(cfg.get("daily_summary_time") or "08:00"),
        }
    finally:
        con.close()


@app.get("/api/webhooks")
@app.get("/api/webhooks/")
def webhooks(request: Request):
    _require_session(request)
    con = _db_conn()
    try:
        if not _table_exists(con, "webhooks"):
            return []
        cols = _table_cols(con, "webhooks")
        webhook_type_expr = "webhook_type" if "webhook_type" in cols else "'generic' AS webhook_type"
        rows = con.execute(
            "SELECT id, name, events, active, headers_json, created_at, updated_at, "
            f"{webhook_type_expr} FROM webhooks ORDER BY id DESC"
        ).fetchall()
        out = []
        for row in rows:
            item = dict(row)
            item["active"] = bool(item.get("active"))
            item["webhook_type"] = str(item.get("webhook_type") or "generic")
            item["url"] = "[locked]"
            item["headers"] = {}
            item["headers_json"] = "{}"
            item["events"] = _json(item.get("events"), ["failure"])
            item["locked"] = True
            item["upgrade_required"] = True
            out.append(item)
        return out
    finally:
        con.close()


def _not_in_community(feature: str) -> JSONResponse:
    return JSONResponse(
        status_code=501,
        content={
            "detail": f"The {feature} feature is available in DBAegis Professional/Enterprise, not Community.",
            "edition": PRODUCT_EDITION,
            "runtime": COMMUNITY_RUNTIME_MODE,
        },
    )


@app.api_route(
    "/api/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
)
def community_api_fallback(path: str, request: Request):
    _require_session(request)
    return _not_in_community(f"/api/{path}")
