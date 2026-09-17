---
name: b2f
description: Back to the Future. Dual-layer context cleansing and re-execution engine with deterministic shell helper and golden prompt synthesis. Trigger on /b2f, /b2f <timestamp>, or /b2f all.
---

# Back to the Future (b2f) Procedure

Dual-layer context cleansing and re-execution acceleration engine. Combines physical file defense against IDE-level undo wipes with deterministic prompt consolidation, negative constraint extraction, and shell-isolated workspace persistence.

## 0. Prerequisites & System Requirements
- **Python**: Python 3 (>= 3.8) standard library.
- **VCS**: Git (>= 2.0).
- **Shell**: Bash (>= 3.2) or direct Python execution on Windows/macOS/Linux.
- **Engine Entrypoint**:
  - Standalone Cross-Platform Engine: `python3 ~/.gemini/config/skills/b2f/scripts/b2f_engine.py` (or local `scripts/b2f_engine.py`)
  - POSIX Hardened Shell Helper: `~/.gemini/config/skills/b2f/scripts/b2f_helper.sh` (or local `scripts/b2f_helper.sh`)

## 1. Fundamental Invariants
- **Zero Workspace Mutation**: Workspace business files are strictly read-only during `/b2f`. Never modify, revert, or delete business files (only generate the designated `b2f/` directive artifact).
- **Dual-Layer Architecture**:
  - **Script Engine Layer (`scripts/b2f_helper.sh` / `scripts/b2f_engine.py`)**: All mechanical actions (physical `cp` backups, ISO timestamping, manifest sharding, symlink updates, shell persistence, snippet formatting, slice recovery, and archival) MUST strictly execute via the deterministic engine.
  - **Cognitive Synthesis Layer (Agent)**: The Agent exclusively focuses on analyzing conversation history, resolving the anchor window, distilling the Golden Re-execution Directive, extracting Negative Constraints (avoided traps), and verifying system invariants.

## 2. Scope & Time-Travel Modes
- **Default Retraction (`/b2f`)**: Corresponding to **$N-1$ Undo**. Anchors strictly to the preceding user input node ($N-1$ turn) for prompt retraction, optimization, and recovery snapshot.
- **Anchored Window (`/b2f <timestamp>`)**: Corresponding to **Fixed-Node Undo**. Strictly covers the interval from the specified `<timestamp>` node to current HEAD (`<timestamp> -> HEAD`). Consolidates conclusions, avoids traps, and specifies verified invariants within that window.
- **Global Handoff (`/b2f all`)**: Corresponding to **New Session Initialization (Session Close)**. 
  - **Snapshot-Free Handoff**: Does not generate redundant `_bak` slices since current workspace code represents the verified target baseline. Recovery snippet short-circuits to No-Op.
  - **Convergence & Archival Hook**: Identifies all intermediate `b2f` fragments generated in the current conversation, merges their full specifications into a single master `b2f_all_YYYYMMDD.md`, and archives intermediate fragments to `b2f/.archive/<session_date>/` via the `archive` subcommand.

## 3. Mechanical Execution via Helper Script
All mechanical operations invoke `~/.gemini/config/skills/b2f/scripts/b2f_helper.sh` (or `b2f_engine.py`) via native `run_command`:

1. **Tool-Call Audit & Mechanical Changeset Fallback**:
   - Inspect the interval (`target -> HEAD`) for all files modified/created by tools (`write_to_file`, `replace_file_content`, shell writes) to form `AffectedChangeset`.
   - The backup engine automatically executes `git status --porcelain` to capture any unstaged/staged/untracked dirty files as a physical safety net, combining them with any explicitly specified paths.
2. **Conditional Backup**:
   - **If modified files exist**: Execute:
     ```bash
     ~/.gemini/config/skills/b2f/scripts/b2f_helper.sh backup "<anchor>" [--git-diff] [file_paths...]
     ```
     - Uses byte-for-byte exact copies into `~/.gemini/backups/recovery/`.
     - Automatically limits single files to `<= 10MB` (skips oversized/binary blobs with a warning).
     - Generates sharded `manifest_<anchor>_<ts>.json` and updates `manifest.json` symlink.
   - **If no files modified (Zero Changeset Bypass) or `/b2f all`**: Skip backup entirely.

## 4. Shell-Isolated Direct Persistence (IDE Undo Immunity)
To prevent IDE Undo from accidentally deleting the newly generated `b2f/*.md` document, persistence MUST completely bypass IDE editor tools (`write_to_file`):

1. **Target Path**: `<workspace_root>/b2f/b2f_<anchor>_YYYYMMDD.md` (or master `b2f_all_YYYYMMDD.md`).
   - The engine dynamically resolves the Git repository root to prevent subfolder CWD drift.
2. **Golden Directive Synthesis**:
   The generated artifact MUST adhere to the standard Re-execution Directive structure:
   - **YAML Frontmatter**: `schema_version: "2.0"`, `anchor_node`, `mode`, `generated_at`, `conversation_id`, `context_cleaning: true`.
   - **Section 1: Optimized Re-execution Prompt**: Precise, unambiguous target specification ready for immediate one-shot execution in a fresh session.
   - **Section 2: Negative Constraints & Discarded Approaches**: Document discarded attempts and strict prohibitions discovered during exploration.
   - **Section 3: Verified Architectural Invariants**: Proven facts and design rules that must be preserved.
   - **Section 4: Master Deliverables & Codebase Baseline**: Table tracking active deliverables and baseline file states.
3. **Execution via Script**:
   Execute via `run_command`:
   ```bash
   cat << 'EOF' | ~/.gemini/config/skills/b2f/scripts/b2f_helper.sh persist "<anchor>" "<target_file>"
   <content>
   EOF
   ```

## 5. Passive Recovery Command & Pointer Pattern
- **Snippet Assembly**: Run helper script to obtain deterministic recovery snippet:
  ```bash
  ~/.gemini/config/skills/b2f/scripts/b2f_helper.sh snippet "<anchor>" [file_paths...]
  ```
- **Zero Changeset & Global Handoff Handling**: When `AffectedChangeset` is empty or during `/b2f all`, the snippet is a clean No-Op:
  ```bash
  <!-- Zero Changeset: No files mutated, recovery bypassed -->
  ```

## 6. Fragment Archival & History Retention
- **Intermediate Fragment Archiving**: On session completion or `/b2f all`, execute:
  ```bash
  ~/.gemini/config/skills/b2f/scripts/b2f_helper.sh archive [YYYYMMDD]
  ```
  Moves intermediate `b2f_*.md` fragments into `b2f/.archive/<YYYYMMDD>/`.
- **LRU History Pruning**:
  The engine automatically retains only the 30 most recent manifest snapshots in `~/.gemini/backups/history/`, pruning older manifests during cleanup. Manual pruning can be invoked with `prune [max_keep]`.

## 7. Deliverable Contract
Output strictly a single section with clickable `[basename](file:///absolute/path)` links:
- Clickable links to modified files, active backup files, and the persisted b2f directive file.
- The consolidated pointer prompt inside a single Markdown code block (including passive recovery snippet).
