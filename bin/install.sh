#!/usr/bin/env bash
# =============================================================================
#  DBAegis Database Resilience Platform — Installer/Upgrade
#
#  Usage:
#    tar xzf dbaegis.tar.gz
#    cd dbaegis
#    sudo DBAEGIS_USER=dbaegis bash install.sh --fresh
#    sudo DBAEGIS_USER=dbaegis bash install.sh --upgrade
#    sudo DBAEGIS_USER=dbaegis bash install.sh --rollback
#
#  Optional environment overrides (set before running):
#    DBAEGIS_BASE=/opt/dbaegis      Base installation directory
#    DBAEGIS_USER=myuser            Run service as this user (default: invoking user)
#    DBAEGIS_DB_PATH=/data/dbaegis/dbaegis.db
#                                    SQLite metadata database path
#    DBAEGIS_BACKUP_DIR=/backups    Backup artifact directory
#    DBAEGIS_TEMP_DIR=/opt/dbaegis/tmp
#                                    DBAegis VM temporary backup/restore work directory
#    DBAEGIS_LICENSE_DIR=/opt/dbaegis/license
#                                    License token, public key, and license metadata directory
#    DBAEGIS_PYTHON_DIR=/opt/dbaegis/python
#                                    Embedded Python runtime directory
#                                    Custom/system runtimes must be Python 3.12+
#    DBAEGIS_PYTHON_URL=https://...
#                                    Override embedded Python tarball URL
#    DBAEGIS_PYTHON_SHA256=<sha>     Required SHA256 when overriding embedded Python URL/version
#    DBAEGIS_API_PORT=8000          API port
#    DBAEGIS_UI_PORT=3000           UI port
#    DBAEGIS_SERVICE_PRIVATE_TMP=no systemd PrivateTmp isolation for the service (default no)
#    DBAEGIS_OS_PACKAGE_MODE=install
#                                    New-VM installs process prerequisite OS packages by default
#                                    so named packages can be installed or upgraded when needed
#                                    for compatibility.
#                                    Set to missing-only to skip already-installed packages.
#    DBAEGIS_ROLLBACK_DIR=/opt/dbaegis/rollback
#                                    Runtime snapshots created before upgrades
#    DBAEGIS_ROLLBACK_SNAPSHOT=...  Optional snapshot path/name for --rollback
#    DBAEGIS_BUILD_CHANNEL=stable   Optional CI override when package has no release.json
#    DBAEGIS_RELEASE_NAME="DBAegis 1.0.0"
#                                    Optional display name; defaults to DBAegis <version>
#    DBAEGIS_BUILD_TIME=auto         Optional build timestamp; auto uses current UTC
#    DBAEGIS_GIT_COMMIT=<sha>        Optional commit/build identifier for release metadata
#    DBAEGIS_INSTALL_SNOWSQL=0        Set to 1/true/yes to install SnowSQL for Snowflake support
#    DBAEGIS_SNOWSQL_VERSION=1.5.0    Optional SnowSQL version for opt-in install
#    DBAEGIS_SNOWSQL_URL=https://...  Optional SnowSQL installer URL override
#    DBAEGIS_SNOWSQL_SHA256=<sha>     Optional SnowSQL installer SHA256 override
#    DBAEGIS_SNOWSQL_HOME=/opt/dbaegis Optional SnowSQL HOME/config location
#    DBAEGIS_SNOWSQL_DEST=/opt/dbaegis/vendor/snowsql/bin Optional managed SnowSQL binary dir
#    DBAEGIS_SNOWSQL_LINK=/usr/local/bin/snowsql Optional command wrapper path
#    DBAEGIS_INSTALL_SQLPACKAGE=0     Set to 1/true/yes to install Microsoft SqlPackage
#    DBAEGIS_INSTALL_SQLCMD=0         Set to 1/true/yes to install Microsoft sqlcmd/mssql-tools18
#    DBAEGIS_ACCEPT_MICROSOFT_EULA=0  Required as 1/true/yes for SQLCMD install
#    DBAEGIS_INSTALL_MONGODB_TOOLS=0  Set to 1/true/yes to install mongosh and MongoDB Database Tools
#    DBAEGIS_INSTALL_CLICKHOUSE_CLIENT=0
#                                    Set to 1/true/yes to install clickhouse-client
#
#  Installs:
#    - Embedded Python 3 runtime + virtualenv with all dependencies
#    - FastAPI/uvicorn API backend
#    - nginx UI server
#    - systemd service (systemctl start|stop|restart dbaegis)
#    - pre-upgrade runtime snapshots and rollback support
#    - SQLite database at /opt/dbaegis/data/dbaegis.db
#    - Config at /opt/dbaegis/conf/dbaegis.conf
# =============================================================================
set -euo pipefail
umask 077

DBAEGIS_BASE="${DBAEGIS_BASE:-/opt/dbaegis}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DBAEGIS_VERSION="${DBAEGIS_VERSION:-1.0.0}"
DBAEGIS_BUILD_CHANNEL="${DBAEGIS_BUILD_CHANNEL:-}"
DBAEGIS_RELEASE_NAME="${DBAEGIS_RELEASE_NAME:-}"
DBAEGIS_BUILD_TIME="${DBAEGIS_BUILD_TIME:-}"
DBAEGIS_GIT_COMMIT="${DBAEGIS_GIT_COMMIT:-${GIT_COMMIT:-}}"
DBAEGIS_EDITION_ENV_PROVIDED=0
DBAEGIS_LICENSE_REQUIRED_ENV_PROVIDED=0
DBAEGIS_LICENSE_INSTANCE_ID_ENV_PROVIDED=0
[[ -n "${DBAEGIS_EDITION+x}" ]] && DBAEGIS_EDITION_ENV_PROVIDED=1
[[ -n "${DBAEGIS_LICENSE_REQUIRED+x}" ]] && DBAEGIS_LICENSE_REQUIRED_ENV_PROVIDED=1
[[ -n "${DBAEGIS_LICENSE_INSTANCE_ID+x}" ]] && DBAEGIS_LICENSE_INSTANCE_ID_ENV_PROVIDED=1

find_packaged_release_manifest() {
    local candidate
    for candidate in \
        "${SCRIPT_PARENT_DIR}/release.json" \
        "${SCRIPT_DIR}/release.json" \
        "${SCRIPT_PARENT_DIR}/conf/release.json" \
        "${SCRIPT_DIR}/conf/release.json" \
        "${SCRIPT_PARENT_DIR}/app/release.json" \
        "${SCRIPT_DIR}/app/release.json"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

read_packaged_release_manifest_value() {
    local manifest_path="$1" key="$2" value=""
    [[ -f "$manifest_path" ]] || return 0
    if command -v python3 >/dev/null 2>&1; then
        value="$(python3 - "$manifest_path" "$key" 2>/dev/null <<'PY' || true
from __future__ import annotations

import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(sys.argv[2])
if value not in (None, ""):
    print(value)
PY
)"
    fi
    if [[ -z "$value" ]]; then
        value="$(awk -v key="$key" '
            $0 ~ "\"" key "\"[[:space:]]*:" {
                line = $0
                sub(".*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", line)
                sub("\".*", "", line)
                print line
                exit
            }
        ' "$manifest_path" 2>/dev/null || true)"
    fi
    printf '%s' "$value"
}

resolve_installer_version() {
    local candidate source_file="" parsed=""
    for candidate in \
        "${SCRIPT_PARENT_DIR}/app/version.py" \
        "${SCRIPT_DIR}/app/version.py" \
        "${SCRIPT_DIR}/version.py" \
        "${DBAEGIS_BASE}/app/version.py"; do
        if [[ -f "$candidate" ]]; then
            source_file="$candidate"
            break
        fi
    done
    [[ -n "$source_file" ]] || return 0
    parsed="$(awk -F= '
        /^PRODUCT_VERSION[[:space:]]*=/ {
            value=$2
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            sub(/^"/, "", value)
            sub(/"$/, "", value)
            print value
            exit
        }
    ' "$source_file" 2>/dev/null || true)"
    [[ -n "$parsed" ]] && DBAEGIS_VERSION="$parsed"
}
resolve_installer_version

if [[ -z "$DBAEGIS_BUILD_CHANNEL" && -n "$DBAEGIS_RELEASE_NAME" ]]; then
    DBAEGIS_BUILD_CHANNEL="stable"
fi
if [[ -n "$DBAEGIS_BUILD_CHANNEL" && -z "$DBAEGIS_RELEASE_NAME" ]]; then
    DBAEGIS_RELEASE_NAME="DBAegis ${DBAEGIS_VERSION}"
fi

INSTALL_LOG="/tmp/dbaegis-install-${DBAEGIS_VERSION}-$(date +%Y%m%d-%H%M%S).log"
: > "$INSTALL_LOG"
chmod 600 "$INSTALL_LOG"
exec > >(tee -a "$INSTALL_LOG") 2>&1
echo "[INFO] Installer log: $INSTALL_LOG"

# Prevent accidental concurrent re-entry/looping on install or upgrade.
DBAEGIS_LOOP_GUARD_FILE="/run/dbaegis-install-loop-guard"

installer_loop_guard_clear() {
    local guard_pid=""
    [[ -f "$DBAEGIS_LOOP_GUARD_FILE" ]] || return 0
    guard_pid="$(awk -F= '/^pid=/{print $2}' "$DBAEGIS_LOOP_GUARD_FILE" 2>/dev/null || true)"
    if [[ "$guard_pid" == "$$" ]]; then
        rm -f "$DBAEGIS_LOOP_GUARD_FILE"
    fi
}

installer_loop_guard_check() {
    local guard_mode="$1" guard_version="" guard_mode_file="" guard_ts="" guard_pid="" now
    now="$(date +%s)"
    if [[ -f "$DBAEGIS_LOOP_GUARD_FILE" ]]; then
        guard_version="$(awk -F= '/^version=/{print $2}' "$DBAEGIS_LOOP_GUARD_FILE" 2>/dev/null || true)"
        guard_mode_file="$(awk -F= '/^mode=/{print $2}' "$DBAEGIS_LOOP_GUARD_FILE" 2>/dev/null || true)"
        guard_ts="$(awk -F= '/^ts=/{print $2}' "$DBAEGIS_LOOP_GUARD_FILE" 2>/dev/null || true)"
        guard_pid="$(awk -F= '/^pid=/{print $2}' "$DBAEGIS_LOOP_GUARD_FILE" 2>/dev/null || true)"
        if [[ "$guard_version" == "$DBAEGIS_VERSION" && "$guard_mode_file" == "$guard_mode" && -n "$guard_ts" && -n "$guard_pid" ]]; then
            if (( now - guard_ts < 120 )) && kill -0 "$guard_pid" 2>/dev/null; then
                echo "[INFO] Detected running installer for ${guard_mode} ${DBAEGIS_VERSION} at pid ${guard_pid}; skipping duplicate run."
                exit 0
            fi
        fi
    fi
    {
        echo "version=${DBAEGIS_VERSION}"
        echo "mode=${guard_mode}"
        echo "ts=${now}"
        echo "pid=$$"
    } > "$DBAEGIS_LOOP_GUARD_FILE"
    chmod 600 "$DBAEGIS_LOOP_GUARD_FILE" 2>/dev/null || true
    trap installer_loop_guard_clear EXIT
}


# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}── $* ──────────────────────────────────────${NC}"; }

normalize_dbaegis_edition() {
    local edition="${1,,}"
    case "$edition" in
        community|professional|enterprise)
            printf '%s' "$edition"
            ;;
        *)
            die "Unknown DBAEGIS_EDITION '${1}'. Use community, professional, or enterprise."
            ;;
    esac
}

# ── Require root ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"

# ── Resolve install user ──────────────────────────────────────────────────────
# Respect DBAEGIS_USER env, otherwise use SUDO_USER, otherwise current user.
# Upgrades refine this after reading the active config so they preserve SERVICE_USER.
INSTALL_USER="${DBAEGIS_USER:-${SUDO_USER:-$(whoami)}}"
INSTALL_GROUP=$(id -gn "$INSTALL_USER" 2>/dev/null || echo "$INSTALL_USER")
info "Initial DBAegis install user: ${BOLD}${INSTALL_USER}${NC}"

# ── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID,,}"
        OS_VERSION_ID="${VERSION_ID:-}"
        OS_VER="${VERSION_ID%%.*}"
    else
        die "Cannot detect OS — /etc/os-release not found"
    fi
}
detect_os

# ── Install mode ───────────────────────────────────────────────────────────────
MODE="${1:-auto}"
case "$MODE" in
  auto|--auto) MODE="auto" ;;
  fresh|--fresh) MODE="fresh" ;;
  upgrade|--upgrade) MODE="upgrade" ;;
  rollback|--rollback) MODE="rollback" ;;
  *) die "Unknown mode '$MODE'. Use --fresh, --upgrade, or --rollback" ;;
esac
OS_PACKAGE_MODE="${DBAEGIS_OS_PACKAGE_MODE:-install}"
case "$OS_PACKAGE_MODE" in
  missing-only|install) ;;
  *) die "Unknown DBAEGIS_OS_PACKAGE_MODE '${OS_PACKAGE_MODE}'. Use missing-only or install" ;;
esac

DBAEGIS_PACKAGED_RELEASE_MANIFEST="$(find_packaged_release_manifest || true)"
DBAEGIS_PACKAGED_EDITION=""
if [[ -n "$DBAEGIS_PACKAGED_RELEASE_MANIFEST" ]]; then
    DBAEGIS_PACKAGED_EDITION="$(read_packaged_release_manifest_value "$DBAEGIS_PACKAGED_RELEASE_MANIFEST" "edition" || true)"
fi

# ── Paths — all derived from DBAEGIS_BASE (override before running) ───────────
DBAEGIS_BASE="${DBAEGIS_BASE:-/opt/dbaegis}"
CONF_FILE="${DBAEGIS_CONF:-${DBAEGIS_BASE}/conf/dbaegis.conf}"
CONF_DIR="$(dirname "$CONF_FILE")"

# These will be read from conf after generation, but set defaults here too
APP_DIR="${DBAEGIS_BASE}/app"
UI_DIR="${DBAEGIS_BASE}/ui"
DATA_DIR="${DBAEGIS_BASE}/data"
DBAEGIS_DB_PATH="${DBAEGIS_DB_PATH:-${DATA_DIR}/dbaegis.db}"
BACKUP_DIR="${DBAEGIS_BACKUP_DIR:-/backups}"
LOG_DIR="${DBAEGIS_BASE}/logs"
LOG_BACKUP_COUNT="${DBAEGIS_LOG_BACKUP_COUNT:-${LOG_BACKUP_COUNT:-9}}"
TEMP_DIR="${DBAEGIS_TEMP_DIR:-${DBAEGIS_BASE}/tmp}"
LICENSE_DIR="${DBAEGIS_LICENSE_DIR:-${DBAEGIS_BASE}/license}"
DBAEGIS_EDITION_SOURCE="default"
if (( DBAEGIS_EDITION_ENV_PROVIDED )); then
    DBAEGIS_EDITION_SOURCE="environment"
elif [[ -n "$DBAEGIS_PACKAGED_EDITION" ]]; then
    DBAEGIS_EDITION="$DBAEGIS_PACKAGED_EDITION"
    DBAEGIS_EDITION_SOURCE="package"
else
    DBAEGIS_EDITION="${DBAEGIS_EDITION:-community}"
fi
DBAEGIS_EDITION="$(normalize_dbaegis_edition "$DBAEGIS_EDITION")"
DBAEGIS_LICENSE_REQUIRED="${DBAEGIS_LICENSE_REQUIRED:-false}"
case "${DBAEGIS_EDITION}" in
    professional|enterprise)
        DBAEGIS_LICENSE_REQUIRED=true
        ;;
esac
DBAEGIS_LICENSE_KEY_FILE="${DBAEGIS_LICENSE_KEY_FILE:-${LICENSE_DIR}/dbaegis.license}"
DBAEGIS_LICENSE_PUBLIC_KEY_FILE="${DBAEGIS_LICENSE_PUBLIC_KEY_FILE:-${LICENSE_DIR}/license_public.pem}"
DBAEGIS_LICENSE_INSTANCE_ID="${DBAEGIS_LICENSE_INSTANCE_ID:-}"
SELF_BACKUP_DIR="${BACKUP_DIR}/self"
VENV_DIR="${DBAEGIS_BASE}/venv"
ROLLBACK_DIR="${DBAEGIS_ROLLBACK_DIR:-${DBAEGIS_BASE}/rollback}"
ROLLBACK_SNAPSHOT="${DBAEGIS_ROLLBACK_SNAPSHOT:-}"
PYTHON_DIR="${DBAEGIS_PYTHON_DIR:-${DBAEGIS_BASE}/python}"
PYTHON_BIN="${DBAEGIS_PYTHON_BIN:-${PYTHON_DIR}/bin/python3}"
PYTHON_RELEASE="${DBAEGIS_PYTHON_RELEASE:-20260414}"
PYTHON_VERSION="${DBAEGIS_PYTHON_VERSION:-3.12.13}"
MIN_PYTHON_VERSION="3.12"
PYTHON_DOWNLOAD="${DBAEGIS_PYTHON_DOWNLOAD:-auto}"
DB_PARENT_DIR="$(dirname "${DBAEGIS_DB_PATH}")"
PYTHON_URL_CUSTOM=0

case "$(uname -m)" in
    x86_64|amd64) PYTHON_TRIPLET="${DBAEGIS_PYTHON_TRIPLET:-x86_64-unknown-linux-gnu}" ;;
    aarch64|arm64) PYTHON_TRIPLET="${DBAEGIS_PYTHON_TRIPLET:-aarch64-unknown-linux-gnu}" ;;
    *) PYTHON_TRIPLET="${DBAEGIS_PYTHON_TRIPLET:-}" ;;
esac
if [[ -n "${DBAEGIS_PYTHON_URL:-}" ]]; then
    PYTHON_URL="${DBAEGIS_PYTHON_URL}"
    PYTHON_URL_CUSTOM=1
elif [[ -n "$PYTHON_TRIPLET" ]]; then
    PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}%2B${PYTHON_RELEASE}-${PYTHON_TRIPLET}-install_only.tar.gz"
else
    PYTHON_URL=""
fi
PYTHON_SHA256="${DBAEGIS_PYTHON_SHA256:-}"
if [[ -z "$PYTHON_SHA256" && "$PYTHON_URL_CUSTOM" != "1" ]]; then
    case "${PYTHON_VERSION}:${PYTHON_RELEASE}:${PYTHON_TRIPLET}" in
        "3.12.13:20260414:x86_64-unknown-linux-gnu")
            PYTHON_SHA256="cdcf8724d46e4857f8db5ee9f4252dc2f5da34f7940294ec6b312389dd3f41e0"
            ;;
        "3.12.13:20260414:aarch64-unknown-linux-gnu")
            PYTHON_SHA256="355d981eafb9b2870af79ddc106ced7266b6f6d2101d8fbcb05620fa386642b9"
            ;;
    esac
fi

