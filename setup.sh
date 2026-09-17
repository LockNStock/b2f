#!/usr/bin/env bash
#
# setup.sh - Installer & Hardening Provisioner for b2f Skill
# Validates system requirements, deploys executable assets, and sets write-protection.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_TARGET_DIR="${HOME}/.gemini/config/skills/b2f"

log_info() {
    printf "[b2f setup] %s\n" "$1"
}

log_error() {
    printf "[b2f setup ERROR] %s\n" "$1" >&2
}

# 1. Validate prerequisites
log_info "Checking prerequisites..."
if ! command -v python3 >/dev/null 2>&1; then
    log_error "Python 3 is required but not found."
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
    log_error "git is required but not found."
    exit 1
fi
log_info "git verified."

# 2. Deploy / Link to global skills directory if running from external repo
if [ "${SCRIPT_DIR}" != "${SKILL_TARGET_DIR}" ]; then
    log_info "Configuring skill directory link: ${SCRIPT_DIR} -> ${SKILL_TARGET_DIR}"
    mkdir -p "$(dirname "${SKILL_TARGET_DIR}")"
    if [ -e "${SKILL_TARGET_DIR}" ] && [ ! -L "${SKILL_TARGET_DIR}" ]; then
        log_info "Existing directory found at ${SKILL_TARGET_DIR}. Creating backup..."
        mv "${SKILL_TARGET_DIR}" "${SKILL_TARGET_DIR}.bak_$(date +%Y%m%d%H%M%S)"
    fi
    ln -sfn "${SCRIPT_DIR}" "${SKILL_TARGET_DIR}"
fi

# 3. Apply execute permissions and write-protection (chmod 555) on executable engines
log_info "Applying write protection (chmod 555) on executable engines..."
if [ -f "${SCRIPT_DIR}/scripts/b2f_helper.sh" ]; then
    chmod 555 "${SCRIPT_DIR}/scripts/b2f_helper.sh"
fi

if [ -f "${SCRIPT_DIR}/scripts/b2f_engine.py" ]; then
    chmod 555 "${SCRIPT_DIR}/scripts/b2f_engine.py"
fi

# 4. Self-test
log_info "Running engine self-test..."
python3 "${SCRIPT_DIR}/scripts/b2f_engine.py" template --help >/dev/null
bash "${SCRIPT_DIR}/scripts/b2f_helper.sh" help >/dev/null

log_info "b2f installation and hardening completed successfully."
log_info "Active Skill Path: ${SKILL_TARGET_DIR}"
