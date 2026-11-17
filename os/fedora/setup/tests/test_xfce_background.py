"""Background confirmation tests; no live XFConf access."""
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "fedora-setup-02-xfce-settings.sh"


class BackgroundTests(unittest.TestCase):
    def run_background(self, answers, check):
        code = r'''
source "$1"
changes=()
run_as_user() {
  if [[ "$*" == 'xfconf-query -c xfce4-desktop -l' ]]; then
    echo /backdrop/screen0/monitorHDMI-1/workspace0/last-image
    echo /backdrop/screen0/monitorHDMI-1/workspace0/image-style
  else
    return 1
  fi
}
set_xfconf_int() { changes+=("$2=$3"); }
set_xfconf_rgba_black() { changes+=("$1=black"); }
''' + check
        result = subprocess.run(["bash", "-c", code, "test", str(SCRIPT)],
                                input=answers, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_no_enter_and_eof_do_not_access_wallpaper_settings(self):
        for answer in ("n\n", "\n", ""):
            with self.subTest(answer=answer):
                self.run_background(answer, r'''
run_as_user() { echo UNEXPECTED >&2; exit 99; }
configure_background
[[ "${#changes[@]}" == 0 ]]
''')

    def test_yes_changes_only_style_and_colour(self):
        self.run_background("y\n", r'''
configure_background
[[ "${#changes[@]}" == 3 ]]
[[ "${changes[0]}" == */image-style=0 ]]
[[ "${changes[1]}" == */color-style=0 ]]
[[ "${changes[2]}" == */rgba1=black ]]
''')

    def test_declining_on_repeat_does_not_reset_previous_settings(self):
        self.run_background("y\nn\n", r'''
configure_background
configure_background
[[ "${#changes[@]}" == 3 ]]
''')


if __name__ == "__main__":
    unittest.main()
