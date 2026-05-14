#!/usr/bin/env python3
"""Reset a local DBAegis admin password from the server shell.

This recovery utility intentionally changes only one local admin user row and
clears only that user's sessions. It does not edit other users, LDAP settings,
or bootstrap config values.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import os
import re
import secrets
import shlex
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


DEFAULT_CONF = "/opt/dbaegis/conf/dbaegis.conf"
DEFAULT_DB = "/opt/dbaegis/data/dbaegis.db"


class ResetAdminPasswordError(RuntimeError):
    pass


@dataclass(frozen=True)
class ResetAdminPasswordResult:
    db_path: Path
    user_id: int
    username: str
    sessions_cleared: int
    activated: bool
    dry_run: bool


def _vm_timestamp() -> str:
    return datetime.now().replace(microsecond=0).strftime("%Y-%m-%d %H:%M:%S")


def _load_conf(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("export "):
            stripped = stripped[len("export "):].strip()
        if "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
            continue
        value = value.strip()
        try:
            parsed = shlex.split(value, comments=False, posix=True)
            if len(parsed) == 1:
                value = parsed[0]
        except ValueError:
            value = value.strip("\"'")
        values[key] = value
    return values


def _resolve_db_path(args: argparse.Namespace, conf: dict[str, str]) -> Path:
    value = (
        args.db
        or os.environ.get("DBAEGIS_DB_PATH")
        or os.environ.get("DB_PATH")
        or os.environ.get("VAULT_DB_PATH")
        or conf.get("DBAEGIS_DB_PATH")
        or conf.get("DB_PATH")
        or conf.get("VAULT_DB_PATH")
        or DEFAULT_DB
    )
    return Path(value).expanduser()


def _hash_password(password: str, salt: str | None = None, iterations: int = 390000) -> str:
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256",
        str(password).encode("utf-8"),
        salt.encode("utf-8"),
        iterations,
    )
    encoded = base64.urlsafe_b64encode(digest).decode("ascii")
    return f"pbkdf2_sha256${iterations}${salt}${encoded}"


def _table_exists(con: sqlite3.Connection, name: str) -> bool:
    row = con.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (name,),
    ).fetchone()
    return row is not None


def _table_columns(con: sqlite3.Connection, name: str) -> set[str]:
    return {str(row[1]) for row in con.execute(f"PRAGMA table_info({name})").fetchall()}


def _user_select_sql(cols: set[str], where_sql: str) -> str:
    auth_source = "auth_source" if "auth_source" in cols else "'local' AS auth_source"
    fields = f"id, username, password_hash, role, active, {auth_source}"
    return f"SELECT {fields} FROM users WHERE {where_sql}"


def _local_admin_where(cols: set[str]) -> str:
    auth_clause = "1 = 1"
    if "auth_source" in cols:
        auth_clause = "lower(coalesce(auth_source, 'local')) = 'local'"
    return f"lower(role) = 'admin' AND {auth_clause}"


def _truthy_db_flag(value: object) -> bool:
    return str(value if value is not None else "").strip().lower() not in ("", "0", "false", "no", "off")


def _require_users_schema(con: sqlite3.Connection) -> set[str]:
    if not _table_exists(con, "users"):
        raise ResetAdminPasswordError("metadata DB has no users table")
    cols = _table_columns(con, "users")
    required = {"id", "username", "password_hash", "role", "active"}
    missing = sorted(required - cols)
    if missing:
        raise ResetAdminPasswordError(f"users table is missing required column(s): {', '.join(missing)}")
    return cols


def _resolve_target_user(
    con: sqlite3.Connection,
    cols: set[str],
    username: str | None,
) -> sqlite3.Row:
    cur = con.cursor()
    if username:
        cur.execute(_user_select_sql(cols, "lower(username) = lower(?)"), (username,))
        row = cur.fetchone()
        if row is None:
            raise ResetAdminPasswordError(f"user not found: {username}")
        if str(row["auth_source"] or "local").lower() != "local":
            raise ResetAdminPasswordError("LDAP-managed users cannot have a local password reset")
        if str(row["role"] or "").lower() != "admin":
            raise ResetAdminPasswordError("target user is not an admin")
        return row

    cur.execute(_user_select_sql(cols, _local_admin_where(cols)) + " ORDER BY id ASC")
    rows = cur.fetchall()
    if not rows:
        raise ResetAdminPasswordError("no local admin users were found; LDAP users must be reset in LDAP")
    if len(rows) > 1:
        names = ", ".join(str(row["username"]) for row in rows)
        raise ResetAdminPasswordError(f"multiple local admin users found ({names}); pass --username")
    return rows[0]


def reset_admin_password(
    db_path: Path | str,
    password: str,
    username: str | None = None,
    *,
    activate: bool = False,
    dry_run: bool = False,
) -> ResetAdminPasswordResult:
    db_path = Path(db_path).expanduser()
    if not db_path.exists():
        raise ResetAdminPasswordError(f"metadata DB does not exist: {db_path}")
    if not dry_run and not password:
        raise ResetAdminPasswordError("password cannot be empty")
    if not dry_run and password == "admin":
        raise ResetAdminPasswordError("refusing to set the default password 'admin'")

    con = sqlite3.connect(str(db_path), timeout=30)
    con.row_factory = sqlite3.Row
    try:
        con.execute("BEGIN IMMEDIATE")
        cols = _require_users_schema(con)
        row = _resolve_target_user(con, cols, username)
        user_id = int(row["id"])
        is_active = _truthy_db_flag(row["active"])
        if not is_active and not activate:
            raise ResetAdminPasswordError(
                f"local admin '{row['username']}' is inactive; rerun with --activate to enable that account"
            )

        if dry_run:
            con.rollback()
            return ResetAdminPasswordResult(
                db_path=db_path,
                user_id=user_id,
                username=str(row["username"]),
                sessions_cleared=0,
                activated=False,
                dry_run=True,
            )

        sets = ["password_hash = ?"]
        values: list[object] = [_hash_password(password)]
        activated = False
        if not is_active and activate:
            sets.append("active = 1")
            activated = True
        if "updated_at" in cols:
            sets.append("updated_at = ?")
            values.append(_vm_timestamp())
        values.append(user_id)
        con.execute(f"UPDATE users SET {', '.join(sets)} WHERE id = ?", values)

        sessions_cleared = 0
        if _table_exists(con, "sessions"):
            cur = con.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
            sessions_cleared = max(0, int(cur.rowcount or 0))

        con.commit()
        return ResetAdminPasswordResult(
            db_path=db_path,
            user_id=user_id,
            username=str(row["username"]),
            sessions_cleared=sessions_cleared,
            activated=activated,
            dry_run=False,
        )
    except Exception:
        try:
            con.rollback()
        except Exception:
            pass
        raise
    finally:
        con.close()


def _read_password(args: argparse.Namespace) -> tuple[str, bool]:
    inputs = [bool(args.generate), bool(args.password_env)]
    if sum(1 for item in inputs if item) > 1:
        raise ResetAdminPasswordError("choose only one password source: --generate or --password-env")

    if args.generate:
        return secrets.token_urlsafe(24), True

    if args.password_env:
        value = os.environ.get(args.password_env)
        if value is None:
            raise ResetAdminPasswordError(f"environment variable is not set: {args.password_env}")
        return str(value), False

    if not sys.stdin.isatty():
        raise ResetAdminPasswordError("non-interactive use requires --generate or --password-env")

    password = getpass.getpass("New admin password: ")
    confirm = getpass.getpass("Confirm new admin password: ")
    if password != confirm:
        raise ResetAdminPasswordError("passwords did not match")
    return password, False


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Reset one local DBAegis admin password without modifying other users.",
    )
    parser.add_argument("--db", help=f"SQLite metadata DB path. Default: config value or {DEFAULT_DB}")
    parser.add_argument("--conf", default=DEFAULT_CONF, help=f"DBAegis config path. Default: {DEFAULT_CONF}")
    parser.add_argument("--username", help="Local admin username to reset. Required when multiple local admins exist.")
    parser.add_argument("--password-env", help="Environment variable containing the new password.")
    parser.add_argument("--generate", action="store_true", help="Generate a random password and print it after a successful reset.")
    parser.add_argument("--activate", action="store_true", help="Enable the target local admin if it is currently inactive.")
    parser.add_argument("--dry-run", action="store_true", help="Resolve the target local admin without writing changes.")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    conf = _load_conf(Path(args.conf).expanduser())
    db_path = _resolve_db_path(args, conf)

    generated = False
    password = ""
    if not args.dry_run:
        password, generated = _read_password(args)

    result = reset_admin_password(
        db_path,
        password,
        username=args.username,
        activate=args.activate,
        dry_run=args.dry_run,
    )

    if result.dry_run:
        print(
            f"Dry run: local admin '{result.username}' (id {result.user_id}) would be reset in {result.db_path}."
        )
        print("Other users would not be modified.")
        return 0

    print(f"Reset password for local admin '{result.username}' (id {result.user_id}) in {result.db_path}.")
    if result.activated:
        print("Activated that admin account.")
    print(f"Cleared {result.sessions_cleared} session(s) for that user only; other users were not modified.")
    if generated:
        print(f"Generated password: {password}")
        print("Store it securely; it is not written to dbaegis.conf.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ResetAdminPasswordError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
