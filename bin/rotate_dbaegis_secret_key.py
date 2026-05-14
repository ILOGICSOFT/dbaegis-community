#!/usr/bin/env python3
"""Rotate the DBAegis metadata encryption key.

This is an offline maintenance command. Stop DBAegis before running it so no
backup, restore, or UI request writes secrets while rows are being re-encrypted.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

try:
    from cryptography.fernet import Fernet, InvalidToken
except Exception as exc:  # pragma: no cover - exercised in operator environments
    Fernet = None
    InvalidToken = Exception
    _CRYPTO_IMPORT_ERROR = exc
else:
    _CRYPTO_IMPORT_ERROR = None


ENC_PREFIX = "enc:v1:"
DEFAULT_CONF = "/opt/dbaegis/conf/dbaegis.conf"
DEFAULT_DB = "/opt/dbaegis/data/dbaegis.db"
LEGACY_SYSTEMD_SECRET_DROPIN = Path("/etc/systemd/system/dbaegis.service.d/10-secret.conf")
SENSITIVE_CONF_KEYS = {"DBAEGIS_SECRET_KEY", "BOOTSTRAP_ADMIN_PASSWORD"}
STORAGE_SECRET_KEYS = {
    "access_key_id",
    "access_key",
    "secret_access_key",
    "secret_key",
    "account_key",
    "sas_token",
    "service_account_json",
    "service_account",
    "client_secret",
    "private_key",
    "connection_string",
    "azure_connection_string",
    "shared_access_signature",
    "api_key",
    "token",
}
CONNECTION_OPTION_SECRET_KEYS = STORAGE_SECRET_KEYS | {
    "ssh_password",
    "ssh_key",
    "s3_secret",
    "az_conn_str",
    "password",
    "passphrase",
}
SMTP_SECRET_KEYS = {"password"}
LDAP_SECRET_KEYS = {"bind_password"}


def _vm_timestamp(dt: datetime | None = None) -> str:
    value = dt or datetime.now()
    if value.tzinfo is not None:
        value = value.astimezone().replace(tzinfo=None)
    return value.replace(microsecond=0).strftime("%Y-%m-%d %H:%M:%S")


class RotationError(RuntimeError):
    pass


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


def _derive_fernet(secret: str) -> Fernet:
    if Fernet is None:
        raise RotationError(f"cryptography is required: {_CRYPTO_IMPORT_ERROR}")
    secret = str(secret or "").strip()
    if not secret:
        raise RotationError("secret key cannot be empty")
    key = base64.urlsafe_b64encode(hashlib.sha256(secret.encode("utf-8")).digest())
    return Fernet(key)


def _is_encrypted(value: object) -> bool:
    return isinstance(value, str) and value.startswith(ENC_PREFIX)


def _decrypt_existing(value: object, old_fernet: Fernet, label: str) -> str:
    if value in (None, ""):
        return ""
    text = str(value)
    if not _is_encrypted(text):
        return text
    token = text[len(ENC_PREFIX):]
    try:
        return old_fernet.decrypt(token.encode("utf-8")).decode("utf-8")
    except InvalidToken as exc:
        raise RotationError(f"cannot decrypt {label}; old DBAEGIS_SECRET_KEY is wrong") from exc


def _encrypt_new(value: object, new_fernet: Fernet) -> str:
    if value in (None, ""):
        return ""
    return ENC_PREFIX + new_fernet.encrypt(str(value).encode("utf-8")).decode("utf-8")


def _secret_key_name_matches(name: str, secret_keys: set[str]) -> bool:
    key = str(name or "").strip().lower()
    return (
        key in secret_keys
        or key.endswith("_password")
        or key.endswith("-password")
        or "secret" in key
        or "token" in key
        or key in {"password", "passphrase", "private_key"}
    )


def _secret_value_to_text(value: object) -> str:
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)


def _rotate_secret_tree(value: object, old_fernet: Fernet, new_fernet: Fernet, secret_keys: set[str], label: str, parent_key: str = "") -> tuple[object, bool]:
    if isinstance(value, dict):
        changed = False
        out: dict[str, object] = {}
        for key, item in value.items():
            rotated, item_changed = _rotate_secret_tree(item, old_fernet, new_fernet, secret_keys, f"{label}.{key}", key)
            out[key] = rotated
            changed = changed or item_changed
        return out, changed
    if isinstance(value, list):
        changed = False
        out_list: list[object] = []
        for idx, item in enumerate(value):
            rotated, item_changed = _rotate_secret_tree(item, old_fernet, new_fernet, secret_keys, f"{label}[{idx}]", parent_key)
            out_list.append(rotated)
            changed = changed or item_changed
        return out_list, changed
    if not _secret_key_name_matches(parent_key, secret_keys) or value in (None, ""):
        return value, False
    plain = _decrypt_existing(_secret_value_to_text(value), old_fernet, label)
    encrypted = _encrypt_new(plain, new_fernet)
    return encrypted, encrypted != value


def _webhook_header_is_sensitive(name: str) -> bool:
    header = str(name or "").strip().lower().replace("_", "-")
    return (
        header == "authorization"
        or header.endswith("-authorization")
        or "api-key" in header
        or "apikey" in header
        or "token" in header
        or "secret" in header
        or "signature" in header
    )


def _table_exists(con: sqlite3.Connection, table_name: str) -> bool:
    row = con.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (table_name,),
    ).fetchone()
    return bool(row)


def _table_columns(con: sqlite3.Connection, table_name: str) -> set[str]:
    if not _table_exists(con, table_name):
        return set()
    return {str(row["name"]) for row in con.execute(f"PRAGMA table_info({table_name})").fetchall()}


def _rotate_connection_passwords(con: sqlite3.Connection, old_fernet: Fernet, new_fernet: Fernet) -> int:
    if not _table_exists(con, "connections"):
        return 0
    changed = 0
    rows = con.execute("SELECT id, password FROM connections").fetchall()
    for row in rows:
        conn_id = row["id"]
        raw = row["password"]
        if raw in (None, ""):
            continue
        plain = _decrypt_existing(raw, old_fernet, f"connections.id={conn_id}.password")
        encrypted = _encrypt_new(plain, new_fernet)
        if encrypted == raw:
            continue
        con.execute(
            "UPDATE connections SET password=?, updated_at=? WHERE id=?",
            (encrypted, _vm_timestamp(), conn_id),
        )
        changed += 1
    return changed


def _rotate_storage_destinations(con: sqlite3.Connection, old_fernet: Fernet, new_fernet: Fernet) -> int:
    if not _table_exists(con, "storage_destinations"):
        return 0
    changed = 0
    rows = con.execute("SELECT id, payload_json FROM storage_destinations").fetchall()
    for row in rows:
        storage_id = row["id"]
        try:
            payload = json.loads(row["payload_json"] or "{}")
        except Exception as exc:
            raise RotationError(f"storage_destinations.id={storage_id}.payload_json is not valid JSON") from exc
        if not isinstance(payload, dict):
            raise RotationError(f"storage_destinations.id={storage_id}.payload_json must be a JSON object")
        updated = dict(payload)
        touched = False
        for key in STORAGE_SECRET_KEYS:
            if key not in updated or updated.get(key) in (None, ""):
                continue
            plain = _decrypt_existing(
                updated.get(key),
                old_fernet,
                f"storage_destinations.id={storage_id}.{key}",
            )
            encrypted = _encrypt_new(plain, new_fernet)
            if encrypted != updated.get(key):
                updated[key] = encrypted
                touched = True
        if not touched:
            continue
        con.execute(
            "UPDATE storage_destinations SET payload_json=?, updated_at=? WHERE id=?",
            (json.dumps(updated), _vm_timestamp(), storage_id),
        )
        changed += 1
    return changed


def _rotate_connection_options(con: sqlite3.Connection, old_fernet: Fernet, new_fernet: Fernet) -> int:
    if not _table_exists(con, "connections"):
        return 0
    changed = 0
    rows = con.execute("SELECT id, options_json FROM connections").fetchall()
    for row in rows:
        conn_id = row["id"]
        try:
            payload = json.loads(row["options_json"] or "{}")
        except Exception as exc:
            raise RotationError(f"connections.id={conn_id}.options_json is not valid JSON") from exc
        if not isinstance(payload, dict):
            continue
        updated, touched = _rotate_secret_tree(
            payload,
            old_fernet,
            new_fernet,
            CONNECTION_OPTION_SECRET_KEYS,
            f"connections.id={conn_id}.options_json",
        )
        if not touched:
            continue
        con.execute(
            "UPDATE connections SET options_json=?, updated_at=? WHERE id=?",
            (json.dumps(updated), _vm_timestamp(), conn_id),
        )
        changed += 1
    return changed


def _rotate_user_mfa_secrets(con: sqlite3.Connection, old_fernet: Fernet, new_fernet: Fernet) -> int:
    cols = _table_columns(con, "users")
    if "mfa_secret" not in cols:
        return 0
    changed = 0
    rows = con.execute("SELECT id, mfa_secret FROM users").fetchall()
    has_updated_at = "updated_at" in cols
    for row in rows:
        user_id = row["id"]
        raw = row["mfa_secret"]
        if raw in (None, ""):
            continue
        plain = _decrypt_existing(raw, old_fernet, f"users.id={user_id}.mfa_secret")
        encrypted = _encrypt_new(plain, new_fernet)
        if encrypted == raw:
            continue
        if has_updated_at:
            con.execute(
                "UPDATE users SET mfa_secret=?, updated_at=? WHERE id=?",
                (encrypted, _vm_timestamp(), user_id),
            )
        else:
            con.execute("UPDATE users SET mfa_secret=? WHERE id=?", (encrypted, user_id))
        changed += 1
    return changed


def _rotate_system_setting_json(con: sqlite3.Connection, old_fernet: Fernet, new_fernet: Fernet, setting_key: str, secret_keys: set[str]) -> int:
    if not _table_exists(con, "system_settings"):
        return 0
    row = con.execute("SELECT value FROM system_settings WHERE key=?", (setting_key,)).fetchone()
    if not row or not row["value"]:
        return 0
    try:
        payload = json.loads(row["value"] or "{}")
    except Exception as exc:
        raise RotationError(f"system_settings.{setting_key} is not valid JSON") from exc
    if not isinstance(payload, dict):
        return 0
    updated, touched = _rotate_secret_tree(payload, old_fernet, new_fernet, secret_keys, f"system_settings.{setting_key}")
    if not touched:
        return 0
    con.execute("UPDATE system_settings SET value=? WHERE key=?", (json.dumps(updated), setting_key))
    return 1


def _rotate_smtp_settings_table(con: sqlite3.Connection, old_fernet: Fernet, new_fernet: Fernet) -> int:
    if not _table_exists(con, "smtp_settings"):
        return 0
    changed = 0
    rows = con.execute("SELECT id, password FROM smtp_settings").fetchall()
    for row in rows:
        raw = row["password"]
        if raw in (None, ""):
            continue
        plain = _decrypt_existing(raw, old_fernet, f"smtp_settings.id={row['id']}.password")
        encrypted = _encrypt_new(plain, new_fernet)
        if encrypted == raw:
            continue
        con.execute("UPDATE smtp_settings SET password=?, updated_at=? WHERE id=?", (encrypted, _vm_timestamp(), row["id"]))
        changed += 1
    return changed


def _rotate_webhooks(con: sqlite3.Connection, old_fernet: Fernet, new_fernet: Fernet) -> int:
    if not _table_exists(con, "webhooks"):
        return 0
    changed = 0
    rows = con.execute("SELECT id, url, headers_json FROM webhooks").fetchall()
    for row in rows:
        webhook_id = row["id"]
        url = row["url"] or ""
        updated_url = url
        touched = False
        if url:
            plain_url = _decrypt_existing(url, old_fernet, f"webhooks.id={webhook_id}.url")
            updated_url = _encrypt_new(plain_url, new_fernet)
            touched = touched or updated_url != url
        try:
            headers = json.loads(row["headers_json"] or "{}")
        except Exception as exc:
            raise RotationError(f"webhooks.id={webhook_id}.headers_json is not valid JSON") from exc
        if not isinstance(headers, dict):
            headers = {}
        updated_headers = dict(headers)
        for key, value in list(updated_headers.items()):
            if not _webhook_header_is_sensitive(key) or value in (None, ""):
                continue
            plain = _decrypt_existing(value, old_fernet, f"webhooks.id={webhook_id}.headers.{key}")
            encrypted = _encrypt_new(plain, new_fernet)
            if encrypted != value:
                updated_headers[key] = encrypted
                touched = True
        if not touched:
            continue
        con.execute(
            "UPDATE webhooks SET url=?, headers_json=?, updated_at=? WHERE id=?",
            (updated_url, json.dumps(updated_headers), _vm_timestamp(), webhook_id),
        )
        changed += 1
    return changed


def _backup_file(path: Path, suffix: str) -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = path.with_name(f"{path.name}.{stamp}.{suffix}")
    shutil.copy2(path, backup_path)
    _redact_conf_backup(backup_path)
    return backup_path


def _redact_conf_backup(path: Path) -> None:
    if path.name.startswith("dbaegis.conf"):
        lines = path.read_text(encoding="utf-8").splitlines()
        output = []
        for line in lines:
            replaced = False
            for key in SENSITIVE_CONF_KEYS:
                if re.match(rf"^\s*(?:export\s+)?{re.escape(key)}\s*=", line):
                    output.append(f"{key}=redacted-active-dbaegis.conf")
                    replaced = True
                    break
            if not replaced:
                output.append(line)
        path.write_text("\n".join(output) + "\n", encoding="utf-8")


def _backup_sqlite_database(db_path: Path, suffix: str) -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = db_path.with_name(f"{db_path.name}.{stamp}.{suffix}")
    source_con = sqlite3.connect(str(db_path), timeout=30)
    dest_con = sqlite3.connect(str(backup_path))
    try:
        source_con.backup(dest_con)
    finally:
        dest_con.close()
        source_con.close()
    backup_path.chmod(0o600)
    return backup_path


def _update_conf_secret_key(conf_path: Path, new_key: str) -> Path:
    if not conf_path.exists():
        raise RotationError(f"config file does not exist: {conf_path}")
    backup_path = _backup_file(conf_path, "before-secret-key-rotation")
    lines = conf_path.read_text(encoding="utf-8").splitlines()
    replacement = f"DBAEGIS_SECRET_KEY={shlex.quote(new_key)}"
    pattern = re.compile(r"^(\s*(?:export\s+)?DBAEGIS_SECRET_KEY\s*=).*$")
    changed = False
    output: list[str] = []
    for line in lines:
        if pattern.match(line):
            output.append(replacement)
            changed = True
        else:
            output.append(line)
    if not changed:
        output.append(replacement)
    conf_path.write_text("\n".join(output) + "\n", encoding="utf-8")
    return backup_path


def _remove_legacy_systemd_secret_dropin() -> Path | None:
    if not LEGACY_SYSTEMD_SECRET_DROPIN.exists():
        return None
    try:
        LEGACY_SYSTEMD_SECRET_DROPIN.unlink()
        try:
            LEGACY_SYSTEMD_SECRET_DROPIN.parent.rmdir()
        except OSError:
            pass
    except PermissionError as exc:
        raise RotationError(
            f"legacy systemd secret drop-in exists and must be removed so dbaegis.conf is the only key source: "
            f"{LEGACY_SYSTEMD_SECRET_DROPIN}"
        ) from exc
    return LEGACY_SYSTEMD_SECRET_DROPIN


def _value_from_env(name: str | None) -> str:
    if not name:
        return ""
    return str(os.environ.get(name) or "").strip()


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


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Re-encrypt DBAegis saved secrets from one DBAEGIS_SECRET_KEY to another.",
    )
    parser.add_argument("--db", help=f"SQLite metadata DB path. Default: config value or {DEFAULT_DB}")
    parser.add_argument("--conf", default=DEFAULT_CONF, help=f"DBAegis config path. Default: {DEFAULT_CONF}")
    parser.add_argument("--old-key", help="Current DBAEGIS_SECRET_KEY. If omitted, read from --old-key-env or config.")
    parser.add_argument("--old-key-env", help="Environment variable containing the current DBAEGIS_SECRET_KEY.")
    parser.add_argument("--new-key", help="Replacement DBAEGIS_SECRET_KEY.")
    parser.add_argument("--new-key-env", help="Environment variable containing the replacement DBAEGIS_SECRET_KEY.")
    parser.add_argument("--generate-new-key", action="store_true", help="Generate a replacement key.")
    parser.add_argument("--update-conf", action="store_true", help="Write the replacement key to dbaegis.conf after DB rotation succeeds.")
    parser.add_argument("--no-db-backup", action="store_true", help="Do not create a DB copy before writing.")
    parser.add_argument("--dry-run", action="store_true", help="Validate and report counts without committing changes.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    conf_path = Path(args.conf).expanduser()
    conf = _load_conf(conf_path)

    old_key = str(args.old_key or _value_from_env(args.old_key_env) or conf.get("DBAEGIS_SECRET_KEY") or "").strip()
    if args.generate_new_key:
        if args.new_key or args.new_key_env:
            raise RotationError("--generate-new-key cannot be combined with --new-key or --new-key-env")
        if not args.update_conf and not args.dry_run:
            raise RotationError("--generate-new-key requires --update-conf so the generated key is not lost")
        new_key = secrets.token_urlsafe(48)
    else:
        new_key = str(args.new_key or _value_from_env(args.new_key_env) or "").strip()

    if not old_key:
        raise RotationError("old key is required; pass --old-key, --old-key-env, or a config with DBAEGIS_SECRET_KEY")
    if not new_key:
        raise RotationError("new key is required; pass --new-key, --new-key-env, or --generate-new-key")
    if old_key == new_key:
        raise RotationError("old and new DBAEGIS_SECRET_KEY values are the same")

    db_path = _resolve_db_path(args, conf)
    if not db_path.exists():
        raise RotationError(f"metadata DB does not exist: {db_path}")

    old_fernet = _derive_fernet(old_key)
    new_fernet = _derive_fernet(new_key)

    db_backup = None
    conf_backup = None
    removed_dropin = None
    if not args.dry_run and not args.no_db_backup:
        db_backup = _backup_sqlite_database(db_path, "before-secret-key-rotation")

    con = sqlite3.connect(str(db_path), timeout=30)
    con.row_factory = sqlite3.Row
    try:
        con.execute("BEGIN IMMEDIATE")
        connection_count = _rotate_connection_passwords(con, old_fernet, new_fernet)
        connection_option_count = _rotate_connection_options(con, old_fernet, new_fernet)
        storage_count = _rotate_storage_destinations(con, old_fernet, new_fernet)
        smtp_config_count = _rotate_system_setting_json(con, old_fernet, new_fernet, "smtp_config", SMTP_SECRET_KEYS)
        ldap_config_count = _rotate_system_setting_json(con, old_fernet, new_fernet, "auth_ldap_config", LDAP_SECRET_KEYS)
        mfa_user_count = _rotate_user_mfa_secrets(con, old_fernet, new_fernet)
        smtp_table_count = _rotate_smtp_settings_table(con, old_fernet, new_fernet)
        webhook_count = _rotate_webhooks(con, old_fernet, new_fernet)
        if args.dry_run:
            con.rollback()
        else:
            con.commit()
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()

    if args.update_conf and not args.dry_run:
        conf_backup = _update_conf_secret_key(conf_path, new_key)
        removed_dropin = _remove_legacy_systemd_secret_dropin()

    print("DBAegis secret key rotation complete" if not args.dry_run else "DBAegis secret key rotation dry run complete")
    print(f"metadata_db={db_path}")
    print(f"connection_password_rows={connection_count}")
    print(f"connection_option_rows={connection_option_count}")
    print(f"storage_destination_rows={storage_count}")
    print(f"smtp_config_rows={smtp_config_count}")
    print(f"ldap_config_rows={ldap_config_count}")
    print(f"mfa_user_rows={mfa_user_count}")
    print(f"smtp_settings_rows={smtp_table_count}")
    print(f"webhook_rows={webhook_count}")
    if db_backup:
        print(f"db_backup={db_backup}")
    if conf_backup:
        print(f"conf_backup={conf_backup}")
    if removed_dropin:
        print(f"removed_legacy_systemd_secret_dropin={removed_dropin}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RotationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
