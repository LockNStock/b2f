#!/usr/bin/env python3
"""
b2f_engine.py - Pure Python Standalone Engine for Back to the Future (b2f) Skill

Cross-platform, deterministic implementation of:
  - Physical isolation backups and versioned manifest sharding
  - Native file persistence bypassing IDE undo stacks
  - Bit-accurate restoration and historical archive management
  - Golden Re-execution Prompt assembly and passive recovery snippets
  - Defensive path parsing and sensitive backup purging

Standard library only: requires Python >= 3.8.
"""

from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

MAX_FILE_SIZE = 10 * 1024 * 1024  # 10 MB
HISTORY_RETENTION_LIMIT = 30


def get_recovery_dir() -> Path:
    return Path.home() / ".gemini" / "backups" / "recovery"


def get_history_dir() -> Path:
    return Path.home() / ".gemini" / "backups" / "history"


def log_info(msg: str) -> None:
    print(f"[b2f] {msg}")


def log_warn(msg: str) -> None:
    print(f"[b2f WARN] {msg}", file=sys.stderr)


def log_error(msg: str) -> None:
    print(f"[b2f ERROR] {msg}", file=sys.stderr)


def get_git_env() -> dict[str, str]:
    env = os.environ.copy()
    if (
        sys.platform == "darwin"
        and "DEVELOPER_DIR" not in env
        and os.path.isdir("/Library/Developer/CommandLineTools")
    ):
        env["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"
    return env


def get_workspace_root() -> Path:
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            env=get_git_env(),
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return Path(proc.stdout.strip()).resolve()
    except OSError:
        pass
    return Path.cwd().resolve()


def collect_git_dirty_files(ws_root: Path) -> list[str]:
    """Safely collects dirty files via null-terminated porcelain git output."""
    dirty_files: list[str] = []
    try:
        proc = subprocess.run(
            ["git", "status", "-z", "--porcelain"],
            cwd=str(ws_root),
            capture_output=True,
            env=get_git_env(),
            check=False,
        )
        if proc.returncode == 0 and proc.stdout:
            raw_entries = proc.stdout.split(b"\0")
            i = 0
            while i < len(raw_entries):
                entry = raw_entries[i]
                if not entry or len(entry) < 3:
                    i += 1
                    continue

                status = entry[:2]
                path_bytes = entry[3:]
                path_str = path_bytes.decode("utf-8", errors="replace")

                # In case of rename/copy, next null element contains the target path
                if b"R" in status or b"C" in status:
                    if i + 1 < len(raw_entries):
                        i += 1
                        path_str = raw_entries[i].decode("utf-8", errors="replace")

                full_path = (ws_root / path_str).resolve()
                if full_path.is_file():
                    dirty_files.append(str(full_path))
                i += 1
    except OSError:
        pass
    return dirty_files


# -----------------------------------------------------------------------------
# Subcommand: backup
# -----------------------------------------------------------------------------
def cmd_backup(args: argparse.Namespace) -> int:
    anchor = args.anchor
    explicit_files = args.files or []
    auto_git = args.auto or args.git_diff or (len(explicit_files) == 0)

    ws_root = get_workspace_root()
    git_files = collect_git_dirty_files(ws_root) if auto_git else []

    # Calculate deterministic ordered union
    seen = set()
    all_files: list[Path] = []
    for f_str in explicit_files + git_files:
        p = Path(f_str).resolve()
        if p not in seen:
            seen.add(p)
            all_files.append(p)

    if not all_files:
        log_info("Zero Changeset: No dirty files to backup.")
        return 0

    recovery_dir = get_recovery_dir()
    history_dir = get_history_dir()
    recovery_dir.mkdir(parents=True, exist_ok=True)
    history_dir.mkdir(parents=True, exist_ok=True)

    now = datetime.datetime.now(datetime.timezone.utc).astimezone()
    now_iso = now.isoformat()
    ts = now.strftime("%Y%m%dT%H%M%S")

    safe_anchor = re.sub(r"[/:\s]", "_", anchor)
    manifest_filename = f"manifest_{safe_anchor}_{ts}.json"
    manifest_path = recovery_dir / manifest_filename

    backups: list[dict[str, str]] = []

    for file_path in all_files:
        if not file_path.exists():
            log_warn(f"File {file_path} does not exist. Skipping.")
            continue
        if file_path.is_dir():
            continue

        try:
            fsize = file_path.stat().st_size
        except OSError as e:
            log_warn(f"Could not access {file_path}: {e}. Skipping.")
            continue

        if fsize > MAX_FILE_SIZE:
            log_warn(
                f"File {file_path} ({fsize} bytes) exceeds 10MB limit. Skipping."
            )
            continue

        name = file_path.name
        if "." in name:
            stem, ext = name.rsplit(".", 1)
            ext_dot = f".{ext}"
        else:
            stem = name
            ext_dot = ""

        pattern = str(recovery_dir / f"{stem}_{ts}_v*_bak{ext_dot}")
        existing_matches = glob.glob(pattern)
        rev = len(existing_matches) + 1
        bak_filename = f"{stem}_{ts}_v{rev}_bak{ext_dot}"
        bak_path = recovery_dir / bak_filename

        with (
            open(file_path, "rb") as src,
            open(bak_path, "wb") as dst,
        ):
            shutil.copyfileobj(src, dst)

        backups.append({
            "source_path": str(file_path),
            "backup_file": bak_filename,
            "version": f"v{rev}",
            "target_node": anchor,
        })

    if not backups:
        log_info("Zero Changeset: No valid candidate files backed up.")
        return 0

    manifest_data = {
        "session_anchor": anchor,
        "created_at": now_iso,
        "backups": backups,
    }

    with open(manifest_path, "w", encoding="utf-8") as mf:
        json.dump(manifest_data, mf, indent=2, ensure_ascii=False)
        mf.write("\n")

    # Update active manifest symlink or file pointer
    symlink_path = recovery_dir / "manifest.json"
    try:
        if symlink_path.is_symlink() or symlink_path.exists():
            symlink_path.unlink()
        symlink_path.symlink_to(manifest_filename)
    except OSError:
        # Fallback for Windows without symlink privilege
        shutil.copy2(manifest_path, symlink_path)

    log_info(
        f"Created {len(backups)} physical backup(s) and manifest"
        f" {manifest_filename}."
    )
    log_info(f"Active manifest symlink updated: {symlink_path} -> {manifest_filename}")
    return 0


# -----------------------------------------------------------------------------
# Subcommand: persist
# -----------------------------------------------------------------------------
def cmd_persist(args: argparse.Namespace) -> int:
    target_str = args.target_file
    mirror = args.mirror

    ws_root = get_workspace_root()
    target_path = Path(target_str)
    if not target_path.is_absolute():
        target_path = (ws_root / target_path).resolve()

    target_path.parent.mkdir(parents=True, exist_ok=True)

    # Read binary stream from stdin directly into target file
    content = sys.stdin.buffer.read()
    with open(target_path, "wb") as f:
        f.write(content)

    log_info(f"Persisted: {target_path} via native OS shell.")

    if mirror:
        recovery_dir = get_recovery_dir()
        recovery_dir.mkdir(parents=True, exist_ok=True)
        base_name = target_path.name
        if "." in base_name:
            stem, ext = base_name.rsplit(".", 1)
            mirror_filename = f"{stem}_bak.{ext}"
        else:
            mirror_filename = f"{base_name}_bak"
        mirror_path = recovery_dir / mirror_filename
        shutil.copy2(target_path, mirror_path)
        log_info(f"Mirrored to recovery: {mirror_path}")

    return 0


# -----------------------------------------------------------------------------
# Subcommand: restore
# -----------------------------------------------------------------------------
def cmd_restore(args: argparse.Namespace) -> int:
    mode = "--cleanup" if args.cleanup else ("--wipe" if args.wipe else "")
    recovery_dir = get_recovery_dir()
    history_dir = get_history_dir()
    manifest_link = recovery_dir / "manifest.json"

    if not manifest_link.exists() and not manifest_link.is_symlink():
        log_info(
            f"No active recovery manifest found in {recovery_dir}. Nothing to"
            " restore."
        )
        return 0

    ws_root = get_workspace_root()

    try:
        with open(manifest_link, "r", encoding="utf-8") as mf:
            manifest = json.load(mf)
    except Exception as e:
        log_error(f"Failed to parse manifest: {e}")
        return 1

    backups = manifest.get("backups", [])
    for item in backups:
        src_path = Path(item.get("source_path", ""))
        bak_name = item.get("backup_file", "")
        bak_path = recovery_dir / bak_name

        if bak_path.exists():
            src_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(bak_path, src_path)
            log_info(f"Restored: {src_path} <- {bak_name}")
        else:
            log_warn(f"Backup slice {bak_name} missing.")

    # Check and restore missing b2f workspace documents from mirrors
    if recovery_dir.exists():
        for fname in os.listdir(recovery_dir):
            if fname.startswith("b2f_") and fname.endswith("_bak.md"):
                orig_name = fname.replace("_bak.md", ".md")
                workspace_b2f = ws_root / "b2f" / orig_name
                if not workspace_b2f.exists():
                    workspace_b2f.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(recovery_dir / fname, workspace_b2f)
                    log_info(
                        f"Restored missing workspace artifact: {workspace_b2f}"
                        f" <- {fname}"
                    )

    if mode == "--cleanup":
        for item in backups:
            bak_path = recovery_dir / item.get("backup_file", "")
            if bak_path.exists():
                try:
                    bak_path.unlink()
                except OSError:
                    pass

        real_manifest = manifest_link.resolve()
        if real_manifest.exists() and real_manifest != manifest_link:
            history_dir.mkdir(parents=True, exist_ok=True)
            dest_history = history_dir / real_manifest.name
            shutil.move(str(real_manifest), str(dest_history))
            log_info(f"Archived manifest to {dest_history}")

        if manifest_link.is_symlink() or manifest_link.exists():
            manifest_link.unlink()

        log_info("Cleaned up active recovery slices.")
        prune_history(history_dir, HISTORY_RETENTION_LIMIT)

    elif mode == "--wipe":
        shutil.rmtree(recovery_dir, ignore_errors=True)
        log_info(f"Wiped recovery directory {recovery_dir}.")

    return 0


# -----------------------------------------------------------------------------
# Subcommand: archive
# -----------------------------------------------------------------------------
def cmd_archive(args: argparse.Namespace) -> int:
    date_folder = args.date or datetime.date.today().strftime("%Y%m%d")
    ws_root = get_workspace_root()
    b2f_dir = ws_root / "b2f"

    if not b2f_dir.is_dir():
        log_info(f"No b2f directory found at {b2f_dir}. Nothing to archive.")
        return 0

    archive_target = b2f_dir / ".archive" / date_folder
    archive_target.mkdir(parents=True, exist_ok=True)

    archived_count = 0
    for file_path in b2f_dir.glob("b2f_*.md"):
        filename = file_path.name
        if filename.startswith("b2f_all_") or filename == "implementation_plan.md":
            continue

        dest = archive_target / filename
        shutil.move(str(file_path), str(dest))
        log_info(f"Archived fragment: {filename} -> b2f/.archive/{date_folder}/")
        archived_count += 1

    log_info(
        f"Total {archived_count} fragment(s) safely archived to {archive_target}."
    )
    return 0


# -----------------------------------------------------------------------------
# Subcommand: prune
# -----------------------------------------------------------------------------
def prune_history(history_dir: Path, max_keep: int) -> int:
    if not history_dir.exists():
        return 0
    manifests = list(history_dir.glob("manifest_*.json"))
    if len(manifests) > max_keep:
        manifests.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        to_delete = manifests[max_keep:]
        for mf in to_delete:
            try:
                mf.unlink()
            except OSError as e:
                log_warn(f"Failed to remove {mf}: {e}")
        log_info(
            f"Pruned {len(to_delete)} history manifest(s). Retained top"
            f" {max_keep}."
        )
        return len(to_delete)
    return 0


def cmd_prune(args: argparse.Namespace) -> int:
    history_dir = get_history_dir()
    max_keep = args.max_keep or HISTORY_RETENTION_LIMIT
    deleted = prune_history(history_dir, max_keep)
    if deleted == 0:
        manifest_count = (
            len(list(history_dir.glob("manifest_*.json")))
            if history_dir.exists()
            else 0
        )
        log_info(
            f"History count ({manifest_count}) within limit ({max_keep}). No"
            " pruning needed."
        )
    return 0


# -----------------------------------------------------------------------------
# Subcommand: purge
# -----------------------------------------------------------------------------
def cmd_purge(args: argparse.Namespace) -> int:
    """Security-focused command to wipe sensitive cached snapshots and history."""
    purge_all = args.all
    recovery_dir = get_recovery_dir()
    history_dir = get_history_dir()

    if recovery_dir.exists():
        for p in recovery_dir.iterdir():
            try:
                if p.is_dir():
                    shutil.rmtree(p)
                else:
                    p.unlink()
            except OSError as e:
                log_warn(f"Failed to remove {p}: {e}")
        log_info(f"Purged active recovery directory: {recovery_dir}")

    if purge_all and history_dir.exists():
        for p in history_dir.iterdir():
            try:
                if p.is_dir():
                    shutil.rmtree(p)
                else:
                    p.unlink()
            except OSError as e:
                log_warn(f"Failed to remove {p}: {e}")
        log_info(f"Purged historical snapshot archive: {history_dir}")

    log_info("Purge operation completed successfully.")
    return 0


# -----------------------------------------------------------------------------
# Subcommand: snippet
# -----------------------------------------------------------------------------
def cmd_snippet(args: argparse.Namespace) -> int:
    files = args.files or []
    recovery_dir = get_recovery_dir()
    manifest_link = recovery_dir / "manifest.json"

    if not manifest_link.exists() and not manifest_link.is_symlink():
        print("<!-- Zero Changeset: No files mutated, recovery bypassed -->")
        return 0

    try:
        with open(manifest_link, "r", encoding="utf-8") as mf:
            manifest = json.load(mf)
    except Exception:
        print("<!-- Zero Changeset: No files mutated, recovery bypassed -->")
        return 0

    backups = manifest.get("backups", [])
    commands: list[str] = []
    engine_path = Path(__file__).resolve()

    for item in backups:
        src = item.get("source_path", "")
        bak_name = item.get("backup_file", "")
        commands.append(f'cp ~/.gemini/backups/recovery/{bak_name} "{src}"')

    if commands:
        recovery_cmd = (
            " && ".join(commands) + f" && python3 {engine_path} restore --cleanup"
        )
        print(f"<!-- Passive Recovery Command -->\n{recovery_cmd}")
    else:
        print("<!-- Zero Changeset: No files mutated, recovery bypassed -->")

    return 0


# -----------------------------------------------------------------------------
# Subcommand: template
# -----------------------------------------------------------------------------
def cmd_template(args: argparse.Namespace) -> int:
    anchor = args.anchor or "HEAD"
    title = args.title or "Verified Task Execution Directive"
    now_iso = (
        datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat()
    )

    content = f"""---
schema_version: "2.0"
anchor_node: "{anchor}"
mode: "fixed_node" # n_minus_1 | fixed_node | global_handoff
generated_at: "{now_iso}"
context_cleaning: true
---

# b2f Re-execution Directive: {title}

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
"""
    print(content)
    return 0


# -----------------------------------------------------------------------------
# Subcommand: assemble
# -----------------------------------------------------------------------------
def cmd_assemble(args: argparse.Namespace) -> int:
    directive_file = Path(args.directive_file).resolve()
    if not directive_file.is_file():
        log_error(f"Directive file {directive_file} not found")
        return 1

    content = directive_file.read_text(encoding="utf-8")
    base_name = directive_file.name

    match = re.search(
        r"## 1\.[^\n]*\n(.*?)(?=\n---\s*\n|\n## 2\.|\Z)", content, re.DOTALL
    )
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

    tier2 = f"Read and strictly execute the verified specifications consolidated in [{base_name}](file://{directive_file})."

    # Assemble recovery snippet
    snippet_ns = argparse.Namespace(anchor=args.anchor, files=args.files or [])
    import io

    old_stdout = sys.stdout
    sys.stdout = io.StringIO()
    cmd_snippet(snippet_ns)
    recovery_snip = sys.stdout.getvalue().strip()
    sys.stdout = old_stdout

    if not recovery_snip:
        recovery_snip = (
            "<!-- Passive Recovery Command -->\n<!-- Zero Changeset: No files"
            " mutated, recovery bypassed -->"
        )
    elif "<!-- Passive Recovery Command -->" not in recovery_snip:
        recovery_snip = f"<!-- Passive Recovery Command -->\n{recovery_snip}"

    print(f"{tier1}\n\n{tier2}\n\n{recovery_snip}")
    return 0


# -----------------------------------------------------------------------------
# CLI Entry Point
# -----------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Back to the Future (b2f) Engine - Deterministic Re-execution & Snapshot Architecture"
    )
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # backup
    p_backup = subparsers.add_parser(
        "backup", help="Perform physical isolated backups and generate manifest"
    )
    p_backup.add_argument("anchor", help="Anchor timestamp or identifier")
    p_backup.add_argument(
        "files", nargs="*", help="File paths to backup (optional if auto-git)"
    )
    p_backup.add_argument(
        "--git-diff",
        action="store_true",
        help="Capture uncommitted git modifications",
    )
    p_backup.add_argument(
        "--auto",
        action="store_true",
        help="Alias for automatic git dirty capture",
    )
    p_backup.set_defaults(func=cmd_backup)

    # persist
    p_persist = subparsers.add_parser(
        "persist", help="Write file from stdin bypassing IDE Undo"
    )
    p_persist.add_argument("anchor", help="Anchor identifier")
    p_persist.add_argument("target_file", help="Destination file path")
    p_persist.add_argument(
        "--mirror",
        action="store_true",
        help="Mirror copy into recovery directory",
    )
    p_persist.set_defaults(func=cmd_persist)

    # restore
    p_restore = subparsers.add_parser(
        "restore", help="Restore files from active manifest"
    )
    p_restore.add_argument(
        "--cleanup", action="store_true", help="Remove recovery slices on finish"
    )
    p_restore.add_argument(
        "--wipe", action="store_true", help="Wipe recovery directory entirely"
    )
    p_restore.set_defaults(func=cmd_restore)

    # archive
    p_archive = subparsers.add_parser(
        "archive", help="Archive intermediate b2f_*.md fragments"
    )
    p_archive.add_argument(
        "date", nargs="?", default=None, help="Date folder name (YYYYMMDD)"
    )
    p_archive.set_defaults(func=cmd_archive)

    # prune
    p_prune = subparsers.add_parser(
        "prune", help="Prune history manifests older than retention limit"
    )
    p_prune.add_argument(
        "max_keep",
        type=int,
        nargs="?",
        default=HISTORY_RETENTION_LIMIT,
        help="Number of snapshots to retain (default: 30)",
    )
    p_prune.set_defaults(func=cmd_prune)

    # purge
    p_purge = subparsers.add_parser(
        "purge", help="Security wipe of cached snapshots and history"
    )
    p_purge.add_argument(
        "--all",
        action="store_true",
        help="Wipe both active recovery and historical snapshots",
    )
    p_purge.set_defaults(func=cmd_purge)

    # snippet
    p_snippet = subparsers.add_parser(
        "snippet", help="Generate passive recovery command snippet"
    )
    p_snippet.add_argument(
        "anchor", nargs="?", default="", help="Anchor identifier"
    )
    p_snippet.add_argument("files", nargs="*", help="File paths")
    p_snippet.set_defaults(func=cmd_snippet)

    # template
    p_template = subparsers.add_parser(
        "template", help="Generate Golden Re-execution Directive template"
    )
    p_template.add_argument(
        "anchor", nargs="?", default="HEAD", help="Anchor node"
    )
    p_template.add_argument(
        "title",
        nargs="?",
        default="Verified Task Execution Directive",
        help="Directive title",
    )
    p_template.set_defaults(func=cmd_template)

    # assemble
    p_assemble = subparsers.add_parser(
        "assemble", help="Assemble 3-tier Golden Re-execution Prompt block"
    )
    p_assemble.add_argument("directive_file", help="Path to b2f markdown file")
    p_assemble.add_argument(
        "anchor", nargs="?", default="", help="Anchor identifier"
    )
    p_assemble.add_argument("files", nargs="*", help="File paths")
    p_assemble.set_defaults(func=cmd_assemble)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
