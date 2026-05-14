
# ── Minimal local auth (safe step 1) ─────────────────────────────────────────
import secrets as _auth_secrets
import hashlib as _auth_hashlib
import hmac as _auth_hmac
import base64 as _auth_base64
from datetime import datetime as _auth_dt, timedelta as _auth_td
from fastapi import Response as _AuthResponse

AUTH_ENABLED = str(os.environ.get("AUTH_ENABLED", "true")).strip().lower() not in ("0", "false", "no")
SESSION_COOKIE_NAME = str(os.environ.get("SESSION_COOKIE_NAME", "dbaegis_session")).strip() or "dbaegis_session"
try:
    SESSION_TTL_HOURS = max(1, min(int(str(os.environ.get("SESSION_TTL_HOURS", "12")).strip() or "12"), 168))
except Exception:
    SESSION_TTL_HOURS = 12
BOOTSTRAP_ADMIN_USER = str(os.environ.get("BOOTSTRAP_ADMIN_USER", "admin")).strip() or "admin"
BOOTSTRAP_ADMIN_PASSWORD = str(os.environ.get("BOOTSTRAP_ADMIN_PASSWORD") or "")
_BOOTSTRAP_ADMIN_PASSWORD_PLACEHOLDERS = {
    "admin",
    "change-me",
    "changeme",
    "default",
    "password",
    "dbaegis",
}
_MIN_BOOTSTRAP_ADMIN_PASSWORD_LENGTH = 12


def _bootstrap_admin_password_error(value) -> str:
    cleaned = str(value or "").strip()
    lowered = cleaned.lower()
    if not cleaned:
        return "BOOTSTRAP_ADMIN_PASSWORD must be set before seeding the initial admin user"
    if lowered in _BOOTSTRAP_ADMIN_PASSWORD_PLACEHOLDERS or lowered.startswith("change-me"):
        return "BOOTSTRAP_ADMIN_PASSWORD must be set to a non-default value before seeding the initial admin user"
    if len(cleaned) < _MIN_BOOTSTRAP_ADMIN_PASSWORD_LENGTH:
        return f"BOOTSTRAP_ADMIN_PASSWORD must be at least {_MIN_BOOTSTRAP_ADMIN_PASSWORD_LENGTH} characters before seeding the initial admin user"
    return ""

def _auth_now():
    return _auth_dt.now()

def _auth_now_str():
    return _auth_now().strftime("%Y-%m-%d %H:%M:%S")

