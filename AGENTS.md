# Repository instructions

## Scope and implementation

- Make repository changes here, in `bash-scripts`. Do not update an older sibling
  checkout as part of this work. Preserve unrelated user changes.
- These are standalone Bash scripts with `.sh` extensions. Preserve Bash
  shebangs, executable permissions, and each file's existing formatting.
- Keep changes focused. Avoid unrelated refactoring, repository-wide formatting,
  or introducing a shared framework for independent scripts without a need.
- Preserve command names, options, defaults, output locations, exit behavior,
  and stdout/stderr contracts unless the task changes them.
- Default persistent user results belong under `$HOME/bash-scripts-output`.
  Keep scripts independent of repository location and working directory.
  Preserve explicit user paths, user/XDG state, installation directories,
  system paths, and temporary storage required for correctness.
- Examples may use `./bash-scripts/...` when the parent-directory assumption is
  clear. Runtime operations must not assume that layout.

## Shell correctness and safety

- Quote path expansions and use arrays for command arguments. Use NUL-delimited
  traversal and `--` where appropriate. Treat filenames and values as data;
  do not construct executable shell text from them.
- Preserve error-handling intent. Do not mechanically add `set -euo pipefail`:
  diagnostics and batch processing deliberately handle partial failures.
- Preserve collision checks, backups, undo maps, atomic replacement, rollback,
  locks, signal cleanup, and target identity/protection checks.
- Preserve privilege boundaries. Keep desktop configuration under the intended
  user, npm user installations non-root, and root's HOME/XDG/session environment
  out of user operations.
- Keep `--help` and `-h` side-effect-free and before installation, privilege
  checks, or operational work. The CLI suite executes both for every script.
- Preserve each dry-run/inspection mode's documented guarantees. Do not assume
  every script implements these modes.
- Retain download verification, signing-key checks, and explicit opt-in for
  T3 Code's sandbox fallback.

## Verification

- Run `bash -n` and ShellCheck for changed Bash files. Parse embedded Python with
  `ast.parse` when it changes; do not run operational helpers to validate syntax.
- Run relevant ordinary suites from the repository root:

  ```bash
  python3 -m unittest discover -s tests -v
  python3 -m unittest discover -s os/fedora/tests -v
  python3 -m unittest discover -s os/fedora/setup/tests -v
  ```

- Test using temporary files, mocked commands, and isolated HOME/XDG paths. Add
  regressions for meaningful behavior changes, including argument handling,
  failure paths, recovery, and safety guarantees.
- Do not run package/firmware updates, installation, desktop configuration, or
  disk writes merely as smoke tests. Live changes require task authorization;
  documentation and ordinary test work do not imply it.
- For `os/dd.sh`, use static checks and isolated/mocked tests on the working
  computer. Never use a real device as a routine verification target.
- Read [other/danger/AGENTS.md](other/danger/AGENTS.md) before editing or validating
  that subtree. Its runtime suites are excluded from ordinary local testing.
- Report checks actually performed, failures, and unverified behavior. Unit,
  syntax, and lint results are not hardware or distribution qualification.

## T3 Code integration

- Preserve the installed copy under `$HOME/.local/opt/t3code` and the command
  shortcut under `$HOME/.local/bin`. Installed shortcuts must not depend on
  the repository script's location.
- Preserve the separate launcher desktop entry and post-startup URL-handler
  repair. T3 Code can regenerate its own entry and registration during startup.
  Respect an explicitly selected unrelated handler.
- Test relocation and simulated registration resets when changing this behavior,
  including forwarding to an existing instance and startup failure.
- Editing the repository does not refresh an installed launcher. When installation
  is part of the task, verify the installed copy matches the source and the live
  shortcut/handler targets are correct.
- Do not restart a running user session solely for validation. Distinguish a
  request forwarded to an existing instance from a verified fresh startup.

## Documentation and handoff

- Update help and README when behavior, requirements, privileges, outputs, or
  recovery steps change.
- Keep README focused on users and AGENTS focused on editing and verification.
  Link detailed erasure qualification requirements instead of duplicating them.
- Do not commit generated output, credentials, diagnostics, or Python caches.
- Do not claim changes are saved in Git unless the intended files are tracked
  and committed as authorized by the task.
