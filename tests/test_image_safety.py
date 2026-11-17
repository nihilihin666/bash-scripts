"""Image decisions and safe replacement with mocked image tools."""
from support import ScriptTest


class ImageTests(ScriptTest):
    def test_proportional_dimensions_and_conflicting_constraints(self):
        for settings, expected in (
            ('', '1200 800 0'),
            ('MAX_WIDTH=600', '600 400 1'),
            ('MAX_HEIGHT=200', '300 200 1'),
            ('MIN_WIDTH=1800', '1800 1200 1'),
            ('MAX_WIDTH=100; MAX_HEIGHT=100', '100 67 1'),
        ):
            with self.subTest(settings=settings):
                result = self.bash('image.sh', settings + '\nsolve_dimensions 1200 800\n'
                                   'echo "$TARGET_WIDTH $TARGET_HEIGHT $NEEDS_RESIZE"')
                self.assertEqual(result.stdout.strip(), expected)
        self.bash('image.sh', 'MIN_WIDTH=1800\nMAX_HEIGHT=200\n'
                  'if solve_dimensions 1200 800; then exit 98; fi')

    def test_missing_dependencies_in_dry_run_never_install_or_write(self):
        result = self.bash('image.sh', '''
DRY_RUN=1
imagemagick_available() { return 1; }
exiv2_available() { return 1; }
detect_distribution() { DISTRO_ID=fedora; }
collect_missing_packages() { MISSING_PACKAGES=(ImageMagick exiv2); }
install_missing_packages() { echo unexpected-install >&2; exit 98; }
ensure_dependencies
''', expected=1)
        self.assertIn('[dry-run]', result.stdout)
        self.assertNotIn('unexpected-install', result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])

    def pipeline(self):
        source = self.work / 'source.png'
        source.write_bytes(b'original image')
        return source, '''
file="$1"
SOURCE_WIDTH=1200; SOURCE_HEIGHT=800; SOURCE_FORMAT=PNG
FRAME_COUNT=1; HAS_ALPHA=0; MAX_WIDTH=600
OVERWRITE=1; OUTPUT_FORMAT=PNG
COLOR_ACTION=none; COLOR_WARNING=''
color_action_for_file() { :; }
has_explicit_required_change() { REQUIRED_CHANGE=1; }
build_destination() { DESTINATION="$file"; }
build_magick_args() { MAGICK_ARGS=("$1"); }
fake_magick() { printf 'converted' > "${@: -1}"; }
MAGICK_CMD=(fake_magick)
clean_candidate_metadata() { return 0; }
'''

    def test_processing_dry_run_leaves_source_and_home_unchanged(self):
        source, setup = self.pipeline()
        self.bash('image.sh', setup + '''
DRY_RUN=1
make_temp_for_destination() { exit 98; }
process_supported_file "$file" source.png
[[ "$FILES_WOULD_CHANGE" == 1 && "$FILES_CHANGED" == 0 ]]
''', source)
        self.assertEqual(source.read_bytes(), b'original image')
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertEqual(list(self.work.glob('.source*')), [])

    def test_invalid_conversion_preserves_source_and_cleans_temporary(self):
        source, setup = self.pipeline()
        result = self.bash('image.sh', setup + '''
validate_candidate() { return 1; }
process_supported_file "$file" source.png
[[ "$FILES_FAILED" == 1 && "$FILES_CHANGED" == 0 && -z "$CURRENT_TMP" ]]
''', source)
        self.assertIn('failed validation', result.stderr)
        self.assertEqual(source.read_bytes(), b'original image')
        self.assertEqual(list(self.work.glob('.source*')), [])
        self.assertEqual(list(self.home.iterdir()), [])

    def test_backup_failure_prevents_replacement(self):
        source, setup = self.pipeline()
        result = self.bash('image.sh', setup + '''
validate_candidate() { return 0; }
backup_source() { return 1; }
process_supported_file "$file" source.png
[[ "$FILES_FAILED" == 1 && "$FILES_CHANGED" == 0 ]]
''', source)
        self.assertIn('Failed to back up', result.stderr)
        self.assertEqual(source.read_bytes(), b'original image')
        self.assertEqual(list(self.work.glob('.source*')), [])

    def test_destination_appearing_before_commit_is_preserved(self):
        source = self.work / 'source.png'
        candidate = self.work / 'candidate.png'
        destination = self.work / 'destination.png'
        source.write_bytes(b'original')
        candidate.write_bytes(b'converted')
        destination.write_bytes(b'existing')
        self.bash('image.sh', '''
if commit_candidate "$1" source.png "$2" "$3"; then exit 98; fi
''', source, candidate, destination)
        self.assertEqual(source.read_bytes(), b'original')
        self.assertEqual(candidate.read_bytes(), b'converted')
        self.assertEqual(destination.read_bytes(), b'existing')

    def test_candidate_validation_rejects_wrong_format_size_frames_and_alpha(self):
        candidate = self.work / 'candidate.png'
        candidate.write_bytes(b'fake image')
        for frames, info in (
            ('1', 'JPEG|600|400|false|'),
            ('1', 'PNG|601|400|false|'),
            ('1\n1', 'PNG|600|400|false|'),
            ('1', 'PNG|600|400|true|'),
        ):
            with self.subTest(frames=frames, info=info):
                self.bash('image.sh', '''
SOURCE_WIDTH=1200; SOURCE_HEIGHT=800
TARGET_WIDTH=600; TARGET_HEIGHT=400; OUTPUT_FORMAT=PNG
HAS_ALPHA=1; COLOR_ACTION=none
frames="$2"; info="$3"
identify_mock() {
    case "$*" in *'%m|'*) printf '%s' "$info";; *) printf '%s\n' "$frames";; esac
}
IDENTIFY_CMD=(identify_mock)
if validate_candidate "$1"; then exit 98; fi
''', candidate, frames, info)

    def test_valid_candidate_is_accepted_and_backed_up_before_replacement(self):
        source, setup = self.pipeline()
        self.bash('image.sh', setup + '''
identify_mock() {
    case "$*" in *'%m|'*) printf 'PNG|600|400|false|';; *) printf '1\n';; esac
}
IDENTIFY_CMD=(identify_mock)
process_supported_file "$file" source.png
[[ "$FILES_CHANGED" == 1 && "$FILES_FAILED" == 0 && "$BACKUPS_CREATED" == 1 ]]
''', source)
        self.assertEqual(source.read_bytes(), b'converted')
        backups = list((self.home / 'bash-scripts-output/image').rglob('source.png'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), b'original image')
