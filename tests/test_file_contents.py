"""Atomic combined listings on private text fixtures."""
from support import ScriptTest


class FileContentsTests(ScriptTest):
    def setUp(self):
        super().setUp()
        self.input = self.work / 'input'
        self.input.mkdir()

    def test_output_and_temporary_are_excluded_on_repeat(self):
        (self.input / '-leading\nfile.txt').write_text('unique source text')
        (self.input / 'empty.txt').touch()
        (self.input / 'binary.dat').write_bytes(b'\0binary')
        (self.input / 'skip.png').write_text('excluded image')
        for _ in range(2):
            self.bash('other/file-contents.sh', 'main "$1" combined.txt', self.input)
            output = (self.input / 'combined.txt').read_text()
            self.assertEqual(output.count('unique source text'), 1)
            self.assertIn('##### File: -leading\nfile.txt #####', output)
            self.assertIn('##### File: empty.txt #####', output)
            self.assertNotIn('File: combined.txt', output)
            self.assertNotIn('.combined.txt.tmp.', output)
            self.assertNotIn('binary', output)
            self.assertNotIn('excluded image', output)
        self.assertEqual(list(self.input.glob('.combined.txt.tmp.*')), [])

    def test_failed_generation_or_replacement_preserves_previous_output(self):
        (self.input / 'source.txt').write_text('source')
        output = self.input / 'combined.txt'
        output.write_text('previous complete output')
        for failure in ('generation', 'replacement'):
            with self.subTest(failure=failure):
                self.bash('other/file-contents.sh', '''
if [[ "$2" == generation ]]; then
    emit_contents() { printf 'partial output'; return 7; }
else
    mv() { return 7; }
fi
main "$1" combined.txt
''', self.input, failure, expected=7)
                self.assertEqual(output.read_text(), 'previous complete output')
                self.assertEqual(list(self.input.glob('.combined.txt.tmp.*')), [])

    def test_output_path_escape_is_rejected(self):
        result = self.bash('other/file-contents.sh', 'main "$1" ../outside.txt',
                           self.input, expected=1)
        self.assertIn('filename, not a path', result.stderr)
        self.assertFalse((self.work / 'outside.txt').exists())
