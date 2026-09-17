#!/usr/bin/env bash
#
# b2f_helper.sh - Deterministic Engine for Back to the Future (b2f) Skill
# Handles physical isolation backups, manifest sharding, shell-level persistence,
# restoration, and prompt snippet generation.
#

set -euo pipefail

# Ensure DEVELOPER_DIR is set on macOS if Command Line Tools exist, preventing Xcode license prompts
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Library/Developer/CommandLineTools" ]; then
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
fi

RECOVERY_DIR="${HOME}/.gemini/backups/recovery"
HISTORY_DIR="${HOME}/.gemini/backups/history"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
MAX_FILE_SIZE=$((10 * 1024 * 1024)) # 10MB
HISTORY_RETENTION_LIMIT=30

# Format helpers
log_info() {
    printf "[b2f] %s\n" "$1"
}

log_warn() {
    printf "[b2f WARN] %s\n" "$1" >&2
}

log_error() {
    printf "[b2f ERROR] %s\n" "$1" >&2
}

get_workspace_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

# -----------------------------------------------------------------------------
# Subcommand: backup <anchor> [--git-diff|--auto] [file_path...]
# -----------------------------------------------------------------------------
cmd_backup() {
    if [ "$#" -lt 1 ]; then
        log_error "Usage: b2f_helper.sh backup <anchor> [--git-diff|--auto] [file1...]"
        exit 1
    fi

    local anchor="$1"
    shift

    local files=()
    local auto_git=false

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --git-diff|--auto)
                auto_git=true
                shift
                ;;
            *)
                files+=("$1")
                shift
                ;;
        esac
    done

    # If no files specified, automatically inspect git status
    if [ "${#files[@]}" -eq 0 ]; then
        auto_git=true
    fi

    local git_files=()
    if [ "${auto_git}" = true ]; then
        local ws_root
        ws_root="$(get_workspace_root)"
        if git -C "${ws_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            while IFS= read -r line; do
                [ -z "${line}" ] && continue
                local path_part="${line:3}"
                if [[ "${path_part}" == *" -> "* ]]; then
                    path_part="${path_part##* -> }"
                fi
                path_part="${path_part%\"}"
                path_part="${path_part#\"}"
                local full_path="${ws_root}/${path_part}"
                if [ -e "${full_path}" ] && [ ! -d "${full_path}" ]; then
                    git_files+=("${full_path}")
                fi
            done < <(git -C "${ws_root}" status --porcelain 2>/dev/null || true)
        fi
    fi

    mkdir -p "${RECOVERY_DIR}"
    mkdir -p "${HISTORY_DIR}"

    local now_iso
    now_iso="$(date +"%Y-%m-%dT%H:%M:%S%z")"
    local ts
    ts="$(date +"%Y%m%dT%H%M%S")"

    # Sanitize anchor for safe filenames
    local safe_anchor
    safe_anchor="$(echo "${anchor}" | tr '/: ' '___')"

    local manifest_file="manifest_${safe_anchor}_${ts}.json"
    local manifest_path="${RECOVERY_DIR}/${manifest_file}"

    # Build backup items array using python3 for schema purity and union calculation
    python3 - <<EOF
import json, sys, os, glob

recovery_dir = "${RECOVERY_DIR}"
history_dir = "${HISTORY_DIR}"
anchor = "${anchor}"
now_iso = "${now_iso}"
ts = "${ts}"
max_file_size = ${MAX_FILE_SIZE}
history_retention = ${HISTORY_RETENTION_LIMIT}

explicit_files = """${files[*]:-}""".split()
git_files = """${git_files[*]:-}""".split()

# Preserve order while building union set
seen = set()
all_files = []
for f in explicit_files + git_files:
    abs_f = os.path.abspath(f)
    if abs_f not in seen:
        seen.add(abs_f)
        all_files.append(abs_f)

if not all_files:
    print("[b2f] Zero Changeset: No dirty files to backup.")
    sys.exit(0)

backups = []