API_PORT="${DBAEGIS_API_PORT:-8000}"
UI_PORT="${DBAEGIS_UI_PORT:-3000}"
HTTPS_PORT="${DBAEGIS_HTTPS_PORT:-3443}"
TLS_MODE="${DBAEGIS_TLS_MODE:-off}"
HTTP_BEHAVIOR="${DBAEGIS_HTTP_BEHAVIOR:-both}"
SERVICE_PRIVATE_TMP="${DBAEGIS_SERVICE_PRIVATE_TMP:-no}"
OS_PACKAGE_MODE="${OS_PACKAGE_MODE:-install}"
TLS_SERVER_NAME="${DBAEGIS_TLS_SERVER_NAME:-localhost}"
TLS_CERT_PATH="${DBAEGIS_TLS_CERT_PATH:-${DBAEGIS_BASE}/tls/server.crt}"
TLS_KEY_PATH="${DBAEGIS_TLS_KEY_PATH:-${DBAEGIS_BASE}/tls/server.key}"
TLS_CHAIN_PATH="${DBAEGIS_TLS_CHAIN_PATH:-${DBAEGIS_BASE}/tls/chain.crt}"
INSTALL_SNOWSQL="${DBAEGIS_INSTALL_SNOWSQL:-0}"
SNOWSQL_VERSION="${DBAEGIS_SNOWSQL_VERSION:-1.5.0}"
SNOWSQL_BOOTSTRAP_VERSION="${DBAEGIS_SNOWSQL_BOOTSTRAP_VERSION:-1.5}"
SNOWSQL_INSTALLER_SHA256_DEFAULT="3124e9b642fab946e701e64e72417fa90797a5708156d3d974eeaf9bea4402c3"
SNOWSQL_INSTALLER_URL="${DBAEGIS_SNOWSQL_URL:-https://sfc-repo.snowflakecomputing.com/snowsql/bootstrap/${SNOWSQL_BOOTSTRAP_VERSION}/linux_x86_64/snowsql-${SNOWSQL_VERSION}-linux_x86_64.bash}"
SNOWSQL_INSTALLER_SHA256="${DBAEGIS_SNOWSQL_SHA256:-${SNOWSQL_INSTALLER_SHA256_DEFAULT}}"
SNOWSQL_HOME="${DBAEGIS_SNOWSQL_HOME:-${DBAEGIS_BASE}}"
SNOWSQL_DEST="${DBAEGIS_SNOWSQL_DEST:-${DBAEGIS_BASE}/vendor/snowsql/bin}"
SNOWSQL_LINK="${DBAEGIS_SNOWSQL_LINK:-/usr/local/bin/snowsql}"
INSTALL_SQLPACKAGE="${DBAEGIS_INSTALL_SQLPACKAGE:-0}"
SQLPACKAGE_URL="${DBAEGIS_SQLPACKAGE_URL:-https://aka.ms/sqlpackage-linux}"
SQLPACKAGE_SHA256="${DBAEGIS_SQLPACKAGE_SHA256:-}"
SQLPACKAGE_DEST="${DBAEGIS_SQLPACKAGE_DEST:-${DBAEGIS_BASE}/vendor/sqlpackage}"
INSTALL_SQLCMD="${DBAEGIS_INSTALL_SQLCMD:-0}"
ACCEPT_MICROSOFT_EULA="${DBAEGIS_ACCEPT_MICROSOFT_EULA:-0}"
INSTALL_MONGODB_TOOLS="${DBAEGIS_INSTALL_MONGODB_TOOLS:-0}"
MONGODB_TOOLS_VERSION="${DBAEGIS_MONGODB_TOOLS_VERSION:-100.16.1}"
MONGODB_TOOLS_URL="${DBAEGIS_MONGODB_TOOLS_URL:-}"
MONGODB_TOOLS_SHA256="${DBAEGIS_MONGODB_TOOLS_SHA256:-}"
MONGOSH_VERSION="${DBAEGIS_MONGOSH_VERSION:-2.8.2}"
MONGOSH_URL="${DBAEGIS_MONGOSH_URL:-}"
MONGOSH_SHA256="${DBAEGIS_MONGOSH_SHA256:-}"
MONGODB_INSTALL_ROOT="${DBAEGIS_MONGODB_INSTALL_ROOT:-/opt/dbaegis-tools/mongodb}"
INSTALL_CLICKHOUSE_CLIENT="${DBAEGIS_INSTALL_CLICKHOUSE_CLIENT:-0}"
CLICKHOUSE_REPO_CHANNEL="${DBAEGIS_CLICKHOUSE_REPO_CHANNEL:-stable}"
CLICKHOUSE_VERSION="${DBAEGIS_CLICKHOUSE_VERSION:-}"

read_existing_conf_value() {
    local target="$1" key="$2" raw
    [[ -f "$target" ]] || return 0
    raw="$(awk -v key="$key" '
        /^[[:space:]]*($|#)/ { next }
        {
            line = $0
            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                sub(/^[^=]*=/, "", line)
                sub(/^[[:space:]]*/, "", line)
                sub(/[[:space:]]*#.*$/, "", line)
                print line
                exit
            }
        }
    ' "$target" 2>/dev/null || true)"
    raw="${raw%\"}"
    raw="${raw#\"}"
    raw="${raw%\'}"
    raw="${raw#\'}"
    printf '%s' "$raw"
}

resolve_install_identity_from_conf() {
    local configured_user=""
    if [[ -z "${DBAEGIS_USER:-}" && "$MODE" != "fresh" && -f "$CONF_FILE" ]]; then
        configured_user="$(read_existing_conf_value "$CONF_FILE" "SERVICE_USER" || true)"
        if [[ -n "$configured_user" && "$configured_user" != "$INSTALL_USER" ]]; then
            INSTALL_USER="$configured_user"
            INSTALL_GROUP=$(id -gn "$INSTALL_USER" 2>/dev/null || echo "$INSTALL_USER")
            info "Using existing configured service user: ${BOLD}${INSTALL_USER}${NC}"
        fi
    fi
}

resolve_install_identity_from_conf

validate_install_user() {
    if ! id -u "$INSTALL_USER" >/dev/null 2>&1; then
        die "DBAEGIS_USER '${INSTALL_USER}' does not exist. Create the OS service user first, or rerun with an existing DBAEGIS_USER."
    fi
    INSTALL_GROUP="$(id -gn "$INSTALL_USER" 2>/dev/null)" || die "Could not resolve primary group for DBAEGIS_USER '${INSTALL_USER}'"
}

validate_install_user

load_existing_conf_runtime_paths() {
    local value
    [[ -f "$CONF_FILE" ]] || return 0

    value="$(read_existing_conf_value "$CONF_FILE" "APP_DIR")"
    [[ -n "$value" ]] && APP_DIR="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "UI_DIR")"
    [[ -n "$value" ]] && UI_DIR="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "DBAEGIS_DB_PATH")"
    [[ -n "$value" ]] && DBAEGIS_DB_PATH="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "BACKUP_DIR")"
    [[ -n "$value" ]] && BACKUP_DIR="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "SELF_BACKUP_DIR")"
    [[ -n "$value" ]] && SELF_BACKUP_DIR="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "LOG_DIR")"
    [[ -n "$value" ]] && LOG_DIR="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "DBAEGIS_TEMP_DIR")"
    [[ -n "$value" ]] && TEMP_DIR="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "DBAEGIS_LICENSE_DIR")"
    [[ -n "$value" ]] && LICENSE_DIR="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "VENV_DIR")"
    [[ -n "$value" ]] && VENV_DIR="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "DBAEGIS_PYTHON_DIR")"
    [[ -n "$value" ]] && PYTHON_DIR="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "DBAEGIS_PYTHON_BIN")"
    [[ -n "$value" ]] && PYTHON_BIN="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "API_PORT")"
    [[ -n "$value" ]] && API_PORT="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "UI_PORT")"
    [[ -n "$value" ]] && UI_PORT="$value"
    value="$(read_existing_conf_value "$CONF_FILE" "HTTPS_PORT")"
    [[ -n "$value" ]] && HTTPS_PORT="$value"
    DB_PARENT_DIR="$(dirname "${DBAEGIS_DB_PATH}")"
}

path_is_under_base() {
    local target="$1" base_real target_parent target_real
    base_real="$(cd "$DBAEGIS_BASE" 2>/dev/null && pwd -P)" || return 1
    if [[ -e "$target" ]]; then
        target_real="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)/$(basename "$target")" || return 1
    else
        target_parent="$(dirname "$target")"
        target_real="$(mkdir -p "$target_parent" && cd "$target_parent" && pwd -P)/$(basename "$target")" || return 1
    fi
    [[ "$target_real" == "$base_real" || "$target_real" == "$base_real"/* ]]
}

runtime_tar_entries() {
    local entries=()
    local entry
    for entry in app ui bin docs venv release.json UPGRADE_AND_INSTALL.txt; do
        [[ -e "${DBAEGIS_BASE}/${entry}" ]] && entries+=("$entry")
    done
    printf '%s\n' "${entries[@]}"
}

create_upgrade_snapshot() {
    [[ "$MODE" == "upgrade" ]] || return 0
    [[ -d "$DBAEGIS_BASE" ]] || return 0

    local timestamp snapshot_dir manifest_file entries=()
    timestamp="$(date +%Y%m%d-%H%M%S)"
    snapshot_dir="${ROLLBACK_DIR}/${timestamp}"
    manifest_file="${snapshot_dir}/manifest.txt"

    mkdir -p "$snapshot_dir"
    chmod 700 "$ROLLBACK_DIR" "$snapshot_dir"
    chown "${INSTALL_USER}:${INSTALL_GROUP}" "$ROLLBACK_DIR" "$snapshot_dir" 2>/dev/null || true

    mapfile -t entries < <(runtime_tar_entries)
    if (( ${#entries[@]} == 0 )); then
        warn "No runtime files found to snapshot before upgrade"
        return 0
    fi

    tar -czf "${snapshot_dir}/runtime.tar.gz" -C "$DBAEGIS_BASE" "${entries[@]}"
    if [[ -f /etc/systemd/system/dbaegis.service ]]; then
        cp -a /etc/systemd/system/dbaegis.service "${snapshot_dir}/dbaegis.service"
    fi

    {
        echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "mode=pre-upgrade"
        echo "dbaegis_base=${DBAEGIS_BASE}"
        echo "conf_file=${CONF_FILE}"
        echo "runtime_archive=runtime.tar.gz"
        echo "entries=${entries[*]}"
        [[ -f "$CONF_FILE" ]] && sha256sum "$CONF_FILE" | awk '{print "conf_sha256="$1}'
        [[ -f "$DBAEGIS_DB_PATH" ]] && sha256sum "$DBAEGIS_DB_PATH" | awk '{print "db_sha256="$1}'
        if [[ -x "${VENV_DIR}/bin/python" ]]; then
            cd "$DBAEGIS_BASE" && PYTHONPATH="$DBAEGIS_BASE" "${VENV_DIR}/bin/python" -m app.version --json 2>/dev/null | sed 's/^/version_before=/'
        fi
    } > "$manifest_file"

    chmod 600 "${snapshot_dir}/runtime.tar.gz" "$manifest_file"
    [[ -f "${snapshot_dir}/dbaegis.service" ]] && chmod 600 "${snapshot_dir}/dbaegis.service"
    chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$snapshot_dir" 2>/dev/null || true
    success "Pre-upgrade runtime snapshot created at ${snapshot_dir}"
}

latest_rollback_snapshot() {
    find "$ROLLBACK_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | sort | tail -n 1
}

resolve_rollback_snapshot() {
    if [[ -n "$ROLLBACK_SNAPSHOT" ]]; then
        if [[ "$ROLLBACK_SNAPSHOT" == /* ]]; then
            printf '%s\n' "$ROLLBACK_SNAPSHOT"
        else
            printf '%s\n' "${ROLLBACK_DIR}/${ROLLBACK_SNAPSHOT}"
        fi
        return 0
    fi
    latest_rollback_snapshot
}

rollback_restore_failed() {
    local entry
    warn "Rollback did not complete. Attempting to restore displaced runtime files."
    if [[ -n "${ROLLBACK_WORK_DIR:-}" && -d "$ROLLBACK_WORK_DIR" ]]; then
        for entry in app ui bin docs venv release.json UPGRADE_AND_INSTALL.txt; do
            if [[ -e "${ROLLBACK_WORK_DIR}/${entry}" ]]; then
                rm -rf "${DBAEGIS_BASE:?}/${entry}"
                mv "${ROLLBACK_WORK_DIR}/${entry}" "${DBAEGIS_BASE}/${entry}"
            fi
        done
        warn "Displaced runtime files were restored from ${ROLLBACK_WORK_DIR}"
    else
        warn "No displaced runtime directory was available to restore"
    fi
}

run_rollback() {
    load_existing_conf_runtime_paths

    local snapshot_dir runtime_archive timestamp restore_backup entry
    snapshot_dir="$(resolve_rollback_snapshot)"
    [[ -n "$snapshot_dir" && -d "$snapshot_dir" ]] || die "No rollback snapshot found under ${ROLLBACK_DIR}"
    runtime_archive="${snapshot_dir}/runtime.tar.gz"
    [[ -f "$runtime_archive" ]] || die "Rollback snapshot is missing runtime.tar.gz: ${snapshot_dir}"

    for entry in "$APP_DIR" "$UI_DIR" "${DBAEGIS_BASE}/bin" "$VENV_DIR"; do
        path_is_under_base "$entry" || die "Refusing rollback because ${entry} is outside ${DBAEGIS_BASE}"
    done

    header "Rollback"
    info "Using rollback snapshot: ${BOLD}${snapshot_dir}${NC}"
    info "Active config and SQLite metadata DB will be preserved"

    systemctl stop dbaegis.service 2>/dev/null || true

    timestamp="$(date +%Y%m%d-%H%M%S)"
    restore_backup="${ROLLBACK_DIR}/displaced-runtime-${timestamp}"
    ROLLBACK_WORK_DIR="$restore_backup"
    mkdir -p "$restore_backup"
    chmod 700 "$restore_backup"
    trap rollback_restore_failed ERR

    for entry in app ui bin docs venv release.json UPGRADE_AND_INSTALL.txt; do
        if [[ -e "${DBAEGIS_BASE}/${entry}" ]]; then
            mv "${DBAEGIS_BASE}/${entry}" "${restore_backup}/${entry}"
        fi
    done

    tar -xzf "$runtime_archive" -C "$DBAEGIS_BASE"

    if [[ -f "${snapshot_dir}/dbaegis.service" ]]; then
        cp -a "${snapshot_dir}/dbaegis.service" /etc/systemd/system/dbaegis.service
    else
        warn "Snapshot has no systemd unit copy; keeping current dbaegis.service"
    fi

    chown -R "${INSTALL_USER}:${INSTALL_GROUP}" \
        "${DBAEGIS_BASE}/app" \
        "${DBAEGIS_BASE}/ui" \
        "${DBAEGIS_BASE}/bin" \
        "${DBAEGIS_BASE}/docs" \
        "$VENV_DIR" 2>/dev/null || true
    [[ -f "${DBAEGIS_BASE}/release.json" ]] && chown "${INSTALL_USER}:${INSTALL_GROUP}" "${DBAEGIS_BASE}/release.json"
    [[ -f "${DBAEGIS_BASE}/UPGRADE_AND_INSTALL.txt" ]] && chown "${INSTALL_USER}:${INSTALL_GROUP}" "${DBAEGIS_BASE}/UPGRADE_AND_INSTALL.txt"
    [[ -d "${DBAEGIS_BASE}/docs" ]] && chmod 755 "${DBAEGIS_BASE}/docs"
    [[ -f "${DBAEGIS_BASE}/bin/dbaegis" ]] && chmod +x "${DBAEGIS_BASE}/bin/dbaegis"
    [[ -f "${DBAEGIS_BASE}/bin/dbaegis-stack" ]] && chmod +x "${DBAEGIS_BASE}/bin/dbaegis-stack"
    [[ -f "${DBAEGIS_BASE}/bin/install.sh" ]] && chmod +x "${DBAEGIS_BASE}/bin/install.sh"
    [[ -f "${DBAEGIS_BASE}/bin/uninstall.sh" ]] && chmod +x "${DBAEGIS_BASE}/bin/uninstall.sh"
    [[ -f "${DBAEGIS_BASE}/bin/rotate_dbaegis_secret_key.py" ]] && chmod +x "${DBAEGIS_BASE}/bin/rotate_dbaegis_secret_key.py"
    [[ -f "${DBAEGIS_BASE}/bin/reset_admin_password.py" ]] && chmod +x "${DBAEGIS_BASE}/bin/reset_admin_password.py"

    systemctl daemon-reload
    systemctl start dbaegis.service
    sleep 2

    if systemctl is-active --quiet dbaegis.service; then
        success "Rollback complete; dbaegis is running"
        info "Displaced runtime from before rollback is stored at ${restore_backup}"
    else
        die "Rollback restored files, but dbaegis did not start. Check: journalctl -u dbaegis -n 50"
    fi

    trap - ERR
    exit 0
}

chown_tree_if_under_base() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    if path_is_under_base "$target"; then
        chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$target" 2>/dev/null || true
    else
        chown "${INSTALL_USER}:${INSTALL_GROUP}" "$target" 2>/dev/null || true
    fi
}

chown_dir_only() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    chown "${INSTALL_USER}:${INSTALL_GROUP}" "$target" 2>/dev/null || true
}

repair_sqlpackage_permissions() {
    local package_dir="$1"
    local parent_dir link_target
    parent_dir="$(dirname "$package_dir")"
    if [[ -d "$parent_dir" ]]; then
        if declared_under_base "$parent_dir"; then
            chown "${INSTALL_USER}:${INSTALL_GROUP}" "$parent_dir" 2>/dev/null || true
        else
            chown root:root "$parent_dir" 2>/dev/null || true
        fi
    fi
    [[ -d "$parent_dir" ]] && chmod 755 "$parent_dir" 2>/dev/null || true
    [[ -e "$package_dir" ]] || return 0
    if declared_under_base "$package_dir"; then
        chown "${INSTALL_USER}:${INSTALL_GROUP}" "$package_dir" 2>/dev/null || true
    else
        chown root:root "$package_dir" 2>/dev/null || true
    fi
    chmod 755 "$package_dir" 2>/dev/null || true
    if [[ -d "$package_dir" ]]; then
        if declared_under_base "$package_dir"; then
            chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$package_dir" 2>/dev/null || true
        else
            chown -R root:root "$package_dir" 2>/dev/null || true
        fi
        chmod -R u+rwX,go+rX "$package_dir" 2>/dev/null || true
    fi
    [[ -f "${package_dir}/sqlpackage" ]] && chmod 755 "${package_dir}/sqlpackage" 2>/dev/null || true
    if [[ -L /usr/local/bin/sqlpackage ]]; then
        link_target="$(readlink -f /usr/local/bin/sqlpackage 2>/dev/null || true)"
        if [[ "$link_target" == "${package_dir}/sqlpackage" ]]; then
            chown -h root:root /usr/local/bin/sqlpackage 2>/dev/null || true
        fi
    fi
}

repair_snowsql_permissions() {
    local snowsql_root link_target
    [[ -n "${SNOWSQL_DEST:-}" ]] || return 0
    snowsql_root="$SNOWSQL_DEST"
    [[ "$(basename "$snowsql_root")" == "bin" ]] && snowsql_root="$(dirname "$snowsql_root")"
    [[ -e "$snowsql_root" ]] || return 0
    if declared_under_base "$snowsql_root"; then
        chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$snowsql_root" 2>/dev/null || true
        chmod -R u+rwX,go+rX "$snowsql_root" 2>/dev/null || true
    fi
    if [[ -L "$SNOWSQL_LINK" ]]; then
        link_target="$(readlink -f "$SNOWSQL_LINK" 2>/dev/null || true)"
        if [[ "$link_target" == "${SNOWSQL_DEST}/snowsql" ]]; then
            chown -h root:root "$SNOWSQL_LINK" 2>/dev/null || true
        fi
    elif [[ -f "$SNOWSQL_LINK" ]] && grep -Fq "exec \"${SNOWSQL_DEST}/snowsql\"" "$SNOWSQL_LINK" 2>/dev/null; then
        chown root:root "$SNOWSQL_LINK" 2>/dev/null || true
        chmod 755 "$SNOWSQL_LINK" 2>/dev/null || true
    fi
}

repair_vendor_permissions() {
    local vendor_dir="${DBAEGIS_BASE}/vendor"
    if [[ -d "$vendor_dir" ]]; then
        chown "${INSTALL_USER}:${INSTALL_GROUP}" "$vendor_dir" 2>/dev/null || true
        chmod 755 "$vendor_dir" 2>/dev/null || true
    fi
    repair_snowsql_permissions
    repair_sqlpackage_permissions "$SQLPACKAGE_DEST"
}

repair_root_controlled_paths() {
    # Rollback snapshots stay under the DBAegis service user's ownership for
    # consistent install audits. Vendor tools under the install base follow the
    # service-user ownership model; root-owned wrappers stay outside the base.
    if [[ -d "$ROLLBACK_DIR" ]]; then
        chown "${INSTALL_USER}:${INSTALL_GROUP}" "$ROLLBACK_DIR" 2>/dev/null || true
        chmod 700 "$ROLLBACK_DIR" 2>/dev/null || true
    fi
    repair_vendor_permissions
}

declared_under_base() {
    local target="$1" base="${DBAEGIS_BASE%/}"
    [[ "$target" == "$base" || "$target" == "$base/"* ]]
}

secure_tls_paths() {
    local tls_path tls_dir
    for tls_path in "$TLS_CERT_PATH" "$TLS_KEY_PATH" "$TLS_CHAIN_PATH"; do
        [[ -n "${tls_path:-}" ]] || continue
        tls_dir="$(dirname "$tls_path")"
        if declared_under_base "$tls_dir"; then
            mkdir -p "$tls_dir"
            chown "${INSTALL_USER}:${INSTALL_GROUP}" "$tls_dir" 2>/dev/null || true
            chmod 700 "$tls_dir" 2>/dev/null || true
        fi
        if [[ -e "$tls_path" ]] && declared_under_base "$tls_path"; then
            chown "${INSTALL_USER}:${INSTALL_GROUP}" "$tls_path" 2>/dev/null || true
            if [[ "$(basename "$tls_path")" == *key* ]]; then
                chmod 600 "$tls_path" 2>/dev/null || true
            else
                chmod 644 "$tls_path" 2>/dev/null || true
            fi
        fi
    done
}

chown_install_paths() {
    chown "${INSTALL_USER}:${INSTALL_GROUP}" "$DBAEGIS_BASE" 2>/dev/null || true
    for path in \
        "${DBAEGIS_BASE}/bin" \
        "$APP_DIR" \
        "$UI_DIR" \
        "$DATA_DIR" \
        "$LOG_DIR" \
        "$LICENSE_DIR" \
        "${DBAEGIS_BASE}/run" \
        "$VENV_DIR" \
        "$PYTHON_DIR"; do
        chown_tree_if_under_base "$path"
    done
    secure_tls_paths
    for path in "$DB_PARENT_DIR" "$BACKUP_DIR" "$SELF_BACKUP_DIR" "$TEMP_DIR" "$CONF_DIR" "$LICENSE_DIR"; do
        chown_dir_only "$path"
    done
    [[ -e "$DBAEGIS_DB_PATH" ]] && chown "${INSTALL_USER}:${INSTALL_GROUP}" "$DBAEGIS_DB_PATH" 2>/dev/null || true
    repair_root_controlled_paths
}

PYTHON_CONSTRAINTS_FILE="${PYTHON_CONSTRAINTS_FILE:-${SCRIPT_PARENT_DIR}/requirements/install-constraints.txt}"

PYTHON_BUILD_PACKAGES=(
    "pip==26.1"
    "wheel==0.47.0"
    "setuptools==82.0.1"
)

CORE_PYTHON_PACKAGES=(
    "fastapi==0.136.1"
    "uvicorn[standard]==0.46.0"
    "pydantic==2.13.3"
    "httpx==0.28.1"
    "aiohttp==3.13.5"
    "python-multipart==0.0.27"
    "aiofiles==25.1.0"
    "croniter==6.2.2"
    "cryptography==47.0.0"
    "ldap3==2.9.1"
)

CORE_PYTHON_IMPORTS=(
    fastapi
    uvicorn
    pydantic
    httpx
    aiohttp
    multipart
    aiofiles
    croniter
    cryptography
    ldap3
)

OPTIONAL_DB_PYTHON_PACKAGES=(
    "cassandra-driver==3.30.0"
    "neo4j==6.1.0"
    "oracledb==3.4.2"
    "pymssql==2.3.13"
)

OPTIONAL_DB_CLI_PYTHON_PACKAGES=(
    "cqlsh==6.2.2"
)

OPTIONAL_DB_PYTHON_IMPORTS=(
    cassandra
    neo4j
    oracledb
    pymssql
)

OPTIONAL_CLOUD_PYTHON_PACKAGES=(
    "boto3==1.43.1"
    "google-cloud-storage==3.10.1"
    "google-cloud-firestore==2.27.0"
    "azure-storage-blob==12.28.0"
    "azure-cosmos==4.15.0"
)

OPTIONAL_CLOUD_PYTHON_IMPORTS=(
    boto3
    google.cloud.storage
    google.cloud.firestore
    azure.storage.blob
    azure.cosmos
)

verify_core_python_dependencies() {
    sudo -u "$INSTALL_USER" "$VENV_PYTHON" -c '
import importlib.util
import sys

missing = [name for name in sys.argv[1:] if importlib.util.find_spec(name) is None]
if missing:
    print("Missing required Python modules: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
' "${CORE_PYTHON_IMPORTS[@]}"
}

verify_optional_python_dependencies() {
    local label="$1"
    shift
    local output=""
    if output="$(sudo -u "$INSTALL_USER" "$VENV_PYTHON" -c '
import importlib.util
import sys

missing = [name for name in sys.argv[1:] if importlib.util.find_spec(name) is None]
if missing:
    print(", ".join(missing))
    sys.exit(1)
' "$@" 2>&1)"; then
        success "${label} Python dependency precheck passed"
    else
        warn "${label} Python module(s) missing after best-effort install: ${output}"
    fi
}

verify_optional_executable() {
    local label="$1"
    local command_path="$2"
    if sudo -u "$INSTALL_USER" test -x "$command_path"; then
        success "${label} executable precheck passed: ${command_path}"
    else
        warn "${label} executable missing after best-effort install: ${command_path}"
    fi
}

is_truthy() {
    case "${1,,}" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

download_to_path() {
    local url="$1" target="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$target" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$target" "$url"
    else
        return 1
    fi
}

rhel_pkg_install() {
    local requested=("$@")
    local packages=()
    local pkg
    if [[ "$OS_PACKAGE_MODE" == "missing-only" ]]; then
        for pkg in "${requested[@]}"; do
            if rpm -q "$pkg" >/dev/null 2>&1; then
                continue
            fi
            packages+=("$pkg")
        done
        if (( ${#packages[@]} == 0 )); then
            return 0
        fi
    else
        packages=("${requested[@]}")
    fi
    local args=(install -y)
    if [[ "${PKG_MGR:-}" == "dnf" ]]; then
        # Minimal RHEL/UBI images ship curl-minimal/coreutils-single; allow dnf
        # to replace them with the full client packages needed by DBAegis.
        args+=(--allowerasing)
    fi
    "$PKG_MGR" "${args[@]}" "${packages[@]}"
}

debian_pkg_installed() {
    local status=""
    status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
    [[ "$status" == "install ok installed" ]]
}

apt_pkg_available() {
    local candidate=""
    candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

apt_pkg_install() {
    local requested=("$@")
    local packages=()
    local pkg
    if [[ "$OS_PACKAGE_MODE" == "missing-only" ]]; then
        for pkg in "${requested[@]}"; do
            if debian_pkg_installed "$pkg"; then
                continue
            fi
            packages+=("$pkg")
        done
        if (( ${#packages[@]} == 0 )); then
            return 0
        fi
    else
        packages=("${requested[@]}")
    fi
    apt-get install -y "${packages[@]}"
}

install_snowsql_if_requested() {
    if ! is_truthy "$INSTALL_SNOWSQL"; then
        if command -v snowsql >/dev/null 2>&1; then
            success "SnowSQL already installed: $(command -v snowsql)"
        else
            warn "SnowSQL is not installed. Snowflake workflows need snowsql; set DBAEGIS_INSTALL_SNOWSQL=1 to install it during setup."
        fi
        return 0
    fi

    snowsql_version() {
        local candidate="$1"
        local output=""
        local attempted_as_user=0
        [[ -n "$candidate" && -x "$candidate" ]] || return 1
        if [[ "$(id -u)" -eq 0 ]] && id "$INSTALL_USER" >/dev/null 2>&1; then
            attempted_as_user=1
            if command -v sudo >/dev/null 2>&1; then
                output="$(sudo -u "$INSTALL_USER" env HOME="$SNOWSQL_HOME" "$candidate" --version 2>/dev/null || true)"
            elif command -v runuser >/dev/null 2>&1; then
                output="$(runuser -u "$INSTALL_USER" -- env HOME="$SNOWSQL_HOME" "$candidate" --version 2>/dev/null || true)"
            else
                attempted_as_user=0
            fi
        fi
        if [[ -z "$output" && "$attempted_as_user" -eq 0 ]]; then
            output="$(HOME="$SNOWSQL_HOME" "$candidate" --version 2>/dev/null || true)"
        fi
        printf '%s\n' "$output" | awk '/Version:/ {print $2; exit}'
    }

    if [[ "$(uname -m)" != "x86_64" ]]; then
        warn "Automatic SnowSQL install currently supports Linux x86_64 only; install SnowSQL manually for $(uname -m)"
        return 0
    fi

    local candidate existing_snowsql="" existing_version=""
    for candidate in "$SNOWSQL_LINK" "${SNOWSQL_DEST}/snowsql" "$(command -v snowsql 2>/dev/null || true)"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            existing_snowsql="$candidate"
            break
        fi
    done
    if [[ -n "$existing_snowsql" ]]; then
        existing_version="$(snowsql_version "$existing_snowsql" || true)"
        if [[ "$existing_version" == "$SNOWSQL_VERSION" ]]; then
            success "SnowSQL already installed: ${existing_snowsql} (${existing_version})"
            return 0
        fi
        info "SnowSQL ${existing_version:-unknown} found at ${existing_snowsql}; installing requested ${SNOWSQL_VERSION}"
    fi

    info "Installing SnowSQL ${SNOWSQL_VERSION} for Snowflake support"
    local installer="/tmp/snowsql-${SNOWSQL_VERSION}-linux_x86_64.bash"
    download_to_path "$SNOWSQL_INSTALLER_URL" "$installer" || {
        warn "Could not download SnowSQL installer from ${SNOWSQL_INSTALLER_URL}"
        return 0
    }
    chmod 600 "$installer"

    if [[ -n "$SNOWSQL_INSTALLER_SHA256" ]]; then
        echo "${SNOWSQL_INSTALLER_SHA256}  ${installer}" | sha256sum -c - >/dev/null || {
            warn "SnowSQL installer checksum verification failed"
            rm -f "$installer"
            return 0
        }
    fi

    mkdir -p "$SNOWSQL_HOME" "$SNOWSQL_DEST" "$(dirname "$SNOWSQL_LINK")"
    chown "${INSTALL_USER}:${INSTALL_GROUP}" "$SNOWSQL_HOME" 2>/dev/null || true
    chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$SNOWSQL_DEST" 2>/dev/null || true
    HOME="$SNOWSQL_HOME" SNOWSQL_DEST="$SNOWSQL_DEST" SNOWSQL_LOGIN_SHELL=/dev/null bash "$installer" >/tmp/dbaegis-snowsql-install.log 2>&1 || {
        warn "SnowSQL installer failed; see /tmp/dbaegis-snowsql-install.log"
        rm -f "$installer"
        return 0
    }
    chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "${SNOWSQL_HOME}/.snowsql" "$SNOWSQL_DEST" 2>/dev/null || true
    chmod 755 "$(dirname "$SNOWSQL_DEST")" "$SNOWSQL_DEST" 2>/dev/null || true
    chmod -R u+rwX,go+rX "$SNOWSQL_DEST" 2>/dev/null || true
    cat > "$SNOWSQL_LINK" << EOF
#!/usr/bin/env bash
export HOME="${SNOWSQL_HOME}"
exec "${SNOWSQL_DEST}/snowsql" "\$@"
EOF
    chmod 755 "$SNOWSQL_LINK"
    repair_snowsql_permissions
    rm -f "$installer"
    hash -r 2>/dev/null || true
    if [[ -x "$SNOWSQL_LINK" ]]; then
        local installed_snowsql installed_version
        installed_snowsql="$SNOWSQL_LINK"
        installed_version="$(snowsql_version "$installed_snowsql" || true)"
        if [[ "$installed_version" == "$SNOWSQL_VERSION" ]]; then
            success "SnowSQL installed: ${installed_snowsql} (${installed_version})"
        else
            warn "SnowSQL installer completed, but ${installed_snowsql} reports version ${installed_version:-unknown}; expected ${SNOWSQL_VERSION}"
        fi
    else
        warn "SnowSQL installer completed, but snowsql was not found in PATH"
    fi
}

sqlcmd_path() {
    local candidate
    for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd sqlcmd; do
        if [[ "$candidate" == */* && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        if [[ "$candidate" != */* ]] && command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

link_sqlcmd_if_possible() {
    local candidate="$1"
    [[ -n "$candidate" && "$candidate" == */* && -x "$candidate" ]] || return 0
    ln -sf "$candidate" /usr/local/bin/sqlcmd 2>/dev/null || true
}

install_sqlpackage_if_requested() {
    sqlpackage_accessible_for_service_user() {
        local candidate="$1"
        [[ -n "$candidate" && -x "$candidate" ]] || return 1
        if [[ "$(id -u)" -eq 0 ]] && command -v sudo >/dev/null 2>&1 && id "$INSTALL_USER" >/dev/null 2>&1; then
            sudo -u "$INSTALL_USER" test -x "$candidate" >/dev/null 2>&1 || return 1
        elif [[ "$(id -u)" -eq 0 ]] && command -v runuser >/dev/null 2>&1 && id "$INSTALL_USER" >/dev/null 2>&1; then
            runuser -u "$INSTALL_USER" -- test -x "$candidate" >/dev/null 2>&1 || return 1
        fi
        return 0
    }

    if ! is_truthy "$INSTALL_SQLPACKAGE"; then
        if command -v sqlpackage >/dev/null 2>&1; then
            local existing_sqlpackage
            existing_sqlpackage="$(command -v sqlpackage)"
            if sqlpackage_accessible_for_service_user "$existing_sqlpackage"; then
                success "SqlPackage already installed: ${existing_sqlpackage}"
            else
                warn "SqlPackage was found at ${existing_sqlpackage}, but it is not executable by ${INSTALL_USER}; set DBAEGIS_INSTALL_SQLPACKAGE=1 to repair or reinstall it."
            fi
        elif sqlpackage_accessible_for_service_user "${SQLPACKAGE_DEST}/sqlpackage"; then
            success "SqlPackage already installed: ${SQLPACKAGE_DEST}/sqlpackage"
        else
            warn "SqlPackage is not installed. SQL Server/Azure SQL BACPAC workflows need sqlpackage; set DBAEGIS_INSTALL_SQLPACKAGE=1 to install it during setup."
        fi
        return 0
    fi

    if [[ -e "${SQLPACKAGE_DEST}/sqlpackage" ]]; then
        repair_sqlpackage_permissions "$SQLPACKAGE_DEST"
        if sqlpackage_accessible_for_service_user "${SQLPACKAGE_DEST}/sqlpackage"; then
            ln -sf "${SQLPACKAGE_DEST}/sqlpackage" /usr/local/bin/sqlpackage 2>/dev/null || true
            success "SqlPackage already installed: ${SQLPACKAGE_DEST}/sqlpackage"
            return 0
        fi
    fi

    if command -v sqlpackage >/dev/null 2>&1; then
        local existing_sqlpackage
        existing_sqlpackage="$(command -v sqlpackage)"
        if sqlpackage_accessible_for_service_user "$existing_sqlpackage"; then
            success "SqlPackage already installed: ${existing_sqlpackage}"
            return 0
        fi
        warn "SqlPackage was found at ${existing_sqlpackage}, but it is not executable by ${INSTALL_USER}; reinstalling it."
    fi

    case "$(uname -m)" in
        x86_64|amd64) ;;
        *)
            warn "Automatic SqlPackage install currently uses the Linux x64 package; set DBAEGIS_SQLPACKAGE_URL for $(uname -m) if your platform has a vendor package."
            return 0
            ;;
    esac

    info "Installing Microsoft SqlPackage for SQL Server/Azure SQL BACPAC support"
    case "$OS_ID" in
        rhel|centos|rocky|almalinux|fedora)
            local icu_pkg=""
            for candidate in libicu icu-libs; do
                if rhel_pkg_install "$candidate" >/dev/null 2>&1; then
                    icu_pkg="$candidate"
                    break
                fi
            done
            if [[ -z "$icu_pkg" ]]; then
                warn "Could not install SqlPackage ICU dependency automatically"
            fi
            rhel_pkg_install libunwind >/dev/null 2>&1 || true
            ;;
        ubuntu|debian)
            apt_pkg_install libunwind8 2>/dev/null || warn "Could not install SqlPackage OS dependency packages automatically"
            ;;
    esac
    local archive="/tmp/dbaegis-sqlpackage-linux.zip"
    local extract_dir="${SQLPACKAGE_DEST}.new"
    download_to_path "$SQLPACKAGE_URL" "$archive" || {
        warn "Could not download SqlPackage from ${SQLPACKAGE_URL}"
        return 0
    }
    chmod 600 "$archive"
    if [[ -n "$SQLPACKAGE_SHA256" ]]; then
        echo "${SQLPACKAGE_SHA256}  ${archive}" | sha256sum -c - >/dev/null || {
            warn "SqlPackage checksum verification failed"
            rm -f "$archive"
            return 0
        }
    fi

    mkdir -p "$(dirname "$SQLPACKAGE_DEST")"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    unzip -q "$archive" -d "$extract_dir" || {
        warn "Could not extract SqlPackage archive"
        rm -f "$archive"
        rm -rf "$extract_dir"
        return 0
    }
    repair_sqlpackage_permissions "$extract_dir"
    if ! sqlpackage_accessible_for_service_user "${extract_dir}/sqlpackage"; then
        warn "SqlPackage archive did not contain an executable sqlpackage"
        rm -f "$archive"
        rm -rf "$extract_dir"
        return 0
    fi
    rm -rf "$SQLPACKAGE_DEST"
    mv "$extract_dir" "$SQLPACKAGE_DEST"
    repair_sqlpackage_permissions "$SQLPACKAGE_DEST"
    if ! sqlpackage_accessible_for_service_user "${SQLPACKAGE_DEST}/sqlpackage"; then
        warn "SqlPackage was installed but is not executable by ${INSTALL_USER}"
        rm -f "$archive"
        return 0
    fi
    ln -sf "${SQLPACKAGE_DEST}/sqlpackage" /usr/local/bin/sqlpackage 2>/dev/null || true
    rm -f "$archive"
    hash -r 2>/dev/null || true
    success "SqlPackage installed: ${SQLPACKAGE_DEST}/sqlpackage"
}

