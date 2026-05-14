#!/usr/bin/env bash
# =============================================================================
#  DBAegis Database Resilience Platform — Uninstaller
#  Usage: sudo bash uninstall.sh
#
#  What this removes:
#    - systemd service units (dbaegis, dbaegis-api, dbaegis-ui)
#    - nginx config symlink/include
#    - DBAegis runtime files under the install base (app, ui, venv, logs)
#    - Config at /opt/dbaegis/conf/ only with --purge
#
#  What this ALWAYS preserves:
#    - configured BACKUP_DIR path     (customer database backup files)
#    - configured SELF_BACKUP_DIR     (DBAegis system backup snapshots)
#
#  What this PRESERVES by default (unless --purge is passed):
#    - /opt/dbaegis/data/dbaegis.db    (your database)
#    - /opt/dbaegis/conf/dbaegis.conf (including DBAEGIS_SECRET_KEY)
#
#  Usage:
#    sudo bash uninstall.sh           # keeps database, config, and backups
#    sudo bash uninstall.sh --purge   # removes product metadata/config, keeps backups
#    sudo bash uninstall.sh --yes     # skip confirmation prompt
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}── $* ──────────────────────────────────────${NC}"; }

# ── Parse flags ───────────────────────────────────────────────────────────────
PURGE=0
YES=0
usage() {
    cat <<'EOF'
Usage: sudo bash uninstall.sh [--purge] [--yes]

  --purge  remove database, config, license, and product state; preserve backup artifacts
  --yes    skip confirmation prompt
EOF
}

for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        --yes|-y) YES=1 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $arg" ;;
    esac
done

# ── Require root ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash uninstall.sh"

# ── Detect install base from script, service unit, conf, or default ───────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DBAEGIS_BASE="${DBAEGIS_BASE:-}"
if [[ -z "$DBAEGIS_BASE" ]]; then
    if [[ "$(basename "$SCRIPT_DIR")" == "bin" && -d "${SCRIPT_PARENT_DIR}/conf" ]]; then
        DBAEGIS_BASE="$SCRIPT_PARENT_DIR"
    else
        DBAEGIS_BASE="/opt/dbaegis"
    fi
fi

CONF_FILE="${DBAEGIS_CONF:-${DBAEGIS_BASE}/conf/dbaegis.conf}"
CONF_LOADED=0

read_unit_environment_file() {
    local unit_file="/etc/systemd/system/dbaegis.service" raw
    [[ -f "$unit_file" ]] || return 0
    raw="$(awk -F= '/^[[:space:]]*EnvironmentFile=/{print substr($0, index($0, "=") + 1); exit}' "$unit_file" 2>/dev/null || true)"
    raw="${raw#-}"
    raw="${raw%\"}"
    raw="${raw#\"}"
    raw="${raw%\'}"
    raw="${raw#\'}"
    [[ -n "$raw" ]] && printf '%s\n' "$raw"
}

if [[ -z "${DBAEGIS_CONF:-}" && ! -f "$CONF_FILE" ]]; then
    unit_conf="$(read_unit_environment_file)"
    if [[ -n "${unit_conf:-}" && -f "$unit_conf" ]]; then
        CONF_FILE="$unit_conf"
        DBAEGIS_BASE="$(cd "$(dirname "$CONF_FILE")/.." && pwd)"
    fi
fi

trim_conf_value() {
    local value="$1"
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "$value"
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
                print line
                exit
            }
        }
    ' "$target" 2>/dev/null || true)"
    [[ -n "$raw" ]] || return 0
    trim_conf_value "$raw"
}

load_conf_var() {
    local key="$1" dest="${2:-$1}" value
    value="$(read_conf_value "$CONF_FILE" "$key" || true)"
    [[ -n "$value" ]] || return 0
    printf -v "$dest" '%s' "$value"
}

