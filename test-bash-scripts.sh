#!/usr/bin/env bash

# Discover static checks and ordinary Python tests relative to this runner.

usage() {
    printf '%s\n' "Usage: $0 [--help]

Check every repository .sh file with bash -n and ShellCheck, then run Python
unittest files named test_*.py in every discovered directory.

Options:
  -h, --help  Show this help.

Run as your normal user. Requires bash, python3, and shellcheck; installs nothing.
Paths are resolved from this script, independently of the working directory.
Each test directory runs in a separate Python process, without Python caches.
A .test-runner-ignore file excludes its directory and descendants from runtime
test discovery, while Bash static checks still apply. Symlinks, Git metadata,
Python caches, and virtual environments containing pyvenv.cfg are not traversed.

Exit status: 0 when all checks pass (test skips are allowed), 1 for failed checks
or no discovered suites, 2 for usage, missing tools, or discovery errors.
Results are printed to the terminal; no persistent report is created."
}

main() {
    case "$#" in
        0) ;;
        1)
            case "$1" in
                --help|-h) usage; return 0 ;;
                *) printf 'Error: unknown argument: %s\n' "$1" >&2; return 2 ;;
            esac
            ;;
        *) printf 'Error: expected no arguments; use --help.\n' >&2; return 2 ;;
    esac

    local tool missing=0
    for tool in bash python3 shellcheck; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf 'Error: required tool not found: %s\n' "$tool" >&2
            missing=1
        fi
    done
    (( missing == 0 )) || return 2

    python3 -B - "${BASH_SOURCE[0]}" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

# Load only the files assigned to this directory. unittest discovery can recurse
# into packages, which would run nested suites twice or cross an exclusion marker.
WORKER = r'''
import importlib.util
from pathlib import Path
import sys
import unittest

directory = Path(sys.argv[1])
sys.path.insert(0, str(directory))
loader = unittest.TestLoader()
suite = unittest.TestSuite()
for filename in sys.argv[2:]:
    path = directory / filename
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[path.stem] = module
    spec.loader.exec_module(module)
    suite.addTests(loader.loadTestsFromModule(module))
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
'''


def main():
    root = Path(sys.argv[1]).resolve().parent
    print(f'Repository: {root}', flush=True)
    scripts = []
    suites = []
    excluded = []
    errors = []
    for directory, directories, filenames in os.walk(root, onerror=errors.append):
        base = Path(directory)
        directories[:] = sorted(
            name for name in directories
            if name not in ('.git', '__pycache__')
            and not (base / name).is_symlink()
            and not (base / name / 'pyvenv.cfg').exists())
        if (base / '.test-runner-ignore').exists():
            excluded.append(base)
        files = sorted(name for name in filenames if not (base / name).is_symlink())
        scripts.extend(base / name for name in files if name.endswith('.sh'))
        if not any(path == base or path in base.parents for path in excluded):
            tests = [name for name in files if name.startswith('test_') and name.endswith('.py')]
            if tests:
                suites.append((base, tests))
    if errors:
        for error in errors:
            print(f'Error discovering files: {error}', file=sys.stderr)
        return 2
    for path in excluded:
        print(f'Excluded runtime tests: {path.relative_to(root)}', flush=True)

    passed = 0
    failed = 0
    environment = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'}

    def check(label, arguments):
        nonlocal passed, failed
        print(f'\n>>> {label}', flush=True)
        result = subprocess.run(arguments, cwd=root, env=environment,
                                stdin=subprocess.DEVNULL)
        if result.returncode in (-2, 130, -15, 143):
            raise SystemExit(130 if result.returncode in (-2, 130) else 143)
        if result.returncode == 0:
            passed += 1
        else:
            failed += 1
            print(f'FAIL: {label} (exit {result.returncode})', flush=True)

    for script in scripts:
        relative = script.relative_to(root)
        check(f'Bash syntax: {relative}', ['bash', '-n', str(script)])
        check(f'ShellCheck: {relative}', ['shellcheck', str(script)])
    for directory, files in suites:
        check(f'Unit tests: {directory.relative_to(root)}',
              [sys.executable, '-B', '-c', WORKER, str(directory), *files])
    if not suites:
        print('FAIL: no ordinary test_*.py suites discovered.', flush=True)
        failed += 1
    print(f'\nSummary: {len(scripts)} Bash files, {len(suites)} test directories; '
          f'{passed} checks passed, {failed} failed. Test skips are shown above.', flush=True)
    return 1 if failed else 0


try:
    sys.exit(main())
except KeyboardInterrupt:
    print('\nInterrupted.', file=sys.stderr)
    sys.exit(130)
except OSError as error:
    print(f'Error running checks: {error}', file=sys.stderr)
    sys.exit(2)
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