install_sqlcmd_if_requested() {
    local existing=""
    existing="$(sqlcmd_path 2>/dev/null || true)"
    if ! is_truthy "$INSTALL_SQLCMD"; then
        if [[ -n "$existing" ]]; then
            success "sqlcmd already installed: ${existing}"
        else
            warn "sqlcmd is not installed. SQL Server checks and restore/control workflows need sqlcmd; set DBAEGIS_INSTALL_SQLCMD=1 and DBAEGIS_ACCEPT_MICROSOFT_EULA=Y to install it during setup."
        fi
        return 0
    fi

    if [[ -n "$existing" ]]; then
        link_sqlcmd_if_possible "$existing"
        success "sqlcmd already installed: ${existing}"
        return 0
    fi
    if ! is_truthy "$ACCEPT_MICROSOFT_EULA"; then
        warn "Skipping sqlcmd install because DBAEGIS_ACCEPT_MICROSOFT_EULA is not set to 1/true/yes."
        return 0
    fi

    info "Installing Microsoft sqlcmd/mssql-tools18 for SQL Server support"
    case "$OS_ID" in
        rhel|centos|rocky|almalinux)
            local repo_ver="$OS_VER"
            if [[ "$repo_ver" =~ ^[0-9]+$ ]] && (( repo_ver >= 10 )); then
                repo_ver="9"
            fi
            download_to_path "https://packages.microsoft.com/config/rhel/${repo_ver}/prod.repo" /etc/yum.repos.d/mssql-release.repo || {
                warn "Could not configure Microsoft RHEL repository for sqlcmd"
                return 0
            }
            ACCEPT_EULA=Y rhel_pkg_install msodbcsql18 mssql-tools18 unixODBC-devel || {
                warn "Microsoft sqlcmd/mssql-tools18 installation failed"
                return 0
            }
            ;;
        ubuntu|debian)
            local repo_os="ubuntu" repo_ver="$OS_VERSION_ID" repo_pkg="/tmp/packages-microsoft-prod.deb"
            if [[ "$OS_ID" == "debian" ]]; then
                repo_os="debian"
                repo_ver="$OS_VER"
            fi
            download_to_path "https://packages.microsoft.com/config/${repo_os}/${repo_ver}/packages-microsoft-prod.deb" "$repo_pkg" || {
                warn "Could not download Microsoft repository package for sqlcmd"
                return 0
            }
            dpkg -i "$repo_pkg" || {
                warn "Could not install Microsoft repository package for sqlcmd"
                rm -f "$repo_pkg"
                return 0
            }
            rm -f "$repo_pkg"
            apt-get update -qq
            ACCEPT_EULA=Y apt-get install -y msodbcsql18 mssql-tools18 unixodbc-dev || {
                warn "Microsoft sqlcmd/mssql-tools18 installation failed"
                return 0
            }
            ;;
        *)
            warn "Automatic sqlcmd install is not implemented for OS '${OS_ID}'. Install mssql-tools18 manually or set sqlcmd_path in connection options."
            return 0
            ;;
    esac

    existing="$(sqlcmd_path 2>/dev/null || true)"
    link_sqlcmd_if_possible "$existing"
    if [[ -n "$existing" ]]; then
        success "sqlcmd installed: ${existing}"
    else
        warn "sqlcmd installation completed, but sqlcmd was not found in PATH or /opt/mssql-tools18/bin"
    fi
}

mongodb_tools_platform() {
    if [[ -n "${DBAEGIS_MONGODB_TOOLS_PLATFORM:-}" ]]; then
        printf '%s\n' "$DBAEGIS_MONGODB_TOOLS_PLATFORM"
        return 0
    fi
    case "$OS_ID" in
        rhel|centos|rocky|almalinux)
            if [[ "$OS_VER" =~ ^[0-9]+$ ]] && (( OS_VER >= 9 )); then
                printf 'rhel93\n'
            elif [[ "$OS_VER" =~ ^[0-9]+$ ]] && (( OS_VER == 8 )); then
                printf 'rhel88\n'
            elif [[ "$OS_VER" =~ ^[0-9]+$ ]] && (( OS_VER == 7 )); then
                printf 'rhel70\n'
            else
                return 1
            fi
            ;;
        ubuntu)
            [[ -n "$OS_VERSION_ID" ]] || return 1
            printf 'ubuntu%s\n' "${OS_VERSION_ID//./}"
            ;;
        debian)
            [[ -n "$OS_VER" ]] || return 1
            printf 'debian%s\n' "$OS_VER"
            ;;
        amzn)
            if [[ "$OS_VER" == "2023" ]]; then
                printf 'amazon2023\n'
            else
                printf 'amazon2\n'
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