if [[ -f "$CONF_FILE" ]]; then
    CONF_LOADED=1
    load_conf_var "DBAEGIS_BASE"
    load_conf_var "APP_DIR"
    load_conf_var "UI_DIR"
    load_conf_var "DBAEGIS_DB_PATH"
    load_conf_var "DB_PATH"
    load_conf_var "VAULT_DB_PATH"
    load_conf_var "BACKUP_DIR"
    load_conf_var "SELF_BACKUP_DIR"
    load_conf_var "LOG_DIR"
    load_conf_var "DBAEGIS_TEMP_DIR" "TEMP_DIR"
    load_conf_var "DBAEGIS_LICENSE_DIR" "LICENSE_DIR"
    load_conf_var "VENV_DIR"
    load_conf_var "DBAEGIS_PYTHON_DIR" "PYTHON_DIR"
    load_conf_var "DBAEGIS_ROLLBACK_DIR" "ROLLBACK_DIR"
    info "Loaded config from ${CONF_FILE}"
fi

CONF_DIR="$(dirname "$CONF_FILE")"
APP_DIR="${APP_DIR:-${DBAEGIS_BASE}/app}"
UI_DIR="${UI_DIR:-${DBAEGIS_BASE}/ui}"
DATA_DIR="${DBAEGIS_BASE}/data"
DB_PATH="${DBAEGIS_DB_PATH:-${DB_PATH:-${VAULT_DB_PATH:-${DATA_DIR}/dbaegis.db}}}"
BACKUP_DIR="${BACKUP_DIR:-${DBAEGIS_BACKUP_DIR:-/backups}}"
SELF_BACKUP_DIR="${SELF_BACKUP_DIR:-${DBAEGIS_SELF_BACKUP_DIR:-${BACKUP_DIR}/self}}"
LOG_DIR="${LOG_DIR:-${DBAEGIS_BASE}/logs}"
VENV_DIR="${VENV_DIR:-${DBAEGIS_BASE}/venv}"
PYTHON_DIR="${PYTHON_DIR:-${DBAEGIS_BASE}/python}"
TEMP_DIR="${TEMP_DIR:-${DBAEGIS_BASE}/tmp}"
LICENSE_DIR="${LICENSE_DIR:-${DBAEGIS_BASE}/license}"
ROLLBACK_DIR="${ROLLBACK_DIR:-${DBAEGIS_ROLLBACK_DIR:-${DBAEGIS_BASE}/rollback}}"
TLS_DIR="${DBAEGIS_BASE}/tls"
RUN_DIR="${DBAEGIS_BASE}/run"
VENDOR_DIR="${DBAEGIS_BASE}/vendor"
MONGODB_INSTALL_ROOT="${DBAEGIS_MONGODB_INSTALL_ROOT:-/opt/dbaegis-tools/mongodb}"
SNOWSQL_HOME="${DBAEGIS_SNOWSQL_HOME:-${DBAEGIS_BASE}}"
SNOWSQL_CONFIG_DIR="${SNOWSQL_HOME}/.snowsql"

normalize_path() {
    local path="$1"
    if command -v readlink >/dev/null 2>&1; then
        readlink -m "$path" 2>/dev/null && return 0
    fi
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$path" 2>/dev/null && return 0
    fi
    printf '%s\n' "$path"
}

is_protected_path() {
    local path="$1"
    case "$path" in
        ""|"/"|"/bin"|"/bin/"*|"/boot"|"/boot/"*|"/dev"|"/dev/"*|"/etc"|"/etc/"*|"/lib"|"/lib/"*|"/lib64"|"/lib64/"*|"/proc"|"/proc/"*|"/root"|"/root/"*|"/run"|"/run/"*|"/sbin"|"/sbin/"*|"/sys"|"/sys/"*|"/usr"|"/usr/"*)
            return 0
            ;;
        "/home"|"/opt"|"/tmp"|"/var")
            return 0
            ;;
    esac
    return 1
}