for file_path in all_files:
    if not os.path.exists(file_path):
        print(f"[b2f WARN] File {file_path} does not exist. Skipping.", file=sys.stderr)
        continue

    if os.path.isdir(file_path):
        continue

    try:
        fsize = os.path.getsize(file_path)
    except OSError as e:
        print(f"[b2f WARN] Could not access {file_path}: {e}. Skipping.", file=sys.stderr)
        continue

    if fsize > max_file_size:
        print(f"[b2f WARN] File {file_path} ({fsize} bytes) exceeds 10MB limit. Skipping.", file=sys.stderr)
        continue

    base_name = os.path.basename(file_path)
    if "." in base_name:
        stem, ext = base_name.rsplit(".", 1)
        ext_dot = "." + ext
    else:
        stem = base_name
        ext_dot = ""

    # Detect existing revisions to prevent collision
    pattern = os.path.join(recovery_dir, f"{stem}_{ts}_v*_bak{ext_dot}")
    matches = glob.glob(pattern)
    rev = len(matches) + 1
    bak_filename = f"{stem}_{ts}_v{rev}_bak{ext_dot}"
    bak_path = os.path.join(recovery_dir, bak_filename)

    # Physical raw copy (byte for byte)
    with open(file_path, "rb") as src, open(bak_path, "wb") as dst:
        dst.write(src.read())

    backups.append({
        "source_path": file_path,
        "backup_file": bak_filename,
        "version": f"v{rev}",
        "target_node": anchor
    })

if not backups:
    print("[b2f] Zero Changeset: No valid candidate files backed up.")
    sys.exit(0)

manifest_data = {
    "session_anchor": anchor,
    "created_at": now_iso,
    "backups": backups
}

with open("${manifest_path}", "w", encoding="utf-8") as mf:
    json.dump(manifest_data, mf, indent=2, ensure_ascii=False)
    mf.write("\n")

