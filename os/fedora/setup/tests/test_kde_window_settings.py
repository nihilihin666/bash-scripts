"""Isolated regression tests; never connect to a real desktop session.

Run: python3 -m unittest discover -s os/fedora/setup/tests -v
Node.js is used only by tests to execute the actual embedded Plasma JavaScript.
"""

import contextlib
import copy
import io
import json
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "fedora-setup-02-kde-settings.sh"
SOURCE = SCRIPT.read_text()
HELPER = SOURCE.split('  python3 - "$@" <<\'PY\'\n', 1)[1].split('\nPY\n}', 1)[0]
MODULE = types.ModuleType("kde_window_settings")
try:
    import dbus
except ImportError:
    # Test hosts need not have KDE or python3-dbus installed.
    dbus = types.SimpleNamespace(
        Array=lambda value, signature=None: list(value),
        Struct=lambda value, signature=None: tuple(value), UInt32=int)
with patch.dict("sys.modules", dbus=dbus):
    exec(compile(HELPER, str(SCRIPT) + ":embedded-python", "exec"), MODULE.__dict__)


def panel(types_, pid=10):
    return dict(id=pid, screen=0, location="bottom", formFactor="horizontal",
                locked=False, widgets=[dict(id=pid * 100 + i, type=t, index=i)
                                       for i, t in enumerate(types_)])


class FakeAccel:
    def __init__(self):
        self.bindings = {("kwin", name): [] for name in MODULE.TARGETS}
        self.bindings[("kwin", "Window Quick Tile Left")] = [(MODULE.META | MODULE.LEFT,), (123,)]
        self.bindings[("other", "chord")] = [(MODULE.META | MODULE.RIGHT, 42), (456,)]
        self.bindings[("other", "unrelated")] = [(999,)]
        self.calls = []

    def allMainComponents(self):
        return [[name, "", name, ""] for name in sorted({k[0] for k in self.bindings})]

    def allActionsForComponent(self, component):
        return [[c, a, c, a] for c, a in self.bindings if c == component[0]]

    def shortcutKeys(self, action):
        return [(list(k),) for k in self.bindings[tuple(action[:2])]]

    def setForeignShortcutKeys(self, action, wire):
        keys = MODULE.sequences(wire)
        self.bindings[tuple(action[:2])] = keys
        self.calls.append((tuple(action[:2]), keys))


# Model Plasma's widget-index setter, including its last-index clamp.
JS_HARNESS = r'''
const fs = require("fs");
const vm = require("vm");
const input = JSON.parse(fs.readFileSync(0, "utf8"));
let nextId = 100000;
const ps = input.panels.map(p => {
    let ws = p.widgets.map(w => ({id:w.id,type:w.type}));
    function wrap(w) {
        return {id:w.id,type:w.type,
            get index() {return ws.indexOf(w);},
            set index(i) {
                ws.splice(ws.indexOf(w),1);
                ws.splice(Math.min(Math.max(0,i),ws.length-1),0,w);
            },
            remove() {ws.splice(ws.indexOf(w),1);}
        };
    }
    return {...p, widgets:()=>ws.map(wrap),
        widgetById:id=>wrap(ws.find(w=>w.id===id)),
        addWidget:type=>{const w={id:nextId++,type};ws.push(w);return wrap(w);}
    };
});
const output = [];
const ctx = vm.createContext({panels:()=>ps, panelById:id=>ps.find(p=>p.id===id),
    knownWidgetTypes:input.knownWidgetTypes,
    print:s=>output.push(s)});
vm.runInContext(input.script,ctx);
process.stdout.write(JSON.stringify({output,
    panels:ps.map(p=>({...p,widgets:p.widgets().map(w=>({id:w.id,type:w.type,index:w.index}))}))}));
'''


