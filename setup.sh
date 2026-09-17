#!/usr/bin/env bash
#
# setup.sh - Robust Installer & Environment Provisioner for b2f Skill
# Validates prerequisites, establishes skill links, and manages security hardening.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_TARGET_DIR="${B2F_SKILL_DIR:-${HOME}/.gemini/config/skills/b2f}"

log_info() {
    printf "[b2f setup] %s\n" "$1"
}

log_warn() {
    printf "[b2f setup WARN] %s\n" "$1" >&2
}

log_error() {
    printf "[b2f setup ERROR] %s\n" "$1" >&2
}

mode="install"
harden=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --harden)
            harden=true
            shift
            ;;
        --unharden)
            mode="unharden"
            shift
            ;;
        --uninstall)
            mode="uninstall"
            shift
            ;;
        --help|-h)
            cat << 'EOF'
Usage: ./setup.sh [OPTIONS]

Options:
  --harden      Apply strict write protection (chmod 555) on executable engines.
  --unharden    Restore standard write permissions (chmod 755) for git updates.
  --uninstall   Remove deployed skill link from target environment.
  -h, --help    Display this help message.

Environment Variables:
  B2F_SKILL_DIR Custom installation directory (default: ~/.gemini/config/skills/b2f)
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Handle uninstall
if [ "${mode}" = "uninstall" ]; then
    if [ -L "${SKILL_TARGET_DIR}" ]; then
        rm "${SKILL_TARGET_DIR}"
        log_info "Removed skill link: ${SKILL_TARGET_DIR}"
    elif [ -d "${SKILL_TARGET_DIR}" ]; then
        log_warn "Target path is a real directory, not a symlink. Retaining to prevent data loss."
    else
        log_info "No installation found at ${SKILL_TARGET_DIR}."
    fi
    exit 0
fi

# Handle unharden
if [ "${mode}" = "unharden" ]; then
    log_info "Restoring write permissions (chmod 755)..."
    chmod 755 "${SCRIPT_DIR}/scripts/b2f_engine.py" "${SCRIPT_DIR}/scripts/b2f_helper.sh"
    log_info "Engines are now writable for git updates and maintenance."
    exit 0
fi

# 1. Validate prerequisites
log_info "Validating environment prerequisites..."
if ! command -v python3 >/dev/null 2>&1; then
    log_error "Python 3 is required but not installed."
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_MAJOR=$(echo "${PYTHON_VERSION}" | cut -d. -f1)
PYTHON_MINOR=$(echo "${PYTHON_VERSION}" | cut -d. -f2)

if [ "${PYTHON_MAJOR}" -lt 3 ] || { [ "${PYTHON_MAJOR}" -eq 3 ] && [ "${PYTHON_MINOR}" -lt 8 ]; }; then
    log_error "Python >= 3.8 is required (detected Python ${PYTHON_VERSION})."
    exit 1
fi
log_info "Python ${PYTHON_VERSION} verified."

if ! command -v git >/dev/null 2>&1; then
    log_error "Git is required but not installed."
    exit 1
fi
log_info "Git verified."

# 2. Deploy link to global skills directory if running from external repo
if [ "${SCRIPT_DIR}" != "${SKILL_TARGET_DIR}" ]; then
    log_info "Configuring skill directory link: ${SCRIPT_DIR} -> ${SKILL_TARGET_DIR}"
    mkdir -p "$(dirname "${SKILL_TARGET_DIR}")"
    if [ -e "${SKILL_TARGET_DIR}" ] && [ ! -L "${SKILL_TARGET_DIR}" ]; then
        backup_path="${SKILL_TARGET_DIR}.bak_$(date +%Y%m%d%H%M%S)"
        log_warn "Existing directory found at ${SKILL_TARGET_DIR}. Safe backup created at: ${backup_path}"
        mv "${SKILL_TARGET_DIR}" "${backup_path}"
    fi
    ln -sfn "${SCRIPT_DIR}" "${SKILL_TARGET_DIR}"
fi

# 3. Configure permissions
if [ "${harden}" = true ]; then
    log_info "Applying strict write protection (chmod 555)..."
    chmod 555 "${SCRIPT_DIR}/scripts/b2f_engine.py" "${SCRIPT_DIR}/scripts/b2f_helper.sh"
else
    log_info "Applying standard executable permissions (chmod 755)..."
    chmod 755 "${SCRIPT_DIR}/scripts/b2f_engine.py" "${SCRIPT_DIR}/scripts/b2f_helper.sh"
fi

# 4. Engine self-test
log_info "Running engine validation..."
python3 "${SCRIPT_DIR}/scripts/b2f_engine.py" template --help >/dev/null
bash "${SCRIPT_DIR}/scripts/b2f_helper.sh" help >/dev/null

log_info "Installation completed successfully."
log_info "Active Skill Path: ${SKILL_TARGET_DIR}"
if [ "${harden}" = false ]; then
    log_info "Note: Engines configured in standard mode (chmod 755). Use './setup.sh --harden' for strict write-lock."
fi