mongodb_tools_arch() {
    local platform="$1"
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64)
            case "$platform" in
                ubuntu*|debian*) printf 'arm64\n' ;;
                *) printf 'aarch64\n' ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

mongosh_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) return 1 ;;
    esac
}

install_mongodb_archive() {
    local label="$1" url="$2" sha="$3" archive_name="$4"
    local archive="/tmp/${archive_name}"
    download_to_path "$url" "$archive" || {
        warn "Could not download ${label} from ${url}"
        return 1
    }
    chmod 600 "$archive"
    if [[ -n "$sha" ]]; then
        echo "${sha}  ${archive}" | sha256sum -c - >/dev/null || {
            warn "${label} checksum verification failed"
            rm -f "$archive"
            return 1
        }
    fi
    mkdir -p "$MONGODB_INSTALL_ROOT"
    if path_is_under_base "$MONGODB_INSTALL_ROOT"; then
        chown "${INSTALL_USER}:${INSTALL_GROUP}" "$DBAEGIS_BASE" 2>/dev/null || true
    fi
    tar -xzf "$archive" -C "$MONGODB_INSTALL_ROOT" || {
        warn "Could not extract ${label} archive"
        rm -f "$archive"
        return 1
    }
    rm -f "$archive"
    chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$MONGODB_INSTALL_ROOT" 2>/dev/null || true
    return 0
}

mongodb_tool_accessible_for_service_user() {
    local candidate="$1"
    [[ -n "$candidate" && -x "$candidate" ]] || return 1
    if [[ "$(id -u)" -eq 0 ]] && command -v sudo >/dev/null 2>&1 && id "$INSTALL_USER" >/dev/null 2>&1; then
        sudo -u "$INSTALL_USER" test -x "$candidate" >/dev/null 2>&1 || return 1
    elif [[ "$(id -u)" -eq 0 ]] && command -v runuser >/dev/null 2>&1 && id "$INSTALL_USER" >/dev/null 2>&1; then
        runuser -u "$INSTALL_USER" -- test -x "$candidate" >/dev/null 2>&1 || return 1
    fi
    return 0
}

link_mongodb_database_tools_from_dir() {
    local bin_dir="$1"
    [[ -n "$bin_dir" && -d "$bin_dir" ]] || return 0
    local tool
    for tool in mongodump mongorestore bsondump mongoexport mongoimport mongofiles mongostat mongotop; do
        if mongodb_tool_accessible_for_service_user "${bin_dir}/${tool}"; then
            ln -sf "${bin_dir}/${tool}" "/usr/local/bin/${tool}" 2>/dev/null || true
        fi
    done
}

link_mongosh_if_possible() {
    local shell_bin="$1"
    if mongodb_tool_accessible_for_service_user "$shell_bin"; then
        ln -sf "$shell_bin" /usr/local/bin/mongosh 2>/dev/null || true
    fi
}

mongodb_database_tools_bin_dir() {
    find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongodump -printf '%h\n' 2>/dev/null | sort | tail -n 1 || true
}

mongosh_bin_path() {
    find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongosh -print -quit 2>/dev/null || true
}

mongodb_database_tools_version() {
    local candidate="$1"
    [[ -n "$candidate" && -x "$candidate" ]] || return 1
    "$candidate" --version 2>/dev/null | awk '/version:/ {print $3; exit}'
}

mongosh_version() {
    local candidate="$1"
    [[ -n "$candidate" && -x "$candidate" ]] || return 1
    "$candidate" --version 2>/dev/null | awk 'NR == 1 {print $1; exit}'
}

install_mongodb_tools_if_requested() {
    local have_dump=0 have_restore=0 have_shell=0
    command -v mongodump >/dev/null 2>&1 && have_dump=1
    command -v mongorestore >/dev/null 2>&1 && have_restore=1
    command -v mongosh >/dev/null 2>&1 && have_shell=1
    if [[ $have_dump -eq 0 || $have_restore -eq 0 ]]; then
        [[ -x "$(find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongodump -print -quit 2>/dev/null)" ]] && have_dump=1
        [[ -x "$(find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongorestore -print -quit 2>/dev/null)" ]] && have_restore=1
    fi
    if [[ $have_shell -eq 0 ]]; then
        [[ -x "$(find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongosh -print -quit 2>/dev/null)" ]] && have_shell=1
    fi

    if ! is_truthy "$INSTALL_MONGODB_TOOLS"; then
        if [[ $have_dump -eq 1 && $have_restore -eq 1 && $have_shell -eq 1 ]]; then
            success "MongoDB client tools already installed"
        else
            warn "MongoDB client tools are not fully installed. MongoDB workflows need mongodump/mongorestore and connection checks need mongosh; set DBAEGIS_INSTALL_MONGODB_TOOLS=1 to install them during setup."
        fi
        return 0
    fi

    local platform arch tools_url mongosh_url shell_arch bin_dir shell_bin
    bin_dir="$(mongodb_database_tools_bin_dir)"
    shell_bin="$(mongosh_bin_path)"
    local dump_candidate restore_candidate shell_candidate dump_version restore_version shell_version
    if [[ -n "$bin_dir" ]]; then
        dump_candidate="${bin_dir}/mongodump"
        restore_candidate="${bin_dir}/mongorestore"
    fi
    [[ -x "${dump_candidate:-}" ]] || dump_candidate="$(command -v mongodump 2>/dev/null || true)"
    [[ -x "${restore_candidate:-}" ]] || restore_candidate="$(command -v mongorestore 2>/dev/null || true)"
    shell_candidate="${shell_bin}"
    [[ -x "${shell_candidate:-}" ]] || shell_candidate="$(command -v mongosh 2>/dev/null || true)"
    if [[ $have_dump -eq 1 && $have_restore -eq 1 ]]; then
        dump_version="$(mongodb_database_tools_version "$dump_candidate" || true)"
        restore_version="$(mongodb_database_tools_version "$restore_candidate" || true)"
        if [[ "$dump_version" != "$MONGODB_TOOLS_VERSION" || "$restore_version" != "$MONGODB_TOOLS_VERSION" ]]; then
            info "MongoDB Database Tools ${dump_version:-unknown}/${restore_version:-unknown} found; installing requested ${MONGODB_TOOLS_VERSION}"
            have_dump=0
            have_restore=0
        fi
    fi
    if [[ $have_shell -eq 1 ]]; then
        shell_version="$(mongosh_version "$shell_candidate" || true)"
        if [[ "$shell_version" != "$MONGOSH_VERSION" ]]; then
            info "MongoDB Shell ${shell_version:-unknown} found; installing requested ${MONGOSH_VERSION}"
            have_shell=0
        fi
    fi
    if [[ $have_dump -eq 1 && $have_restore -eq 1 && $have_shell -eq 1 ]]; then
        link_mongodb_database_tools_from_dir "$bin_dir"
        link_mongosh_if_possible "$shell_bin"
        hash -r 2>/dev/null || true
        local final_dump final_restore final_shell
        final_dump="$(command -v mongodump 2>/dev/null || find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongodump -print -quit 2>/dev/null || true)"
        final_restore="$(command -v mongorestore 2>/dev/null || find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongorestore -print -quit 2>/dev/null || true)"
        final_shell="$(command -v mongosh 2>/dev/null || find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongosh -print -quit 2>/dev/null || true)"
        if mongodb_tool_accessible_for_service_user "$final_dump" && mongodb_tool_accessible_for_service_user "$final_restore" && mongodb_tool_accessible_for_service_user "$final_shell"; then
            success "MongoDB client tools already installed"
        else
            warn "MongoDB client tools were found, but one or more tools are not executable by ${INSTALL_USER}"
        fi
        return 0
    fi

    platform="$(mongodb_tools_platform || true)"
    [[ -n "$platform" ]] || {
        warn "Automatic MongoDB Database Tools install is not implemented for OS '${OS_ID}'. Set DBAEGIS_MONGODB_TOOLS_URL for this platform."
        return 0
    }
    arch="$(mongodb_tools_arch "$platform" || true)"
    [[ -n "$arch" ]] || {
        warn "Automatic MongoDB Database Tools install is not implemented for architecture $(uname -m)"
        return 0
    }

    if [[ $have_dump -eq 0 || $have_restore -eq 0 ]]; then
        tools_url="${MONGODB_TOOLS_URL:-https://fastdl.mongodb.org/tools/db/mongodb-database-tools-${platform}-${arch}-${MONGODB_TOOLS_VERSION}.tgz}"
        info "Installing MongoDB Database Tools ${MONGODB_TOOLS_VERSION}"
        install_mongodb_archive "MongoDB Database Tools" "$tools_url" "$MONGODB_TOOLS_SHA256" "mongodb-database-tools-${MONGODB_TOOLS_VERSION}.tgz" || true
        bin_dir="$(mongodb_database_tools_bin_dir)"
    fi
    link_mongodb_database_tools_from_dir "$bin_dir"

    if [[ $have_shell -eq 0 ]]; then
        shell_arch="$(mongosh_arch || true)"
        [[ -n "$shell_arch" ]] || {
            warn "Automatic mongosh install is not implemented for architecture $(uname -m)"
            return 0
        }
        mongosh_url="${MONGOSH_URL:-https://downloads.mongodb.com/compass/mongosh-${MONGOSH_VERSION}-linux-${shell_arch}.tgz}"
        info "Installing MongoDB Shell ${MONGOSH_VERSION}"
        install_mongodb_archive "MongoDB Shell" "$mongosh_url" "$MONGOSH_SHA256" "mongosh-${MONGOSH_VERSION}.tgz" || true
        shell_bin="$(mongosh_bin_path)"
    fi
    link_mongosh_if_possible "$shell_bin"

    hash -r 2>/dev/null || true
    local final_dump final_restore final_shell
    final_dump="$(command -v mongodump 2>/dev/null || find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongodump -print -quit 2>/dev/null || true)"
    final_restore="$(command -v mongorestore 2>/dev/null || find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongorestore -print -quit 2>/dev/null || true)"
    final_shell="$(command -v mongosh 2>/dev/null || find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongosh -print -quit 2>/dev/null || true)"
    if mongodb_tool_accessible_for_service_user "$final_dump" && mongodb_tool_accessible_for_service_user "$final_restore" && mongodb_tool_accessible_for_service_user "$final_shell"; then
        success "MongoDB client tools installed"
    else
        warn "MongoDB client tool installation completed, but one or more tools are still missing"
    fi
}

install_clickhouse_client_if_requested() {
    if ! is_truthy "$INSTALL_CLICKHOUSE_CLIENT"; then
        if command -v clickhouse-client >/dev/null 2>&1; then
            success "ClickHouse client already installed: $(command -v clickhouse-client)"
        else
            warn "ClickHouse client is not installed. ClickHouse workflows need clickhouse-client; set DBAEGIS_INSTALL_CLICKHOUSE_CLIENT=1 to install it during setup."
        fi
        return 0
    fi

    if command -v clickhouse-client >/dev/null 2>&1; then
        success "ClickHouse client already installed: $(command -v clickhouse-client)"
        return 0
    fi

    info "Installing ClickHouse client"
    case "$OS_ID" in
        rhel|centos|rocky|almalinux|fedora)
            download_to_path https://packages.clickhouse.com/rpm/clickhouse.repo /etc/yum.repos.d/clickhouse.repo || {
                warn "Could not configure ClickHouse RPM repository"
                return 0
            }
            local rpm_pkg="clickhouse-client"
            [[ -n "$CLICKHOUSE_VERSION" ]] && rpm_pkg="clickhouse-client-${CLICKHOUSE_VERSION}"
            rhel_pkg_install "$rpm_pkg" || {
                warn "ClickHouse client installation failed"
                return 0
            }
            ;;
        ubuntu|debian)
            apt_pkg_install apt-transport-https ca-certificates curl gnupg
            local key_tmp="/tmp/clickhouse-keyring.gpg.tmp"
            download_to_path https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key "$key_tmp" || {
                warn "Could not download ClickHouse repository key"
                return 0
            }
            gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg "$key_tmp" || {
                warn "Could not install ClickHouse repository key"
                rm -f "$key_tmp"
                return 0
            }
            rm -f "$key_tmp"
            local deb_arch
            deb_arch="$(dpkg --print-architecture)"
            echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${deb_arch}] https://packages.clickhouse.com/deb ${CLICKHOUSE_REPO_CHANNEL} main" > /etc/apt/sources.list.d/clickhouse.list
            apt-get update -qq
            local deb_pkg="clickhouse-client"
            [[ -n "$CLICKHOUSE_VERSION" ]] && deb_pkg="clickhouse-client=${CLICKHOUSE_VERSION}"
            apt-get install -y "$deb_pkg" || {
                warn "ClickHouse client installation failed"
                return 0
            }
            ;;
        *)
            warn "Automatic ClickHouse client install is not implemented for OS '${OS_ID}'. Install clickhouse-client manually or set clickhouse_client_path in connection options."
            return 0
            ;;
    esac

    if command -v clickhouse-client >/dev/null 2>&1; then
        success "ClickHouse client installed: $(command -v clickhouse-client)"
    else
        warn "ClickHouse client installation completed, but clickhouse-client was not found in PATH"
    fi
}

# ── Script directory / package roots ──────────────────────────────────────────
# Support both release-payload execution from repo root and installed-tree
# execution from /opt/dbaegis/bin/install.sh.
# SCRIPT_DIR and SCRIPT_PARENT_DIR are resolved before installer logging starts.

if [[ "$MODE" == "auto" ]]; then
    if [[ -d "$DBAEGIS_BASE" && -f "$DBAEGIS_BASE/bin/install.sh" ]]; then
        MODE="upgrade"
    else
        MODE="fresh"
    fi
fi
installer_loop_guard_check "$MODE"
info "Install mode: ${BOLD}${MODE}${NC}"

if [[ "$MODE" != "fresh" ]]; then
    load_existing_conf_runtime_paths
fi

if [[ "$MODE" == "rollback" ]]; then
    run_rollback
fi

if [[ "$MODE" == "fresh" ]]; then
    systemctl stop dbaegis 2>/dev/null || true
    systemctl disable dbaegis 2>/dev/null || true
fi

header "Prechecks"
info "Resolved install user       : ${BOLD}${INSTALL_USER}${NC}"
info "Resolved install base       : ${BOLD}${DBAEGIS_BASE}${NC}"
info "Resolved metadata DB path   : ${BOLD}${DBAEGIS_DB_PATH}${NC}"
info "Resolved backup dir         : ${BOLD}${BACKUP_DIR}${NC}"
info "Resolved temp dir           : ${BOLD}${TEMP_DIR}${NC}"
info "Resolved Python runtime     : ${BOLD}${PYTHON_DIR}${NC}"
info "Resolved tmp isolation      : ${BOLD}${SERVICE_PRIVATE_TMP}${NC}"
info "Resolved OS package mode    : ${BOLD}${OS_PACKAGE_MODE}${NC}"
info "Resolved API/UI ports       : ${BOLD}${API_PORT}/${UI_PORT}${NC}"
info "Core Python packages        : ${BOLD}${CORE_PYTHON_PACKAGES[*]}${NC}"
info "Optional DB Python packages : ${BOLD}${OPTIONAL_DB_PYTHON_PACKAGES[*]}${NC}"
info "Optional DB CLI packages    : ${BOLD}${OPTIONAL_DB_CLI_PYTHON_PACKAGES[*]}${NC}"
info "Optional cloud packages     : ${BOLD}${OPTIONAL_CLOUD_PYTHON_PACKAGES[*]}${NC}"
if [[ -n "$DBAEGIS_BUILD_CHANNEL" || -n "$DBAEGIS_RELEASE_NAME" || -n "$DBAEGIS_BUILD_TIME" || -n "$DBAEGIS_GIT_COMMIT" ]]; then
    info "Release metadata requested : ${BOLD}channel=${DBAEGIS_BUILD_CHANNEL:-<default>} name=${DBAEGIS_RELEASE_NAME:-<none>} build_time=${DBAEGIS_BUILD_TIME:-<none>} git_commit=${DBAEGIS_GIT_COMMIT:-<none>}${NC}"
fi

if [[ "${DBAEGIS_BASE}" != "/opt/dbaegis" ]]; then
    warn "Non-default install base selected: ${DBAEGIS_BASE}"
fi
if [[ "${DBAEGIS_DB_PATH}" != "${DATA_DIR}/dbaegis.db" ]]; then
    warn "Non-default metadata DB path selected: ${DBAEGIS_DB_PATH}"
fi
if [[ "${BACKUP_DIR}" != "/backups" ]]; then
    warn "Non-default backup directory selected: ${BACKUP_DIR}"
fi
if [[ "${TEMP_DIR}" != "${DBAEGIS_BASE}/tmp" ]]; then
    warn "Non-default DBAegis temp directory selected: ${TEMP_DIR}"
