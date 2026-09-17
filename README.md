# Back to the Future (b2f)

> Dual-Layer Context Cleansing & Re-Execution Acceleration Engine for AI Coding Agents.

`b2f` combines **physical snapshot defenses** against IDE-level undo wipes with **deterministic cognitive directive synthesis**, negative constraint extraction, and shell-isolated workspace persistence.

---

## Key Features

- **Dual-Layer Architecture**:
  - **Script Engine Layer**: Physical raw byte backups (`recovery/`), versioned manifest sharding (`history/`), zero-undo native file persistence, bit-level recovery, and fragment archival.
  - **Cognitive Synthesis Layer**: Distills the conversation history into a consolidated **Golden Re-execution Directive** with strict negative constraints and verified invariants.
- **Changeset Mechanical Safety Net (`--git-diff` / `--auto`)**:
  - Automatically queries `git status --porcelain` to capture all uncommitted dirty files (modified, staged, untracked) as a physical backup safety net, taking the union with any explicitly specified paths.
- **Git Root Dynamic Resolution**:
  - Dynamically anchors to the Git repository root (`git rev-parse --show-toplevel`), preventing directory drift when subcommands are invoked from nested folders.
- **Oversized Blob & LRU History Protection**:
  - Automatically limits backup file size (`<= 10MB`) to prevent backing up large datasets or binary artifacts.
  - Maintains the 30 most recent manifest snapshots in `~/.gemini/backups/history/`, pruning obsolete versions during cleanup.
- **Cross-Platform Standalone Python CLI (`b2f_engine.py`)**:
  - 100% Python 3 (>= 3.8) standard library with native support for Linux, macOS, and Windows.
  - Zero third-party package dependencies.

---

## File Structure

```
b2f/
├── SKILL.md                 # Antigravity agent skill specification
├── setup.sh                 # Environment check, symlink deployment & chmod 555 hardening
├── README.md                # Project documentation
└── scripts/
    ├── b2f_engine.py        # Standalone cross-platform Python CLI engine
    └── b2f_helper.sh        # Hardened POSIX Bash wrapper
```

---

## Installation & Setup

Clone the repository and execute `setup.sh` to configure permissions and install to your agent environment:

```bash
git clone https://github.com/LockNStock/b2f.git
cd b2f
./setup.sh
```

`setup.sh` verifies `python3 >= 3.8` and `git`, links the skill to `~/.gemini/config/skills/b2f`, and applies write protection (`chmod 555`) to the executable engines.

---

## CLI Subcommands Reference

Both `b2f_engine.py` and `b2f_helper.sh` provide the following interface:

```bash
# 1. Physical backup with automatic git dirty detection
python3 scripts/b2f_engine.py backup <anchor> [--git-diff] [file_paths...]

# 2. Native persistence bypassing IDE undo stack
cat << 'EOF' | python3 scripts/b2f_engine.py persist <anchor> <target_file> [--mirror]
<content>
EOF

# 3. Restore files from active manifest and clean up slices
python3 scripts/b2f_engine.py restore [--cleanup|--wipe]

# 4. Generate passive recovery command snippet
python3 scripts/b2f_engine.py snippet <anchor> [file_paths...]

# 5. Output Golden Re-execution Directive markdown template
python3 scripts/b2f_engine.py template [anchor] [title]

# 6. Assemble 3-tier Golden Re-execution Prompt
python3 scripts/b2f_engine.py assemble <directive_file> [anchor] [file_paths...]

# 7. Archive intermediate b2f_*.md fragments
python3 scripts/b2f_engine.py archive [date_folder]

# 8. Prune historical manifests
python3 scripts/b2f_engine.py prune [max_keep]
```

---

## License

MIT License.
