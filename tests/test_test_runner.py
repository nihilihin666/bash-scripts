"""Run only miniature repositories, never recursively run the real suite."""
import ast
from pathlib import Path
import shutil
import subprocess

from support import ROOT, ScriptTest


class TestRunnerTests(ScriptTest):
    def setUp(self):
        super().setUp()
        self.repo = self.work / 'relocated repository with spaces'
        self.repo.mkdir()
        self.runner = self.repo / 'test-bash-scripts.sh'
        shutil.copy2(ROOT / 'test-bash-scripts.sh', self.runner)
        self.command('shellcheck', '''
printf 'lint:%s\n' "$*" >> "$HOME/checks"
if [[ "${FAKE_LINT_FAIL:-0}" == 1 ]]; then exit 1; fi
''')

    def fixture(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def write_test_module(self, relative, label, *, fail=False, skip=False):
        return self.fixture(relative, f'''import unittest
from pathlib import Path
import os

class Fixture(unittest.TestCase):
    def test_fixture(self):
        self.assertEqual(Path.cwd(), Path({str(self.repo)!r}))
        with (Path(os.environ['HOME']) / 'executed').open('a') as output:
            output.write({label!r} + '\\n')
        {'self.skipTest("fixture skip")' if skip else 'self.assertFalse(' + repr(fail) + ')'}
''')

    def run_runner(self, *args, expected=0, env=None):
        result = subprocess.run(
            [str(self.runner), *args], cwd=self.work,
            env=self.env if env is None else env,
            text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def executed(self):
        path = self.home / 'executed'
        return path.read_text().splitlines() if path.exists() else []

    def test_new_directories_are_discovered_after_relocation(self):
        self.write_test_module('first/tests/test_example.py', 'first')
        self.write_test_module('a new directory/deep/tests/test_example.py', 'second')
        self.fixture('a new directory/helper.sh', '#!/usr/bin/env bash\nexit 98\n')
        result = self.run_runner()
        self.assertEqual(sorted(self.executed()), ['first', 'second'])
        self.assertIn('2 Bash files, 2 test directories', result.stdout)
        self.assertIn(str(self.repo / 'a new directory/helper.sh'),
                      (self.home / 'checks').read_text())
        self.assertEqual(list(self.repo.rglob('__pycache__')), [])

    def test_nested_packages_are_not_run_twice_and_module_names_are_isolated(self):
        self.fixture('tests/__init__.py', '')
        self.fixture('tests/nested/__init__.py', '')
        for directory, label in (('tests', 'parent'), ('tests/nested', 'child')):
            self.fixture(f'{directory}/local_helper.py', f'VALUE = {label!r}\n')
            module = self.write_test_module(f'{directory}/test_same.py', label)
            module.write_text('from local_helper import VALUE\n' + module.read_text() +
                              f'\nassert VALUE == {label!r}\n')
        result = self.run_runner()
        self.assertEqual(self.executed(), ['parent', 'child'])
        self.assertIn('2 test directories', result.stdout)

    def test_exclusion_marker_blocks_descendants_but_keeps_static_checks(self):
        self.write_test_module('safe/test_ok.py', 'safe')
        self.fixture('restricted/.test-runner-ignore', 'Do not execute these tests.\n')
        self.fixture('restricted/__init__.py', '')
        self.fixture('restricted/deeper/__init__.py', '')
        self.fixture('restricted/test_never_import.py', 'raise RuntimeError("unsafe import")\n')
        self.fixture('restricted/deeper/test_never_import.py', 'raise RuntimeError("unsafe import")\n')
        self.fixture('restricted/source.sh', '#!/usr/bin/env bash\nexit 98\n')
        result = self.run_runner()
        self.assertEqual(self.executed(), ['safe'])
        self.assertIn('Excluded runtime tests: restricted', result.stdout)
        self.assertIn('ShellCheck: restricted/source.sh', result.stdout)
        self.assertNotIn('unsafe import', result.stderr)

    def test_marked_nested_package_is_not_imported_by_parent_suite(self):
        self.write_test_module('tests/test_safe.py', 'safe')
        self.fixture('tests/unsafe/__init__.py', 'raise RuntimeError("unsafe package")\n')
        self.fixture('tests/unsafe/.test-runner-ignore', '')
        self.fixture('tests/unsafe/test_bad.py', 'raise RuntimeError("unsafe test")\n')
        self.run_runner()
        self.assertEqual(self.executed(), ['safe'])

    def test_caches_git_virtualenvs_and_symlinks_are_not_discovered(self):
        self.write_test_module('safe/test_ok.py', 'safe')
        for directory in ('.git', '__pycache__', 'environment'):
            self.write_test_module(f'{directory}/test_bad.py', directory, fail=True)
        self.fixture('environment/pyvenv.cfg', '')
        outside = self.work / 'outside'
        outside.mkdir()
        (outside / 'test_bad.py').write_text('raise RuntimeError("outside")\n')
        (self.repo / 'linked-directory').symlink_to(outside, target_is_directory=True)
        (self.repo / 'test_link.py').symlink_to(outside / 'test_bad.py')
        (self.repo / 'linked.sh').symlink_to('/nonexistent/script.sh')
        self.run_runner()
        self.assertEqual(self.executed(), ['safe'])

    def test_failures_are_counted_and_later_checks_still_run(self):
        self.fixture('broken.sh', '#!/usr/bin/env bash\nif\n')
        self.write_test_module('a/tests/test_fail.py', 'failed suite', fail=True)
        self.write_test_module('z/tests/test_pass.py', 'later suite')
        result = self.run_runner(expected=1, env={**self.env, 'FAKE_LINT_FAIL': '1'})
        self.assertEqual(self.executed(), ['failed suite', 'later suite'])
        self.assertIn('FAIL: Bash syntax: broken.sh', result.stdout)
        self.assertIn('FAIL: ShellCheck: broken.sh', result.stdout)
        self.assertIn('FAIL: Unit tests: a/tests', result.stdout)
        # Both the runner and broken.sh receive failing mocked lint checks.
        self.assertIn('2 checks passed, 4 failed', result.stdout)

    def test_import_errors_fail_without_preventing_later_suites(self):
        self.fixture('a/test_broken.py', 'raise RuntimeError("import failure")\n')
        self.write_test_module('z/test_ok.py', 'later')
        result = self.run_runner(expected=1)
        self.assertIn('import failure', result.stderr)
        self.assertEqual(self.executed(), ['later'])

    def test_skips_are_visible_and_do_not_fail_runner(self):
        self.write_test_module('tests/test_skip.py', 'skipped', skip=True)
        result = self.run_runner()
        self.assertIn('skipped=1', result.stderr)
        self.assertIn('0 failed', result.stdout)

    def test_interrupted_check_stops_before_later_suites(self):
        self.write_test_module('tests/test_later.py', 'must not execute')
        self.command('shellcheck', 'exit 130\n')
        self.run_runner(expected=130)
        self.assertEqual(self.executed(), [])

    def test_missing_tools_produce_errors_without_running_checks(self):
        for missing in ('bash', 'python3', 'shellcheck'):
            with self.subTest(missing=missing):
                path = self.work / f'only-tools-except-{missing}'
                path.mkdir()
                for tool in ('bash', 'python3', 'shellcheck'):
                    if tool != missing:
                        (path / tool).symlink_to(shutil.which(tool, path=self.env['PATH']))
                result = subprocess.run(
                    [shutil.which('bash'), str(self.runner)], cwd=self.work,
                    env={**self.env, 'PATH': str(path)}, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(f'required tool not found: {missing}', result.stderr)
                self.assertFalse((self.home / 'checks').exists())

    def test_help_and_bad_arguments_need_no_tools_or_discovery(self):
        for flag, expected in (('--help', 0), ('-h', 0), ('--unknown', 2)):
            with self.subTest(flag=flag):
                result = subprocess.run(
                    [shutil.which('bash'), str(self.runner), flag], cwd=self.work,
                    env={**self.env, 'PATH': '/nonexistent'},
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if expected == 0:
                    self.assertIn('Show this help', result.stdout)
        self.assertFalse((self.home / 'checks').exists())

    def test_empty_repository_fails_instead_of_reporting_tests_passed(self):
        result = self.run_runner(expected=1)
        self.assertIn('no ordinary test_*.py suites discovered', result.stdout)

    def test_runtime_exclusion_marker_is_present_for_erasure_suites(self):
        self.assertTrue((ROOT / 'other/danger/tests/.test-runner-ignore').is_file())

    def test_embedded_python_syntax_without_running_runner(self):
        source = self.runner.read_text()
        helper = source.split("<<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
        tree = ast.parse(helper)
        worker = next(node.value.value for node in tree.body
                      if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == 'WORKER'
                              for target in node.targets))
        ast.parse(worker)
