"""No block devices: test orchestration with fake discovery and verifiers.

Target identity/protection refusal propagation is exercised at the final write
boundary. These tests do not qualify actual storage discovery or hardware.
"""
from support import ScriptTest


class DiskWriterTests(ScriptTest):
    def setup_main(self):
        iso = self.work / 'image with spaces.iso'
        iso.write_bytes(b'ISO fixture')
        return iso, '''
require_command() { :; }
require_interactive_terminal() { :; }
discover_candidates() { :; }
choose_target() { TARGET=/mock/usb; TARGET_SIZE=10000; }
show_fdisk_details() { :; }
prompt_dd_options() { :; }
collect_mounts() { MOUNT_POINTS=(); }
verify_target() { printf 'verify\n' >> "$HOME/order"; }
'''

    def test_dry_run_does_not_unmount_or_write(self):
        iso, setup = self.setup_main()
        result = self.bash('os/dd.sh', setup + 'main --dry-run "$1"', iso)
        self.assertIn('no unmount or write', result.stdout)
        self.assertEqual((self.home / 'order').read_text(), 'verify\n')

    def test_final_verification_refusal_prevents_write(self):
        result = self.bash('os/dd.sh', '''
TARGET=/mock/usb
verify_target() { die 'target identity changed'; }
confirm_and_write
''', stdin='CREATE /mock/usb\n', expected=1)
        self.assertIn('target identity changed', result.stderr)
        self.assertNotIn('successfully', result.stdout)

    def test_missing_target_is_refused_before_discovery_commands(self):
        result = self.bash('os/dd.sh', 'TARGET=/mock/nonexistent\nverify_target', expected=1)
        self.assertIn('selected target disappeared', result.stderr)

    def test_active_swap_partition_is_refused(self):
        result = self.bash('os/dd.sh', '''
TARGET=/mock/usb
lsblk() { printf '/mock/usb\n/mock/usb1\n'; }
swapon() { printf '/dev/mock-swap\n'; }
readlink() {
    if [[ "${@: -1}" == /dev/mock-swap ]]; then echo /mock/usb1
    else printf '%s\n' "${@: -1}"; fi
}
verify_no_active_swap
''', expected=1)
        self.assertIn('active swap', result.stderr)

    def test_wrong_confirmation_cancels_before_verification(self):
        result = self.bash('os/dd.sh', '''
TARGET=/mock/usb
verify_target() { exit 98; }
confirm_and_write
''', stdin='yes\n')
        self.assertIn('Cancelled', result.stdout)

    def test_remount_after_confirmation_prevents_write(self):
        result = self.bash('os/dd.sh', '''
TARGET=/mock/usb
verify_target() { :; }
collect_mounts() { MOUNT_POINTS=(/mock/mounted); }
confirm_and_write
''', stdin='CREATE /mock/usb\n', expected=1)
        self.assertIn('mounted again', result.stderr)

    def test_write_failure_has_no_success_and_preserves_argument_boundaries(self):
        iso = self.work / 'image with spaces.iso'
        iso.write_bytes(b'ISO fixture')
        result = self.bash('os/dd.sh', '''
TARGET=/mock/usb; ISO_PATH="$1"
verify_target() { echo verified > "$HOME/verified"; }
collect_mounts() { MOUNT_POINTS=(); }
dd() {
    [[ -f "$HOME/verified" ]] || exit 98
    printf '%s\\0' "$@" > "$HOME/dd-args"
    return 7
}
confirm_and_write
''', iso, stdin='CREATE /mock/usb\n', expected=1)
        self.assertIn('may contain a partial image', result.stderr)
        self.assertNotIn('successfully', result.stdout)
        self.assertEqual((self.home / 'dd-args').read_bytes().split(b'\0')[:-1],
                         [f'if={iso}'.encode(), b'of=/mock/usb', b'bs=4M',
                          b'status=progress', b'conv=fsync'])