require_safe_abs_path() {
    local path="$1" label="$2" normalized
    [[ -n "$path" && "$path" == /* && "$path" != "/" ]] || die "Refusing to remove unsafe ${label} path: ${path:-<empty>}"
    normalized="$(normalize_path "$path")"
    [[ -n "$normalized" && "$normalized" == /* && "$normalized" != "/" ]] || die "Refusing to remove unsafe ${label} path: ${path:-<empty>}"
    if is_protected_path "$normalized"; then
        die "Refusing to remove protected ${label} path: ${normalized}"
    fi
}

path_is_safe_abs() {
    local path="$1" normalized
    [[ -n "$path" && "$path" == /* && "$path" != "/" ]] || return 1
    normalized="$(normalize_path "$path")"
    [[ -n "$normalized" && "$normalized" == /* && "$normalized" != "/" ]] || return 1
    ! is_protected_path "$normalized"
}

require_safe_abs_path "$DBAEGIS_BASE" "install base"
BASE_REAL="$(normalize_path "$DBAEGIS_BASE")"

path_is_same_or_under() {
    local child="$1" parent="$2" child_real parent_real
    [[ -n "$child" && -n "$parent" ]] || return 1
    child_real="$(normalize_path "$child")"
    parent_real="$(normalize_path "$parent")"
    [[ "$child_real" == "$parent_real" || "$child_real" == "${parent_real}/"* ]]
}

path_is_under_install_base() {
    path_is_same_or_under "$1" "$BASE_REAL"
}

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}DBAegis Uninstaller${NC}"
echo ""
echo -e "  Install base : ${DBAEGIS_BASE}"
if [[ $PURGE -eq 1 ]]; then
    echo -e "  ${RED}${BOLD}Mode         : PURGE — database, config, license, and product state will be deleted${NC}"
    echo -e "  ${YELLOW}${BOLD}Backups     : preserved at ${BACKUP_DIR}/${NC}"
else
    echo -e "  Mode         : Safe — database (${DB_PATH}), config (${CONF_FILE}), and backups (${BACKUP_DIR}/) will be kept"
fi
echo ""
if [[ $YES -ne 1 ]]; then
    read -r -p "Are you sure you want to uninstall DBAegis? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

# =============================================================================
header "1/4  Stop & disable services"
# =============================================================================

stop_service() {
    local svc="$1"
    if systemctl list-units --all "${svc}.service" &>/dev/null 2>&1 || \
       systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
        systemctl stop "$svc" 2>/dev/null && info "Stopped ${svc}" || true
        systemctl disable "$svc" 2>/dev/null && info "Disabled ${svc}" || true
    fi
}

terminate_stale_dbaegis_processes() {
    local pattern="${DBAEGIS_BASE}/(bin/dbaegis-stack|venv/bin/uvicorn|run/nginx/conf/nginx-main.conf)"
    if pgrep -f "$pattern" >/dev/null 2>&1; then
        warn "Found DBAegis processes still running after systemd stop; terminating them"
        pkill -TERM -f "$pattern" 2>/dev/null || true
        sleep 2
        if pgrep -f "$pattern" >/dev/null 2>&1; then
            pkill -KILL -f "$pattern" 2>/dev/null || true
            warn "Force-killed remaining DBAegis processes"
        fi
    fi
}

stop_service dbaegis
stop_service dbaegis-api
stop_service dbaegis-ui
terminate_stale_dbaegis_processes

# Remove systemd unit files
for unit in dbaegis dbaegis-api dbaegis-ui; do
    UNIT_FILE="/etc/systemd/system/${unit}.service"
    if [[ -f "$UNIT_FILE" ]]; then
        rm -f "$UNIT_FILE"
        success "Removed ${UNIT_FILE}"
    fi
done

LEGACY_DROPIN_DIR="/etc/systemd/system/dbaegis.service.d"
LEGACY_DROPIN_FILE="${LEGACY_DROPIN_DIR}/10-secret.conf"
if [[ -f "$LEGACY_DROPIN_FILE" ]]; then
    rm -f "$LEGACY_DROPIN_FILE"
    success "Removed legacy secret drop-in: ${LEGACY_DROPIN_FILE}"
fi
rmdir "$LEGACY_DROPIN_DIR" 2>/dev/null || true

systemctl daemon-reload
systemctl reset-failed dbaegis.service dbaegis-api.service dbaegis-ui.service 2>/dev/null || true
success "Systemd units removed"

# =============================================================================
header "2/4  Remove nginx config"
# =============================================================================

# Remove symlinks in all standard include dirs
for NGINX_INCLUDE_DIR in \
    /etc/nginx/conf.d \
    /etc/nginx/sites-enabled \
    /usr/local/etc/nginx/conf.d; do
    LINK="${NGINX_INCLUDE_DIR}/dbaegis.conf"
    if [[ -L "$LINK" || -f "$LINK" ]]; then
        rm -f "$LINK"
        success "Removed ${LINK}"
    fi
done

# Remove injected include line from nginx.conf if present
for NGINX_MAIN in /etc/nginx/nginx.conf /usr/local/etc/nginx/nginx.conf; do
    if [[ -f "$NGINX_MAIN" ]] && grep -q "dbaegis" "$NGINX_MAIN"; then
        sed -i '/dbaegis/d' "$NGINX_MAIN"
        success "Removed dbaegis include from ${NGINX_MAIN}"
    fi
done

# Reload nginx if running
if systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx 2>/dev/null && success "nginx reloaded" || true
fi

# =============================================================================
header "3/4  Remove application files"
# =============================================================================

remove_dir() {
    local d="$1" label="$2"
    if ! path_is_safe_abs "$d"; then
        warn "Skipped protected or unsafe ${label} path: ${d:-<empty>}"
        return 0
    fi
    if [[ -d "$d" ]]; then
        rm -rf "$d"
        success "Removed ${label}: ${d}"
    fi
}

remove_file() {
    local f="$1" label="$2"
    if ! path_is_safe_abs "$f"; then
        warn "Skipped protected or unsafe ${label} path: ${f:-<empty>}"
        return 0
    fi
    if [[ -e "$f" ]]; then
        rm -f "$f"
        success "Removed ${label}: ${f}"
    fi
}

remove_runtime_dir() {
    local d="$1" label="$2"
    if path_is_under_install_base "$d"; then
        remove_dir "$d" "$label"
    else
        warn "Preserved external ${label} path: ${d:-<empty>}"
    fi
}

remove_config() {
    if path_is_under_install_base "$CONF_DIR"; then
        remove_dir "$CONF_DIR" "conf"
    else
        remove_file "$CONF_FILE" "config file"
    fi
}

remove_managed_usr_local() {
    local f="$1" label="$2" target=""
    if [[ -L "$f" ]]; then
        target="$(readlink -f "$f" 2>/dev/null || true)"
        if [[ -n "$target" && "$target" == "${DBAEGIS_BASE}/"* ]]; then
            rm -f "$f"
            success "Removed ${label}: ${f}"
        fi
    elif [[ -f "$f" ]] && grep -Fq "$DBAEGIS_BASE" "$f" 2>/dev/null; then
        rm -f "$f"
        success "Removed ${label}: ${f}"
    fi
}

# Remove binary symlink from /usr/local/bin
if [[ -L /usr/local/bin/dbaegis ]]; then
    LINK_TARGET="$(readlink -f /usr/local/bin/dbaegis 2>/dev/null || true)"
    if [[ "$LINK_TARGET" == "${DBAEGIS_BASE}/"* ]]; then
        rm -f /usr/local/bin/dbaegis
        success "Removed /usr/local/bin/dbaegis"
    else
        warn "Skipped /usr/local/bin/dbaegis because it points outside ${DBAEGIS_BASE}"
    fi
fi
for managed_link in \
    /usr/local/bin/snowsql \
    /usr/local/bin/sqlpackage \
    /usr/local/bin/mongosh \
    /usr/local/bin/mongodump \
    /usr/local/bin/mongorestore \
    /usr/local/bin/mongoexport \
    /usr/local/bin/mongoimport \
    /usr/local/bin/mongofiles \
    /usr/local/bin/mongostat \
    /usr/local/bin/mongotop; do
    remove_managed_usr_local "$managed_link" "$(basename "$managed_link") wrapper"
done

remove_runtime_dir "$APP_DIR"   "app"
remove_runtime_dir "$UI_DIR"    "ui"
remove_runtime_dir "$VENV_DIR"  "venv"
remove_runtime_dir "$PYTHON_DIR" "embedded Python"
remove_runtime_dir "$TEMP_DIR"  "temp"
remove_runtime_dir "$RUN_DIR"   "runtime"
# Remove bin/ dir contents except install/uninstall scripts
BIN_DIR="${DBAEGIS_BASE}/bin"
if [[ -d "$BIN_DIR" ]]; then
    require_safe_abs_path "$BIN_DIR" "bin directory"
    rm -f "${BIN_DIR}/dbaegis"
    rm -f "${BIN_DIR}/dbaegis-stack"
    rm -f "${BIN_DIR}/rotate_dbaegis_secret_key.py"
    rm -f "${BIN_DIR}/reset_admin_password.py"
    info "Cleaned ${BIN_DIR}/dbaegis binary"
fi
remove_runtime_dir "$LOG_DIR"   "logs"
remove_file "${DBAEGIS_BASE}/UPGRADE_AND_INSTALL.txt" "install notes"

# =============================================================================
header "4/4  Data & backups"
# =============================================================================

if [[ $PURGE -eq 1 ]]; then
    if path_is_same_or_under "$DB_PATH" "$DATA_DIR"; then
        remove_dir "$DATA_DIR" "database"
    elif [[ -f "$DB_PATH" ]]; then
        remove_file "$DB_PATH" "database file"
    fi
    remove_runtime_dir "$LICENSE_DIR" "license files"
    remove_runtime_dir "$TLS_DIR" "TLS material"
    remove_dir "$ROLLBACK_DIR" "rollback snapshots"
    remove_runtime_dir "${DBAEGIS_BASE}/requirements" "requirements"
    remove_runtime_dir "${DBAEGIS_BASE}/docs" "customer documentation"
    remove_runtime_dir "$SNOWSQL_CONFIG_DIR" "SnowSQL config"
    remove_runtime_dir "$MONGODB_INSTALL_ROOT" "MongoDB client tools"
    remove_runtime_dir "$VENDOR_DIR" "vendor tools"
    remove_file "${DBAEGIS_BASE}/release.json" "release metadata"
    remove_runtime_dir "$BIN_DIR" "bin"
    remove_config
    # Remove base dir if now empty
    if [[ -d "$DBAEGIS_BASE" ]] && [[ -z "$(ls -A "$DBAEGIS_BASE" 2>/dev/null)" ]]; then
        require_safe_abs_path "$DBAEGIS_BASE" "base directory"
        rm -rf "$DBAEGIS_BASE"
        success "Removed base directory: ${DBAEGIS_BASE}"
    fi
    warn "Database backups preserved: ${BACKUP_DIR}/"
    if ! path_is_same_or_under "$SELF_BACKUP_DIR" "$BACKUP_DIR"; then
        warn "Self backups preserved: ${SELF_BACKUP_DIR}/"
    fi
else
    warn "Database preserved : ${DB_PATH}"
    warn "Backups preserved  : ${BACKUP_DIR}/"
    if ! path_is_same_or_under "$SELF_BACKUP_DIR" "$BACKUP_DIR"; then
        warn "Self backups preserved: ${SELF_BACKUP_DIR}/"
    fi
    warn "License files preserved: ${LICENSE_DIR}/"
    warn "Config preserved   : ${CONF_FILE}"
    warn "To remove these too, run: sudo bash uninstall.sh --purge"
    echo ""
    info "Remaining files at: ${DBAEGIS_BASE}"
fi

# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║        DBAegis uninstalled successfully!         ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
if [[ $PURGE -eq 0 ]]; then
    echo -e "  Your data is safe at: ${BOLD}${DB_PATH}${NC}"
    echo -e "  Your backups are at : ${BOLD}${BACKUP_DIR}/${NC}"
    echo -e "  Your config/key is at: ${BOLD}${CONF_FILE}${NC}"
    echo ""
    echo -e "  To reinstall: ${BOLD}sudo bash install.sh${NC}"
    echo -e "  To remove product metadata/config/license: ${BOLD}sudo bash uninstall.sh --purge${NC}"
else
    echo -e "  Your database backups are still at: ${BOLD}${BACKUP_DIR}/${NC}"
    if ! path_is_same_or_under "$SELF_BACKUP_DIR" "$BACKUP_DIR"; then
        echo -e "  Your system backups are still at  : ${BOLD}${SELF_BACKUP_DIR}/${NC}"
    fi
fi
echo ""