fi
if [[ "${DBAEGIS_DB_PATH}" == /tmp/* || "${BACKUP_DIR}" == /tmp/* ]]; then
    warn "Avoid placing persistent metadata or backup paths under /tmp on production hosts"
fi
if command -v ss >/dev/null 2>&1; then
    if ss -ltn "( sport = :${API_PORT} )" 2>/dev/null | tail -n +2 | grep -q .; then
        warn "Port ${API_PORT} already appears to be in use"
    fi
    if ss -ltn "( sport = :${UI_PORT} )" 2>/dev/null | tail -n +2 | grep -q .; then
        warn "Port ${UI_PORT} already appears to be in use"
    fi
fi
info "If default paths need to change, rerun with overrides such as:"
echo "  sudo DBAEGIS_USER=${INSTALL_USER} \\"
echo "       DBAEGIS_BASE=${DBAEGIS_BASE} \\"
echo "       DBAEGIS_DB_PATH=${DBAEGIS_DB_PATH} \\"
echo "       DBAEGIS_BACKUP_DIR=${BACKUP_DIR} \\"
echo "       DBAEGIS_TEMP_DIR=${TEMP_DIR} \\"
echo "       DBAEGIS_PYTHON_DIR=${PYTHON_DIR} \\"
echo "       bash bin/install.sh --${MODE}"

# =============================================================================
header "1/7  Prerequisites"
# =============================================================================

install_packages_rhel() {
    info "Detected RHEL/CentOS/Rocky/AlmaLinux ${OS_VER}"
    PKG_MGR="dnf"
    command -v dnf &>/dev/null || PKG_MGR="yum"

    # EPEL only available on RHEL 8/9 — skip on RHEL 10+
    if [[ "${OS_VER}" -lt 10 ]] 2>/dev/null; then
        rhel_pkg_install epel-release 2>/dev/null || true
    fi

    rhel_pkg_install \
        sudo \
        tzdata \
        sqlite \
        nginx \
        ca-certificates \
        curl wget git \
        iproute procps-ng util-linux hostname \
        coreutils findutils gawk grep sed \
        openssh-clients sshpass \
        tar gzip bzip2 xz unzip zip \
        postgresql \
        gcc make pkgconf-pkg-config \
        openssl \
        openssl-devel \
        libffi-devel \
        systemd || die "Required package installation failed"

    rhel_pkg_install valkey 2>/dev/null || \
        rhel_pkg_install redis 2>/dev/null || \
        warn "Could not install valkey/redis client tools automatically — Redis backup/restore needs redis-cli or valkey-cli"

    if ! command -v mysql &>/dev/null && ! command -v mariadb &>/dev/null; then
        rhel_pkg_install mariadb 2>/dev/null || \
            rhel_pkg_install mysql 2>/dev/null || \
            rhel_pkg_install mysql-community-client 2>/dev/null || \
            warn "Could not install MySQL/MariaDB client tools automatically — install mysql/mariadb client tools separately if those workflows are needed"
        hash -r 2>/dev/null || true
    fi
}

install_packages_debian() {
    info "Detected Debian/Ubuntu ${OS_VER}"
    export DEBIAN_FRONTEND=noninteractive
    if [[ "$OS_PACKAGE_MODE" == "missing-only" ]]; then
        info "OS package mode is missing-only; using existing apt indexes for installed-package validation"
    else
        apt-get update -qq
    fi
    apt_pkg_install \
        sudo \
        tzdata \
        sqlite3 \
        nginx \
        ca-certificates \
        curl wget git \
        iproute2 procps util-linux hostname \
        coreutils findutils gawk grep sed \
        openssh-client sshpass \
        tar gzip bzip2 xz-utils unzip zip \
        postgresql-client \
        redis-tools \
        gcc make pkg-config \
        openssl \
        libssl-dev \
        libffi-dev \
        systemd || die "Required package installation failed"

    if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
        if debian_pkg_installed mysql-community-server-core; then
            if apt_pkg_available mysql-community-client; then
                apt_pkg_install mysql-community-client 2>/dev/null || \
                    warn "Could not install Oracle MySQL client tools automatically — install mysql-community-client separately if MySQL workflows are needed"
            elif apt_pkg_available mysql-client; then
                apt_pkg_install mysql-client 2>/dev/null || \
                    warn "Could not install Oracle MySQL client tools automatically — install mysql-client separately if MySQL workflows are needed"
            else
                warn "Oracle MySQL server core is installed but no matching mysql client package was found; skipping default-mysql-client to avoid replacing MySQL server-core files"
            fi
        else
            apt_pkg_install default-mysql-client 2>/dev/null || \
                warn "Could not install MySQL/MariaDB client tools automatically — install mysql/mariadb client tools separately if those workflows are needed"
        fi
        hash -r 2>/dev/null || true
    fi
}

case "$OS_ID" in
    rhel|centos|rocky|almalinux|fedora) install_packages_rhel ;;
    ubuntu|debian|linuxmint|pop)        install_packages_debian ;;
    *) warn "Unknown OS '${OS_ID}' — attempting generic install"; install_packages_debian ;;
esac

verify_prerequisite_commands() {
    local missing=()
    local cmd
    for cmd in bash awk sed grep tar gzip ssh scp sshpass systemctl openssl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing+=("curl-or-wget")
    fi
    if ! command -v nginx >/dev/null 2>&1 && [[ ! -x /usr/sbin/nginx ]]; then
        missing+=("nginx")
    fi
    if ! command -v psql >/dev/null 2>&1; then
        warn "psql was not found after package installation — PostgreSQL workflows need PostgreSQL client tools"
    fi
    if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
        warn "mysql/mariadb was not found after package installation — MySQL/MariaDB logical workflows need a client binary"
    fi
    if ! command -v redis-cli >/dev/null 2>&1 && ! command -v valkey-cli >/dev/null 2>&1; then
        warn "redis-cli/valkey-cli was not found after package installation — Redis workflows need one of these client binaries"
    fi
    if (( ${#missing[@]} )); then
        die "Required command(s) missing after package installation: ${missing[*]}. Check OS repositories and package-manager output; if running with DBAEGIS_OS_PACKAGE_MODE=missing-only, rerun with DBAEGIS_OS_PACKAGE_MODE=install."
    fi
}
verify_prerequisite_commands
install_snowsql_if_requested
install_sqlpackage_if_requested
install_sqlcmd_if_requested
install_mongodb_tools_if_requested
install_clickhouse_client_if_requested

require_absolute_nonroot_path() {
    local value="$1" label="$2"
    [[ -n "$value" && "$value" == /* && "$value" != "/" ]] || die "${label} must be a non-root absolute path; got '${value:-<empty>}'"
}

install_embedded_python() {
    require_absolute_nonroot_path "$PYTHON_DIR" "DBAEGIS_PYTHON_DIR"
    require_absolute_nonroot_path "$TEMP_DIR" "DBAEGIS_TEMP_DIR"

    if [[ -x "$PYTHON_BIN" ]]; then
        info "Using existing embedded Python at ${PYTHON_BIN}"
        return 0
    fi

    if [[ "${PYTHON_DOWNLOAD}" == "skip" || "${PYTHON_DOWNLOAD}" == "false" || "${PYTHON_DOWNLOAD}" == "no" ]]; then
        command -v python3 &>/dev/null || die "DBAEGIS_PYTHON_DOWNLOAD=${PYTHON_DOWNLOAD}, but system python3 was not found"
        PYTHON_BIN="$(command -v python3)"
        warn "Using system Python at ${PYTHON_BIN} because embedded Python download was disabled"
        return 0
    fi

    [[ -n "$PYTHON_URL" ]] || die "No embedded Python URL is available for architecture $(uname -m); set DBAEGIS_PYTHON_URL or DBAEGIS_PYTHON_BIN"
    command -v curl &>/dev/null || command -v wget &>/dev/null || die "curl or wget is required to download embedded Python"
    command -v sha256sum &>/dev/null || die "sha256sum is required to verify embedded Python"
    [[ -n "$PYTHON_SHA256" ]] || die "Embedded Python SHA256 is required; set DBAEGIS_PYTHON_SHA256 when overriding DBAEGIS_PYTHON_URL, DBAEGIS_PYTHON_VERSION, DBAEGIS_PYTHON_RELEASE, or DBAEGIS_PYTHON_TRIPLET"

    mkdir -p "$PYTHON_DIR" "$TEMP_DIR"
    local archive_name archive_path extract_dir candidate
    archive_name="$(basename "${PYTHON_URL%%\?*}")"
    archive_name="${archive_name//%2B/+}"
    archive_path="${TEMP_DIR}/${archive_name}"
    extract_dir="${PYTHON_DIR}.new"
    require_absolute_nonroot_path "$extract_dir" "Embedded Python extraction directory"

    info "Downloading embedded Python ${PYTHON_VERSION} from ${PYTHON_URL}"
    if command -v curl &>/dev/null; then
        curl -fL "$PYTHON_URL" -o "$archive_path"
    else
        wget -O "$archive_path" "$PYTHON_URL"
    fi
    echo "${PYTHON_SHA256}  ${archive_path}" | sha256sum -c - >/dev/null || die "Embedded Python checksum verification failed"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$archive_path" -C "$extract_dir"

    candidate="${extract_dir}/python"
    [[ -x "${candidate}/bin/python3" || -x "${candidate}/bin/python" ]] || die "Embedded Python archive did not contain python/bin/python3"
    rm -rf "$PYTHON_DIR"
    mv "$candidate" "$PYTHON_DIR"
    rm -rf "$extract_dir"
    if [[ -x "${PYTHON_DIR}/bin/python3" ]]; then
        PYTHON_BIN="${PYTHON_DIR}/bin/python3"
    else
        PYTHON_BIN="${PYTHON_DIR}/bin/python"
    fi
    chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$PYTHON_DIR" "$archive_path"
    success "Embedded Python installed under ${PYTHON_DIR}"
}

require_supported_python_runtime() {
    local runtime="$1" required="${MIN_PYTHON_VERSION}" current="" status=0
    [[ -x "$runtime" ]] || die "Python runtime ${runtime} is not executable"
    current="$("$runtime" - "$required" <<'PY'
import sys

required = tuple(int(part) for part in sys.argv[1].split(".")[:2])
current = sys.version_info[:2]
print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
if current < required:
    sys.exit(42)
PY
)" || status=$?
    if (( status == 42 )); then
        die "Python runtime ${runtime} reports ${current}, but DBAegis requires Python ${required} or newer. Use the default embedded Python download or set DBAEGIS_PYTHON_BIN to a supported runtime."
    elif (( status != 0 )); then
        die "Unable to validate Python runtime ${runtime}"
    fi
}

install_embedded_python
PYTHON="$PYTHON_BIN"
require_supported_python_runtime "$PYTHON"
PY_VERSION=$("$PYTHON" --version 2>&1 | awk '{print $2}')
success "Python ${PY_VERSION} ready at ${PYTHON}"

# =============================================================================
header "2/7  Directory structure"
# =============================================================================

if [[ "$MODE" == "fresh" ]]; then
    mkdir -p "$DBAEGIS_BASE" "$DBAEGIS_BASE/bin" "${DBAEGIS_BASE}/run" "${DBAEGIS_BASE}/requirements" "${DBAEGIS_BASE}/docs" "$APP_DIR" "$APP_DIR/services" "$UI_DIR" "$DATA_DIR" "$DB_PARENT_DIR" "$BACKUP_DIR" "$SELF_BACKUP_DIR" "$LOG_DIR" "$TEMP_DIR" "$LICENSE_DIR" "$VENV_DIR" "$PYTHON_DIR" "$CONF_DIR"
else
    mkdir -p "$DBAEGIS_BASE" "$DBAEGIS_BASE/bin" "${DBAEGIS_BASE}/run" "${DBAEGIS_BASE}/requirements" "${DBAEGIS_BASE}/docs" "$APP_DIR" "$APP_DIR/services" "$UI_DIR" "$DATA_DIR" "$DB_PARENT_DIR" "$BACKUP_DIR" "$SELF_BACKUP_DIR" "$LOG_DIR" "$TEMP_DIR" "$LICENSE_DIR" "$VENV_DIR" "$PYTHON_DIR" "$CONF_DIR"
fi

chown_install_paths
chown_tree_if_under_base "${DBAEGIS_BASE}/requirements"
chown_tree_if_under_base "${DBAEGIS_BASE}/docs"
chmod 750 "$DATA_DIR" "$LOG_DIR" "$TEMP_DIR" "$CONF_DIR"
chmod 750 "$BACKUP_DIR" "$SELF_BACKUP_DIR"
chmod 750 "$LICENSE_DIR"
chmod 755 "$APP_DIR" "$UI_DIR" "${DBAEGIS_BASE}/docs"

success "Directory structure ready under ${DBAEGIS_BASE}"

create_upgrade_snapshot

# =============================================================================
header "3/7  Configuration file"
# =============================================================================

shell_quote() {
    printf '%q' "$1"
}

generate_dbaegis_secret_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        "$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(48))'
    fi
}

generate_bootstrap_admin_password() {
    "$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(24))'
}

is_weak_dbaegis_secret_key() {
    local value="${1:-}" lowered
    lowered="${value,,}"
    [[ -n "$value" ]] || return 0
    case "$lowered" in
        change-me|change-me-generate-a-random-secret|changeme|default|secret|dbaegis|preserve-existing-dbaegis.conf|redacted-active-dbaegis.conf)
            return 0
            ;;
    esac
    [[ ${#value} -ge 32 ]] || return 0
    return 1
}

is_weak_bootstrap_admin_password() {
    local value="${1:-}" lowered
    lowered="${value,,}"
    [[ -n "$value" ]] || return 0
    case "$lowered" in
        admin|change-me|changeme|default|password|dbaegis)
            return 0
            ;;
    esac
    [[ ${#value} -ge 12 ]] || return 0
    return 1
}

secure_conf_file() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    chmod 640 "$target"
    chown "${INSTALL_USER}:${INSTALL_GROUP}" "$target"
}

secure_conf_files() {
    secure_conf_file "$CONF_FILE"
    secure_conf_file "${CONF_FILE}.bak"
    secure_conf_file "${CONF_FILE}.new"
}

read_conf_value() {
    local target="$1" key="$2" raw
    [[ -f "$target" ]] || return 0
    raw="$(awk -v key="$key" '
        /^[[:space:]]*($|#)/ { next }
        {
            line = $0
            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                sub(/^[^=]*=/, "", line)
                sub(/^[[:space:]]*/, "", line)
                print line
                exit
            }
        }
    ' "$target" 2>/dev/null || true)"
    [[ -n "$raw" ]] || return 0
    "$PYTHON" - "$raw" <<'PY'
import shlex
import sys

raw = sys.argv[1].strip()
try:
    parsed = shlex.split(raw, comments=False, posix=True)
except ValueError:
    print(raw.strip("\"'"))
else:
    print(parsed[0] if len(parsed) == 1 else raw.strip("\"'"))
PY
}

read_conf_secret_key() {
    local target="$1"
    read_conf_value "$target" "DBAEGIS_SECRET_KEY"
}