print(f"[b2f] Created {len(backups)} physical backup(s) and manifest ${manifest_file}.")
EOF

    if [ -f "${manifest_path}" ]; then
        # Update latest symlink
        ln -sf "${manifest_file}" "${RECOVERY_DIR}/manifest.json"
        log_info "Active manifest symlink updated: ${RECOVERY_DIR}/manifest.json -> ${manifest_file}"
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: persist <anchor> <target_workspace_file> [--mirror]
# -----------------------------------------------------------------------------
cmd_persist() {
    if [ "$#" -lt 2 ]; then
        log_error "Usage: b2f_helper.sh persist <anchor> <target_file> [--mirror]"
        exit 1
    fi

    local anchor="$1"
    local target_file="$2"
    local mirror=false
    if [ "${3:-}" = "--mirror" ]; then
        mirror=true
    fi

    # Anchor target file to workspace root if relative path
    local ws_root
    ws_root="$(get_workspace_root)"
    if [[ "${target_file}" != /* ]]; then
        target_file="${ws_root}/${target_file}"
    fi

    mkdir -p "$(dirname "${target_file}")"

    # Read from standard input directly into target file (bypassing IDE Undo stack)
    cat > "${target_file}"
    log_info "Persisted: ${target_file} via native OS shell."

    if [ "${mirror}" = true ]; then
        mkdir -p "${RECOVERY_DIR}"
        local base_name
        base_name="$(basename "${target_file}")"
        local mirror_path="${RECOVERY_DIR}/${base_name%.*}_bak.${base_name##*.}"
        cp "${target_file}" "${mirror_path}"
        log_info "Mirrored to recovery: ${mirror_path}"
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: restore [--cleanup|--wipe]
# -----------------------------------------------------------------------------
cmd_restore() {
    local mode="${1:-}"
    local manifest_link="${RECOVERY_DIR}/manifest.json"

    if [ ! -f "${manifest_link}" ] && [ ! -L "${manifest_link}" ]; then
        log_info "No active recovery manifest found in ${RECOVERY_DIR}. Nothing to restore."
        return 0
    fi

    local ws_root
    ws_root="$(get_workspace_root)"

    python3 - <<EOF
import json, sys, os, shutil, glob

recovery_dir = "${RECOVERY_DIR}"
history_dir = "${HISTORY_DIR}"
manifest_link = "${manifest_link}"
ws_root = "${ws_root}"
mode = "${mode}"
history_retention = ${HISTORY_RETENTION_LIMIT}

if not os.path.exists(manifest_link):
    print("[b2f] No manifest found.")
    sys.exit(0)

with open(manifest_link, "r", encoding="utf-8") as mf:
    manifest = json.load(mf)

backups = manifest.get("backups", [])
restored_files = []

for item in backups:
    src = item.get("source_path")
    bak_name = item.get("backup_file")
    bak_path = os.path.join(recovery_dir, bak_name)

    if os.path.exists(bak_path):
        os.makedirs(os.path.dirname(src), exist_ok=True)
        shutil.copy2(bak_path, src)
        restored_files.append(src)
        print(f"[b2f] Restored: {src} <- {bak_name}")
    else:
        print(f"[b2f WARN] Backup slice {bak_name} missing.", file=sys.stderr)

# Check and restore missing b2f workspace documents from mirrors if present
if os.path.exists(recovery_dir):
    for fname in os.listdir(recovery_dir):
        if fname.startswith("b2f_") and fname.endswith("_bak.md"):
            orig_name = fname.replace("_bak.md", ".md")
            workspace_b2f = os.path.join(ws_root, "b2f", orig_name)
            if not os.path.exists(workspace_b2f):
                os.makedirs(os.path.dirname(workspace_b2f), exist_ok=True)
                shutil.copy2(os.path.join(recovery_dir, fname), workspace_b2f)
                print(f"[b2f] Restored missing workspace artifact: {workspace_b2f} <- {fname}")

if mode == "--cleanup":
    # Safely remove restored slices
    for item in backups:
        bak_name = item.get("backup_file")
        bak_path = os.path.join(recovery_dir, bak_name)
        if os.path.exists(bak_path):
            os.remove(bak_path)

    # Archive real manifest file
    real_manifest = os.path.realpath(manifest_link)
    if os.path.exists(real_manifest):
        os.makedirs(history_dir, exist_ok=True)
        dest_history = os.path.join(history_dir, os.path.basename(real_manifest))
        shutil.move(real_manifest, dest_history)
        print(f"[b2f] Archived manifest to {dest_history}")

    if os.path.islink(manifest_link) or os.path.exists(manifest_link):
        os.remove(manifest_link)
    print("[b2f] Cleaned up active recovery slices.")

    # LRU pruning of history directory
    manifests = glob.glob(os.path.join(history_dir, "manifest_*.json"))
    if len(manifests) > history_retention:
        manifests.sort(key=lambda p: os.path.getmtime(p), reverse=True)
        for old_mf in manifests[history_retention:]:
            try:
                os.remove(old_mf)
            except OSError:
                pass
        print(f"[b2f] Pruned history manifests to last {history_retention} snapshots.")

elif mode == "--wipe":
    shutil.rmtree(recovery_dir, ignore_errors=True)
    print(f"[b2f] Wiped recovery directory {recovery_dir}.")
EOF
}

# -----------------------------------------------------------------------------
# Subcommand: archive [date_folder] [filter_pattern]
# -----------------------------------------------------------------------------
cmd_archive() {
    local date_folder="${1:-$(date +"%Y%m%d")}"
    local ws_root
    ws_root="$(get_workspace_root)"
    local b2f_dir="${ws_root}/b2f"

    if [ ! -d "${b2f_dir}" ]; then
        log_info "No b2f directory found at ${b2f_dir}. Nothing to archive."
        return 0
    fi

    local archive_target="${b2f_dir}/.archive/${date_folder}"
    mkdir -p "${archive_target}"

    python3 - <<EOF
import os, shutil, glob

b2f_dir = "${b2f_dir}"
archive_target = "${archive_target}"

archived_count = 0
for filepath in glob.glob(os.path.join(b2f_dir, "b2f_*.md")):
    filename = os.path.basename(filepath)
    # Exclude aggregated master b2f_all files and plan documents
    if filename.startswith("b2f_all_") or filename == "implementation_plan.md":
        continue

    dest = os.path.join(archive_target, filename)
    shutil.move(filepath, dest)
    print(f"[b2f] Archived fragment: {filename} -> b2f/.archive/${date_folder}/")
    archived_count += 1

print(f"[b2f] Total {archived_count} fragment(s) safely archived to {archive_target}.")
EOF
}

# -----------------------------------------------------------------------------
# Subcommand: prune [max_keep]
# -----------------------------------------------------------------------------
cmd_prune() {
    local max_keep="${1:-${HISTORY_RETENTION_LIMIT}}"
    python3 - <<EOF
import os, glob, sys

history_dir = "${HISTORY_DIR}"
max_keep = int("${max_keep}")

if not os.path.exists(history_dir):
    print(f"[b2f] History directory {history_dir} does not exist.")
    sys.exit(0)

manifests = glob.glob(os.path.join(history_dir, "manifest_*.json"))
if len(manifests) > max_keep:
    manifests.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    to_delete = manifests[max_keep:]
    for mf in to_delete:
        try:
            os.remove(mf)
        except OSError as e:
            print(f"[b2f WARN] Failed to remove {mf}: {e}", file=sys.stderr)
    print(f"[b2f] Pruned {len(to_delete)} history manifest(s). Retained top {max_keep}.")
else:
    print(f"[b2f] History count ({len(manifests)}) is within limit ({max_keep}). No pruning needed.")
EOF
}

# -----------------------------------------------------------------------------
# Subcommand: snippet <anchor> [file_paths...]
# -----------------------------------------------------------------------------
cmd_snippet() {
    local anchor="${1:-}"
    shift || true
    local files=("$@")

    local manifest_link="${RECOVERY_DIR}/manifest.json"
    if [ ! -f "${manifest_link}" ] && [ ! -L "${manifest_link}" ]; then
        echo "<!-- Zero Changeset: No files mutated, recovery bypassed -->"
        return 0
    fi

    python3 - <<EOF
import json, os

manifest_link = "${manifest_link}"
with open(manifest_link, "r", encoding="utf-8") as mf:
    manifest = json.load(mf)

backups = manifest.get("backups", [])
commands = []

for item in backups:
    src = item.get("source_path")
    bak_name = item.get("backup_file")
    commands.append(f'cp ~/.gemini/backups/recovery/{bak_name} "{src}"')

if commands:
    recovery_cmd = " && ".join(commands) + " && ${SCRIPT_PATH} restore --cleanup"
    print(f"<!-- Passive Recovery Command -->\n{recovery_cmd}")
else:
    print("<!-- Zero Changeset: No files mutated, recovery bypassed -->")
EOF
}

# -----------------------------------------------------------------------------
# Subcommand: template <anchor> [title]
# -----------------------------------------------------------------------------
cmd_template() {
    local anchor="${1:-HEAD}"
    local title="${2:-Verified Task Execution Directive}"
    local now_iso
    now_iso="$(date +"%Y-%m-%dT%H:%M:%S%z")"

    cat << EOF
---
schema_version: "2.0"
anchor_node: "${anchor}"
mode: "fixed_node" # n_minus_1 | fixed_node | global_handoff
generated_at: "${now_iso}"
context_cleaning: true
---

# b2f Re-execution Directive: ${title}

> **使命定位**：本文档已将 Anchor 节点以来的多轮试错、方案推演与架构共识提炼固化。后续会话请直接以此为【最新地面真值】，无需回顾历史争论。

---

## 1. 优化后的重做指令 (Optimized Re-execution Prompt)
> **直达执行目标**：综合多轮讨论后，该节点最精准、最无歧义的目标定义。

- **核心目标**：
- **输入与依赖**：
- **执行规格与输出要求**：
  1. 
  2. 
  3. 

---

## 2. 试错结论与负向约束 (Negative Constraints / 避坑指南)
> **消除试错噪音的关键**：明确记录此前讨论中“被推翻的方案”与“禁止踩的坑”，防止重做时重蹈覆辙。

- [PROHIBITED] 已废弃方案：
- [PROHIBITED] 禁止动作：
- [WARN] 临界边界：

---

## 3. 固化的系统不变量 (Verified Architectural Invariants)
> **已经验证有效的技术事实**：重做时必须继承且不得破坏的前提。

- **Invariants**: 

---

## 4. 交付物与当前代码基线 (Deliverables & Codebase Baseline)
| 文件/资产 | 链接 | 期望终态 (Target State) |
| :--- | :--- | :--- |
| | | |

---

## 5. 被动安全恢复 (Passive Recovery)
EOF
}

# -----------------------------------------------------------------------------
# Subcommand: assemble <directive_file> [anchor] [file_paths...]
# Mechanically compiles the mandatory 3-tier Golden Re-execution Prompt block
# -----------------------------------------------------------------------------
cmd_assemble() {
    if [ "$#" -lt 1 ]; then
        log_error "Usage: b2f_helper.sh assemble <b2f_directive_file> [anchor] [file_paths...]"
        exit 1
    fi

    local directive_file="$1"
    shift
    local anchor="${1:-}"
    if [ -n "${anchor}" ]; then
        shift || true
    fi
    local files=("$@")

    local recovery_snip
    if [ "${#files[@]}" -gt 0 ]; then
        recovery_snip="$(cmd_snippet "${anchor}" "${files[@]}")"
    else
        recovery_snip="$(cmd_snippet "${anchor}")"
    fi

    python3 - "${directive_file}" "${recovery_snip}" << 'EOF'
import sys, os, re

directive_file = sys.argv[1] if len(sys.argv) > 1 else ""
recovery_snip = sys.argv[2] if len(sys.argv) > 2 else ""

if not directive_file or not os.path.exists(directive_file):
    print(f"Error: Directive file {directive_file} not found", file=sys.stderr)
    sys.exit(1)

abs_path = os.path.abspath(directive_file)
base_name = os.path.basename(abs_path)

with open(abs_path, "r", encoding="utf-8") as f:
    content = f.read()

# Extract Section 1
match = re.search(r"## 1\.[^\n]*\n(.*?)(?=\n---\s*\n|\n## 2\.|\Z)", content, re.DOTALL)
if match:
    sec1 = match.group(1).strip()
    lines = sec1.split("\n")
    clean_lines = [l for l in lines if not l.strip().startswith(">")]
    tier1 = "\n".join(clean_lines).strip()
    code_match = re.search(r"^```[a-zA-Z0-9]*\n(.*?)\n```$", tier1, re.DOTALL)
    if code_match:
        tier1 = code_match.group(1).strip()
else:
    tier1 = "[WARN] Section 1 (Optimized Re-execution Directive) missing."

tier2 = f"Read and strictly execute the verified specifications consolidated in [{base_name}](file://{abs_path})."

if not recovery_snip.strip():
    recovery_snip = "<!-- Passive Recovery Command -->\n<!-- Zero Changeset: No files mutated, recovery bypassed -->"
elif "<!-- Passive Recovery Command -->" not in recovery_snip:
    recovery_snip = f"<!-- Passive Recovery Command -->\n{recovery_snip}"

print(f"{tier1}\n\n{tier2}\n\n{recovery_snip}")
EOF
}

# -----------------------------------------------------------------------------
# Main entry point
# -----------------------------------------------------------------------------
case "${1:-help}" in
    backup)
        shift
        cmd_backup "$@"
        ;;
    persist)
        shift
        cmd_persist "$@"
        ;;
    restore)
        shift
        cmd_restore "$@"
        ;;
    archive)
        shift
        cmd_archive "$@"
        ;;
    prune)
        shift
        cmd_prune "$@"
        ;;
    snippet)
        shift
        cmd_snippet "$@"
        ;;
    template)
        shift
        cmd_template "$@"
        ;;
    assemble)
        shift
        cmd_assemble "$@"
        ;;
    help|*)
        cat << 'EOF'
Usage: b2f_helper.sh <subcommand> [args...]

Subcommands:
  backup <anchor> [--git-diff|--auto] [file1...] Perform physical isolated backups and generate sharded manifest.
  persist <anchor> <target_file> [--mirror]      Write file from stdin via native shell to bypass IDE Undo stack.
  restore [--cleanup|--wipe]                     Restore files from active manifest and optionally archive/clean slices.
  archive [date_folder]                          Archive intermediate b2f_*.md fragments to b2f/.archive/<date>/.
  prune [max_keep]                               Prune history manifests older than retention limit (default: 30).
  snippet <anchor> [files...]                    Generate deterministic passive recovery command snippet.
  template <anchor> [title]                      Generate standard Golden Re-execution Directive markdown template.
  assemble <b2f_file> [anchor] [files...]        Mechanically assemble mandatory 3-tier Golden Re-execution Prompt block.
EOF
        ;;
esac
