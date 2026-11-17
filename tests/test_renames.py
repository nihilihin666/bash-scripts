"""Real renames on disposable files; command failures are injected locally."""
import base64

from support import ScriptTest


class RenameTests(ScriptTest):
    def setUp(self):
        super().setUp()
        self.input = self.work / 'input with spaces'
        self.input.mkdir()

    def populate(self):
        for index, name in enumerate(('Hello World.TXT', '-leading.txt',
                                      'line\nbreak.txt', 'sub dir/HTTPServer.json')):
            path = self.input / name
            path.parent.mkdir(exist_ok=True)
            path.write_text(f'contents {index}')

    def test_random_round_trip_preserves_names_and_contents(self):
        self.populate()
        before = self.snapshot(self.input)
        self.bash('randomise-filenames.sh', 'main --prefix "some prefix=" "$1"', self.input)
        self.assertEqual(sorted(self.snapshot(self.input).values()), sorted(before.values()))
        maps = list((self.home / 'bash-scripts-output').glob('*.map'))
        self.assertEqual(len(maps), 1)
        self.assertEqual(maps[0].stat().st_mode & 0o777, 0o600)
        self.bash('randomise-filenames.sh', 'main --reverse "$1"', maps[0])
        self.assertEqual(self.snapshot(self.input), before)
        self.assertEqual(list(self.input.rglob('.randomise-filenames*')), [])

    def test_no_manifest_only_removes_map_after_success(self):
        (self.input / 'original.txt').write_text('keep')
        self.bash('randomise-filenames.sh', 'main --no-manifest "$1"', self.input)
        self.assertEqual(list((self.home / 'bash-scripts-output').glob('*.map')), [])
        self.assertEqual(list(self.snapshot(self.input).values()), [b'keep'])

    def test_random_retry_on_reserved_destination(self):
        (self.input / 'one.txt').write_text('one')
        (self.input / 'two.txt').write_text('two')
        self.bash('randomise-filenames.sh', '''
random_7_digit_number() {
    local n=0
    [[ ! -f "$HOME/count" ]] || read -r n < "$HOME/count"
    printf '%s\n' "$((n + 1))" > "$HOME/count"
    if (( n < 2 )); then echo 1234567; else echo 7654321; fi
}
main "$1"
''', self.input)
        self.assertEqual(set(self.snapshot(self.input)), {'1234567.txt', '7654321.txt'})
        self.assertEqual(sorted(self.snapshot(self.input).values()), [b'one', b'two'])

    def test_rename_failure_rolls_back_both_utilities(self):
        for script in ('randomise-filenames.sh', 'files-to-dash-case.sh'):
            with self.subTest(script=script):
                for path in self.input.iterdir():
                    path.unlink()
                (self.input / 'First File.txt').write_text('first')
                (self.input / 'Second File.txt').write_text('second')
                before = self.snapshot(self.input)
                result = self.bash(script, '''
count=0
mv() {
    count=$((count + 1))
    if (( count == 2 )); then return 7; fi
    command mv "$@"
}
main "$1"
''', self.input, expected=1 if script == 'files-to-dash-case.sh' else 7)
                self.assertRegex(result.stderr, 'rolled back|original filenames were restored')
                self.assertEqual(self.snapshot(self.input), before)
                self.assertEqual(list(self.input.rglob('.randomise-filenames*')), [])
                self.assertEqual(list((self.home / 'bash-scripts-output').glob('*.map')), [])

    def write_map(self, records):
        def enc(value):
            return base64.b64encode(value.encode()).decode()
        path = self.work / 'undo.map'
        path.write_text('randomise-filenames-map-v1\nroot\t' + enc(str(self.input)) + '\n' +
                        ''.join('file\t' + enc(old) + '\t' + enc(new) + '\n'
                                for old, new in records))
        return path

    def test_random_failure_during_final_moves_restores_originals(self):
        self.populate()
        before = self.snapshot(self.input)
        self.bash('randomise-filenames.sh', '''
count=0
mv() {
    count=$((count + 1))
    if (( count == 6 )); then return 7; fi
    command mv "$@"
}
main "$1"
''', self.input, expected=7)
        self.assertEqual(self.snapshot(self.input), before)
        self.assertEqual(list(self.input.rglob('.randomise-filenames*')), [])
        self.assertEqual(list((self.home / 'bash-scripts-output').glob('*.map')), [])

    def test_termination_rolls_back_both_utilities(self):
        for script in ('randomise-filenames.sh', 'files-to-dash-case.sh'):
            with self.subTest(script=script):
                self.populate()
                (self.input / 'Another File.txt').write_text('another')
                before = self.snapshot(self.input)
                self.bash(script, '''
count=0
mv() {
    count=$((count + 1))
    if (( count == 2 )); then kill -TERM "$$"; fi
    command mv "$@"
}
main "$1"
''', self.input, expected=143)
                self.assertEqual(self.snapshot(self.input), before)
                self.assertEqual(list(self.input.rglob('.randomise-filenames*')), [])

    def test_incomplete_random_rollback_retains_map_and_all_file_contents(self):
        (self.input / 'First File.txt').write_text('first')
        (self.input / 'Second File.txt').write_text('second')
        result = self.bash('randomise-filenames.sh', '''
count=0
mv() {
    count=$((count + 1))
    if (( count == 2 || count == 3 )); then return 7; fi
    command mv "$@"
}
main "$1"
''', self.input, expected=7)
        self.assertIn('recovery was incomplete', result.stderr)
        self.assertIn('Recovery map:', result.stderr)
        maps = list((self.home / 'bash-scripts-output').glob('*.map'))
        self.assertEqual(len(maps), 1)
        self.assertEqual(sorted(self.snapshot(self.input).values()), [b'first', b'second'])
        self.assertTrue(list(self.input.rglob('.randomise-filenames*')))

    def test_reverse_rejects_unsafe_duplicate_missing_and_colliding_paths(self):
        (self.input / 'random.txt').write_text('random')
        (self.input / 'occupied.txt').write_text('occupied')
        outside = self.work / 'outside'
        outside.mkdir()
        (outside / 'keep.txt').write_text('outside')
        (self.input / 'link').symlink_to(outside, target_is_directory=True)
        for records, diagnostic in (
            ([('../escape', 'random.txt')], 'unsafe path'),
            ([('/absolute', 'random.txt')], 'unsafe path'),
            ([('link/keep.txt', 'random.txt')], 'escapes the map root'),
            ([('original', 'random.txt'), ('other', 'random.txt')], 'duplicate path'),
            ([('original', 'missing.txt')], 'file is missing'),
            ([('occupied.txt', 'random.txt')], 'destination already exists'),
        ):
            with self.subTest(records=records):
                before = self.snapshot(self.input)
                result = self.bash('randomise-filenames.sh', 'main --reverse "$1"',
                                   self.write_map(records), expected=1)
                self.assertIn(diagnostic, result.stderr)
                self.assertEqual(self.snapshot(self.input), before)
                self.assertEqual((outside / 'keep.txt').read_text(), 'outside')

    def test_reverse_rejects_malformed_map_without_renames(self):
        (self.input / 'keep.txt').write_text('keep')
        before = self.snapshot(self.input)
        path = self.work / 'bad.map'
        for text in ('', 'randomise-filenames-map-v1\nroot\t%%%\n',
                     'randomise-filenames-map-v1\nunknown\tvalue\n'):
            with self.subTest(text=text):
                path.write_text(text)
                self.bash('randomise-filenames.sh', 'main --reverse "$1"', path, expected=1)
                self.assertEqual(self.snapshot(self.input), before)

    def test_dash_case_recursive_names_and_collision(self):
        self.populate()
        (self.input / 'hello-world.txt').write_text('existing')
        self.bash('files-to-dash-case.sh', 'main --camel --recursive "$1"', self.input)
        self.assertEqual(self.snapshot(self.input), {
            'Hello World.TXT': b'contents 0', 'hello-world.txt': b'existing',
            '-leading.txt': b'contents 1', 'line\nbreak.txt': b'contents 2',
            'sub dir/http-server.json': b'contents 3',
        })

    def test_dash_case_conflicting_options_leave_files_unchanged(self):
        self.populate()
        before = self.snapshot(self.input)
        self.bash('files-to-dash-case.sh', 'main --lower --camel "$1"', self.input, expected=1)
        self.assertEqual(self.snapshot(self.input), before)