class FakeKDE(MODULE.KDE):
    def __init__(self, count=1, panels=None):
        self.state = dict(desktops=[[i, "desktop-" + str(i), "My " + str(i)] for i in range(count)],
                          current="desktop-0", rows=2)
        self.accel = FakeAccel()
        self.panel_state = panels if panels is not None else [panel(["launcher", MODULE.TRAY, "clock"])]
        self.props = self
        self.vd = self
        self.desktop_calls = []
        self.known_widgets = [MODULE.PAGER, MODULE.TRAY]

    def GetAll(self, interface):
        return copy.deepcopy(self.state)

    def Set(self, interface, key, value):
        self.desktop_calls.append((key, value))
        self.state[key] = value

    def createDesktop(self, index, name):
        self.desktop_calls.append(("create", index))
        self.state["desktops"].append([int(index), "new-" + str(index), name or "Desktop " + str(index + 1)])

    def removeDesktop(self, ident):
        self.desktop_calls.append(("remove", ident))
        self.state["desktops"] = [d for d in self.state["desktops"] if d[1] != ident]

    def setDesktopName(self, ident, name):
        next(d for d in self.state["desktops"] if d[1] == ident)[2] = name

    def script(self, code):
        result = subprocess.run(["node", "-e", JS_HARNESS], text=True, capture_output=True,
                                input=json.dumps(dict(panels=self.panel_state, script=MODULE.PANEL_QUERY + code,
                                                      knownWidgetTypes=self.known_widgets)),
                                check=True)
        data = json.loads(result.stdout)
        self.panel_state = data["panels"]
        return json.loads(data["output"][0][6:])