set_conf_value() {
    local target="$1" key="$2" value="$3" quoted
    quoted="$(shell_quote "$value")"
    "$PYTHON" - "$target" "$key" "$quoted" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
replacement = f"{key}={sys.argv[3]}"
pattern = re.compile(rf"^\s*(?:export\s+)?{re.escape(key)}\s*=")
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
changed = False
out = []
for line in lines:
    if pattern.match(line):
        if not changed:
            out.append(replacement)
            changed = True
        continue
    out.append(line)
if not changed:
    if out and out[-1].strip():
        out.append("")
    out.append(replacement)
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

ensure_conf_default_value() {
    local target="$1" key="$2" value="$3"
    local current_value
    current_value="$(read_conf_value "$target" "$key" || true)"
    [[ -n "$current_value" ]] && return 0
    set_conf_value "$target" "$key" "$value"
    secure_conf_file "$target"
    success "Added ${key} to existing config"
}

conf_key_exists() {
    local target="$1" key="$2"
    [[ -f "$target" ]] || return 1
    grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$target"
}

migrate_license_file_if_needed() {
    local old_path="$1" new_path="$2" label="$3"
    [[ -n "$old_path" && -n "$new_path" && "$old_path" != "$new_path" ]] || return 0
    [[ -f "$old_path" ]] || return 0
    if [[ -e "$new_path" ]]; then
        warn "Preserved existing ${label} at ${new_path}; old file remains at ${old_path}"
        return 0
    fi
    mkdir -p "$(dirname "$new_path")"
    cp -p "$old_path" "$new_path"
    chown "${INSTALL_USER}:${INSTALL_GROUP}" "$new_path" 2>/dev/null || true
    chmod 640 "$new_path" 2>/dev/null || true
    success "Copied ${label} to ${new_path}"
}

ensure_license_config_paths() {
    local target="$1" configured_dir effective_dir current_key current_public current_instance_id old_key old_public base_old_key base_old_public

    ensure_edition_config_value "$target"
    ensure_license_required_config_value "$target"

    configured_dir="$(read_conf_value "$target" "DBAEGIS_LICENSE_DIR" || true)"
    effective_dir="${configured_dir:-$LICENSE_DIR}"
    old_key="${CONF_DIR}/dbaegis.license"
    old_public="${CONF_DIR}/license_public.pem"
    base_old_key="${DBAEGIS_BASE}/conf/dbaegis.license"
    base_old_public="${DBAEGIS_BASE}/conf/license_public.pem"

    mkdir -p "$effective_dir"
    chown_dir_only "$effective_dir"
    chmod 750 "$effective_dir" 2>/dev/null || true

    if [[ -z "$configured_dir" ]]; then
        set_conf_value "$target" "DBAEGIS_LICENSE_DIR" "$effective_dir"
        secure_conf_file "$target"
        success "Added DBAEGIS_LICENSE_DIR to existing config"
    fi

    current_key="$(read_conf_value "$target" "DBAEGIS_LICENSE_KEY_FILE" || true)"
    if [[ -z "$current_key" || "$current_key" == "$old_key" || "$current_key" == "$base_old_key" ]]; then
        if [[ -f "$current_key" ]]; then
            migrate_license_file_if_needed "$current_key" "${effective_dir}/dbaegis.license" "license token"
        else
            migrate_license_file_if_needed "$old_key" "${effective_dir}/dbaegis.license" "license token"
            [[ "$base_old_key" == "$old_key" ]] || migrate_license_file_if_needed "$base_old_key" "${effective_dir}/dbaegis.license" "license token"
        fi
        set_conf_value "$target" "DBAEGIS_LICENSE_KEY_FILE" "${effective_dir}/dbaegis.license"
        secure_conf_file "$target"
        success "Set DBAEGIS_LICENSE_KEY_FILE to ${effective_dir}/dbaegis.license"
    fi

    current_public="$(read_conf_value "$target" "DBAEGIS_LICENSE_PUBLIC_KEY_FILE" || true)"
    if [[ -z "$current_public" || "$current_public" == "$old_public" || "$current_public" == "$base_old_public" ]]; then
        if [[ -f "$current_public" ]]; then
            migrate_license_file_if_needed "$current_public" "${effective_dir}/license_public.pem" "license public key"
        else
            migrate_license_file_if_needed "$old_public" "${effective_dir}/license_public.pem" "license public key"
            [[ "$base_old_public" == "$old_public" ]] || migrate_license_file_if_needed "$base_old_public" "${effective_dir}/license_public.pem" "license public key"
        fi
        set_conf_value "$target" "DBAEGIS_LICENSE_PUBLIC_KEY_FILE" "${effective_dir}/license_public.pem"
        secure_conf_file "$target"
        success "Set DBAEGIS_LICENSE_PUBLIC_KEY_FILE to ${effective_dir}/license_public.pem"
    fi

    current_instance_id="$(read_conf_value "$target" "DBAEGIS_LICENSE_INSTANCE_ID" || true)"
    if ! conf_key_exists "$target" "DBAEGIS_LICENSE_INSTANCE_ID"; then
        set_conf_value "$target" "DBAEGIS_LICENSE_INSTANCE_ID" "$DBAEGIS_LICENSE_INSTANCE_ID"
        secure_conf_file "$target"
        success "Added DBAEGIS_LICENSE_INSTANCE_ID to existing config"
    elif (( DBAEGIS_LICENSE_INSTANCE_ID_ENV_PROVIDED )) && [[ "$current_instance_id" != "$DBAEGIS_LICENSE_INSTANCE_ID" ]]; then
        set_conf_value "$target" "DBAEGIS_LICENSE_INSTANCE_ID" "$DBAEGIS_LICENSE_INSTANCE_ID"
        secure_conf_file "$target"
        success "Updated DBAEGIS_LICENSE_INSTANCE_ID from environment"
    fi
}

ensure_edition_config_value() {
    local target="$1" current_value current_normalized
    current_value="$(read_conf_value "$target" "DBAEGIS_EDITION" || true)"
    current_normalized="${current_value,,}"
    if [[ -z "$current_value" ]]; then
        set_conf_value "$target" "DBAEGIS_EDITION" "$DBAEGIS_EDITION"
        secure_conf_file "$target"
        success "Added DBAEGIS_EDITION to existing config"
    elif [[ "$current_normalized" != "$DBAEGIS_EDITION" && ( "$DBAEGIS_EDITION_SOURCE" == "environment" || "$DBAEGIS_EDITION_SOURCE" == "package" ) ]]; then
        set_conf_value "$target" "DBAEGIS_EDITION" "$DBAEGIS_EDITION"
        secure_conf_file "$target"
        success "Updated DBAEGIS_EDITION to ${DBAEGIS_EDITION} from ${DBAEGIS_EDITION_SOURCE}"
    fi
}

ensure_license_required_config_value() {
    local target="$1" current_value current_normalized desired desired_normalized reason=""
    current_value="$(read_conf_value "$target" "DBAEGIS_LICENSE_REQUIRED" || true)"
    current_normalized="${current_value,,}"
    desired="$DBAEGIS_LICENSE_REQUIRED"
    desired_normalized="${desired,,}"

    if [[ "$DBAEGIS_EDITION" == "professional" || "$DBAEGIS_EDITION" == "enterprise" ]]; then
        desired="true"
        desired_normalized="true"
        reason="${DBAEGIS_EDITION} edition"
    elif (( DBAEGIS_LICENSE_REQUIRED_ENV_PROVIDED )); then
        reason="environment override"
    elif [[ "$DBAEGIS_EDITION" == "community" && ( "$DBAEGIS_EDITION_SOURCE" == "environment" || "$DBAEGIS_EDITION_SOURCE" == "package" ) ]]; then
        desired="false"
        desired_normalized="false"
        reason="community edition"
    fi

    if [[ -z "$current_value" ]]; then
        set_conf_value "$target" "DBAEGIS_LICENSE_REQUIRED" "$desired"
        secure_conf_file "$target"
        success "Added DBAEGIS_LICENSE_REQUIRED to existing config"
    elif [[ -n "$reason" && "$current_normalized" != "$desired_normalized" ]]; then
        set_conf_value "$target" "DBAEGIS_LICENSE_REQUIRED" "$desired"
        secure_conf_file "$target"
        success "Updated DBAEGIS_LICENSE_REQUIRED to ${desired} for ${reason}"
    fi
}

ensure_conf_secret_key() {
    local target="$1" current_secret
    current_secret="$(read_conf_secret_key "$target" || true)"
    if ! is_weak_dbaegis_secret_key "$current_secret"; then
        DBAEGIS_SECRET_KEY="$current_secret"
        return 0
    fi
    if is_weak_dbaegis_secret_key "${DBAEGIS_SECRET_KEY:-}"; then
        DBAEGIS_SECRET_KEY="$(generate_dbaegis_secret_key)"
    fi
    set_conf_value "$target" "DBAEGIS_SECRET_KEY" "$DBAEGIS_SECRET_KEY"
    secure_conf_file "$target"
    success "Set a non-placeholder DBAEGIS_SECRET_KEY in existing config"
}

ensure_bootstrap_admin_password() {
    local target="$1" current_password
    current_password="$(read_conf_value "$target" "BOOTSTRAP_ADMIN_PASSWORD" || true)"
    if ! is_weak_bootstrap_admin_password "$current_password"; then
        BOOTSTRAP_ADMIN_PASSWORD_VALUE="$current_password"
        return 0
    fi
    if is_weak_bootstrap_admin_password "${BOOTSTRAP_ADMIN_PASSWORD:-}"; then
        BOOTSTRAP_ADMIN_PASSWORD_VALUE="$(generate_bootstrap_admin_password)"
    else
        BOOTSTRAP_ADMIN_PASSWORD_VALUE="$BOOTSTRAP_ADMIN_PASSWORD"
    fi
    set_conf_value "$target" "BOOTSTRAP_ADMIN_PASSWORD" "$BOOTSTRAP_ADMIN_PASSWORD_VALUE"
    secure_conf_file "$target"
    success "Set a non-default BOOTSTRAP_ADMIN_PASSWORD in existing config"
}

load_conf_var() {
    local key="$1" dest="${2:-$1}" value
    value="$(read_conf_value "$CONF_FILE" "$key" || true)"
    [[ -n "$value" ]] || return 0
    printf -v "$dest" '%s' "$value"
}

load_installer_conf_values() {
    load_conf_var "DBAEGIS_BASE"
    load_conf_var "APP_DIR"
    load_conf_var "UI_DIR"
    load_conf_var "DBAEGIS_DB_PATH"
    load_conf_var "BACKUP_DIR"
    load_conf_var "SELF_BACKUP_DIR"
    load_conf_var "LOG_DIR"
    load_conf_var "DBAEGIS_TEMP_DIR" "TEMP_DIR"
    load_conf_var "DBAEGIS_LICENSE_DIR" "LICENSE_DIR"
    load_conf_var "DBAEGIS_EDITION"
    load_conf_var "DBAEGIS_LICENSE_REQUIRED"
    load_conf_var "DBAEGIS_LICENSE_KEY_FILE"
    load_conf_var "DBAEGIS_LICENSE_PUBLIC_KEY_FILE"
    load_conf_var "DBAEGIS_LICENSE_INSTANCE_ID"
    load_conf_var "VENV_DIR"
    load_conf_var "DBAEGIS_PYTHON_DIR" "PYTHON_DIR"
    load_conf_var "DBAEGIS_PYTHON_BIN" "PYTHON_BIN"
    load_conf_var "API_PORT"
    load_conf_var "UI_PORT"
    load_conf_var "HTTPS_PORT"
    load_conf_var "TLS_MODE"
    load_conf_var "HTTP_BEHAVIOR"
    load_conf_var "SERVICE_PRIVATE_TMP"
    load_conf_var "TLS_SERVER_NAME"
    load_conf_var "TLS_CERT_PATH"
    load_conf_var "TLS_KEY_PATH"
    load_conf_var "TLS_CHAIN_PATH"
    load_conf_var "API_BIND"
    load_conf_var "LOG_LEVEL"
    load_conf_var "LOG_BACKUP_COUNT"
}

remove_legacy_systemd_secret_dropin() {
    local dropin_dir="/etc/systemd/system/dbaegis.service.d"
    local dropin_file="${dropin_dir}/10-secret.conf"
    if [[ -e "$dropin_file" ]]; then
        rm -f "$dropin_file"
        rmdir "$dropin_dir" 2>/dev/null || true
        success "Removed legacy systemd DBAEGIS_SECRET_KEY drop-in; dbaegis.conf is the only key source"
    fi
}

existing_secret_key=""
if [[ -f "$CONF_FILE" ]]; then
    existing_secret_key="$(read_conf_secret_key "$CONF_FILE" || true)"
fi
if ! is_weak_dbaegis_secret_key "$existing_secret_key"; then
    DBAEGIS_SECRET_KEY="$existing_secret_key"
elif is_weak_dbaegis_secret_key "${DBAEGIS_SECRET_KEY:-}"; then
    DBAEGIS_SECRET_KEY="$(generate_dbaegis_secret_key)"
fi
if is_weak_bootstrap_admin_password "${BOOTSTRAP_ADMIN_PASSWORD:-}"; then
    BOOTSTRAP_ADMIN_PASSWORD_VALUE="$(generate_bootstrap_admin_password)"
else
    BOOTSTRAP_ADMIN_PASSWORD_VALUE="$BOOTSTRAP_ADMIN_PASSWORD"
fi

generate_conf() {
local target="${1:-$CONF_FILE}"
local rendered_secret_key="$DBAEGIS_SECRET_KEY"
local rendered_bootstrap_password="$BOOTSTRAP_ADMIN_PASSWORD_VALUE"
if [[ "$target" != "$CONF_FILE" ]]; then
    rendered_secret_key="preserve-existing-dbaegis.conf"
    rendered_bootstrap_password="change-me"
fi
cat > "$target" << EOF
# =============================================================================
#  DBAegis configuration — ${target}
#  Restart the service after editing: systemctl restart dbaegis
# =============================================================================

# ── Paths ─────────────────────────────────────────────────────────────────────
DBAEGIS_BASE=${DBAEGIS_BASE}
APP_DIR=${APP_DIR}
UI_DIR=${UI_DIR}

# SQLite database path — change this to point to a different volume/mount
DBAEGIS_DB_PATH=${DBAEGIS_DB_PATH}

# Backup files storage directory
BACKUP_DIR=${BACKUP_DIR}

# DBAegis VM temporary work directory for backup/restore staging
DBAEGIS_TEMP_DIR=${TEMP_DIR}

# System backup snapshot directory
SELF_BACKUP_DIR=${SELF_BACKUP_DIR}

# Log directory
LOG_DIR=${LOG_DIR}

# Python virtualenv
VENV_DIR=${VENV_DIR}

# Embedded Python runtime used to create/run the virtualenv
DBAEGIS_PYTHON_DIR=${PYTHON_DIR}
DBAEGIS_PYTHON_BIN=${PYTHON_BIN}

# ── Network ───────────────────────────────────────────────────────────────────
# API backend port (uvicorn)
API_PORT=${API_PORT}

# UI port (nginx)
UI_PORT=${UI_PORT}

# HTTPS port (nginx TLS listener)
HTTPS_PORT=${HTTPS_PORT}

# TLS mode: off | self_signed | customer_provided
TLS_MODE=${TLS_MODE}

# HTTP behavior when TLS is enabled: both | redirect | https_only
HTTP_BEHAVIOR=${HTTP_BEHAVIOR}

# systemd PrivateTmp isolation for the DBAegis service: yes | no
# Set to no when local backup/restore source paths must remain visible under /tmp.
SERVICE_PRIVATE_TMP=${SERVICE_PRIVATE_TMP}

# TLS certificate settings used when TLS_MODE != off
TLS_SERVER_NAME=${TLS_SERVER_NAME}
TLS_CERT_PATH=${TLS_CERT_PATH}
TLS_KEY_PATH=${TLS_KEY_PATH}
TLS_CHAIN_PATH=${TLS_CHAIN_PATH}

# API bind address. Keep the FastAPI service local; nginx is the public entrypoint.
API_BIND=127.0.0.1

# ── Runtime ───────────────────────────────────────────────────────────────────
# User the service runs as
SERVICE_USER=${INSTALL_USER}

# Uvicorn workers. Keep at 1 because backup/restore cancellation and the
# scheduler use in-process state.
UVICORN_WORKERS=1

# Backup process timeout in seconds (default 4 hours)
DBAEGIS_BACKUP_TIMEOUT=14400

# Log level: debug | info | warning | error
LOG_LEVEL=info

# Number of rotated dbaegis.log, nginx-access.log, and nginx-error.log files
# to keep in addition to each active log.
LOG_BACKUP_COUNT=${LOG_BACKUP_COUNT}

# ── License Enforcement ─────────────────────────────────────────────────────
# DBAEGIS_EDITION controls package entitlement defaults. Use community for
# public/community packages. Professional and Enterprise always require a
# matching signed license.
DBAEGIS_EDITION=${DBAEGIS_EDITION}
# Set DBAEGIS_LICENSE_REQUIRED=true to require a valid signed license before
# normal API use. Paid editions force this behavior. Keep the private signing
# key outside this server.
DBAEGIS_LICENSE_REQUIRED=${DBAEGIS_LICENSE_REQUIRED}
DBAEGIS_LICENSE_DIR=${LICENSE_DIR}
DBAEGIS_LICENSE_KEY_FILE=${DBAEGIS_LICENSE_KEY_FILE}
DBAEGIS_LICENSE_PUBLIC_KEY_FILE=${DBAEGIS_LICENSE_PUBLIC_KEY_FILE}
DBAEGIS_LICENSE_INSTANCE_ID=${DBAEGIS_LICENSE_INSTANCE_ID}

# Secret key used to encrypt stored connection, storage, notification, LDAP,
# Microsoft Authenticator MFA, webhook, and restore-option secrets.
# Preserve across upgrades. Use "dbaegis rotate-secret-key" to change it.
DBAEGIS_SECRET_KEY=$(shell_quote "$rendered_secret_key")

# ── Local Authentication ─────────────────────────────────────────────────────
AUTH_ENABLED=true
SESSION_COOKIE_NAME=dbaegis_session
SESSION_TTL_HOURS=12
# auto = secure only when request/proxy scheme is HTTPS; set true to force HTTPS-only cookies.
SESSION_COOKIE_SECURE=auto
BOOTSTRAP_ADMIN_USER=admin
BOOTSTRAP_ADMIN_PASSWORD=$(shell_quote "$rendered_bootstrap_password")
# Microsoft Authenticator MFA is configured in the UI/API under Access Control > MFA.
# MFA enrollment secrets are stored encrypted in the metadata DB with DBAEGIS_SECRET_KEY.

# ── LDAP Authentication (optional) ──────────────────────────────────────────
# LDAP is configured in the UI/API, but these placeholders document the
# expected settings for managed deployments and config management.
LDAP_ENABLED=false
LDAP_SERVER_URI=
LDAP_BIND_DN=
LDAP_BIND_PASSWORD=
LDAP_USER_BASE_DN=
LDAP_USER_FILTER='(&(objectClass=person)(|(uid={username})(sAMAccountName={username})(userPrincipalName={username})))'
LDAP_GROUP_BASE_DN=
LDAP_ADMIN_GROUP=admin
LDAP_READ_ONLY_GROUP=read_only
LDAP_USE_SSL=false
LDAP_START_TLS=false
LDAP_VERIFY_CERT=true
LDAP_CA_CERT_FILE=
EOF
}

if [[ -f "$CONF_FILE" ]]; then
    warn "Config already exists at ${CONF_FILE} — backing up to ${CONF_FILE}.bak"
    cp "$CONF_FILE" "${CONF_FILE}.bak"
    set_conf_value "${CONF_FILE}.bak" "DBAEGIS_SECRET_KEY" "redacted-active-dbaegis.conf"
    set_conf_value "${CONF_FILE}.bak" "BOOTSTRAP_ADMIN_PASSWORD" "redacted-active-dbaegis.conf"
    secure_conf_file "${CONF_FILE}.bak"
    ensure_conf_secret_key "$CONF_FILE"
    ensure_bootstrap_admin_password "$CONF_FILE"
    ensure_conf_default_value "$CONF_FILE" "SERVICE_PRIVATE_TMP" "$SERVICE_PRIVATE_TMP"
    ensure_conf_default_value "$CONF_FILE" "LOG_BACKUP_COUNT" "$LOG_BACKUP_COUNT"
    ensure_license_config_paths "$CONF_FILE"
    if [[ "$MODE" == "upgrade" ]]; then
        generate_conf "${CONF_FILE}.new"
        secure_conf_file "${CONF_FILE}.new"
        success "Existing config preserved; new template written to ${CONF_FILE}.new"
    else
        generate_conf "$CONF_FILE"
        secure_conf_file "$CONF_FILE"
        success "Config written to ${CONF_FILE}"
    fi
else
    generate_conf "$CONF_FILE"
    secure_conf_file "$CONF_FILE"
    success "Config written to ${CONF_FILE}"
fi
remove_legacy_systemd_secret_dropin

# Load known conf values without executing the config file as root.
load_installer_conf_values
TEMP_DIR="${DBAEGIS_TEMP_DIR:-$TEMP_DIR}"
LICENSE_DIR="${DBAEGIS_LICENSE_DIR:-$LICENSE_DIR}"
PYTHON_DIR="${DBAEGIS_PYTHON_DIR:-$PYTHON_DIR}"
PYTHON_BIN="${DBAEGIS_PYTHON_BIN:-${PYTHON_DIR}/bin/python3}"
PYTHON="$PYTHON_BIN"
DB_PARENT_DIR="$(dirname "${DBAEGIS_DB_PATH}")"

mkdir -p "$DBAEGIS_BASE" "$DBAEGIS_BASE/bin" "${DBAEGIS_BASE}/run" "$APP_DIR" "$APP_DIR/services" "$UI_DIR" "$DATA_DIR" "$DB_PARENT_DIR" "$BACKUP_DIR" "$SELF_BACKUP_DIR" "$LOG_DIR" "$TEMP_DIR" "$LICENSE_DIR" "$VENV_DIR" "$PYTHON_DIR" "$CONF_DIR"
chown_install_paths
secure_conf_files
touch "$LOG_DIR/dbaegis.log" "$LOG_DIR/nginx-access.log" "$LOG_DIR/nginx-error.log"
chown "${INSTALL_USER}:${INSTALL_GROUP}" "$LOG_DIR" "$LOG_DIR/dbaegis.log" "$LOG_DIR/nginx-access.log" "$LOG_DIR/nginx-error.log"
chmod 750 "$DATA_DIR" "$LOG_DIR" "$TEMP_DIR" "$CONF_DIR"
chmod 640 "$LOG_DIR/dbaegis.log" "$LOG_DIR/nginx-access.log" "$LOG_DIR/nginx-error.log"
chmod 750 "$BACKUP_DIR" "$SELF_BACKUP_DIR"
chmod 750 "$LICENSE_DIR"

if [[ ! -x "$PYTHON" ]]; then
    warn "Configured Python runtime ${PYTHON} is not executable; installing embedded Python"
    install_embedded_python
    PYTHON="$PYTHON_BIN"
fi
require_supported_python_runtime "$PYTHON"

# =============================================================================
header "4/7  Python virtualenv & packages"
# =============================================================================

# Create venv as the install user
sudo -u "$INSTALL_USER" "$PYTHON" -m venv "$VENV_DIR"
PIP="${VENV_DIR}/bin/pip"
VENV_PYTHON="${VENV_DIR}/bin/python"

PIP_CONSTRAINT_ARGS=()
if [[ -f "$PYTHON_CONSTRAINTS_FILE" ]]; then
    PIP_CONSTRAINT_ARGS=(--constraint "$PYTHON_CONSTRAINTS_FILE")
else
    warn "Python constraints file not found at ${PYTHON_CONSTRAINTS_FILE}; installing exact direct package pins without transitive constraints"
fi

sudo -u "$INSTALL_USER" "$PIP" install "${PIP_CONSTRAINT_ARGS[@]}" "${PYTHON_BUILD_PACKAGES[@]}" -q

# Core API and validation dependencies
sudo -u "$INSTALL_USER" "$PIP" install "${PIP_CONSTRAINT_ARGS[@]}" "${CORE_PYTHON_PACKAGES[@]}" -q
info "Running core Python dependency import precheck..."
verify_core_python_dependencies
success "Core Python dependency precheck passed"

# Optional DB driver dependencies (best-effort — won't fail install if unavailable)
info "Installing optional database drivers (best-effort)..."
sudo -u "$INSTALL_USER" "$PIP" install "${PIP_CONSTRAINT_ARGS[@]}" "${OPTIONAL_DB_PYTHON_PACKAGES[@]}" -q 2>/dev/null || warn "Some optional drivers failed — Cassandra/Neo4j/Oracle/SQL Server features may be limited"
verify_optional_python_dependencies "Optional database driver" "${OPTIONAL_DB_PYTHON_IMPORTS[@]}"

info "Installing optional database CLI Python packages (best-effort)..."
sudo -u "$INSTALL_USER" "$PIP" install "${PIP_CONSTRAINT_ARGS[@]}" "${OPTIONAL_DB_CLI_PYTHON_PACKAGES[@]}" -q 2>/dev/null || warn "Some optional CLI packages failed — Cassandra raw .cql restore may need a configured cqlsh path"
verify_optional_executable "Optional Cassandra cqlsh" "${VENV_DIR}/bin/cqlsh"

# Optional cloud storage clients used for direct remote backup copy/restore.
info "Installing cloud storage clients (best-effort)..."
sudo -u "$INSTALL_USER" "$PIP" install "${PIP_CONSTRAINT_ARGS[@]}" "${OPTIONAL_CLOUD_PYTHON_PACKAGES[@]}" -q 2>/dev/null || warn "Cloud backup clients failed to install — S3/GCS/Azure direct copy will be unavailable until these packages are installed"
verify_optional_python_dependencies "Optional cloud client" "${OPTIONAL_CLOUD_PYTHON_IMPORTS[@]}"

success "Python environment ready at ${VENV_DIR}"
warn "Optional vendor tools are not auto-installed by default. Auto-install flags are available for SnowSQL, SqlPackage, sqlcmd/mssql-tools18, MongoDB client tools, and ClickHouse client. Database-home or server-side tools still need engine-specific installation: MySQL/MariaDB physical tools (xtrabackup/mariabackup), Couchbase cbbackupmgr, Oracle expdp/impdp/sqlplus/rman, Neo4j neo4j-admin, and Cassandra nodetool."
if [[ -x "$SNOWSQL_LINK" ]]; then
    success "Snowflake SnowSQL precheck passed: ${SNOWSQL_LINK}"
elif command -v snowsql >/dev/null 2>&1; then
    success "Snowflake SnowSQL precheck passed: $(command -v snowsql)"
else
    warn "Snowflake SnowSQL missing — Snowflake backup/restore needs snowsql on the DBAegis VM"
fi
SQLPACKAGE_PRECHECK_PATH=""
if command -v sqlpackage >/dev/null 2>&1; then
    SQLPACKAGE_PRECHECK_PATH="$(command -v sqlpackage)"
fi
if [[ -n "$SQLPACKAGE_PRECHECK_PATH" ]] && sqlpackage_accessible_for_service_user "$SQLPACKAGE_PRECHECK_PATH"; then
    success "SqlPackage precheck passed: ${SQLPACKAGE_PRECHECK_PATH}"
elif sqlpackage_accessible_for_service_user "${SQLPACKAGE_DEST}/sqlpackage"; then
    success "SqlPackage precheck passed: ${SQLPACKAGE_DEST}/sqlpackage"
else
    warn "SqlPackage missing — SQL Server/Azure SQL BACPAC backup/restore needs sqlpackage on the DBAegis VM"
fi
SQLCMD_FOUND="$(sqlcmd_path 2>/dev/null || true)"
if [[ -n "$SQLCMD_FOUND" ]]; then
    success "sqlcmd precheck passed: ${SQLCMD_FOUND}"
else
    warn "sqlcmd missing — SQL Server connection checks and restore/control paths need sqlcmd"
fi
MONGODUMP_FOUND="$(command -v mongodump 2>/dev/null || find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongodump -print -quit 2>/dev/null || true)"
MONGORESTORE_FOUND="$(command -v mongorestore 2>/dev/null || find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongorestore -print -quit 2>/dev/null || true)"
MONGOSH_FOUND="$(command -v mongosh 2>/dev/null || find "$MONGODB_INSTALL_ROOT" -mindepth 2 -maxdepth 3 -type f -name mongosh -print -quit 2>/dev/null || true)"
if [[ -n "$MONGODUMP_FOUND" && -n "$MONGORESTORE_FOUND" && -n "$MONGOSH_FOUND" ]]; then
    success "MongoDB client tools precheck passed"
else
    warn "MongoDB client tools missing — MongoDB workflows need mongodump/mongorestore and precheck/physical lock support needs mongosh"
fi
if command -v clickhouse-client >/dev/null 2>&1; then
    success "ClickHouse client precheck passed: $(command -v clickhouse-client)"
else
    warn "ClickHouse client missing — ClickHouse backup/restore needs clickhouse-client on the DBAegis VM"
fi

# =============================================================================
header "5/7  Application files"
# =============================================================================

release_metadata_requested() {
    [[ -n "$DBAEGIS_BUILD_CHANNEL" || -n "$DBAEGIS_RELEASE_NAME" || -n "$DBAEGIS_BUILD_TIME" || -n "$DBAEGIS_GIT_COMMIT" ]]
}

release_manifest_generation_requested() {
    release_metadata_requested || [[ "$DBAEGIS_EDITION_SOURCE" == "environment" ]]
}

write_release_manifest() {
    local manifest_path="${DBAEGIS_BASE}/release.json"
    local packaged_manifest=""

    packaged_manifest="$(find_packaged_release_manifest || true)"
    if [[ -n "$packaged_manifest" ]] && ! release_metadata_requested; then
        if [[ -e "$manifest_path" && "$packaged_manifest" -ef "$manifest_path" ]]; then
            chown "${INSTALL_USER}:${INSTALL_GROUP}" "$manifest_path"
            chmod 644 "$manifest_path"
            success "Packaged release metadata kept at ${manifest_path}"
            return 0
        fi

        cp "$packaged_manifest" "$manifest_path"
        chown "${INSTALL_USER}:${INSTALL_GROUP}" "$manifest_path"
        chmod 644 "$manifest_path"
        success "Packaged release metadata copied to ${manifest_path}"
        return 0
    fi

    if ! release_manifest_generation_requested; then
        if [[ -f "$manifest_path" ]]; then
            chown "${INSTALL_USER}:${INSTALL_GROUP}" "$manifest_path"
            chmod 644 "$manifest_path"
            success "Existing release metadata preserved at ${manifest_path}"
        fi
        return 0
    fi

    sudo -u "$INSTALL_USER" env \
        DBAEGIS_RELEASE_JSON_PRODUCT="DBAegis" \
        DBAEGIS_RELEASE_JSON_VERSION="$DBAEGIS_VERSION" \
        DBAEGIS_RELEASE_JSON_CHANNEL="$DBAEGIS_BUILD_CHANNEL" \
        DBAEGIS_RELEASE_JSON_NAME="$DBAEGIS_RELEASE_NAME" \
        DBAEGIS_RELEASE_JSON_TIME="$DBAEGIS_BUILD_TIME" \
        DBAEGIS_RELEASE_JSON_COMMIT="$DBAEGIS_GIT_COMMIT" \
        DBAEGIS_RELEASE_JSON_EDITION="$DBAEGIS_EDITION" \
        "$VENV_PYTHON" - "$manifest_path" <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])