def _auth_future_str(hours: int):
    return (_auth_now() + _auth_td(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")

def _auth_audit_timestamp():
    return _auth_now_str()

_SESSION_HASH_PREFIX = "sha256:"


def _auth_hash_token(value) -> str:
    raw = str(value or "")
    if not raw:
        return ""
    if raw.startswith(_SESSION_HASH_PREFIX):
        return raw
    return _SESSION_HASH_PREFIX + _auth_hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _auth_session_lookup_values(value) -> tuple[str, str]:
    raw = str(value or "")
    return (_auth_hash_token(raw), raw)


def _auth_encrypt_session_secret(value) -> str:
    encryptor = globals().get("_encrypt_storage_secret_value") or globals().get("_encrypt_password_value")
    if callable(encryptor) and value not in (None, ""):
        return encryptor(value)
    return str(value or "")


def _auth_decrypt_session_secret(value) -> str:
    decryptor = globals().get("_decrypt_storage_secret_value") or globals().get("_decrypt_password_value")
    if callable(decryptor):
        return decryptor(value)
    return str(value or "")

def _ensure_auth_tables(con):
    cur = con.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT NOT NULL UNIQUE,
          password_hash TEXT NOT NULL,
          role TEXT NOT NULL CHECK(role IN ('admin','read_only')),
          active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT DEFAULT (datetime('now','localtime')),
          updated_at TEXT DEFAULT (datetime('now','localtime')),
          last_login_at TEXT
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS sessions (
          id TEXT PRIMARY KEY,
          user_id INTEGER NOT NULL,
          created_at TEXT DEFAULT (datetime('now','localtime')),
          expires_at TEXT NOT NULL,
          csrf_token TEXT NOT NULL,
          client_ip TEXT,
          user_agent TEXT,
          FOREIGN KEY(user_id) REFERENCES users(id)
        )
        """
    )
    con.commit()

def _hash_password(password: str, salt: str = "", iterations: int = 390000) -> str:
    salt = salt or _auth_secrets.token_hex(16)
    dk = _auth_hashlib.pbkdf2_hmac(
        "sha256",
        str(password).encode("utf-8"),
        salt.encode("utf-8"),
        iterations,
    )
    digest = _auth_base64.urlsafe_b64encode(dk).decode("ascii")
    return f"pbkdf2_sha256${iterations}${salt}${digest}"

def _verify_password(password: str, stored: str) -> bool:
    try:
        alg, iter_s, salt, digest = str(stored).split("$", 3)
        if alg != "pbkdf2_sha256":
            return False
        calc = _hash_password(password, salt=salt, iterations=int(iter_s)).split("$", 3)[3]
        return _auth_hmac.compare_digest(calc, digest)
    except Exception:
        return False

def _auth_seed_admin_if_needed():
    if not AUTH_ENABLED:
        return
    con = _db_conn()
    _ensure_auth_tables(con)
    cur = con.cursor()
    cur.execute("SELECT COUNT(*) AS c FROM users")
    row = cur.fetchone()
    count = int(row["c"] if row and row["c"] is not None else 0)
    if count == 0:
        password_error = _bootstrap_admin_password_error(BOOTSTRAP_ADMIN_PASSWORD)
        if password_error:
            raise RuntimeError(password_error)
        cur.execute(
            "INSERT INTO users(username, password_hash, role, active) VALUES (?, ?, 'admin', 1)",
            (BOOTSTRAP_ADMIN_USER, _hash_password(BOOTSTRAP_ADMIN_PASSWORD))
        )
        con.commit()
    con.close()

def _auth_get_session(request: Request):
    if not AUTH_ENABLED:
        return None
    sid = request.cookies.get(SESSION_COOKIE_NAME)
    if not sid:
        return None
    con = _db_conn()
    _ensure_auth_tables(con)
    cur = con.cursor()
    lookup_ids = _auth_session_lookup_values(sid)
    cur.execute(
        """
        SELECT s.id AS session_id, s.user_id, s.expires_at, s.csrf_token,
               u.username, u.role, u.active
        FROM sessions s
        JOIN users u ON u.id = s.user_id
        WHERE s.id IN (?, ?)
        """,
        lookup_ids
    )
    row = cur.fetchone()
    con.close()
    if not row:
        return None
    if not bool(row["active"]):
        return None
    if str(row["expires_at"] or "") <= _auth_now_str():
        return None
    return {
        "session_id": row["session_id"],
        "user_id": row["user_id"],
        "username": row["username"],
        "role": row["role"],
        "csrf_token": _auth_decrypt_session_secret(row["csrf_token"]),
        "expires_at": row["expires_at"],
    }

def _auth_require_user(request: Request):
    user = _auth_get_session(request)
    if not user:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return user

def _auth_require_admin(request: Request):
    user = _auth_require_user(request)
    if str(user.get("role") or "") != "admin":
        raise HTTPException(status_code=403, detail="Admin role required")
    return user

def _auth_startup_seed():
    _auth_seed_admin_if_needed()

try:
    from contextlib import asynccontextmanager as _auth_asynccontextmanager
    _auth_previous_lifespan = getattr(app.router, "lifespan_context", None)

    @_auth_asynccontextmanager
    async def _auth_lifespan(_app):
        _auth_startup_seed()
        if _auth_previous_lifespan is not None:
            async with _auth_previous_lifespan(_app):
                yield
        else:
            yield

    app.router.lifespan_context = _auth_lifespan
except Exception:
    # This file is an append fragment; if no app/router exists yet, the host app
    # should call _auth_startup_seed() from its own lifespan handler.
    pass

@app.get("/api/auth/me")
def auth_me(request: Request):
    if not AUTH_ENABLED:
        return {"enabled": False, "authenticated": False}
    user = _auth_get_session(request)
    if not user:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return {
        "enabled": True,
        "authenticated": True,
        "username": user["username"],
        "role": user["role"],
        "csrf_token": user["csrf_token"],
        "expires_at": user["expires_at"],
    }

@app.post("/api/auth/login")
async def auth_login(request: Request, response: _AuthResponse):
    if not AUTH_ENABLED:
        raise HTTPException(status_code=400, detail="Authentication is disabled")
    payload = await request.json()
    username = str((payload or {}).get("username") or "").strip()
    password = str((payload or {}).get("password") or "")
    if not username or not password:
        raise HTTPException(status_code=400, detail="username and password are required")

    con = _db_conn()
    _ensure_auth_tables(con)
    cur = con.cursor()
    cur.execute("SELECT * FROM users WHERE username = ? AND active = 1", (username,))
    row = cur.fetchone()
    if not row or not _verify_password(password, row["password_hash"]):
        con.close()
        raise HTTPException(status_code=401, detail="Invalid username or password")

    sid = _auth_secrets.token_urlsafe(32)
    csrf_token = _auth_secrets.token_urlsafe(24)
    expires_at = _auth_future_str(SESSION_TTL_HOURS)
    stored_sid = _auth_hash_token(sid)
    stored_csrf_token = _auth_encrypt_session_secret(csrf_token)

    cur.execute("DELETE FROM sessions WHERE user_id = ?", (row["id"],))
    cur.execute(
        "INSERT INTO sessions(id, user_id, expires_at, csrf_token, client_ip, user_agent) VALUES (?, ?, ?, ?, ?, ?)",
        (
            stored_sid,
            row["id"],
            expires_at,
            stored_csrf_token,
            request.client.host if request.client else "",
            request.headers.get("user-agent", ""),
        ),
    )
    audit_ts = _auth_audit_timestamp()
    cur.execute(
        "UPDATE users SET last_login_at = ?, updated_at = ? WHERE id = ?",
        (audit_ts, audit_ts, row["id"])
    )
    con.commit()
    con.close()

    response.set_cookie(
        key=SESSION_COOKIE_NAME,
        value=sid,
        httponly=True,
        secure=True,
        samesite="Lax",
        path="/",
        max_age=SESSION_TTL_HOURS * 3600,
    )
    return {
        "detail": "Login successful",
        "username": row["username"],
        "role": row["role"],
        "csrf_token": csrf_token,
        "expires_at": expires_at,
    }

@app.post("/api/auth/logout")
def auth_logout(request: Request, response: _AuthResponse):
    sid = request.cookies.get(SESSION_COOKIE_NAME)
    if sid:
        con = _db_conn()
        _ensure_auth_tables(con)
        cur = con.cursor()
        cur.execute("DELETE FROM sessions WHERE id IN (?, ?)", _auth_session_lookup_values(sid))
        con.commit()
        con.close()
    response.delete_cookie(key=SESSION_COOKIE_NAME, path="/")
    return {"detail": "Logged out"}

@app.get("/api/users/")
def list_users(request: Request):
    _auth_require_admin(request)
    con = _db_conn()
    _ensure_auth_tables(con)
    cur = con.cursor()
    cur.execute(
        "SELECT id, username, role, active, created_at, updated_at, last_login_at FROM users ORDER BY id ASC"
    )
    rows = []
    for r in cur.fetchall():
        d = dict(r)
        d["active"] = bool(d.get("active"))
        rows.append(d)
    con.close()
    return rows

@app.post("/api/users/")
async def create_user(request: Request):
    _auth_require_admin(request)
    payload = await request.json()
    username = str((payload or {}).get("username") or "").strip()
    password = str((payload or {}).get("password") or "")
    role = str((payload or {}).get("role") or "read_only").strip()
    active = 1 if bool((payload or {}).get("active", True)) else 0
    if not username or not password:
        raise HTTPException(status_code=400, detail="username and password are required")
    if role not in ("admin", "read_only"):
        raise HTTPException(status_code=400, detail="role must be admin or read_only")

    con = _db_conn()
    _ensure_auth_tables(con)
    cur = con.cursor()
    try:
        cur.execute(
            "INSERT INTO users(username, password_hash, role, active) VALUES (?, ?, ?, ?)",
            (username, _hash_password(password), role, active)
        )
        new_id = cur.lastrowid
        con.commit()
        cur.execute(
            "SELECT id, username, role, active, created_at, updated_at, last_login_at FROM users WHERE id = ?",
            (new_id,)
        )
        row = dict(cur.fetchone())
        row["active"] = bool(row.get("active"))
        con.close()
        return row
    except sqlite3.IntegrityError:
        con.close()
        raise HTTPException(status_code=409, detail="username already exists")

@app.put("/api/users/{user_id}")
async def update_user(user_id: int, request: Request):
    current = _auth_require_admin(request)
    payload = await request.json()
    role = str((payload or {}).get("role") or "").strip()
    active = (payload or {}).get("active", None)
    username = str((payload or {}).get("username") or "").strip()

    con = _db_conn()
    _ensure_auth_tables(con)
    cur = con.cursor()
    cur.execute("SELECT id, username FROM users WHERE id = ?", (user_id,))
    row = cur.fetchone()
    if not row:
        con.close()
        raise HTTPException(status_code=404, detail="User not found")

    sets = []
    vals = []
    if username:
        sets.append("username = ?")
        vals.append(username)
    if role:
        if role not in ("admin", "read_only"):
            con.close()
            raise HTTPException(status_code=400, detail="role must be admin or read_only")
        sets.append("role = ?")
        vals.append(role)
    if active is not None:
        sets.append("active = ?")
        vals.append(1 if bool(active) else 0)

    if not sets:
        con.close()
        raise HTTPException(status_code=400, detail="nothing to update")

    if int(user_id) == int(current["user_id"]) and active is not None and not bool(active):
        con.close()
        raise HTTPException(status_code=400, detail="cannot deactivate your own active session user")

    vals.append(_auth_audit_timestamp())
    vals.append(user_id)
    cur.execute(
        f"UPDATE users SET {', '.join(sets)}, updated_at = ? WHERE id = ?",
        tuple(vals)
    )
    con.commit()
    cur.execute(
        "SELECT id, username, role, active, created_at, updated_at, last_login_at FROM users WHERE id = ?",
        (user_id,)
    )
    out = dict(cur.fetchone())
    out["active"] = bool(out.get("active"))
    con.close()
    return out

@app.post("/api/users/{user_id}/password")
async def update_user_password(user_id: int, request: Request):
    _auth_require_admin(request)
    payload = await request.json()
    password = str((payload or {}).get("password") or "")
    if not password:
        raise HTTPException(status_code=400, detail="password is required")
    con = _db_conn()
    _ensure_auth_tables(con)
    cur = con.cursor()
    cur.execute("SELECT id FROM users WHERE id = ?", (user_id,))
    if not cur.fetchone():
        con.close()
        raise HTTPException(status_code=404, detail="User not found")
    cur.execute(
        "UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?",
        (_hash_password(password), _auth_audit_timestamp(), user_id)
    )
    cur.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
    con.commit()
    con.close()
    return {"detail": "Password updated"}

@app.delete("/api/users/{user_id}")
def delete_user(user_id: int, request: Request):
    current = _auth_require_admin(request)
    if int(user_id) == int(current["user_id"]):
        raise HTTPException(status_code=400, detail="cannot delete your own active session user")
    con = _db_conn()
    _ensure_auth_tables(con)
    cur = con.cursor()
    cur.execute("SELECT id FROM users WHERE id = ?", (user_id,))
    if not cur.fetchone():
        con.close()
        raise HTTPException(status_code=404, detail="User not found")
    cur.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
    cur.execute("DELETE FROM users WHERE id = ?", (user_id,))
    con.commit()
    con.close()
    return {"detail": "Deleted"}