@unittest.skipUnless(shutil.which("node"), "Node.js required for isolated Plasma scripting tests")
class WindowSettingsTests(unittest.TestCase):
    def setUp(self):
        self.signals = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}

    def tearDown(self):
        for sig, handler in self.signals.items():
            signal.signal(sig, handler)

    def apply(self, kde, reduce=False, panel_id=10, saved=None):
        saved = kde.inspect() if saved is None else saved
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            MODULE.apply(kde, saved, panel_id, reduce, directory)
            recovery = Path(directory) / "window-settings-live.json"
            self.assertEqual(json.loads(recovery.read_text()), saved)
            self.assertEqual(recovery.stat().st_mode & 0o777, 0o600)

    def test_apply_and_repeat_without_duplicates_or_extra_writes(self):
        kde = FakeKDE()
        self.apply(kde)
        self.assertEqual(len(kde.state["desktops"]), 3)
        self.assertEqual(kde.state["desktops"][0], [0, "desktop-0", "My 0"])
        self.assertEqual(kde.state["rows"], 1)
        self.assertEqual([w["type"] for w in kde.panel_state[0]["widgets"]],
                         ["launcher", MODULE.PAGER, MODULE.TRAY, "clock"])
        for action, key in MODULE.TARGETS.items():
            self.assertEqual(kde.accel.bindings[("kwin", action)], [(key,)])
        self.assertEqual(kde.accel.bindings[("kwin", "Window Quick Tile Left")], [(123,)])
        self.assertEqual(kde.accel.bindings[("other", "chord")], [(456,)])
        self.assertEqual(kde.accel.bindings[("other", "unrelated")], [(999,)])
        before = kde.inspect()
        kde.accel.calls.clear()
        kde.desktop_calls.clear()
        self.apply(kde)
        self.assertEqual(kde.inspect(), before)
        self.assertEqual(kde.accel.calls, [])
        self.assertEqual(kde.desktop_calls, [])

    def test_reuses_pager_on_either_side(self):
        for widgets in ([MODULE.PAGER, "tasks", MODULE.TRAY, "clock"],
                        ["tasks", MODULE.TRAY, "clock", MODULE.PAGER]):
            with self.subTest(widgets=widgets):
                kde = FakeKDE(panels=[panel(widgets)])
                ident = next(w["id"] for w in kde.panel_state[0]["widgets"] if w["type"] == MODULE.PAGER)
                self.apply(kde)
                ws = kde.panel_state[0]["widgets"]
                self.assertEqual([w["type"] for w in ws], ["tasks", MODULE.PAGER, MODULE.TRAY, "clock"])
                self.assertEqual(ws[1]["id"], ident)

    def test_extra_desktops_require_separate_consent(self):
        for reduce, expected in ((False, 5), (True, 3)):
            with self.subTest(reduce=reduce):
                kde = FakeKDE(count=5)
                self.apply(kde, reduce=reduce)
                self.assertEqual(len(kde.state["desktops"]), expected)
                self.assertEqual(kde.state["desktops"][:3], [[i, "desktop-" + str(i), "My " + str(i)] for i in range(3)])

    def test_missing_ambiguous_or_vertical_panel_is_not_eligible(self):
        candidates = [panel(["clock"]), panel([MODULE.TRAY, MODULE.TRAY]),
                      panel([MODULE.PAGER, MODULE.TRAY, MODULE.PAGER])]
        vertical = panel([MODULE.TRAY]); vertical["formFactor"] = "vertical"
        locked = panel([MODULE.TRAY]); locked["locked"] = True
        candidates += [vertical, locked]
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                kde = FakeKDE(panels=[candidate])
                before = copy.deepcopy(kde.panel_state)
                self.assertEqual(kde.inspect()["panels"], [])
                self.apply(kde, panel_id=-1)
                self.assertEqual(kde.panel_state, before)
                self.assertEqual(len(kde.state["desktops"]), 3)

    def test_failure_restores_shortcuts_panel_and_desktops(self):
        kde = FakeKDE()
        before = kde.inspect()
        real_change = kde.change_desktops
        calls = 0

        def fail_once(count):
            nonlocal calls
            calls += 1
            real_change(count)
            if calls == 1:
                raise RuntimeError("injected failure")

        with patch.object(kde, "change_desktops", side_effect=fail_once), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "injected failure"):
                self.apply(kde)
        self.assertEqual(kde.inspect(), before)

    def test_stale_snapshot_refuses_all_changes(self):
        kde = FakeKDE()
        saved = kde.inspect()
        kde.state["rows"] = 3
        before = kde.inspect()
        with self.assertRaisesRegex(RuntimeError, "changed during setup"):
            self.apply(kde, saved=saved)
        self.assertEqual(kde.inspect(), before)
        self.assertEqual(kde.accel.calls, [])

    def test_missing_pager_plugin_skips_panel(self):
        kde = FakeKDE()
        kde.known_widgets = []
        before = copy.deepcopy(kde.panel_state)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(kde.inspect()["panels"], [])
            self.apply(kde, panel_id=-1)
        self.assertEqual(kde.panel_state, before)

    def test_missing_kwin_action_refuses_inspection(self):
        kde = FakeKDE()
        del kde.accel.bindings[("kwin", "Window Minimize")]
        with self.assertRaisesRegex(RuntimeError, "Required KWin actions missing"):
            kde.inspect()
        self.assertEqual(kde.accel.calls, [])

    def test_partial_shortcut_failure_restores_existing_bindings(self):
        kde = FakeKDE()
        before = kde.inspect()
        setter = kde.set_shortcut
        calls = 0

        def fail_once(action, keys):
            nonlocal calls
            calls += 1
            setter(action, keys)
            if calls == 2:
                raise RuntimeError("injected shortcut failure")

        with patch.object(kde, "set_shortcut", side_effect=fail_once), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "injected shortcut failure"):
                self.apply(kde)
        self.assertEqual(kde.inspect(), before)

    def test_only_selected_panel_changes(self):
        kde = FakeKDE(panels=[panel([MODULE.TRAY], 10), panel(["tasks", MODULE.TRAY], 20)])
        other = copy.deepcopy(kde.panel_state[0])
        self.apply(kde, panel_id=20)
        self.assertEqual(kde.panel_state[0], other)
        self.assertEqual([w["type"] for w in kde.panel_state[1]["widgets"]],
                         ["tasks", MODULE.PAGER, MODULE.TRAY])


class ShellTests(unittest.TestCase):
    def test_declining_never_inspects_or_changes_window_settings(self):
        result = subprocess.run(["bash", "-c", r'''
source "$1"
window_settings_helper() { echo 'Unexpected helper invocation' >&2; exit 99; }
collect_window_settings_choice
configure_window_settings
[[ "$USE_WINDOW_SETTINGS" == 0 && "$WINDOW_SETTINGS_STATUS" == 'unchanged by choice' ]]
''', "test", str(SCRIPT)], input="\n", capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_help_and_dry_run_do_not_need_a_session(self):
        for option in ("--help", "--dry-run"):
            result = subprocess.run(["bash", str(SCRIPT), option], capture_output=True, text=True,
                                    env={"PATH": "/usr/bin:/bin"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("desktop", result.stdout)


if __name__ == "__main__":
    unittest.main()
