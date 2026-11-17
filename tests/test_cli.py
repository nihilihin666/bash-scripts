"""CLI checks that do not install tools or perform the scripts' operations."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CliTests(unittest.TestCase):
    def shell(self, script, code, expected=0):
        result = subprocess.run(
            ['bash', '-c', 'source "$1"\n' + code, 'test', str(ROOT / script)],
            text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_help_aliases_for_every_script(self):
        for script in sorted(ROOT.rglob('*.sh')):
            with self.subTest(script=script.relative_to(ROOT)):
                results = [subprocess.run(
                    ['bash', str(script), flag], text=True,
                    capture_output=True, timeout=10) for flag in ('--help', '-h')]
                for result in results:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('Usage:', result.stdout)
                    self.assertIn('--help', result.stdout)
                    self.assertIn('Show this help', result.stdout)
                self.assertEqual(results[0].stdout, results[1].stdout)

    def test_downloader_long_and_short_options(self):
        for audio, cookies in (('--audio-only', '--cookies-from-browser'), ('-a', '-c')):
            with self.subTest(audio=audio, cookies=cookies):
                self.shell('youtube-download.sh', f'''
parse_args {audio} {cookies} firefox https://example.com/video
[[ "$AUDIO_ONLY" == 1 && "$COOKIES_BROWSER" == firefox && "$URL" == https://example.com/video ]]
''')

    def test_downloader_cookie_option_requires_value(self):
        result = self.shell('youtube-download.sh', 'parse_args --cookies-from-browser', expected=1)
        self.assertIn('--cookies-from-browser requires a browser value', result.stderr)

    def test_prefix_value_is_a_separate_literal_argument(self):
        self.shell('randomise-filenames.sh', '''
parse_args --prefix 'some prefix=value' --no-manifest ./input
[[ "$PREFIX" == 'some prefix=value' && "$KEEP_MANIFEST" == 0 && "$DIR" == ./input ]]
''')
        result = self.shell('randomise-filenames.sh', 'parse_args --prefix=value ./input', expected=1)
        self.assertIn('unknown argument', result.stderr)

    def test_image_dash_case_dimensions_and_formats(self):
        for fmt in ('jpg', 'png', 'webp'):
            with self.subTest(fmt=fmt):
                self.shell('image.sh', f'''
parse_args --min-width 10 --min-height 20 --max-width 500 --max-height 600 --to-{fmt} input.png
[[ "$MIN_WIDTH" == 10 && "$MIN_HEIGHT" == 20 && "$MAX_WIDTH" == 500 && "$MAX_HEIGHT" == 600 && "$TARGET_FORMAT" == {fmt} ]]
''')


if __name__ == '__main__':
    unittest.main()