data = {
    "product": os.environ["DBAEGIS_RELEASE_JSON_PRODUCT"],
    "version": os.environ["DBAEGIS_RELEASE_JSON_VERSION"],
}

channel = os.environ.get("DBAEGIS_RELEASE_JSON_CHANNEL", "").strip()
if channel:
    data["build_channel"] = channel

release_name = os.environ.get("DBAEGIS_RELEASE_JSON_NAME", "").strip()
if release_name:
    data["release_name"] = release_name

build_time = os.environ.get("DBAEGIS_RELEASE_JSON_TIME", "").strip()
if build_time.lower() in {"auto", "now"}:
    build_time = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
if build_time:
    data["build_time"] = build_time

git_commit = os.environ.get("DBAEGIS_RELEASE_JSON_COMMIT", "").strip()
if git_commit:
    data["git_commit"] = git_commit[:40]

edition = os.environ.get("DBAEGIS_RELEASE_JSON_EDITION", "").strip()
if edition:
    data["edition"] = edition

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    chown "${INSTALL_USER}:${INSTALL_GROUP}" "$manifest_path"
    chmod 644 "$manifest_path"
    success "Release metadata written to ${manifest_path}"
}

copy_file() {
    local src="$1" dst="$2"
    if [[ -f "$src" ]]; then
        local src_real dst_real
        src_real="$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")"
        if [[ -e "$dst" ]]; then
            dst_real="$(cd "$(dirname "$dst")" && pwd -P)/$(basename "$dst")"
            if [[ "$src_real" == "$dst_real" ]]; then
                chown "${INSTALL_USER}:${INSTALL_GROUP}" "$dst"
                success "Kept $(basename "$src")"
                return 0
            fi
        fi
        cp "$src" "$dst"
        chown "${INSTALL_USER}:${INSTALL_GROUP}" "$dst"
        success "Copied $(basename "$src")"
    else
        warn "Source not found: ${src} — skipping"
    fi
}

copy_dir() {
    local src="$1" dst="$2"
    if [[ -d "$src" ]]; then
        local src_real dst_real
        src_real="$(cd "$src" && pwd -P)"
        if [[ -d "$dst" ]]; then
            dst_real="$(cd "$dst" && pwd -P)"
            if [[ "$src_real" == "$dst_real" ]]; then
                chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$dst"
                success "Kept $(basename "$src") asset directory"
                return 0
            fi
        fi
        rm -rf "$dst"
        cp -R "$src" "$dst"
        chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$dst"
        success "Copied $(basename "$src") asset directory"
    else
        warn "Source directory not found: ${src} — skipping"
    fi
}

copy_customer_docs() {
    local src="$1" dst="$2" doc copied=0
    local docs=(
        "BACKUP_RESTORE_SUPPORT.md"
        "CODE_PROTECTION.md"
        "CONTROL_PLANE_DISASTER_RECOVERY.md"
        "DBAEGIS_HANDBOOK.pdf"
        "INSTALL_UPGRADE_UNINSTALL.md"
        "PRODUCT_EDITIONS.md"
    )

    if [[ "$DBAEGIS_EDITION" == "professional" || "$DBAEGIS_EDITION" == "enterprise" ]]; then
        docs+=(
            "ARCHITECTURE.md"
            "DEPENDENCY_TRACKING.md"
            "EDITION_PACKAGE_CONTENTS.md"
            "LICENSE_MODEL.md"
            "PRODUCT_OPERATIONS_RUNBOOK.md"
            "PRODUCTION_MONITORING_ALERTING.md"
            "SQLITE_METADATA_SCHEMA.md"
        )
    fi
    if [[ "$DBAEGIS_EDITION" == "enterprise" ]]; then
        docs+=(
            "ENTERPRISE_READINESS.md"
            "INDEPENDENT_SECURITY_ASSESSMENT.md"
        )
    fi

    [[ -d "$src" ]] || die "Package is missing docs directory"
    [[ -f "${src}/DBAEGIS_HANDBOOK.pdf" ]] || die "Package is missing docs/DBAEGIS_HANDBOOK.pdf"
    path_is_under_base "$dst" || die "Refusing to replace documentation outside ${DBAEGIS_BASE}: ${dst}"

    rm -rf "$dst"
    mkdir -p "$dst"
    for doc in "${docs[@]}"; do
        if [[ -f "${src}/${doc}" ]]; then
            cp "${src}/${doc}" "${dst}/${doc}"
            copied=$((copied + 1))
        fi
    done
    (( copied > 0 )) || die "No customer documentation files were found in ${src}"
    [[ -f "${dst}/DBAEGIS_HANDBOOK.pdf" ]] || die "Customer handbook was not installed"

    chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$dst"
    find "$dst" -type d -exec chmod 755 {} +
    find "$dst" -type f -exec chmod 644 {} +
    success "Copied customer documentation"
}

remove_installed_tree() {
    local target="$1" label="$2"
    [[ -e "$target" ]] || return 0
    path_is_under_base "$target" || die "Refusing to remove ${label} outside ${DBAEGIS_BASE}: ${target}"
    rm -rf "$target"
    success "Removed out-of-edition ${label}"
}

resolve_source_file() {
    local rel="$1"
    local candidate=""
    for candidate in \
        "${SCRIPT_DIR}/${rel}" \
        "${SCRIPT_PARENT_DIR}/${rel}" \
        "${SCRIPT_DIR}/app/${rel}" \
        "${SCRIPT_PARENT_DIR}/app/${rel}" \
        "${SCRIPT_DIR}/app/services/${rel}" \
        "${SCRIPT_PARENT_DIR}/app/services/${rel}" \
        "${SCRIPT_DIR}/ui/${rel}" \
        "${SCRIPT_PARENT_DIR}/ui/${rel}" \
        "${SCRIPT_DIR}/bin/${rel}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

resolve_source_dir() {
    local rel="$1"
    local candidate=""
    for candidate in \
        "${SCRIPT_DIR}/${rel}" \
        "${SCRIPT_PARENT_DIR}/${rel}" \
        "${SCRIPT_DIR}/app/${rel}" \
        "${SCRIPT_PARENT_DIR}/app/${rel}" \
        "${SCRIPT_DIR}/ui/${rel}" \
        "${SCRIPT_PARENT_DIR}/ui/${rel}"; do
        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

cleanup_source_file() {
    local src_file="$1" src_real base_real
    [[ -f "$src_file" ]] || return 0
    src_real="$(cd "$(dirname "$src_file")" && pwd -P)/$(basename "$src_file")"
    base_real="$(cd "$DBAEGIS_BASE" && pwd -P)"
    case "$src_real" in
        "$base_real"/*)
            info "Keeping installed-tree source $(basename "$src_file")"
            ;;
        *)
            info "Leaving source package file in place: $(basename "$src_file")"
            ;;
    esac
}

# Verify all required files are present before copying
BACKUP_ENGINE_SRC="$(resolve_source_file "backup_engine.py")" || die "Missing required file: backup_engine.py"
RESTORE_ENGINE_SRC="$(resolve_source_file "restore_engine.py")" || die "Missing required file: restore_engine.py"
RESTORE_OPTIONS_SRC="$(resolve_source_file "restore_options.py")" || die "Missing required file: restore_options.py"
GLOBAL_NOTIFICATIONS_SRC="$(resolve_source_file "global_notifications.py")" || die "Missing required file: global_notifications.py"
VERSION_SRC="$(resolve_source_file "version.py")" || die "Missing required file: version.py"
LICENSE_SRC="$(resolve_source_file "license.py")" || die "Missing required file: license.py"
WEBHOOK_SECURITY_SRC="$(resolve_source_file "webhook_security.py" || true)"
MAIN_SRC="$(resolve_source_file "main.py")" || die "Missing required file: main.py"
INDEX_SRC="$(resolve_source_file "index.html")" || die "Missing required file: index.html"
INSTALL_CONSTRAINTS_SRC="$(resolve_source_file "requirements/install-constraints.txt")" || die "Missing required file: requirements/install-constraints.txt"
ROTATE_SECRET_KEY_SRC="$(resolve_source_file "rotate_dbaegis_secret_key.py")" || die "Missing required file: rotate_dbaegis_secret_key.py"
RESET_ADMIN_PASSWORD_SRC="$(resolve_source_file "reset_admin_password.py")" || die "Missing required file: reset_admin_password.py"
COMMUNITY_APP_SRC="$(resolve_source_dir "app/community" || true)"
PROFESSIONAL_APP_SRC="$(resolve_source_dir "app/professional" || true)"
ENTERPRISE_APP_SRC="$(resolve_source_dir "app/enterprise" || true)"
PROFESSIONAL_UI_SRC="$(resolve_source_dir "ui/professional" || true)"
ENTERPRISE_UI_SRC="$(resolve_source_dir "ui/enterprise" || true)"
DOCS_SRC="$(resolve_source_dir "docs" || true)"

if [[ "$DBAEGIS_EDITION" == "professional" || "$DBAEGIS_EDITION" == "enterprise" ]]; then
    [[ -n "$PROFESSIONAL_APP_SRC" && -f "${PROFESSIONAL_APP_SRC}/main_runtime.py" ]] || die "Professional/Enterprise package is missing app/professional/main_runtime.py"
    [[ -n "$PROFESSIONAL_APP_SRC" && -f "${PROFESSIONAL_APP_SRC}/license.py" ]] || die "Professional/Enterprise package is missing app/professional/license.py"
fi
[[ -n "$COMMUNITY_APP_SRC" && -f "${COMMUNITY_APP_SRC}/runtime.py" ]] || die "Package is missing app/community/runtime.py"
[[ -n "$DOCS_SRC" && -f "${DOCS_SRC}/DBAEGIS_HANDBOOK.pdf" ]] || die "Package is missing docs/DBAEGIS_HANDBOOK.pdf"
if [[ "$DBAEGIS_EDITION" == "enterprise" ]]; then
    [[ -n "$ENTERPRISE_APP_SRC" && -f "${ENTERPRISE_APP_SRC}/auth_ldap.py" ]] || die "Enterprise package is missing app/enterprise/auth_ldap.py"
    [[ -f "${ENTERPRISE_APP_SRC}/webhooks.py" ]] || die "Enterprise package is missing app/enterprise/webhooks.py"
    [[ -f "${ENTERPRISE_APP_SRC}/reports.py" ]] || die "Enterprise package is missing app/enterprise/reports.py"
    [[ -n "$WEBHOOK_SECURITY_SRC" ]] || die "Enterprise package is missing app/webhook_security.py"
fi

# Copy engine files
copy_file "${BACKUP_ENGINE_SRC}"         "${APP_DIR}/services/backup_engine.py"
copy_file "${RESTORE_ENGINE_SRC}"        "${APP_DIR}/services/restore_engine.py"
copy_file "${RESTORE_OPTIONS_SRC}"       "${APP_DIR}/services/restore_options.py"
copy_file "${GLOBAL_NOTIFICATIONS_SRC}"  "${APP_DIR}/services/global_notifications.py"

copy_file "${VERSION_SRC}"               "${APP_DIR}/version.py"
copy_file "${LICENSE_SRC}"               "${APP_DIR}/license.py"
if [[ "$DBAEGIS_EDITION" == "enterprise" ]]; then
    copy_file "${WEBHOOK_SECURITY_SRC}"  "${APP_DIR}/webhook_security.py"
else
    remove_installed_tree "${APP_DIR}/webhook_security.py" "Enterprise webhook security helper"
fi
copy_file "${MAIN_SRC}"                  "${APP_DIR}/main.py"
copy_file "${INSTALL_CONSTRAINTS_SRC}"   "${DBAEGIS_BASE}/requirements/install-constraints.txt"

# Copy UI
copy_file "${INDEX_SRC}"               "${UI_DIR}/index.html"
if [[ -f "${SCRIPT_PARENT_DIR}/ui/favicon.svg" ]]; then
    copy_file "${SCRIPT_PARENT_DIR}/ui/favicon.svg" "${UI_DIR}/favicon.svg"
elif [[ -f "${SCRIPT_DIR}/ui/favicon.svg" ]]; then
    copy_file "${SCRIPT_DIR}/ui/favicon.svg" "${UI_DIR}/favicon.svg"
else
    warn "UI favicon asset not found in source package"
fi
if [[ -f "${SCRIPT_PARENT_DIR}/ui/logo.svg" ]]; then
    copy_file "${SCRIPT_PARENT_DIR}/ui/logo.svg" "${UI_DIR}/logo.svg"
elif [[ -f "${SCRIPT_DIR}/ui/logo.svg" ]]; then
    copy_file "${SCRIPT_DIR}/ui/logo.svg" "${UI_DIR}/logo.svg"
else
    warn "UI logo asset not found in source package"
fi
if [[ -d "${SCRIPT_PARENT_DIR}/ui/db-logos" ]]; then
    copy_dir "${SCRIPT_PARENT_DIR}/ui/db-logos" "${UI_DIR}/db-logos"
elif [[ -d "${SCRIPT_DIR}/ui/db-logos" ]]; then
    copy_dir "${SCRIPT_DIR}/ui/db-logos" "${UI_DIR}/db-logos"
else
    warn "UI db-logos directory not found in source package"
fi
copy_customer_docs "$DOCS_SRC" "${DBAEGIS_BASE}/docs"

copy_dir "$COMMUNITY_APP_SRC" "${APP_DIR}/community"

case "$DBAEGIS_EDITION" in
    community)
        remove_installed_tree "${APP_DIR}/professional" "Professional app overlay"
        remove_installed_tree "${APP_DIR}/enterprise" "Enterprise app overlay"
        remove_installed_tree "${UI_DIR}/professional" "Professional UI overlay"
        remove_installed_tree "${UI_DIR}/enterprise" "Enterprise UI overlay"
        ;;
    professional)
        copy_dir "$PROFESSIONAL_APP_SRC" "${APP_DIR}/professional"
        [[ -n "$PROFESSIONAL_UI_SRC" ]] && copy_dir "$PROFESSIONAL_UI_SRC" "${UI_DIR}/professional"
        remove_installed_tree "${APP_DIR}/enterprise" "Enterprise app overlay"
        remove_installed_tree "${UI_DIR}/enterprise" "Enterprise UI overlay"
        ;;
    enterprise)
        copy_dir "$PROFESSIONAL_APP_SRC" "${APP_DIR}/professional"
        copy_dir "$ENTERPRISE_APP_SRC" "${APP_DIR}/enterprise"
        [[ -n "$PROFESSIONAL_UI_SRC" ]] && copy_dir "$PROFESSIONAL_UI_SRC" "${UI_DIR}/professional"
        [[ -n "$ENTERPRISE_UI_SRC" ]] && copy_dir "$ENTERPRISE_UI_SRC" "${UI_DIR}/enterprise"
        ;;
esac

# Write __init__.py so the services dir is a proper package
touch "${APP_DIR}/__init__.py" "${APP_DIR}/services/__init__.py"
chown "${INSTALL_USER}:${INSTALL_GROUP}" "${APP_DIR}/__init__.py" "${APP_DIR}/services/__init__.py"

# Clean up source files from the extraction directory — they've been copied
# to their proper locations and are no longer needed here
for src_file in \
    "${BACKUP_ENGINE_SRC}" \
    "${RESTORE_ENGINE_SRC}" \
    "${RESTORE_OPTIONS_SRC}" \
    "${GLOBAL_NOTIFICATIONS_SRC}" \
    "${VERSION_SRC}" \
    "${LICENSE_SRC}" \
    "${WEBHOOK_SECURITY_SRC}" \
    "${MAIN_SRC}" \
    "${INDEX_SRC}"; do
    cleanup_source_file "$src_file"
done
success "Source package files left intact"

# ── Install dbaegis control binary ────────────────────────────────────────────
cat > "${DBAEGIS_BASE}/bin/dbaegis" << 'BINEOF'
#!/usr/bin/env bash
# DBAegis control binary — /opt/dbaegis/bin/dbaegis
# Usage: dbaegis {start|stop|restart|status|log|version|license|rotate-secret-key|reset-admin-password}
set -euo pipefail

DBAEGIS_BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_CONF_FILE="${DBAEGIS_BASE}/conf/dbaegis.conf"
CONF_FILE="${DBAEGIS_CONF:-}"
if [[ -z "$CONF_FILE" && -f /etc/systemd/system/dbaegis.service ]]; then
    CONF_FILE="$(awk -F= '/^EnvironmentFile=/{print substr($0, index($0, "=") + 1); exit}' /etc/systemd/system/dbaegis.service 2>/dev/null || true)"
fi
CONF_FILE="${CONF_FILE:-$DEFAULT_CONF_FILE}"

read_conf_value() {
    local target="$1" key="$2" value
    [[ -f "$target" ]] || return 0
    value="$(awk -v key="$key" '
        /^[[:space:]]*($|#)/ { next }
        {
            line = $0
            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                sub(/^[^=]*=/, "", line)
                sub(/^[[:space:]]*/, "", line)
                sub(/[[:space:]]*#.*$/, "", line)
                print line
                exit
            }
        }
    ' "$target" 2>/dev/null || true)"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "$value"
}

load_conf_var() {
    local key="$1" dest="${2:-$1}" value
    value="$(read_conf_value "$CONF_FILE" "$key")"
    [[ -n "$value" ]] || return 0
    printf -v "$dest" '%s' "$value"
    export "$dest"
}

load_conf_values() {
    local key
    for key in \
        DBAEGIS_DB_PATH BACKUP_DIR SELF_BACKUP_DIR LOG_DIR LOG_BACKUP_COUNT \
        DBAEGIS_TEMP_DIR DBAEGIS_LICENSE_DIR VENV_DIR DBAEGIS_PYTHON_DIR DBAEGIS_PYTHON_BIN \
        API_BIND API_PORT UVICORN_WORKERS LOG_LEVEL DBAEGIS_BACKUP_TIMEOUT \
        AUTH_ENABLED SESSION_COOKIE_NAME SESSION_TTL_HOURS SESSION_COOKIE_SECURE \
        DBAEGIS_EDITION DBAEGIS_LICENSE_REQUIRED DBAEGIS_LICENSE_KEY DBAEGIS_LICENSE_KEY_FILE \
        DBAEGIS_LICENSE_PUBLIC_KEY DBAEGIS_LICENSE_PUBLIC_KEY_FILE DBAEGIS_LICENSE_INSTANCE_ID \
        DBAEGIS_SECRET_KEY BOOTSTRAP_ADMIN_USER BOOTSTRAP_ADMIN_PASSWORD; do
        load_conf_var "$key"
    done
}
[[ -f "$CONF_FILE" ]] && load_conf_values

VENV_DIR="${VENV_DIR:-${DBAEGIS_BASE}/venv}"
DBAEGIS_PYTHON_DIR="${DBAEGIS_PYTHON_DIR:-${DBAEGIS_BASE}/python}"
DBAEGIS_PYTHON_BIN="${DBAEGIS_PYTHON_BIN:-${DBAEGIS_PYTHON_DIR}/bin/python3}"
LOG_DIR="${LOG_DIR:-${DBAEGIS_BASE}/logs}"
LOG_BACKUP_COUNT="${LOG_BACKUP_COUNT:-9}"
API_BIND="${API_BIND:-127.0.0.1}"
API_PORT="${API_PORT:-8000}"
UVICORN_WORKERS="${UVICORN_WORKERS:-1}"
if [[ "$UVICORN_WORKERS" != "1" ]]; then
    echo "DBAegis uses in-process job cancellation and scheduler state; forcing UVICORN_WORKERS=1" >&2
    UVICORN_WORKERS=1
fi
LOG_LEVEL="${LOG_LEVEL:-info}"

