"""Update private Git fixtures; HTTPS is redirected to a local bare repository."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess

from support import ROOT, ScriptTest


class RepositoryUpdateTests(ScriptTest):
    def setUp(self):
        super().setUp()
        self.real_git = shutil.which('git')
        self.env.update({'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1'})
        self.remote = self.work / 'remote.git'
        self.seed = self.work / 'seed'
        self.git('init', '--bare', '--initial-branch=main', str(self.remote))
        self.git('init', '--initial-branch=main', str(self.seed))
        shutil.copy2(ROOT / 'update-bash-scripts.sh', self.seed)
        (self.seed / 'README.md').write_text('initial version\n')
        (self.seed / '.gitignore').write_text('ignored*\n')
        self.commit(self.seed)
        self.git('-C', str(self.seed), 'remote', 'add', 'origin', str(self.remote))
        self.git('-C', str(self.seed), 'push', 'origin', 'main')
        rewrite = f'url.{self.remote.as_uri()}.insteadOf=https://github.com/nihilihin666/bash-scripts.git'
        self.command('git', '''
printf '%s\\0' "$@" >> "$HOME/git-calls"
for argument in "$@"; do
    if [[ -n "${UPDATE_TEST_GIT_FAILURE:-}" && "$argument" == "$UPDATE_TEST_GIT_FAILURE" ]]; then
        echo 'injected network failure' >&2
        exit 7
    fi
done
''' + f'exec {shlex.quote(self.real_git)} -c protocol.file.allow=always -c {shlex.quote(rewrite)} "$@"\n')

    def git(self, *args):
        result = subprocess.run([self.real_git, *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def commit(self, directory):
        self.git('-C', str(directory), 'add', '-A')
        self.git('-C', str(directory), '-c', 'user.name=Fixture',
                 '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture')

    def checkout(self):
        directory = self.work / 'checkout with spaces'
        self.git('clone', str(self.remote), str(directory))
        self.git('-C', str(directory), 'remote', 'set-url', 'origin',
                 'git@github.com:nihilihin666/bash-scripts.git')
        return directory

    def plain_folder(self):
        directory = self.work / 'plain folder with spaces'
        directory.mkdir()
        shutil.copy2(ROOT / 'update-bash-scripts.sh', directory)
        (directory / 'local notes.txt').write_text('keep my local notes\n')
        return directory

    def publish(self):
        (self.seed / 'README.md').write_text('newest version\n')
        (self.seed / 'added.sh').write_text('#!/usr/bin/env bash\nprintf "new version\\n"\n')
        (self.seed / 'added.sh').chmod(0o755)
        script = self.seed / 'update-bash-scripts.sh'
        script.write_text(script.read_text().replace(
            '#!/usr/bin/env bash', '#!/usr/bin/env bash\n# updated fixture', 1))
        self.commit(self.seed)
        self.git('-C', str(self.seed), 'push', 'origin', 'main')

    def run_update(self, directory, *, expected=0, env=None, prelude=''):
        # Loading definitions first allows narrowly scoped failure injection.
        # main still resolves its directory through the real BASH_SOURCE path.
        command = ([str(directory / 'update-bash-scripts.sh')] if not prelude else
                   ['bash', '-c', 'source "$1"\n' + prelude + '\nmain',
                    'fixture', str(directory / 'update-bash-scripts.sh')])
        result = subprocess.run(
            command,
            cwd=self.work, env=self.env if env is None else env,
            text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def assert_clean_temporary(self, directory):
        self.assertFalse((directory.parent / f'.{directory.name}.update-lock').exists())
        self.assertEqual(list(directory.parent.glob('.bash-scripts-update.*')), [])

    def test_anonymous_https_updates_from_other_cwd_and_preserves_ssh_origin(self):
        directory = self.checkout()
        self.publish()
        result = self.run_update(directory)
        self.assertIn('Updated bash-scripts to', result.stdout)
        self.assertEqual((directory / 'README.md').read_text(), 'newest version\n')
        self.assertIn('# updated fixture', (directory / 'update-bash-scripts.sh').read_text())
        self.assertTrue(os.access(directory / 'added.sh', os.X_OK))
        self.assertEqual(self.git('-C', str(directory), 'rev-parse', 'HEAD'),
                         self.git('-C', str(self.seed), 'rev-parse', 'HEAD'))
        self.assertEqual(self.git('-C', str(directory), 'remote', 'get-url', 'origin'),
                         'git@github.com:nihilihin666/bash-scripts.git')
        calls = (self.home / 'git-calls').read_bytes().split(b'\0')
        self.assertIn(b'https://github.com/nihilihin666/bash-scripts.git', calls)
        self.assertIn(b'credential.helper=', calls)
        self.assert_clean_temporary(directory)

    def test_already_current_is_successful(self):
        result = self.run_update(self.checkout())
        self.assertIn('Already up to date', result.stdout)

    def test_default_branch_is_discovered_instead_of_assuming_main(self):
        self.git('-C', str(self.seed), 'branch', 'published')
        self.git('-C', str(self.seed), 'push', 'origin', 'published')
        self.git('--git-dir', str(self.remote), 'symbolic-ref', 'HEAD', 'refs/heads/published')
        directory = self.checkout()
        self.publish()
        self.git('-C', str(self.seed), 'push', 'origin', 'main:published')
        self.run_update(directory)
        self.assertEqual(self.git('-C', str(directory), 'branch', '--show-current'), 'published')
        self.assertEqual((directory / 'README.md').read_text(), 'newest version\n')

    def test_local_tracked_staged_or_untracked_changes_are_preserved(self):
        directory = self.checkout()
        self.publish()
        old_head = self.git('-C', str(directory), 'rev-parse', 'HEAD')
        for kind in ('tracked', 'staged', 'untracked'):
            with self.subTest(kind=kind):
                path = directory / ('notes.txt' if kind == 'untracked' else 'README.md')
                path.write_text('local work\n')
                if kind == 'staged':
                    self.git('-C', str(directory), 'add', 'README.md')
                result = self.run_update(directory, expected=1)
                self.assertIn('Local changes or extra files', result.stderr)
                self.assertEqual(path.read_text(), 'local work\n')
                self.assertEqual(self.git('-C', str(directory), 'rev-parse', 'HEAD'), old_head)
                self.assert_clean_temporary(directory)
                if kind == 'untracked':
                    path.unlink()
                else:
                    self.git('-C', str(directory), 'restore', '--source=HEAD', '--staged', '--worktree', 'README.md')

    def test_local_commits_and_divergence_are_refused(self):
        directory = self.checkout()
        (directory / 'personal.txt').write_text('local commit\n')
        self.commit(directory)
        old_head = self.git('-C', str(directory), 'rev-parse', 'HEAD')
        for diverged in (False, True):
            with self.subTest(diverged=diverged):
                if diverged:
                    self.publish()
                result = self.run_update(directory, expected=1)
                self.assertIn('prevent a safe fast-forward', result.stderr)
                self.assertEqual(self.git('-C', str(directory), 'rev-parse', 'HEAD'), old_head)
                self.assertEqual((directory / 'personal.txt').read_text(), 'local commit\n')

    def test_detached_or_nondefault_branch_is_refused(self):
        directory = self.checkout()
        self.git('-C', str(directory), 'checkout', '--detach')
        result = self.run_update(directory, expected=1)
        self.assertIn('detached HEAD', result.stderr)
        self.git('-C', str(directory), 'checkout', '-b', 'personal')
        result = self.run_update(directory, expected=1)
        self.assertIn("uses branch 'personal'", result.stderr)

    def test_unfinished_operation_is_refused_even_with_clean_files(self):
        directory = self.checkout()
        (directory / '.git/rebase-merge').mkdir()
        result = self.run_update(directory, expected=1)
        self.assertIn('unfinished Git operation', result.stderr)

    def test_fetch_failure_preserves_working_files(self):
        directory = self.checkout()
        self.publish()
        old_head = self.git('-C', str(directory), 'rev-parse', 'HEAD')
        result = self.run_update(directory, expected=1,
                                 env={**self.env, 'UPDATE_TEST_GIT_FAILURE': 'fetch'})
        self.assertIn('Download failed', result.stderr)
        self.assertEqual((directory / 'README.md').read_text(), 'initial version\n')
        self.assertEqual(self.git('-C', str(directory), 'rev-parse', 'HEAD'), old_head)
        self.assert_clean_temporary(directory)

    def test_ignored_file_collision_is_not_overwritten(self):
        directory = self.checkout()
        (directory / 'ignored.txt').write_text('local ignored data\n')
        (self.seed / 'ignored.txt').write_text('published data\n')
        self.git('-C', str(self.seed), 'add', '-f', 'ignored.txt')
        self.commit(self.seed)
        self.git('-C', str(self.seed), 'push', 'origin', 'main')
        result = self.run_update(directory, expected=1)
        self.assertIn('could not be applied safely', result.stderr)
        self.assertEqual((directory / 'ignored.txt').read_text(), 'local ignored data\n')

    def test_plain_folder_becomes_checkout_with_complete_backup(self):
        directory = self.plain_folder()
        self.publish()
        before = self.snapshot(directory)
        result = self.run_update(directory)
        self.assertIn('Original folder backed up to:', result.stdout)
        backups = list((self.home / 'bash-scripts-output/repository-backups').glob('*/repository'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.snapshot(backups[0]), before)
        self.assertTrue((directory / '.git').is_dir())
        self.assertEqual((directory / 'README.md').read_text(), 'newest version\n')
        self.assertFalse((directory / 'local notes.txt').exists())
        self.assertIn('Already up to date', self.run_update(directory).stdout)
        self.assert_clean_temporary(directory)

    def test_plain_folder_network_failure_leaves_original_untouched(self):
        directory = self.plain_folder()
        before = self.snapshot(directory)
        result = self.run_update(directory, expected=1,
                                 env={**self.env, 'UPDATE_TEST_GIT_FAILURE': 'clone'})
        self.assertIn('original folder was left unchanged', result.stderr)
        self.assertEqual(self.snapshot(directory), before)
        self.assertFalse((self.home / 'bash-scripts-output').exists())
        self.assert_clean_temporary(directory)

    def test_failed_backup_does_not_replace_plain_folder(self):
        directory = self.plain_folder()
        before = self.snapshot(directory)
        result = self.run_update(directory, expected=1, prelude='cp() { return 7; }')
        self.assertIn('Backup failed', result.stderr)
        self.assertEqual(self.snapshot(directory), before)
        self.assert_clean_temporary(directory)

    def test_failed_replacement_restores_plain_folder(self):
        directory = self.plain_folder()
        before = self.snapshot(directory)
        result = self.run_update(directory, expected=1, prelude='''
mv() {
    if [[ "$*" == *--no-clobber* ]]; then return 7; fi
    command mv "$@"
}
''')
        self.assertIn('Restored the original folder', result.stderr)
        self.assertEqual(self.snapshot(directory), before)
        self.assert_clean_temporary(directory)

    def test_failed_restoration_retains_original_staging_and_backup(self):
        directory = self.plain_folder()
        before = self.snapshot(directory)
        result = self.run_update(directory, expected=1, prelude='''
mv() {
    if [[ "$*" == *--no-clobber* || "${@: -2:1}" == */previous ]]; then return 7; fi
    command mv "$@"
}
''')
        self.assertIn('Original folder retained for recovery:', result.stderr)
        stages = list(directory.parent.glob('.bash-scripts-update.*'))
        self.assertEqual(len(stages), 1)
        self.assertEqual(self.snapshot(stages[0] / 'previous'), before)
        backups = list((self.home / 'bash-scripts-output/repository-backups').glob('*/repository'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.snapshot(backups[0]), before)
        self.assertFalse((directory.parent / f'.{directory.name}.update-lock').exists())

    def test_interrupted_replacement_restores_plain_folder(self):
        directory = self.plain_folder()
        before = self.snapshot(directory)
        self.run_update(directory, expected=143, prelude='''
mv() {
    if [[ "$*" == *--no-clobber* ]]; then kill -TERM "$$"; fi
    command mv "$@"
}
''')
        self.assertEqual(self.snapshot(directory), before)
        self.assert_clean_temporary(directory)

    def test_existing_lock_is_not_removed_by_second_updater(self):
        directory = self.plain_folder()
        lock = directory.parent / f'.{directory.name}.update-lock'
        lock.mkdir()
        result = self.run_update(directory, expected=1)
        self.assertIn('Another update may be running', result.stderr)
        self.assertTrue(lock.is_dir())
        self.assertFalse((self.home / 'git-calls').exists())

    def test_plain_folder_cannot_back_up_into_itself(self):
        directory = self.plain_folder()
        result = self.run_update(directory, expected=1, env={**self.env, 'HOME': str(directory)})
        self.assertIn('backup destination is inside this folder', result.stderr)
        self.assertFalse((directory / '.git').exists())
        self.assert_clean_temporary(directory)

    def test_plain_folder_inside_another_checkout_does_not_update_parent(self):
        parent = self.checkout()
        directory = parent / 'copied scripts'
        directory.mkdir()
        shutil.copy2(ROOT / 'update-bash-scripts.sh', directory)
        parent_head = self.git('-C', str(parent), 'rev-parse', 'HEAD')
        self.publish()
        self.run_update(directory)
        self.assertTrue((directory / '.git').is_dir())
        self.assertEqual(self.git('-C', str(parent), 'rev-parse', 'HEAD'), parent_head)
        self.assertEqual((parent / 'README.md').read_text(), 'initial version\n')

    def test_invalid_git_metadata_is_not_treated_as_plain_folder(self):
        directory = self.plain_folder()
        (directory / '.git').write_text('invalid metadata\n')
        before = self.snapshot(directory)
        self.run_update(directory, expected=1)
        self.assertEqual(self.snapshot(directory), before)
        self.assertFalse((self.home / 'bash-scripts-output').exists())
        self.assert_clean_temporary(directory)

    def test_invalid_options_and_missing_git_do_not_create_lock_or_backup(self):
        directory = self.plain_folder()
        for args, expected, diagnostic in ((['--unknown'], 2, 'unknown argument'),
                                            ([], 1, 'Required tool not found: git')):
            with self.subTest(args=args):
                result = subprocess.run(
                    [shutil.which('bash'), str(directory / 'update-bash-scripts.sh'), *args],
                    env={**self.env, 'PATH': '/nonexistent'}, cwd=self.work,
                    text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(diagnostic, result.stderr)
                self.assert_clean_temporary(directory)
                self.assertFalse((self.home / 'bash-scripts-output').exists())

    def test_help_needs_no_git_or_other_tools_and_has_no_side_effects(self):
        directory = self.plain_folder()
        before = self.snapshot(directory)
        for flag in ('--help', '-h'):
            result = subprocess.run(
                [shutil.which('bash'), str(directory / 'update-bash-scripts.sh'), flag],
                env={**self.env, 'PATH': '/nonexistent'}, cwd=self.work,
                text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Show this help', result.stdout)
        self.assertEqual(self.snapshot(directory), before)
        self.assert_clean_temporary(directory)

    def test_git_environment_cannot_redirect_to_another_repository(self):
        directory = self.checkout()
        self.publish()
        seed_head = self.git('-C', str(self.seed), 'rev-parse', 'HEAD')
        self.run_update(directory, env={**self.env, 'GIT_DIR': str(self.seed / '.git'),
                                       'GIT_WORK_TREE': str(self.seed),
                                       'GIT_INDEX_FILE': str(self.seed / '.git/index')})
        self.assertEqual((directory / 'README.md').read_text(), 'newest version\n')
        self.assertEqual(self.git('-C', str(self.seed), 'rev-parse', 'HEAD'), seed_head)
