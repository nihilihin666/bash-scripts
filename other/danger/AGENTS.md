# Erasure script instructions

These rules apply to this directory and its tests in addition to the root
[AGENTS.md](../../AGENTS.md).

## Required references

Read [tests/RELEASE-CHECKLIST.txt](tests/RELEASE-CHECKLIST.txt) before changes or
validation. Consult [tests/REVIEW-NOTES.txt](tests/REVIEW-NOTES.txt) for known
limitations. The checklist defines qualification; ordinary repository checks do
not establish release readiness.

## Working-computer validation

- Use Bash syntax checks, ShellCheck, and Python `ast.parse` for operational source
  and runtime test modules. Do not import or execute the embedded helper to check
  syntax.
- The root CLI suite's side-effect-free `--help`/`-h` checks are allowed. Keep help
  before privilege checks, storage discovery, temporary-file work, and mutations.
- Do not run inventory (`--check`), interactive erasure, or either erasure runtime
  suite as routine local validation.
- Do not run `offline-validation.py` or `vm-integration.py` on the working
  computer, including a VM hosted on it. The checklist states: "All runtime
  validation must run on a SEPARATE disposable test machine or remote VM."
- Follow the checklist's environment, explicit flags, RAM-image ownership, and
  isolation requirements on that separate machine. Physical tests require a
  separate test machine and sacrificial drives. Do not improvise device tests.

## Preserve production safeguards

- Do not bypass refusal paths or add production eligibility overrides for tests.
  Unsupported identity, usage, boot topology, hardware, or sanitization state
  must continue to block automatic writes.
- Preserve boot/system/script/swap protection, repeated identity and generation
  checks, exclusive claims, worker supervision, cancellation, cleanup, exact-size
  overwrite, and complete read-back comparison.
- Preserve the distinction between accessible-sector overwrite and hardware
  sanitization. Never claim inaccessible or retired sectors have been erased.
- Keep temporary storage and optional instruction saving within existing policy.
  Do not redirect erasure reports/working data into the normal home output
  directory. Do not disable swap to simplify protection checks.
- Expanding backends or weakening a conservative policy requires an explicit
  task scope, defined result semantics, and corresponding qualification.

## Evidence and reporting

State the checks performed and environment used. Keep runtime and physical
qualification pending until required tests actually pass for the relevant
revision and environment. Update the checklist and review notes when changes
affect their claims. Authored tests and static review are not executed runtime
evidence.