cmd="${1:-help}"
case "$cmd" in
    start)
        cd "${DBAEGIS_BASE}"
        export PYTHONPATH="${DBAEGIS_BASE}"
        export DBAEGIS_PYTHON_DIR DBAEGIS_PYTHON_BIN
        export PATH="${VENV_DIR}/bin:${DBAEGIS_PYTHON_DIR}/bin:${PATH}"
        exec "${VENV_DIR}/bin/uvicorn" app.main:app \
            --host "$API_BIND" \
            --port "$API_PORT" \
            --workers "$UVICORN_WORKERS" \
            --log-level "$LOG_LEVEL" \
            --access-log
        ;;
    stop)
        systemctl stop dbaegis
        ;;
    restart)
        systemctl restart dbaegis
        ;;
    status)
        systemctl status dbaegis
        ;;
    log|logs)
        journalctl -u dbaegis -f
        ;;
    version)
        cd "${DBAEGIS_BASE}"
        export PYTHONPATH="${DBAEGIS_BASE}"
        if [[ -x "${VENV_DIR}/bin/python" ]]; then
            "${VENV_DIR}/bin/python" -m app.version --line && exit 0
        fi
        if [[ -x "${DBAEGIS_PYTHON_BIN}" ]]; then
            "${DBAEGIS_PYTHON_BIN}" -m app.version --line && exit 0
        fi
        echo "DBAegis unknown"
        ;;
    license)
        shift
        cd "${DBAEGIS_BASE}"
        export PYTHONPATH="${DBAEGIS_BASE}"
        exec "${VENV_DIR}/bin/python" -m app.license "$@"
        ;;
    rotate-secret-key)
        shift
        exec "${VENV_DIR}/bin/python" "${DBAEGIS_BASE}/bin/rotate_dbaegis_secret_key.py" \
            --conf "$CONF_FILE" \
            "$@"
        ;;
    reset-admin-password)
        shift
        exec "${VENV_DIR}/bin/python" "${DBAEGIS_BASE}/bin/reset_admin_password.py" \
            --conf "$CONF_FILE" \
            "$@"
        ;;
    help|--help|-h)
        echo "Usage: dbaegis {start|stop|restart|status|log|version|license|rotate-secret-key|reset-admin-password}"
        ;;
    *)
        echo "Unknown command: $cmd"
        echo "Usage: dbaegis {start|stop|restart|status|log|version|license|rotate-secret-key|reset-admin-password}"
        exit 1
        ;;
esac
BINEOF

copy_file "${ROTATE_SECRET_KEY_SRC}" "${DBAEGIS_BASE}/bin/rotate_dbaegis_secret_key.py"
copy_file "${RESET_ADMIN_PASSWORD_SRC}" "${DBAEGIS_BASE}/bin/reset_admin_password.py"

chmod +x "${DBAEGIS_BASE}/bin/dbaegis" "${DBAEGIS_BASE}/bin/rotate_dbaegis_secret_key.py" "${DBAEGIS_BASE}/bin/reset_admin_password.py"
chown "${INSTALL_USER}:${INSTALL_GROUP}" "${DBAEGIS_BASE}/bin/dbaegis" "${DBAEGIS_BASE}/bin/rotate_dbaegis_secret_key.py" "${DBAEGIS_BASE}/bin/reset_admin_password.py"

# Symlink to /usr/local/bin so it's available system-wide
ln -sf "${DBAEGIS_BASE}/bin/dbaegis" /usr/local/bin/dbaegis
success "dbaegis binary installed → /usr/local/bin/dbaegis"

# Install/copy install.sh into bin/. When the installer is already running from
# the destination tree, skip the self-move and leave the current script in place.
if [[ "${SCRIPT_DIR}/install.sh" != "${DBAEGIS_BASE}/bin/install.sh" ]] && [[ -f "${SCRIPT_DIR}/install.sh" ]]; then
    cp "${SCRIPT_DIR}/install.sh" "${DBAEGIS_BASE}/bin/install.sh"
fi

# Copy uninstall.sh from the extracted tar payload into the destination bin/.
UNINSTALL_SRC=""
if [[ -f "${SCRIPT_DIR}/bin/uninstall.sh" ]]; then
    UNINSTALL_SRC="${SCRIPT_DIR}/bin/uninstall.sh"
elif [[ -f "${SCRIPT_DIR}/uninstall.sh" ]]; then
    UNINSTALL_SRC="${SCRIPT_DIR}/uninstall.sh"
elif [[ -f "${SCRIPT_PARENT_DIR}/bin/uninstall.sh" ]]; then
    UNINSTALL_SRC="${SCRIPT_PARENT_DIR}/bin/uninstall.sh"
fi

if [[ -n "$UNINSTALL_SRC" ]]; then
    copy_file "$UNINSTALL_SRC" "${DBAEGIS_BASE}/bin/uninstall.sh"
else
    warn "uninstall.sh not found in extracted package; creating non-destructive placeholder"
    cat > "${DBAEGIS_BASE}/bin/uninstall.sh" <<'UNINST'
#!/usr/bin/env bash
set -euo pipefail
echo "DBAegis uninstall helper was not included in this package."
echo "Reinstall or extract a complete DBAegis package, then run bin/uninstall.sh."
exit 1
UNINST
fi

chmod +x "${DBAEGIS_BASE}/bin/install.sh" "${DBAEGIS_BASE}/bin/uninstall.sh"
chown "${INSTALL_USER}:${INSTALL_GROUP}"     "${DBAEGIS_BASE}/bin/install.sh"     "${DBAEGIS_BASE}/bin/uninstall.sh"
success "install.sh and uninstall.sh installed to ${DBAEGIS_BASE}/bin/"

cat > "${DBAEGIS_BASE}/UPGRADE_AND_INSTALL.txt" <<'TXT'
DBAegis install modes

Fresh install:
  sudo DBAEGIS_USER=dbaegis bash install.sh --fresh

Upgrade existing installation in place:
  sudo DBAEGIS_USER=dbaegis bash install.sh --upgrade

Rollback to the latest pre-upgrade runtime snapshot:
  sudo DBAEGIS_USER=dbaegis bash /opt/dbaegis/bin/install.sh --rollback

Rollback to a specific pre-upgrade runtime snapshot:
  sudo DBAEGIS_USER=dbaegis DBAEGIS_ROLLBACK_SNAPSHOT=20260428-010336 bash /opt/dbaegis/bin/install.sh --rollback

Notes:
- --upgrade preserves existing dbaegis.conf and writes a new template to dbaegis.conf.new
- --upgrade updates DBAEGIS_EDITION and paid-edition DBAEGIS_LICENSE_REQUIRED from an official package manifest or explicit installer environment
- --upgrade keeps existing SQLite data and backup files in place
- --upgrade creates a pre-upgrade runtime snapshot under /opt/dbaegis/rollback
- --rollback restores application/UI/bin/venv runtime files and the systemd unit from the selected snapshot
- --rollback preserves the active dbaegis.conf, SQLite metadata DB, backup files, and OS packages
- --rollback does not downgrade OS packages or restore an older SQLite metadata DB
- DBAEGIS_OS_PACKAGE_MODE=install lets the OS package manager process and possibly upgrade all named prerequisites; set to missing-only to install only missing prerequisite OS packages
- If a DB schema change must be reversed, restore the matching system backup or pre-upgrade DB copy
- --fresh is intended for a clean install path
- The installer downloads an embedded Python runtime to /opt/dbaegis/python by default
- If DBAEGIS_PYTHON_DOWNLOAD=skip or DBAEGIS_PYTHON_BIN points at a custom runtime, that runtime must be Python 3.12 or newer
- Default installs own /opt/dbaegis/conf/dbaegis.conf, /opt/dbaegis/data, and /backups/self as DBAEGIS_USER; use sudo/root for systemctl stop/start and run file restore or secret-key rotation steps as the service user
- Override install-time paths with environment variables when the defaults do not match the host:
    sudo DBAEGIS_USER=dbaegis DBAEGIS_DB_PATH=/data/dbaegis/dbaegis.db DBAEGIS_BACKUP_DIR=/srv/backups bash bin/install.sh --fresh
- Override the embedded Python location or tarball with DBAEGIS_PYTHON_DIR=/path or DBAEGIS_PYTHON_URL=https://...
- By default the service runs with PrivateTmp disabled so local backup/restore paths under /tmp remain visible
- To re-enable stricter systemd tmp isolation, install with:
    sudo DBAEGIS_USER=dbaegis DBAEGIS_SERVICE_PRIVATE_TMP=yes bash install.sh --fresh
- Optional vendor client tools are opt-in. To install or verify the DBAegis-tested optional tools during install/upgrade:
    sudo DBAEGIS_INSTALL_SNOWSQL=1 DBAEGIS_INSTALL_SQLPACKAGE=1 DBAEGIS_INSTALL_SQLCMD=1 DBAEGIS_ACCEPT_MICROSOFT_EULA=Y DBAEGIS_INSTALL_MONGODB_TOOLS=1 DBAEGIS_INSTALL_CLICKHOUSE_CLIENT=1 bash bin/install.sh --upgrade
- SnowSQL is managed at /usr/local/bin/snowsql when DBAEGIS_INSTALL_SNOWSQL=1 is used; database-host tools such as Oracle rman, Neo4j neo4j-admin, Cassandra nodetool, Couchbase cbbackupmgr, and MySQL/MariaDB physical tools still belong with the matching database software.
- Official production release packages include release.json at the package root, for example:
    {"build_channel":"stable","edition":"professional"}
- The installer copies packaged release.json to /opt/dbaegis/release.json; /api/version reports the packaged edition and derives the release name from app/version.py when omitted
- DBAEGIS_BUILD_CHANNEL=stable remains available as a CI override when no package release.json exists
- DBAEGIS_SECRET_KEY encrypts saved connection, storage, notification, LDAP, Microsoft Authenticator MFA, webhook, and restore-option secrets
- Initial local admin login values are stored in /opt/dbaegis/conf/dbaegis.conf as BOOTSTRAP_ADMIN_USER and BOOTSTRAP_ADMIN_PASSWORD
- To print the initial local admin login values after setup:
    sudo grep -E '^BOOTSTRAP_ADMIN_USER=|^BOOTSTRAP_ADMIN_PASSWORD=' /opt/dbaegis/conf/dbaegis.conf
- To rotate DBAEGIS_SECRET_KEY, stop the service and run:
    sudo -u dbaegis /opt/dbaegis/bin/dbaegis rotate-secret-key --generate-new-key --update-conf
- To reset a forgotten local admin password without modifying other users, run:
    sudo -u dbaegis /opt/dbaegis/bin/dbaegis reset-admin-password
- Replace dbaegis in that command if the install uses a different service user
- Verify after install, upgrade, or rollback:
    systemctl status dbaegis --no-pager
    curl http://127.0.0.1:8000/health
    curl http://127.0.0.1:8000/api/version
- If TLS is enabled, verify HTTPS too:
    curl -k https://127.0.0.1:3443/health
    curl -k https://127.0.0.1:3443/api/version
- See docs/INSTALL_UPGRADE_UNINSTALL.md for the full parameter reference and rollback limits
TXT
chown "${INSTALL_USER}:${INSTALL_GROUP}" "${DBAEGIS_BASE}/UPGRADE_AND_INSTALL.txt"

write_release_manifest

success "Application files installed"

# =============================================================================
header "6/7  Single systemd service"
# =============================================================================

# ── Standalone nginx config (run as install user, not system nginx) ──────────
RUNTIME_DIR="${DBAEGIS_BASE}/run"
NGINX_RUNTIME_DIR="${DBAEGIS_BASE}/run/nginx"
NGINX_CONF_DIR="${NGINX_RUNTIME_DIR}/conf"
mkdir -p "$RUNTIME_DIR" "$NGINX_RUNTIME_DIR" "$NGINX_CONF_DIR" "$NGINX_RUNTIME_DIR/client_body_temp" "$NGINX_RUNTIME_DIR/proxy_temp" "$NGINX_RUNTIME_DIR/fastcgi_temp" "$NGINX_RUNTIME_DIR/uwsgi_temp" "$NGINX_RUNTIME_DIR/scgi_temp"
chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "$RUNTIME_DIR"
chmod 755 "$RUNTIME_DIR" "$NGINX_RUNTIME_DIR"
chmod 750 "$NGINX_CONF_DIR"

NGINX_MAIN_CONF="${NGINX_CONF_DIR}/nginx-main.conf"
NGINX_SERVER_CONF="${NGINX_CONF_DIR}/nginx.conf"
NGINX_TLS_SERVER_CONF="${NGINX_CONF_DIR}/nginx-tls-servers.conf"

for LEGACY_NGINX_CONF in "${CONF_DIR}/nginx.conf" "${CONF_DIR}/nginx-main.conf" "${CONF_DIR}/nginx-tls-servers.conf"; do
    if [[ -e "$LEGACY_NGINX_CONF" && "$LEGACY_NGINX_CONF" != "$NGINX_SERVER_CONF" && "$LEGACY_NGINX_CONF" != "$NGINX_MAIN_CONF" && "$LEGACY_NGINX_CONF" != "$NGINX_TLS_SERVER_CONF" ]]; then
        rm -f "$LEGACY_NGINX_CONF" && success "removed legacy generated nginx config ${LEGACY_NGINX_CONF}" || warn "could not remove legacy generated nginx config ${LEGACY_NGINX_CONF}"
    fi
done

cat > "$NGINX_SERVER_CONF" <<'EOF'
# Rendered at service start by bin/dbaegis-stack from dbaegis.conf
EOF
chown "${INSTALL_USER}:${INSTALL_GROUP}" "$NGINX_SERVER_CONF"
success "nginx server config written to ${NGINX_SERVER_CONF}"

cat > "$NGINX_TLS_SERVER_CONF" <<'EOF'
# Rendered at service start by bin/dbaegis-stack from dbaegis.conf
EOF
chown "${INSTALL_USER}:${INSTALL_GROUP}" "$NGINX_TLS_SERVER_CONF"
success "nginx TLS server config written to ${NGINX_TLS_SERVER_CONF}"

cat > "$NGINX_MAIN_CONF" << EOF
worker_processes auto;
pid ${NGINX_RUNTIME_DIR}/nginx.pid;
error_log ${LOG_DIR}/nginx-error.log warn;

events {
    worker_connections 1024;
}

http {
    include ${NGINX_TLS_SERVER_CONF};
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    types_hash_max_size 4096;
    server_tokens off;

    client_body_temp_path ${NGINX_RUNTIME_DIR}/client_body_temp;
    proxy_temp_path       ${NGINX_RUNTIME_DIR}/proxy_temp;
    fastcgi_temp_path     ${NGINX_RUNTIME_DIR}/fastcgi_temp;
    uwsgi_temp_path       ${NGINX_RUNTIME_DIR}/uwsgi_temp;
    scgi_temp_path        ${NGINX_RUNTIME_DIR}/scgi_temp;

    access_log ${LOG_DIR}/nginx-access.log;

    include ${NGINX_SERVER_CONF};
}
EOF
chown "${INSTALL_USER}:${INSTALL_GROUP}" "$NGINX_MAIN_CONF"
success "standalone nginx config written to ${NGINX_MAIN_CONF}"

# ── single launcher that starts uvicorn + nginx and keeps one foreground pid ─
DBAEGIS_STACK_SRC="$(resolve_source_file "dbaegis-stack")" || die "Missing required file: dbaegis-stack"
copy_file "${DBAEGIS_STACK_SRC}" "${DBAEGIS_BASE}/bin/dbaegis-stack"

chmod +x "${DBAEGIS_BASE}/bin/dbaegis-stack"
chown "${INSTALL_USER}:${INSTALL_GROUP}" "${DBAEGIS_BASE}/bin/dbaegis-stack"
success "single-process launcher installed"

# ── dbaegis.service only ──────────────────────────────────────────────────────
cat > /etc/systemd/system/dbaegis.service << EOF
[Unit]
Description=DBAegis Database Resilience Platform (API + UI)
After=network.target

[Service]
Type=simple
User=${INSTALL_USER}
Group=${INSTALL_GROUP}
WorkingDirectory=${DBAEGIS_BASE}
EnvironmentFile=${CONF_FILE}
Environment=DBAEGIS_CONF=${CONF_FILE}
Environment=PYTHONPATH=${DBAEGIS_BASE}
Environment=CONF_DIR=${CONF_DIR}
Environment=NGINX_CONF_DIR=${NGINX_CONF_DIR}
Environment=DBAEGIS_PYTHON_DIR=${PYTHON_DIR}
Environment=DBAEGIS_PYTHON_BIN=${PYTHON_BIN}
Environment=PATH=${VENV_DIR}/bin:${PYTHON_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${DBAEGIS_BASE}/bin/dbaegis-stack
ExecStop=/bin/kill -s TERM \$MAINPID
SuccessExitStatus=143
Restart=on-failure
RestartSec=5s
PrivateTmp=${SERVICE_PRIVATE_TMP}
ProtectSystem=full
ReadWritePaths=${DBAEGIS_BASE} ${CONF_DIR} ${LOG_DIR} ${TEMP_DIR} ${LICENSE_DIR} ${DB_PARENT_DIR} ${BACKUP_DIR} ${SELF_BACKUP_DIR}

[Install]
WantedBy=multi-user.target
EOF

# stop/disable split services if they exist from older installs
systemctl disable --now dbaegis-api.service dbaegis-ui.service 2>/dev/null || true
rm -f /etc/systemd/system/dbaegis-api.service /etc/systemd/system/dbaegis-ui.service
systemctl daemon-reload
success "Single systemd unit registered: dbaegis.service"

# Validate nginx config with the same runtime user context assumptions
sudo -u "$INSTALL_USER" /usr/sbin/nginx -e "${LOG_DIR}/nginx-error.log" -t -c "$NGINX_MAIN_CONF" 2>&1 && success "standalone nginx config valid" || warn "nginx config test failed — run: sudo -u ${INSTALL_USER} /usr/sbin/nginx -e ${LOG_DIR}/nginx-error.log -t -c ${NGINX_MAIN_CONF}"

# =============================================================================
header "7/7  Enable & start service"
# =============================================================================

systemctl unmask dbaegis.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable dbaegis.service 2>/dev/null && success "dbaegis enabled on boot"
systemctl restart dbaegis.service
sleep 2

if systemctl is-active --quiet dbaegis.service; then
    success "dbaegis running as a single service"
else
    warn "dbaegis failed — check: journalctl -u dbaegis -n 50"
fi
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   DBAegis install/upgrade complete!             ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}UI:${NC}         http://$(hostname -I | awk '{print $1}'):${UI_PORT}"
echo -e "  ${BOLD}API:${NC}        http://$(hostname -I | awk '{print $1}'):${API_PORT}"
echo -e "  ${BOLD}Config:${NC}     ${CONF_FILE}"
echo -e "  ${BOLD}Database:${NC}   ${DBAEGIS_DB_PATH}"
echo -e "  ${BOLD}Backups:${NC}    ${BACKUP_DIR}"
echo -e "  ${BOLD}Temp:${NC}       ${TEMP_DIR}"
echo -e "  ${BOLD}License:${NC}    ${LICENSE_DIR}"
echo -e "  ${BOLD}Logs:${NC}       ${LOG_DIR}"
if [[ "${DBAEGIS_EDITION}" == "enterprise" ]]; then
echo -e "  ${BOLD}LDAP:${NC}       Available after install; configure it in the UI under Access Control > LDAP"
else
echo -e "  ${BOLD}LDAP:${NC}       Enterprise-only; not included in the ${DBAEGIS_EDITION} edition"
fi
if [[ "${DBAEGIS_EDITION}" == "community" ]]; then
echo -e "  ${BOLD}MFA:${NC}        Professional/Enterprise-only; shown as edition locked in the community edition"
else
echo -e "  ${BOLD}MFA:${NC}        Available for local users; configure Microsoft Authenticator under Access Control > MFA"
fi
if [[ "$MODE" == "fresh" ]]; then
echo -e "  ${BOLD}Initial admin:${NC} admin"
echo -e "  ${BOLD}Initial password:${NC} stored in ${CONF_FILE} as BOOTSTRAP_ADMIN_PASSWORD"
fi
echo ""
echo -e "  ${BOLD}Service commands:${NC}"
echo -e "    systemctl start   dbaegis"
echo -e "    systemctl stop    dbaegis"
echo -e "    systemctl restart dbaegis"
echo -e "    systemctl status  dbaegis"
echo -e "    dbaegis start|stop|restart|status
    journalctl -u dbaegis -f        # combined service logs"
echo ""
echo -e "  ${BOLD}To change DB path:${NC}"
echo -e "    1. Re-run install with DBAEGIS_DB_PATH=/new/path/dbaegis.db if this is a fresh host"
echo -e "    2. Or edit ${CONF_FILE}  →  change DBAEGIS_DB_PATH=..."
echo -e "    3. Ensure the parent directory exists and is writable by ${INSTALL_USER}"
echo -e "    4. systemctl restart dbaegis"
echo ""
echo -e "  ${BOLD}To change backup path:${NC}"
echo -e "    1. Re-run install with DBAEGIS_BACKUP_DIR=/new/backup/path if this is a fresh host"
echo -e "    2. Or edit ${CONF_FILE}  →  change BACKUP_DIR=..."
echo -e "    3. Ensure the directory exists and is writable by ${INSTALL_USER}"
echo -e "    4. systemctl restart dbaegis"
echo ""
echo -e "  ${BOLD}To change DBAegis temp path:${NC}"
echo -e "    1. Re-run install with DBAEGIS_TEMP_DIR=/new/temp/path if this is a fresh host"
echo -e "    2. Or edit ${CONF_FILE}  →  change DBAEGIS_TEMP_DIR=..."
echo -e "    3. Ensure the directory exists and is writable by ${INSTALL_USER}"
echo -e "    4. systemctl restart dbaegis"
echo ""
