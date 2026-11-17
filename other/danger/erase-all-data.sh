#!/usr/bin/env bash
# One-drive Linux erasure assistant. Only ordinary, positively identified ATA
# HDDs are eligible for automatic overwrite. Hardware sanitization is manual.
# Bash bootstraps the session; the embedded Python helper handles structured
# discovery, retained descriptors, process supervision and exclusive TXT creation.
# Storage commands are external tools, never reimplementations of ATA/NVMe.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
export BLKID_FILE=/dev/null SYSTEMD_PAGER='' SYSTEMD_COLORS=0
unset CDPATH ENV BASH_ENV LIBMOUNT_FSTAB LIBMOUNT_MTAB LIBMOUNT_DEBUG LIBBLKID_DEBUG LSBLK_DEBUG LIBSMARTCOLS_DEBUG LIBSMARTCOLS_DEBUG_PADDING
umask 077

usage() {
  printf '%s\n' "Usage: sudo bash \"$0\"" \
       "       sudo bash \"$0\" --check" \
       "       bash \"$0\" --help" '

Interactive, one-drive-at-a-time zero overwrite of eligible physical ATA HDDs,
followed by complete direct-I/O read-back comparison. SSDs and uncertain devices
receive manual instructions. No hardware sanitization backend is enabled.
Automatic HDD erasure requires a native ATA/SATA connection. USB bridge scope
and flush semantics are not qualified; reconnect the HDD natively or use manual
instructions. USB external HDD/SSD targets can still receive instruction files.
HDDs advertising ATA SANITIZE also require manual handling until existing
sanitization/failure state can be checked through a qualified backend.

Prepare before the processing day: install the tools, arrange native SATA for
HDDs. Live USB and installed Linux sessions are supported. Automatic overwrite requires
unique identity, corroborated HDD identification, unrestricted accessible
capacity, no unresolved users/holders, and reliably protected boot/system/script
storage. Unsupported devices receive instructions; there is no override.

Version-one write scope: a working systemd/logind session, successful temporary
udisks2 inhibition, trusted root-owned /run tmpfs, resolved swap backing, kernel disk
sequence support, and an identified boot chain. HDD overwrite additionally needs
native libata connectivity and positive ATA rotation/capacity evidence. USB HDDs,
non-systemd environments and older devices without that evidence are manual-only.
Installed Linux is supported when system and boot storage can be resolved;
unresolved installed BIOS boot chains are refused. There is no Fedora version gate.

Success means ONLY: All accessible sectors overwritten and verified.
Inaccessible/retired sectors may retain data. This is not physical-sector proof.

--check     Read-only inventory and protection discovery; no erasure or mounting.
-h, --help  Show this help without examining storage.

Required: Bash, Python >=3.9, util-linux (lsblk/findmnt/losetup).
HDD backend: GNU dd, GNU cmp, smartctl, hdparm, systemctl, systemd-inhibit,
             pgrep, fuser, umount; kernel disk sequence numbers and direct I/O.
Optional TXT saving: mount/umount, e2fsck/dumpe2fs, fsck.fat, fsck.exfat,
                     ntfs-3g/ntfsinfo, according to the existing filesystem.
UEFI boot discovery needs efibootmgr. Unsupported boot topology blocks writes.
UEFI BootCurrent must identify one inventoried GPT/MBR partition. The EFI loader
and live image are protected independently. ISO-style, chainloaded or other layouts
without that evidence are refused even if the live-image USB was found. Qualify
the actual firmware mode and USB creation method before the processing day.
TXT: ext3 uses the ext4 driver; ext3/ext4 writable mounts retain internal journaling.
External journals, recovery-required filesystems and stored ext mount options
are refused. No conversion, repair or forced mounting is performed.

Release qualification is pending: static checks do not establish physical-drive
safety. Run the separate-machine validation suites and sacrificial-hardware
checklist in tests/RELEASE-CHECKLIST.txt before using this version on a real batch.

Fedora packages: python3 util-linux coreutils diffutils smartmontools hdparm
                systemd procps-ng psmisc efibootmgr e2fsprogs dosfstools exfatprogs ntfs-3g ntfsprogs
Debian/Ubuntu:  python3 util-linux coreutils diffutils smartmontools hdparm
                systemd procps psmisc efibootmgr e2fsprogs dosfstools exfatprogs ntfs-3g
Install tools BEFORE the drive-processing session. No automatic installation.

No persistent reports are created. Instructions can be saved only to the selected
unprotected target, never to flash sticks or other drives. All temporary storage
is verified tmpfs. Active swap is allowed; all physical swap backing is protected.
Zram with writeback also protects its backing drive. Swap is never disabled.
No report files are created, but memory/tmpfs contents may reach disk via swap.
Keep power connected. Do not disconnect/reconnect devices during an operation.
Ctrl+C cancels without a second confirmation. Interrupted drives are not cleared.
Exit status: 0 normal completion/cancellation, 2 failure/refusal, 3 manual procedure
required, 130 Ctrl+C. Any earlier failure remains a failure for the whole session;
otherwise any manual-only result remains status 3. q and end-of-input agree.
'
}
case "${1:-}" in
  -h|--help) [[ $# == 1 ]] || { usage >&2; exit 2; }; usage; exit 0 ;;
  ''|--check) [[ $# -le 1 ]] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
if [[ ${1:-} != --check ]]; then
  [[ -t 0 && -t 1 ]] || { printf 'Refused: interactive input and output required.\n' >&2; exit 2; }
  printf '%s\n' 'WARNING: this script can permanently erase every partition and all accessible data' \
    'on ONE selected drive. Selecting the wrong drive destroys data you intended to keep.'
  read -r -p 'Type CONTINUE to proceed: ' reply || exit 0
  [[ $reply == CONTINUE ]] || exit 0
fi
(( EUID == 0 )) || { printf 'Refused: run with sudo bash %q.\n' "$0" >&2; exit 2; }
missing=()
for tool in python3 lsblk findmnt losetup; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if ((${#missing[@]})); then
  printf 'Missing tools: %s\nInstall Python 3 and util-linux; see --help for packages.\n' "${missing[*]}" >&2
  exit 2
fi
# Read the embedded helper directly into Python memory. Executing a large Bash
# here-document can create a temporary file before any RAM/swap checks run.
# The data-only here-document below is never executed by Bash.
# Isolated Python ignores environment-supplied modules and PYTHONPATH.
exec python3 -I -c '
import pathlib, sys
source = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
marker = "\x3c\x3c\x27PY\x27\n"
begin = source.index(marker) + len(marker)
end = source.rindex("\nPY\n")
exec(compile("\n" * source[:begin].count("\n") + source[begin:end], sys.argv[2], "exec"))
' "${1:-interactive}" "${BASH_SOURCE[0]}"
exit 2
# shellcheck disable=SC2317
: <<'PY'
import array
import atexit
import contextlib
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import pathlib
import re
import resource
import shutil
import shlex
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

if sys.version_info < (3, 9):
    print('Refused: Python 3.9 or later is required.', file=sys.stderr)
    sys.exit(2)

# Linux block-device query ioctls from include/uapi/linux/fs.h. These are OS
# queries, not ATA/NVMe commands. Architectures with incompatible ioctl encoding
# fail closed rather than substituting a guessed capacity or identity.
BLKGETSIZE64 = 0x80081272
BLKGETDISKSEQ = 0x80081280
BLKSSZGET = 0x1268
NAME = '00-steps-to-fully-clear-this-drive.txt'
PHASE = 'inspection'
WRITE_STARTED = False
WRITE_FINISHED = False
VERIFIED = False
CURRENT_TARGET = None
OP_STARTED = None
LAST_BYTES = {}
TTY = None
SIGNAL_DEFER_DEPTH = 0
PENDING_SIGNAL = None
INTERRUPTING = False
REGISTERED_PROCS = {}
SCRIPT = os.path.realpath(sys.argv[2])
PSEUDO = {'proc', 'sysfs', 'devtmpfs', 'devpts', 'tmpfs', 'ramfs', 'cgroup',
          'cgroup2', 'securityfs', 'debugfs', 'tracefs', 'configfs', 'pstore',
          'efivarfs', 'mqueue', 'hugetlbfs', 'bpf', 'fusectl', 'binfmt_misc',
          'rpc_pipefs', 'selinuxfs', 'nsfs', 'autofs', 'fuse.portal',
          'fuse.gvfsd-fuse'}
COLS = ('KNAME,PATH,MAJ:MIN,PKNAME,TYPE,MODEL,SERIAL,WWN,SIZE,ROTA,TRAN,RO,RM,'
        'FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS,LOG-SEC,PHY-SEC,START')


class Refusal(Exception):
    pass


class Interrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum


def on_signal(signum, _frame):
    global PENDING_SIGNAL, INTERRUPTING
    if INTERRUPTING:
        return  # Repeated Ctrl+C must not interrupt the cancellation cleanup.
    if SIGNAL_DEFER_DEPTH:
        if PENDING_SIGNAL is None:
            PENDING_SIGNAL = signum
        return
    # A second signal at the deferral boundary supersedes an older pending one;
    # do not carry that older signal into otherwise uninterruptible cleanup.
    PENDING_SIGNAL = None
    INTERRUPTING = True
    raise Interrupted(signum)


@contextlib.contextmanager
def defer_signals():
    """Record interruption until a newly spawned child has an owned handle.

    Do not block the OS signal mask: workers must retain normal termination
    signals. Every use surrounds assignment inside a try/finally cleanup scope.
    """
    global SIGNAL_DEFER_DEPTH, PENDING_SIGNAL, INTERRUPTING
    SIGNAL_DEFER_DEPTH += 1
    try:
        yield
    finally:
        SIGNAL_DEFER_DEPTH -= 1
        if not SIGNAL_DEFER_DEPTH and PENDING_SIGNAL is not None:
            signum, PENDING_SIGNAL = PENDING_SIGNAL, None
            INTERRUPTING = True
            raise Interrupted(signum)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, on_signal)


def clean(value):
    text = str('unknown' if value is None else value)
    return text.encode('ascii', 'backslashreplace').decode('ascii').translate(
        {i: '\\x%02x' % i for i in range(32)} | {127: '\\x7f'})


def say(*values):
    print(' '.join(clean(v) for v in values), flush=True)


def display_text(text):
    for line in text.splitlines():
        say(line)


def ask(prompt):
    if TTY is None:
        raise Refusal('No interactive controlling terminal')
    print(prompt, end='', flush=True)
    line = TTY.readline()
    if not line:
        raise EOFError()
    return line.rstrip('\n')


def need(*tools):
    missing = [tool for tool in tools if not shutil.which(tool)]
    if missing:
        raise Refusal('Missing tools: ' + ', '.join(missing) + '; see --help for installation packages')


def run(args, timeout=30, check=True, pass_fds=(), stdin=None, stdout=subprocess.PIPE,
        text=True, env=None):
    # Never a shell. Timeouts apply to queries, not the multi-hour overwrite.
    proc = None
    try:
        with defer_signals():
            proc = subprocess.Popen(args, stdin=stdin, stdout=stdout,
                                    stderr=subprocess.PIPE, text=text,
                                    errors='backslashreplace' if text else None,
                                    pass_fds=pass_fds, start_new_session=True, env=env)
            register_process(proc)
        output, errors = proc.communicate(timeout=timeout)
        result = subprocess.CompletedProcess(args, proc.returncode, output, errors)
    except subprocess.TimeoutExpired as exc:
        raise Refusal('Command timed out after %ss: %s' % (timeout, shlex.join(args))) from exc
    finally:
        if proc is not None:
            handlers = {sig: signal.signal(sig, signal.SIG_IGN)
                        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
            try:
                stop_group(proc)
                for pipe in (proc.stdout, proc.stderr):
                    if pipe is not None:
                        pipe.close()
                unregister_process(proc)
            finally:
                for sig, handler in handlers.items():
                    signal.signal(sig, handler)
    if check and result.returncode:
        detail = result.stderr or result.stdout or ''
        if isinstance(detail, bytes):
            detail = detail.decode('ascii', 'backslashreplace')
        raise Refusal('Command %s failed (status %s): ' % (shlex.join(args), result.returncode) +
                      detail[-4000:])
    return result


def run_json(args):
    output = ''
    try:
        output = run(args).stdout
        data = json.loads(output)
        if not isinstance(data, dict):
            raise ValueError('Expected a JSON object, received ' + type(data).__name__)
        return data
    except (ValueError, KeyError) as exc:
        raise Refusal('Invalid JSON from %s: %s; output tail=%r' %
                      (shlex.join(args), exc, output[-1000:])) from exc


def flatten(rows):
    for row in rows:
        yield row
        yield from flatten(row.get('children', []))


def text_file(path):
    return pathlib.Path(path).read_text().strip()


def number_of(path):
    info = os.stat(path)
    if not stat.S_ISBLK(info.st_mode):
        raise Refusal('Expected a block device: ' + path)
    return '%d:%d' % (os.major(info.st_rdev), os.minor(info.st_rdev))


def swap_paths():
    # Kernel swap_show() octal-escapes space, tab, newline and backslash.
    # Read that interface directly rather than util-linux presentation output.
    # Decode once only: a literal filename containing "\\040" must stay literal.
    try:
        lines = pathlib.Path('/proc/swaps').read_bytes().decode(
            'utf-8', 'surrogateescape').split('\n')
    except OSError as exc:
        raise Refusal('Cannot read active swap inventory /proc/swaps: ' + str(exc)) from exc
    if not lines or lines[0].split() != ['Filename', 'Type', 'Size', 'Used', 'Priority']:
        raise Refusal('Unexpected /proc/swaps header: %r' % lines[:1])
    paths = []
    escapes = {'040': ' ', '011': '\t', '012': '\n', '134': '\\'}
    for line_number, line in enumerate(lines[1:], 2):
        if not line:
            continue
        match = re.fullmatch(r'([^ \t]+)[ \t]+(file|partition)[ \t]+([0-9]+)'
                             r'[ \t]+([0-9]+)[ \t]+(-?[0-9]+)', line)
        if not match:
            raise Refusal('Cannot parse /proc/swaps line %d: %r; swap backing must be resolved before writes' %
                          (line_number, line))
        encoded = match[1]
        if re.search(r'\\(?!040|011|012|134)', encoded):
            raise Refusal('Unknown kernel swap-name escape on /proc/swaps line %d: %r' %
                          (line_number, encoded))
        path = re.sub(r'\\(040|011|012|134)', lambda m: escapes[m[1]], encoded)
        if not path.startswith('/') or '\0' in path or path.endswith(' (deleted)'):
            raise Refusal('Active swap path cannot be resolved safely: %r (/proc/swaps line %d)' %
                          (path, line_number))
        if path in paths:
            raise Refusal('Duplicate active swap path in /proc/swaps: %r' % path)
        paths.append(path)
    return paths


def zram_backing(name):
    """Return None for established RAM-only zram, or its block backing path."""
    if not re.fullmatch(r'zram[0-9]+', name):
        raise Refusal('Ambiguous zram device name')
    node = pathlib.Path('/sys/class/block') / name
    try:
        physical = str(node.resolve(strict=True))
        if physical != '/sys/devices/virtual/block/' + name:
            raise Refusal('Swap is not established as a kernel zram device')
        try:
            backing = (node / 'backing_dev').read_text().removesuffix('\n')
        except FileNotFoundError:
            # On the verified kernel zram device, this sysfs attribute exists
            # exactly when CONFIG_ZRAM_WRITEBACK is enabled. No /proc/config.gz
            # dependency (Fedora need not expose its kernel config there).
            if str(node.resolve(strict=True)) != physical:
                raise Refusal('Zram disappeared while reading writeback state: ' + name)
            return None
        if backing == 'none':
            return None
        if not backing.startswith('/') or '\0' in backing or backing.endswith(' (deleted)'):
            raise Refusal('Zram %s backing device path is unresolved: %r' % (name, backing))
        number_of(backing)
        return backing
    except (OSError, EOFError, UnicodeError) as exc:
        raise Refusal('Cannot establish zram writeback state at %s/backing_dev: %s; '
                      'its physical backing must be resolved before writes' % (node, exc)) from exc


def require_runtime_directory():
    # Temporary files must use trusted /run. This does not guarantee that
    # memory stays off disk: swap is allowed and protected by Graph instead.
    mounts = list(flatten(run_json(['findmnt', '--json', '--target', '/run',
                                   '--output', 'TARGET,FSTYPE'])['filesystems']))
    if len(mounts) != 1 or mounts[0]['fstype'] != 'tmpfs':
        raise Refusal('/run must resolve to one tmpfs mount; observed: %r' % mounts)
    info = os.lstat('/run')
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise Refusal('/run must be a root-owned directory without group/other write permission; '
                      'observed uid=%s mode=%s' % (info.st_uid, oct(info.st_mode)))


def no_core_dumps():
    # Session instructions and inspection details must not become a persistent
    # core file if a tool/helper crashes. Children inherit the zero core limit.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = libc.prctl
    prctl.argtypes = [ctypes.c_int] + [ctypes.c_ulong] * 4
    prctl.restype = ctypes.c_int
    if prctl(4, 0, 0, 0, 0) != 0:  # PR_SET_DUMPABLE = 4
        raise Refusal('Could not disable persistent helper core dumps')


def failure_details(exc):
    """Console-only context, without executing additional storage commands."""
    say('Diagnostic: phase=', PHASE, '| exception=', type(exc).__name__,
        '| kernel=', os.uname().release, '| Python=', sys.version.split()[0])
    if CURRENT_TARGET is not None:
        say('Diagnostic target:', CURRENT_TARGET.get('path'), '| serial=', CURRENT_TARGET.get('serial'),
            '| major:minor=', CURRENT_TARGET.get('maj:min'), '| diskseq=', CURRENT_TARGET.get('diskseq'))
    say('Details are printed only; no diagnostic report was saved.')


class Graph:
    def __init__(self):
        rows = list(flatten(run_json(['lsblk', '--json', '--bytes', '--list',
                                     '--all', '--output', COLS])['blockdevices']))
        self.rows = {}
        for row in rows:
            name = row['kname']
            if not re.fullmatch(r'[A-Za-z0-9_.!+-]+', name):
                raise Refusal('Ambiguous kernel device name')
            if name in self.rows and self.rows[name] != row:
                raise Refusal('Conflicting block-device inventory')
            self.rows[name] = row
        self.by_number = {r['maj:min']: r['kname'] for r in self.rows.values()}
        self.mounts = list(flatten(run_json(['findmnt', '--json', '--kernel',
                            '--output', 'TARGET,SOURCE,FSTYPE,MAJ:MIN,OPTIONS'])['filesystems']))
        self.loops = None
        self.swaps = []
        self.protected = {}
        self.blockers = []
        self.boot_known = False
        self.live_media_known = False
        self.root_names = set()
        self.nvme_scopes = {}
        self.nvme_snapshots = {}
        try:
            self.discover_nvme_scopes()
        except (Refusal, OSError) as exc:
            self.blockers.append('NVMe physical scope is unresolved: ' + str(exc))
            # Unknown namespace ancestry must never leave a possible system
            # peer selectable, even for instruction-file saving.
            self.protect_names(self.nvme_names(), 'unresolved NVMe physical scope')
        self.build_protection()

    def nvme_names(self):
        return {name for name, row in self.rows.items() if row['type'] == 'disk'
                and (name.startswith('nvme') or row.get('tran') == 'nvme')}

    def discover_nvme_scopes(self):
        names = self.nvme_names()
        if not names:
            return
        groups = {}
        nqns = set()
        for node in sorted(pathlib.Path('/sys/class/nvme-subsystem').iterdir()):
            if not re.fullmatch(r'nvme-subsys[0-9]+', node.name):
                raise Refusal('Unexpected NVMe subsystem entry')
            physical = str(node.resolve(strict=True))
            if not physical.startswith('/sys/devices/'):
                raise Refusal('NVMe subsystem is outside device sysfs')
            nqn = text_file(node / 'subsysnqn')
            if not nqn or nqn in nqns:
                raise Refusal('Missing or duplicated NVMe subsystem identifier')
            nqns.add(nqn)
            controllers = []
            for link in sorted(node.iterdir()):
                if not re.fullmatch(r'nvme[0-9]+', link.name):
                    continue
                controller = str(link.resolve(strict=True))
                class_node = pathlib.Path('/sys/class/nvme') / link.name
                if (controller != str(class_node.resolve(strict=True)) or
                        not controller.startswith('/sys/devices/') or
                        text_file(class_node / 'subsysnqn') != nqn):
                    raise Refusal('Conflicting NVMe controller relationships')
                controllers.append({'name': link.name, 'path': controller,
                                    'serial': text_file(class_node / 'serial'),
                                    'model': text_file(class_node / 'model'),
                                    'transport': text_file(class_node / 'transport')})
            if not controllers:
                raise Refusal('NVMe subsystem has no resolved controllers')
            groups[physical] = {'subsystem': physical, 'nqn': nqn,
                                'controllers': controllers, 'members': []}
        for name in sorted(names):
            node = pathlib.Path('/sys/class/block') / name
            physical = str(node.resolve(strict=True))
            matches = [group for path, group in groups.items()
                       if physical.startswith(path + '/') or any(
                           physical.startswith(c['path'] + '/') for c in group['controllers'])]
            if len(matches) != 1:
                raise Refusal('Namespace has missing/ambiguous subsystem ancestry: ' + name)
            matches[0]['members'].append({'name': name, 'path': physical,
                                         'number': self.rows[name]['maj:min'],
                                         'diskseq': text_file(node / 'diskseq')})
        for group in groups.values():
            members = {member['name'] for member in group['members']}
            for name in members:
                self.nvme_scopes[name] = members
                self.nvme_snapshots[name] = group

    def protect_names(self, names, reason):
        for name in names:
            for member in self.nvme_scopes.get(name, {name}):
                self.protected.setdefault(member, set()).add(reason)

    def path_mount(self, path):
        rows = list(flatten(run_json(['findmnt', '--json', '--target', path,
                   '--output', 'TARGET,SOURCE,FSTYPE,MAJ:MIN,OPTIONS'])['filesystems']))
        if len(rows) != 1:
            raise Refusal('Ambiguous mount backing ' + path)
        return rows[0]

    def path_storage(self, path, seen=None):
        if not os.path.exists(path):
            raise Refusal('Backing path is missing: ' + path)
        return self.mount_storage(self.path_mount(os.path.realpath(path)), seen)

    def block_storage(self, name, seen=None):
        seen = set() if seen is None else set(seen)
        token = ('block', name)
        if token in seen or name not in self.rows:
            raise Refusal('Unresolved/cyclic storage relationship: ' + name)
        seen.add(token)
        row = self.rows[name]
        node = pathlib.Path('/sys/class/block') / name
        if row['type'] == 'part':
            if not row.get('pkname'):
                raise Refusal('Partition has no parent: ' + name)
            return self.block_storage(row['pkname'], seen)
        if re.fullmatch(r'zram[0-9]+', name):
            backing = zram_backing(name)
            if backing is None:
                return set()
            parent = self.by_number.get(number_of(backing))
            if parent is None:
                raise Refusal('Zram backing ancestry is unresolved')
            return self.block_storage(parent, seen)
        slaves = list((node / 'slaves').iterdir())
        if slaves:
            result = set()
            for slave in slaves:
                result |= self.block_storage(slave.name, seen)
            return result
        if row['type'] == 'loop':
            if self.loops is None:
                self.loops = run_json(['losetup', '--json', '--list', '--output',
                                      'NAME,BACK-FILE'])['loopdevices']
            matches = [r for r in self.loops if r['name'] == row['path']]
            if len(matches) != 1:
                raise Refusal('Loop backing file cannot be identified: ' + name)
            backing = matches[0].get('back-file', '')
            if not backing.startswith('/') or backing.endswith(' (deleted)'):
                raise Refusal('Loop %s has inaccessible/ambiguous backing file %r. '
                              'This live-image layout needs backing-device resolution; '
                              'its system storage cannot safely be guessed' % (name, backing))
            return self.path_storage(backing, seen)
        if row['type'] == 'disk':
            return {name}
        if row['type'] == 'rom':
            # Optical media cannot be a selectable/writable drive here.
            return set()
        raise Refusal('Unknown physical ancestry: ' + name)

    def mount_storage(self, mount, seen=None):
        seen = set() if seen is None else set(seen)
        token = ('mount', mount['target'])
        if token in seen:
            raise Refusal('Cyclic filesystem backing relationship')
        seen.add(token)
        fs = mount['fstype']
        if fs in PSEUDO:
            return set()
        if fs == 'overlay':
            opts = {}
            for option in mount.get('options', '').split(','):
                if '=' in option:
                    key, value = option.split('=', 1)
                    opts[key] = value
            if not opts.get('lowerdir'):
                raise Refusal('Overlay lower backing storage is unavailable')
            paths = opts['lowerdir'].split(':')
            paths += [opts[key] for key in ('upperdir', 'workdir') if key in opts]
            result = set()
            for path in paths:
                if not path.startswith('/') or '\\' in path:
                    raise Refusal('Escaped/relative overlay backing path is unsupported')
                result |= self.path_storage(path, seen)
            return result
        number = mount['maj:min']
        source = mount.get('source', '').split('[', 1)[0]
        if number not in self.by_number and source.startswith('/dev/'):
            number = number_of(source)
        name = self.by_number.get(number)
        if name is None:
            raise Refusal('No physical relationship for mount ' + mount['target'])
        if fs == 'btrfs':
            uuid = self.rows[name].get('uuid')
            if not uuid or not re.fullmatch(r'[A-Fa-f0-9-]+', uuid):
                raise Refusal('Btrfs filesystem identity is unknown')
            devices = pathlib.Path('/sys/fs/btrfs') / uuid / 'devices'
            result = set()
            entries = list(devices.iterdir())
            if not entries:
                raise Refusal('Btrfs physical members are unavailable')
            for device in entries:
                member = self.by_number.get((device / 'dev').read_text().strip())
                if member is None:
                    raise Refusal('Btrfs has an unresolved/missing physical member')
                result |= self.block_storage(member, seen)
            return result
        if fs in {'zfs', 'aufs'}:
            raise Refusal(fs + ' backing scope is unsupported')
        return self.block_storage(name, seen)

    def build_protection(self):
        roots = [m for m in self.mounts if m['target'] == '/']
        if len(roots) != 1:
            self.blockers.append('Running root mount is ambiguous')
        else:
            try:
                self.root_names = self.mount_storage(roots[0])
                self.protect_names(self.root_names, 'running root / live image')
            except (Refusal, OSError) as exc:
                self.blockers.append('Cannot resolve running root %r: %s' % (roots[0], exc))
        # Only conventional removable-data locations can be preparation targets.
        # Every other mounted physical filesystem is conservatively system storage.
        for mount in self.mounts:
            target = mount['target']
            external = any(target == p or target.startswith(p + '/')
                           for p in ('/mnt', '/media', '/run/media'))
            live = target in {'/run/initramfs/live', '/run/live/medium', '/cdrom',
                              '/lib/live/mount/medium', '/run/archiso/bootmnt'}
            if mount['fstype'] in PSEUDO:
                continue
            if not external or live:
                try:
                    names = self.mount_storage(mount)
                    self.protect_names(names, 'system/live mount ' + target)
                    if live and names:
                        self.boot_known = True
                        self.live_media_known = True
                except (Refusal, OSError) as exc:
                    self.blockers.append('Cannot resolve system/live mount %r: %s' % (mount, exc))
        try:
            self.protect_names(self.path_storage(SCRIPT), 'script storage (resolved symlinks)')
            # /boot can be a directory within root, even without a separate mount.
            if os.path.exists('/boot'):
                self.protect_names(self.path_storage('/boot'), 'boot files')
        except (Refusal, OSError) as exc:
            self.blockers.append(str(exc))
        # Loading an image into RAM or moving the script must not erase the
        # relationship to its original live medium. Resolve explicit live-root
        # references independently of currently mounted filesystem ancestry.
        cmdline = shlex.split(text_file('/proc/cmdline'))
        live_mode = any(arg.startswith('root=live:') or arg in
                        {'boot=live', 'rd.live.image', 'rd.live.image=1',
                         'rd.live.ram', 'rd.live.ram=1'} for arg in cmdline)
        for arg in cmdline:
            if not arg.startswith('root=live:'):
                continue
            source = arg[len('root=live:'):]
            try:
                keys = {'UUID': 'uuid', 'LABEL': 'label', 'CDLABEL': 'label', 'PARTUUID': 'partuuid'}
                key, separator, value = source.partition('=')
                if separator and key in keys:
                    matches = [r for r in self.rows.values() if r.get(keys[key]) == value]
                    if not matches:
                        raise Refusal('Original live boot medium is missing/unresolved')
                    names = set()
                    for row in matches:
                        names |= self.block_storage(row['kname'])
                    if len(names) != 1:
                        raise Refusal('Live boot identifier resolves to ambiguous physical media')
                elif source.startswith('/dev/'):
                    name = self.by_number.get(number_of(source))
                    if not name:
                        raise Refusal('Live root block source is missing')
                    names = self.block_storage(name)
                    if not names:
                        raise Refusal('Live root source has no identified physical medium')
                else:
                    raise Refusal('Live root reference is unsupported')
                self.protect_names(names, 'original live boot medium from kernel command line')
                self.live_media_known = self.boot_known = True
            except (Refusal, OSError) as exc:
                self.blockers.append(str(exc))
        if live_mode and not self.live_media_known and not self.root_names:
            self.blockers.append('RAM-loaded live image has no resolved original boot medium')
        # Resolve configured system filesystems, including unmounted boot/EFI.
        # An unmounted optional data disk in fstab is not part of the running OS.
        # Mounted filesystems and active swap are protected independently.
        if os.path.exists('/etc/fstab'):
            result = run(['findmnt', '--fstab', '--evaluate', '--json', '--output',
                          'TARGET,SOURCE,FSTYPE'], check=False)
            if result.returncode not in (0, 1):
                self.blockers.append('Configured system filesystems cannot be inspected')
            elif result.stdout.strip():
                entries = json.loads(result.stdout).get('filesystems', [])
                for entry in flatten(entries):
                    source = entry.get('source', '').split('[', 1)[0]
                    target = entry.get('target', '')
                    system_paths = ('/usr', '/boot', '/efi', '/etc', '/var', '/home',
                                    '/opt', '/srv', '/bin', '/sbin', '/lib', '/lib64')
                    if target != '/' and not any(target == p or target.startswith(p + '/')
                                                 for p in system_paths):
                        continue
                    if source.startswith('/dev/') and os.path.exists(source):
                        try:
                            name = self.by_number.get(number_of(source))
                            if name is None:
                                raise Refusal('Configured drive is missing from inventory')
                            self.protect_names(self.block_storage(name), 'configured filesystem ' + target)
                            if entry.get('fstype') == 'btrfs':
                                uuid = self.rows[name].get('uuid')
                                if not uuid:
                                    raise Refusal('Configured Btrfs member identities are unavailable')
                                for member in self.rows.values():
                                    if member.get('uuid') == uuid:
                                        self.protect_names(self.block_storage(member['kname']),
                                                           'configured Btrfs member ' + target)
                        except (Refusal, OSError) as exc:
                            self.blockers.append(str(exc))
                    elif target in {'/', '/usr', '/boot', '/boot/efi', '/efi'} and entry.get('fstype') not in PSEUDO:
                        self.blockers.append('Configured system/boot source is unresolved: ' + target)
        # BIOS boot chains cannot generally be reconstructed from mounted root.
        # A live image backed by identified boot media is sufficient; otherwise
        # resolve the firmware's actual BootCurrent GPT partition on UEFI.
        if os.path.isdir('/sys/firmware/efi'):
            if shutil.which('efibootmgr'):
                try:
                    result = run(['efibootmgr', '-v'])
                    current = re.search(r'^BootCurrent:\s*([0-9A-Fa-f]{4})\s*$', result.stdout, re.M)
                    if not current:
                        raise Refusal('UEFI BootCurrent is unavailable; efibootmgr -v output tail=%r' %
                                      result.stdout[-1000:])
                    entry = re.search(r'^Boot' + current[1] + r'\*?\s+(.*)$', result.stdout, re.M | re.I)
                    guid = re.search(r'HD\([^,]+,GPT,([A-Fa-f0-9-]+),', entry[1] if entry else '')
                    mbr = re.search(r'HD\((\d+),MBR,(?:0x)?([A-Fa-f0-9]+),', entry[1] if entry else '')
                    if guid:
                        partuuid = guid[1].lower()
                    elif mbr:
                        partuuid = '%08x-%02x' % (int(mbr[2], 16), int(mbr[1]))
                    else:
                        raise Refusal('UEFI BootCurrent=%s has no identifiable GPT/MBR partition; entry=%r. '
                                      'ISO/CDROM and chainloaded layouts need a supported boot resolver' %
                                      (current[1], entry[1] if entry else None))
                    matches = [r for r in self.rows.values()
                               if (r.get('partuuid') or '').lower() == partuuid]
                    if len(matches) != 1:
                        raise Refusal('UEFI BootCurrent=%s partition identity=%s matched %d inventory entries: %r' %
                                      (current[1], partuuid, len(matches),
                                       [r['path'] for r in matches]))
                    self.protect_names(self.block_storage(matches[0]['kname']), 'UEFI current boot storage')
                    self.boot_known = True
                except (Refusal, OSError) as exc:
                    # A live image and its EFI loader can reside on different
                    # drives. Identifying one never authorizes guessing the other.
                    self.blockers.append(str(exc))
            else:
                self.blockers.append('efibootmgr is required to protect UEFI boot media')
        if not self.boot_known:
            self.blockers.append('Boot media cannot be reliably identified (unresolved BIOS/live/firmware chain)')
        if not self.root_names and not self.boot_known:
            self.blockers.append('RAM/live root has no identified physical boot backing')
        try:
            self.swaps = swap_paths()
        except (Refusal, OSError) as exc:
            self.blockers.append('Active swap inventory is unresolved: ' + str(exc))
        for path in self.swaps:
            try:
                info = os.stat(path)
                if stat.S_ISBLK(info.st_mode):
                    name = self.by_number.get(number_of(path))
                    if name is None:
                        raise Refusal('Swap block ancestry is unresolved')
                    names = self.block_storage(name)
                elif stat.S_ISREG(info.st_mode):
                    names = self.path_storage(path)
                else:
                    raise Refusal('Expected a block device or regular swap file; mode=' + oct(info.st_mode))
                self.protect_names(names, 'active swap storage ' + repr(path))
            except (Refusal, OSError) as exc:
                self.blockers.append('Cannot resolve active swap %r: %s' % (path, exc))
        self.blockers = sorted(set(self.blockers))

    def drive(self, name):
        if name not in self.rows or self.rows[name]['type'] != 'disk':
            raise Refusal('Selected physical drive disappeared')
        row = dict(self.rows[name])
        node = pathlib.Path('/sys/class/block') / name
        row['physical_path'] = os.path.realpath(node)
        row['diskseq'] = text_file(node / 'diskseq') if (node / 'diskseq').exists() else None
        row['zoned'] = text_file(node / 'queue/zoned') if (node / 'queue/zoned').exists() else 'unknown'
        row['vendor'] = text_file(node / 'device/vendor') if (node / 'device/vendor').exists() else 'unknown'
        row['parts'] = sorted([dict(r) for r in self.rows.values()
                               if r.get('pkname') == name and r['type'] == 'part'], key=lambda r: r['kname'])
        row['holders'] = {}
        for part in [row] + row['parts']:
            row['holders'][part['kname']] = sorted(p.name for p in
                    (pathlib.Path('/sys/class/block') / part['kname'] / 'holders').iterdir())
        row['protected'] = sorted(self.protected.get(name, []))
        row['nvme_scope'] = self.nvme_snapshots.get(name)
        return row

    def candidates(self):
        return [self.drive(name) for name, row in sorted(self.rows.items())
                if row['type'] == 'disk' and name not in self.protected
                and not re.fullmatch(r'zram[0-9]+', name)]

    def target_mounts(self, target):
        numbers = {r['maj:min'] for r in [target] + target['parts']}
        result = []
        for mount in self.mounts:
            number = mount['maj:min']
            source = mount.get('source', '').split('[', 1)[0]
            if number not in self.by_number and source.startswith('/dev/'):
                try:
                    number = number_of(source)
                except (Refusal, OSError):
                    pass
            if number in numbers:
                result.append(mount)
        return result


def fingerprint(row, partitions=True):
    keys = ('path', 'kname', 'maj:min', 'model', 'serial', 'wwn', 'size',
            'log-sec', 'phy-sec', 'tran', 'ro', 'rota', 'diskseq', 'physical_path', 'zoned',
            'nvme_scope')
    value = {key: row.get(key) for key in keys}
    if partitions:
        value['parts'] = [{key: p.get(key) for key in
                          ('path', 'kname', 'maj:min', 'start', 'size', 'uuid', 'partuuid', 'fstype')}
                          for p in row['parts']]
    return value


def revalidate(target, require_idle=False, partitions=True):
    graph = Graph()
    if graph.blockers:
        raise Refusal('Protection is unresolved: ' + '; '.join(graph.blockers))
    fresh = graph.drive(target['kname'])
    if fresh['protected']:
        raise Refusal('Target is protected: ' + '; '.join(fresh['protected']))
    if fingerprint(fresh, partitions=partitions) != fingerprint(target, partitions=partitions):
        before = fingerprint(target, partitions=partitions)
        after = fingerprint(fresh, partitions=partitions)
        changed = {key: {'confirmed': before[key], 'current': after[key]}
                   for key in before if before[key] != after[key]}
        raise Refusal('Identity, capacity or topology changed for %s; inspect and confirm again. Changes: %r' %
                      (target['path'], changed))
    if any(fresh['holders'].values()):
        raise Refusal('Target has active storage holders: ' + str(fresh['holders']))
    if require_idle and graph.target_mounts(fresh):
        raise Refusal('Target %s is still mounted: %r' % (target['path'], graph.target_mounts(fresh)))
    require_runtime_directory()
    return graph, fresh


def describe(row):
    size = int(row.get('size') or 0)
    say('Drive:', row.get('model'), '| serial:', row.get('serial'), '| WWN:', row.get('wwn'))
    say('  Vendor:', row['vendor'], '| capacity: %.3f GB / %.3f TB' % (size / 1e9, size / 1e12), '| exact bytes:', size)
    say('  Path:', row['path'], '| transport:', row.get('tran'), '| rotational hint:', row.get('rota'))
    say('  Read-only:', row.get('ro'), '| removable:', row.get('rm'), '| generation:', row.get('diskseq'))
    say('  Logical / physical sector bytes:', row.get('log-sec'), '/', row.get('phy-sec'), '| zoned:', row['zoned'])
    say('  Physical connection:', row['physical_path'])
    if row.get('nvme_scope'):
        say('  NVMe subsystem:', row['nvme_scope']['nqn'], '| namespace peers:',
            [m['name'] for m in row['nvme_scope']['members']])
    say('  Partitions:', len(row['parts']), '| holders:', row['holders'])
    for part in [row] + row['parts']:
        say('  Filesystem:', part['path'], part.get('fstype'), '| label:', part.get('label'), '| mounts:', part.get('mountpoints'))


def inventory(graph):
    say('')
    say('Active swap entries:', graph.swaps or '(none resolved)', '| unresolved backing blocks writes')
    if graph.swaps:
        say('Swap remains enabled. Session memory and tmpfs may be written to swap; no report file is created.')
    say('Protected drives (never selectable):')
    for name in sorted(graph.protected):
        if graph.rows[name]['type'] == 'disk':
            row = graph.drive(name)
            describe(row)
            for reason in row['protected']:
                say('  Protected:', reason)
    if graph.blockers:
        say('')
        say('Automatic operations blocked:')
        for blocker in graph.blockers:
            say(' ', blocker)
        say('Inspection/manual instructions remain available for unprotected candidates.')
    say('')
    say('Select one physical drive:')
    candidates = graph.candidates()
    for i, row in enumerate(candidates, 1):
        say('[%d]' % i)
        describe(row)
    if not candidates:
        say('No unprotected physical drives available.')
    return candidates


def inspection(target, graph):
    info = {'reasons': list(graph.blockers), 'smart': None, 'ata': '', 'hpa': '',
            'dco': '', 'media': 'unknown', 'eligible': False, 'stable': False,
            'media_identity': False}
    size = int(target.get('size') or 0)
    if not target.get('diskseq'):
        info['reasons'].append('Kernel disk sequence identity is unavailable')
    if target['physical_path'].startswith('/sys/devices/virtual/'):
        info['reasons'].append('Virtual/opaque storage arrangement')
    if target.get('ro'):
        info['reasons'].append('Drive is read-only')
    if target['zoned'] != 'none':
        info['reasons'].append('Zoned or unknown write semantics')
    if any(target['holders'].values()):
        info['reasons'].append('RAID/LVM/device-mapper or other holders are active')
    if target.get('tran') not in {'sata', 'ata', 'usb'}:
        info['reasons'].append('Transport is not supported by the ordinary ATA HDD backend')
    if target.get('tran') == 'usb':
        info['reasons'].append('USB bridge scope/flush semantics are not qualified; reconnect through native SATA for automatic HDD overwrite')
    elif target.get('tran') in {'sata', 'ata'} and not re.search(r'/ata[0-9]+/', target['physical_path']):
        info['reasons'].append('A native libata physical connection is not established; controller write semantics are uncertain')
    sector = int(target.get('log-sec') or 0)
    physical = int(target.get('phy-sec') or 0)
    if sector not in (512, 1024, 2048, 4096) or physical < sector or physical > 4096 or physical & (physical - 1) or size <= 0 or size % sector:
        info['reasons'].append('Unsupported/ambiguous capacity or sector alignment')
    serial, wwn = target.get('serial'), target.get('wwn')
    disks = [r for r in graph.rows.values() if r['type'] == 'disk']
    unique_serial = bool(serial and sum(r.get('serial') == serial for r in disks) == 1)
    unique_wwn = bool(wwn and sum(r.get('wwn') == wwn for r in disks) == 1)
    info['stable'] = unique_serial or unique_wwn
    info['unique_serial'] = unique_serial
    if not info['stable']:
        info['reasons'].append('No unique serial or WWN; identity remains ambiguous')
    say('')
    say('Read-only health/capability inspection (may wake a sleeping drive):')
    if shutil.which('smartctl'):
        result = run(['smartctl', '--json', '--all', target['path']], timeout=60, check=False)
        try:
            smart = json.loads(result.stdout)
            info['smart'] = smart
            for key in ('model_name', 'serial_number', 'firmware_version', 'rotation_rate',
                        'user_capacity', 'smart_status', 'temperature', 'power_on_time',
                        'nvme_smart_health_information_log', 'ata_security',
                        'ata_smart_data'):
                if key in smart:
                    say(' ', key + ':', smart[key])
            table = smart.get('ata_smart_attributes', {}).get('table', [])
            for attr in table:
                if attr.get('id') in (5, 9, 187, 188, 194, 197, 198, 199, 202, 231, 233):
                    say('  SMART attribute:', attr.get('name'), attr.get('raw'), '| failing:', attr.get('when_failed'))
            if smart.get('ata_smart_error_log'):
                say('  ATA error history:', smart['ata_smart_error_log'])
            rotation = smart.get('rotation_rate')
            protocol = smart.get('device', {}).get('protocol')
            if protocol == 'ATA' and isinstance(rotation, int) and 3600 <= rotation <= 20000:
                info['media'] = 'HDD'
            elif protocol == 'NVMe' or (protocol == 'ATA' and rotation == 0):
                info['media'] = 'SSD'
            if result.returncode & 7:
                info['reasons'].append('SMART identification/transport queries failed')
            if smart.get('serial_number', '').strip() != (serial or '').strip():
                info['reasons'].append('SMART and inventory serial identity disagree')
            if smart.get('user_capacity', {}).get('bytes') != size:
                info['reasons'].append('SMART and kernel capacities disagree')
            info['media_identity'] = bool(serial and
                smart.get('serial_number', '').strip() == serial.strip() and
                smart.get('user_capacity', {}).get('bytes') == size and
                not result.returncode & 7)
            if smart.get('smart_status', {}).get('passed') is not True:
                info['reasons'].append('SMART health is failing or unknown; reuse suitability is uncertain')
            for attr in table:
                if attr.get('id') in (197, 198) and attr.get('raw', {}).get('value', 0) != 0:
                    info['reasons'].append('Pending/uncorrectable sectors: do not release without reliable sanitization')
        except (ValueError, TypeError, AttributeError) as exc:
            info['reasons'].append('SMART structured information could not be interpreted')
            say('  SMART detail unavailable:', exc)
    else:
        info['reasons'].append('smartctl is missing (install smartmontools)')
    if info['media'] != 'HDD':
        info['reasons'].append('Drive is SSD or is not positively identified as an ordinary HDD')
    if info['media'] == 'HDD' and shutil.which('hdparm'):
        ident = run(['hdparm', '-I', target['path']], timeout=60, check=False)
        info['ata'] = ident.stdout
        display_text(ident.stdout + ident.stderr)
        rate = re.search(r'Nominal Media Rotation Rate:\s*(\d+)', ident.stdout)
        if ident.returncode or not rate or int(rate[1]) != info['smart'].get('rotation_rate'):
            info['reasons'].append('ATA identification does not corroborate the HDD rotation rate')
        sec = re.search(r'^Security:\s*\n(.*?)(?:\n\S|\Z)', ident.stdout, re.M | re.S)
        if not sec:
            info['reasons'].append('ATA security state is unknown')
        else:
            for state in ('enabled', 'locked'):
                if not re.search(r'^\s*not\s+' + state + r'\s*$', sec[1], re.M):
                    info['reasons'].append('ATA security is enabled, locked or uncertain')
            # Frozen security-command state does not require intervention for
            # logical overwrite. Never unlock/unfreeze it or submit secure erase.
        hpa = run(['hdparm', '-N', target['path']], timeout=60, check=False)
        info['hpa'] = hpa.stdout
        display_text(hpa.stdout + hpa.stderr)
        counts = re.search(r'max sectors\s*=\s*(\d+)\s*/\s*(\d+)', hpa.stdout)
        if hpa.returncode or not counts or int(counts[1]) != int(counts[2]) or int(counts[1]) * sector != size:
            info['reasons'].append('Native capacity/HPA coverage is restricted or unknown')
        if re.search(r'Device Configuration Overlay', ident.stdout, re.I):
            dco = run(['hdparm', '--dco-identify', target['path']], timeout=60, check=False)
            info['dco'] = dco.stdout
            display_text(dco.stdout + dco.stderr)
            count = re.search(r'Real max sectors:\s*(\d+)', dco.stdout, re.I)
            if dco.returncode or 'DCO Checksum verified.' not in dco.stdout or not count or int(count[1]) * sector != size:
                info['reasons'].append('DCO capacity coverage is restricted or unknown')
        if re.search(r'\bSANITIZE feature set\b', ident.stdout, re.I):
            # SANITIZE STATUS EXT can affect failure-mode state on some ATA
            # revisions. Do not silently send it as a supposedly inert query.
            info['reasons'].append('ATA SANITIZE state is unresolved by a qualified read-only backend; use a vendor-qualified manual procedure. Repeating confirmation or reconnecting through SATA does not establish an idle state')
    elif info['media'] == 'HDD':
        info['reasons'].append('hdparm is missing; native-capacity and ATA restrictions cannot be checked')
    elif info['smart'] and info['smart'].get('device', {}).get('protocol') == 'ATA' and shutil.which('hdparm'):
        ident = run(['hdparm', '-I', target['path']], timeout=60, check=False)
        info['ata'] = ident.stdout
        display_text(ident.stdout + ident.stderr)
    if info['smart'] and info['smart'].get('device', {}).get('protocol') == 'NVMe' and shutil.which('nvme'):
        version = run(['nvme', '--version'], check=False).stdout
        major = re.search(r'\bversion\s+(\d+)', version, re.I)
        commands = [['nvme', 'id', 'ctrl'], ['nvme', 'log', 'sanitize']] if major and int(major[1]) >= 3 else [['nvme', 'id-ctrl'], ['nvme', 'sanitize-log']]
        for command in commands:
            result = run(command + [target['path'], '--output-format=json'], check=False)
            say('Read-only NVMe query:', ' '.join(command), '| exit:', result.returncode)
            display_text(result.stdout + result.stderr)
        say('NVMe hardware operations remain manual; controller/subsystem scope must be resolved separately.')
    for tool in ('dd', 'cmp', 'systemctl', 'systemd-inhibit', 'pgrep', 'fuser', 'umount'):
        if not shutil.which(tool):
            info['reasons'].append('Required HDD backend tool missing: ' + tool)
    for tool in ('dd', 'cmp'):
        if shutil.which(tool) and 'GNU' not in run([tool, '--version'], check=False).stdout:
            info['reasons'].append('GNU ' + tool + ' is required for exact-range semantics')
    fresh = Graph().drive(target['kname'])
    if fingerprint(fresh) != fingerprint(target):
        raise Refusal('Device identity or topology changed during inspection; refresh required')
    info['reasons'] = sorted(set(info['reasons']))
    info['eligible'] = not info['reasons']
    say('')
    say('Storage type:', info['media'])
    say('Health information describes drive condition; it is not erasure evidence.')
    if info['eligible']:
        say('Recommendation: whole-device zero overwrite plus full direct-I/O read-back verification.')
        say('Coverage: accessible logical sectors only. Retired/inaccessible physical sectors may retain data.')
    else:
        say('Recommendation: manual procedure required.')
        for reason in info['reasons']:
            say(' ', reason)
    return info


def method_fingerprint(info):
    smart = info.get('smart') or {}
    return {'media': info['media'], 'stable': info['stable'],
            'unique_serial': info['unique_serial'],
            'identity': {key: smart.get(key) for key in
                         ('model_name', 'serial_number', 'firmware_version',
                          'rotation_rate', 'user_capacity', 'ata_security')},
            'ata': info['ata'], 'hpa': info['hpa'], 'dco': info['dco']}


def stop_group(proc):
    if proc is None or proc.poll() is not None:
        return
    # An unreaped child cannot have its PID reused. Never signal a reaped PID:
    # that group number could already belong to an unrelated process.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        say('Waiting for pending device I/O; cancellation cannot bypass kernel I/O.')
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()


def register_process(proc):
    # Called only while spawn signals are deferred, before the owning scope can
    # be interrupted. Retain a final cleanup handle even if a local finally is
    # interrupted before it starts.
    REGISTERED_PROCS[id(proc)] = proc


def unregister_process(proc):
    if proc.poll() is not None:
        REGISTERED_PROCS.pop(id(proc), None)


def cleanup_registered_processes(exclude=()):
    global INTERRUPTING
    previous = INTERRUPTING
    INTERRUPTING = True
    errors = []
    try:
        for proc in reversed(list(REGISTERED_PROCS.values())):
            if any(proc is item for item in exclude):
                continue
            try:
                stop_group(proc)
                for pipe in (proc.stdout, proc.stderr):
                    if pipe is not None:
                        pipe.close()
                unregister_process(proc)
            except (OSError, subprocess.SubprocessError) as exc:
                errors.append('Child cleanup failed: ' + str(exc))
    finally:
        INTERRUPTING = previous
    return errors


# Also covers uncaught Python exceptions; SIGKILL/power loss cannot be cleaned
# up by any userspace script and must always leave completion unknown.
atexit.register(cleanup_registered_processes)


class Preparation:
    def __init__(self):
        self.masked = False
        self.mask_inode = None
        self.restart = False
        self.inhibitor = None

    def __enter__(self):
        try:
            need('systemctl', 'systemd-inhibit', 'pgrep', 'umount')
            require_runtime_directory()
            with defer_signals():
                self.inhibitor = subprocess.Popen([
                    'systemd-inhibit', '--what=sleep:idle', '--mode=block',
                    '--who=erase-all-data', '--why=Drive erase or instruction save in progress',
                    'sh', '-c', 'printf "READY\\n"; exec sleep infinity'],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                register_process(self.inhibitor)
            # A bounded readiness handshake: the child runs only after the
            # inhibitor is acquired. Do not assume Popen success means inhibition.
            import selectors
            selector = selectors.DefaultSelector()
            selector.register(self.inhibitor.stdout, selectors.EVENT_READ)
            try:
                if not selector.select(15) or self.inhibitor.stdout.readline() != b'READY\n':
                    raise Refusal('Could not establish a suspend inhibitor')
            finally:
                selector.close()
            self.inhibit_automount()
            say('Desktop udisks automount and automatic sleep are inhibited for this operation.')
            return self
        except BaseException:
            handlers = {sig: signal.signal(sig, signal.SIG_IGN)
                        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
            try:
                self.cleanup()
            finally:
                for sig, handler in handlers.items():
                    signal.signal(sig, handler)
            raise

    def inhibit_automount(self):
        state = self.unit_state()
        self.restart = state.get('ActiveState') == 'active'
        if state.get('ActiveState') not in {'active', 'inactive', 'failed'}:
            raise Refusal('udisks2 is transitioning or its state is unknown: %r' % state)
        if state.get('LoadState') not in {'loaded', 'masked', 'not-found'}:
            raise Refusal('udisks2 unit load state is unsupported: %r' % state)
        if state.get('LoadState') != 'masked':
            mask = '/run/systemd/system/udisks2.service'
            if os.path.lexists(mask):
                raise Refusal('Unexpected pre-existing runtime udisks2 unit')
            # Record intent before mutation, so partial command failure also
            # restores any runtime mask that was actually created.
            self.masked = True
            run(['systemctl', 'mask', '--runtime', 'udisks2.service'], timeout=60)
            self.mask_inode = os.lstat(mask).st_ino
            # A missing service needs only a mask. Stopping a nonexistent
            # unit can fail despite automount already being absent.
            if state.get('LoadState') != 'not-found':
                run(['systemctl', 'stop', 'udisks2.service'], timeout=60)
        state = self.unit_state()
        if state.get('LoadState') != 'masked' or state.get('ActiveState') != 'inactive':
            raise Refusal('Desktop automount inhibition could not be established; expected masked/inactive, observed %r' % state)
        processes = run(['pgrep', '-x', 'udisksd'], check=False)
        if processes.returncode != 1:
            raise Refusal('udisksd absence is unconfirmed: pgrep status=%s stdout=%r stderr=%r' %
                          (processes.returncode, processes.stdout, processes.stderr))

    def unit_state(self):
        result = run(['systemctl', 'show', 'udisks2.service', '--property=LoadState',
                      '--property=ActiveState', '--property=UnitFileState'])
        return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)

    def check(self):
        if self.inhibitor is None or self.inhibitor.poll() is not None:
            raise Refusal('Suspend inhibition was lost')

    def cleanup(self):
        # Stop any leftover operation child before restoring desktop access.
        errors = cleanup_registered_processes(exclude=(self.inhibitor,))
        if self.masked:
            mask = '/run/systemd/system/udisks2.service'
            try:
                if os.path.lexists(mask):
                    info = os.lstat(mask)
                    if not stat.S_ISLNK(info.st_mode) or os.readlink(mask) != '/dev/null' or (self.mask_inode is not None and info.st_ino != self.mask_inode):
                        raise Refusal('Runtime automount mask changed; refusing to remove an unfamiliar unit')
                    run(['systemctl', 'unmask', '--runtime', 'udisks2.service'], timeout=60)
                if self.restart:
                    run(['systemctl', 'start', 'udisks2.service'], timeout=60)
            except (Refusal, OSError) as exc:
                errors.append(str(exc))
            self.masked = False
        try:
            stop_group(self.inhibitor)
            if self.inhibitor is not None:
                for pipe in (self.inhibitor.stdout, self.inhibitor.stderr):
                    if pipe is not None:
                        pipe.close()
                unregister_process(self.inhibitor)
        except OSError as exc:
            errors.append(str(exc))
        self.inhibitor = None
        for error in errors:
            say('Cleanup failure:', error)
        return errors

    def __exit__(self, kind, _value, _trace):
        # A second Ctrl+C must not abandon restoration or leave a worker running.
        handlers = {sig: signal.signal(sig, signal.SIG_IGN)
                    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        try:
            errors = self.cleanup()
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
        if errors and kind is None:
            raise Refusal('Operation finished, but session settings could not be restored')
        return False


def unmount_target(target):
    graph, fresh = revalidate(target)
    mounts = graph.target_mounts(fresh)
    for mount in sorted(mounts, key=lambda m: len(m['target']), reverse=True):
        if not any(mount['target'] == p or mount['target'].startswith(p + '/')
                   for p in ('/mnt', '/media', '/run/media')):
            raise Refusal('Target has a system/unfamiliar mount: ' + mount['target'])
        say('Cleanly unmounting:', mount['target'])
        run(['umount', '-n', '--', mount['target']], timeout=120)
    # No force, lazy unmount, swapoff, RAID teardown or LVM deactivation.
    return revalidate(target, require_idle=True)


def ioctl_value(fd, request, code):
    value = array.array(code, [0])
    fcntl.ioctl(fd, request, value, True)
    return int(value[0])


def check_raw_users(target, allowed=()):
    need('fuser')
    paths = [r['path'] for r in [target] + target['parts']]
    result = run(['fuser', '--'] + paths, timeout=15, check=False)
    if result.returncode not in (0, 1):
        raise Refusal('Cannot establish raw-device users: ' + result.stderr)
    if re.search(r'Permission denied|Cannot (?:stat|open|access)', result.stderr, re.I):
        raise Refusal('Raw-device user visibility is incomplete: ' + result.stderr)
    try:
        users = {int(value) for value in result.stdout.split()}
    except ValueError as exc:
        raise Refusal('Raw-device user output is ambiguous') from exc
    if result.returncode == 0 and not users:
        raise Refusal('Raw-device usage is reported without identifiable processes')
    unexpected = users - set(allowed)
    if unexpected:
        raise Refusal('Other processes have the target open: ' + str(sorted(unexpected)))


def check_bound(fd, target):
    info = os.fstat(fd)
    expected = tuple(int(n) for n in target['maj:min'].split(':'))
    if not stat.S_ISBLK(info.st_mode) or (os.major(info.st_rdev), os.minor(info.st_rdev)) != expected:
        raise Refusal('Opened handle is not the confirmed block device')
    if ioctl_value(fd, BLKGETDISKSEQ, 'Q') != int(target['diskseq']):
        raise Refusal('Opened device generation changed')
    if ioctl_value(fd, BLKGETSIZE64, 'Q') != int(target['size']):
        raise Refusal('Opened device capacity changed')
    if ioctl_value(fd, BLKSSZGET, 'I') != int(target['log-sec']):
        raise Refusal('Opened logical sector size changed')
    node = pathlib.Path('/sys/class/block') / target['kname']
    if os.path.realpath(node) != target['physical_path'] or text_file(node / 'diskseq') != target['diskseq']:
        raise Refusal('Device disconnected or its path was reassigned')
    if int(text_file(node / 'size')) * 512 != int(target['size']) or text_file(node / 'ro') != '0':
        raise Refusal('Device capacity or read-only state changed')


@contextlib.contextmanager
def exclusive_drive(target):
    # O_EXCL is a Linux block-device claim, in addition to advisory flock.
    # The same open file description is inherited by every dd worker. Neither
    # overwrite nor verification reopens a /dev path after confirmation.
    fd = os.open(target['path'], os.O_RDWR | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        check_bound(fd, target)
        yield fd
    finally:
        os.close(fd)


def check_filesystem_bound(fd, part, target, parent_fd):
    check_bound(parent_fd, target)
    if part['kname'] == target['kname']:
        check_bound(fd, target)
        return
    expected = tuple(int(n) for n in part['maj:min'].split(':'))
    info = os.fstat(fd)
    if not stat.S_ISBLK(info.st_mode) or (os.major(info.st_rdev), os.minor(info.st_rdev)) != expected:
        raise Refusal('Filesystem handle is not the selected partition')
    if (ioctl_value(fd, BLKGETDISKSEQ, 'Q') != int(target['diskseq']) or
            ioctl_value(fd, BLKGETSIZE64, 'Q') != int(part['size']) or
            ioctl_value(fd, BLKSSZGET, 'I') != int(target['log-sec'])):
        raise Refusal('Filesystem generation, capacity or sector size changed')
    node = pathlib.Path('/sys/class/block') / part['kname']
    if (part.get('type') != 'part' or part.get('pkname') != target['kname'] or
            os.path.realpath(node) != target['physical_path'] + '/' + part['kname'] or
            number_of(part['path']) != part['maj:min'] or
            int(text_file(node / 'size')) * 512 != int(part['size']) or
            part.get('start') is None or int(text_file(node / 'start')) != int(part['start']) or
            text_file(node / 'ro') != '0'):
        raise Refusal('Filesystem partition relationship or extent changed')


@contextlib.contextmanager
def exclusive_filesystem(part, target, parent_fd):
    # A kernel block claim keeps other mounts/claimants out during unmounted
    # checks. Read-only checker children inherit this exact device descriptor.
    # O_EXCL does not block arbitrary privileged raw I/O; fuser checks remain
    # required and unrelated storage programs must not run during this session.
    fd = None
    try:
        with defer_signals():
            fd = os.open(part['path'], os.O_RDONLY | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC)
        # For a whole-disk filesystem the parent descriptor already owns the
        # flock; another open-file description would conflict with our own lock.
        if part['kname'] != target['kname']:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        check_filesystem_bound(fd, part, target, parent_fd)
        yield fd
        check_filesystem_bound(fd, part, target, parent_fd)
    finally:
        if fd is not None:
            os.close(fd)


def preflight_direct_read(fd, target):
    sector, size = int(target['log-sec']), int(target['size'])
    for offset in (0, size - sector):
        check_bound(fd, target)
        os.lseek(fd, offset, os.SEEK_SET)
        result = run(['dd', 'bs=%d' % sector, 'count=1',
                      'iflag=direct,fullblock', 'status=none'], stdin=fd,
                     stdout=subprocess.DEVNULL, text=False, timeout=60, check=False)
        if result.returncode or os.lseek(fd, 0, os.SEEK_CUR) != offset + sector:
            raise Refusal('Direct read preflight failed; no overwrite started: ' +
                          result.stderr.decode('ascii', 'backslashreplace'))
    os.lseek(fd, 0, os.SEEK_SET)


def progress(phase, done, expected, start):
    elapsed = max(time.monotonic() - start, 0.001)
    rate = done / elapsed
    remaining = (expected - done) / rate if rate > 0 else None
    eta = '%dm %02ds' % divmod(int(remaining), 60) if remaining is not None else 'unknown'
    print('\r%s: %d / %d bytes (%.2f%%), elapsed %dm %02ds, ETA %s   ' %
          (phase, done, expected, 100 * done / expected,
           int(elapsed) // 60, int(elapsed) % 60, eta), end='', flush=True)


def monitor(procs, fd, target, prep, phase):
    expected = int(target['size'])
    start = time.monotonic()
    next_users = 0
    while any(p.poll() is None for p in procs):
        check_bound(fd, target)
        prep.check()
        if time.monotonic() >= next_users:
            check_raw_users(target, [os.getpid()] + [p.pid for p in procs])
            # The overwrite itself destroys partition/FS metadata. Recheck
            # immutable drive identity and all current protection/usage, rather
            # than requiring the original partition table to survive erasure.
            revalidate(target, require_idle=True, partitions=False)
            next_users = time.monotonic() + 5
        done = os.lseek(fd, 0, os.SEEK_CUR)
        LAST_BYTES[phase] = done
        if not 0 <= done <= expected:
            raise Refusal('Worker exceeded the confirmed byte range')
        progress(phase, done, expected, start)
        if any(p.poll() not in (None, 0) for p in procs):
            raise Refusal('%s worker failed: transferred=%s expected=%s workers=%r' %
                          (phase, done, expected, [(p.pid, p.poll()) for p in procs]))
        time.sleep(1)
    check_bound(fd, target)
    done = os.lseek(fd, 0, os.SEEK_CUR)
    LAST_BYTES[phase] = done
    progress(phase, done, expected, start)
    print(flush=True)
    if done != expected or any(p.returncode != 0 for p in procs):
        raise Refusal('%s incomplete: transferred=%s expected=%s worker statuses=%r' %
                      (phase, done, expected, [(p.pid, p.returncode) for p in procs]))


def finish_workers(procs):
    handlers = {sig: signal.signal(sig, signal.SIG_IGN)
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        for proc in procs:
            stop_group(proc)
            if proc.stderr is not None:
                raw = proc.stderr.read()
                if raw:
                    display_text(raw.decode('ascii', 'backslashreplace'))
                proc.stderr.close()
            if proc.stdout is not None:
                proc.stdout.close()
            unregister_process(proc)
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


def hdd_backend(target, inspection_info, prep):
    global PHASE, WRITE_STARTED, WRITE_FINISHED, VERIFIED
    if not inspection_info['eligible']:
        raise Refusal('Backend eligibility was not established')
    unmount_target(target)
    check_raw_users(target)
    with exclusive_drive(target) as fd:
        revalidate(target, require_idle=True)
        check_bound(fd, target)
        preflight_direct_read(fd, target)
        prep.check()
        require_runtime_directory()
        size = int(target['size'])
        PHASE = 'overwrite'
        WRITE_STARTED = True  # conservative: even a spawn failure is not success
        writer = None
        try:
            with defer_signals():
                writer = subprocess.Popen(['dd', 'if=/dev/zero', 'bs=4194304',
                    'count=%d' % size, 'iflag=count_bytes,fullblock', 'oflag=direct',
                    'conv=notrunc,fsync', 'status=none'], stdout=fd,
                    stderr=subprocess.PIPE, start_new_session=True)
                register_process(writer)
            monitor([writer], fd, target, prep, 'Overwrite')
            os.fsync(fd)
            check_bound(fd, target)
            WRITE_FINISHED = True
        finally:
            if writer is not None:
                finish_workers([writer])
        # Direct I/O on the retained device handle avoids verifying only the
        # Linux page cache. No buffered fallback is allowed.
        PHASE = 'verification'
        os.lseek(fd, 0, os.SEEK_SET)
        reader = comparator = None
        try:
            with defer_signals():
                reader = subprocess.Popen(['dd', 'bs=4194304', 'count=%d' % size,
                    'iflag=direct,fullblock,count_bytes', 'status=none'], stdin=fd,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                register_process(reader)
            with defer_signals():
                comparator = subprocess.Popen(['cmp', '--bytes=%d' % size, '--', '-', '/dev/zero'],
                    stdin=reader.stdout, stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE, start_new_session=True)
                register_process(comparator)
            reader.stdout.close()
            monitor([reader, comparator], fd, target, prep, 'Verification')
            os.fsync(fd)
            check_bound(fd, target)
            if os.lseek(fd, 0, os.SEEK_CUR) != size:
                raise Refusal('Verification byte count disagrees with accessible size')
            VERIFIED = True
        finally:
            if reader is not None and reader.stdout is not None and not reader.stdout.closed:
                reader.stdout.close()
            finish_workers([p for p in (reader, comparator) if p is not None])
    PHASE = 'result'


def confirmation(target, info):
    say('')
    say('FINAL DESTRUCTIVE OPERATION SUMMARY')
    describe(target)
    say('Affected storage: the entire selected physical drive and every partition,', target['size'], 'accessible bytes.')
    say('Method: one zero overwrite. Verification: complete direct-I/O read-back compared byte-for-byte with zero.')
    say('Limitations: inaccessible retired sectors may retain data; this does not certify every physical sector.')
    say('All existing data within this scope will be permanently lost.')
    say('Keep power connected. Ctrl+C stops the worker; pending I/O may delay cleanup.')
    say('Interrupted overwrite is incomplete. Interrupted verification means overwrite completed but verification incomplete.')
    if info['unique_serial'] and re.fullmatch(r'[A-Za-z0-9_.:+-]+', target.get('serial') or ''):
        challenge = 'ERASE ' + target['serial']
    else:
        digest = hashlib.sha256(json.dumps(fingerprint(target), sort_keys=True).encode()).hexdigest()[:12].upper()
        challenge = 'ERASE ' + target['kname'] + '-' + str(target['size']) + '-' + digest
    say('Required confirmation:', challenge)
    return ask('Type that exact confirmation, or anything else to cancel: ') == challenge


def instructions(target, info):
    fields = '\n'.join('  %s: %s' % (key, clean(target.get(key))) for key in
                       ('path', 'model', 'serial', 'wwn', 'size', 'tran', 'physical_path', 'diskseq'))
    reasons = '\n'.join('  - ' + clean(r) for r in info['reasons']) or '  - Automatic operation was declined by the operator.'
    return '''MANUAL PROCEDURE REQUIRED — NO ERASURE CERTIFICATE
Selected drive identity (device paths may change):
%s
Storage type: %s
Why automatic erasure is unavailable or was declined:
%s

Preparation and connection requirements:
1. Back up anything you intend to keep. Read the physical drive label and match
   model, serial/WWN, capacity and connection. Never rely on /dev/sdX alone.
2. Shut down before changing connections. Isolate the target from other data
   drives and boot trusted media that is not the target. Use native SATA/NVMe
   when the vendor tool requires it; USB bridges may not pass erase commands.
3. Reconfirm identity and scope. Stop for mounts, swap, RAID/LVM holders, locked
   security or hidden-capacity restrictions. Never force-unmount, repair, unlock,
   unfreeze or alter capacity just to get past a refusal.

Recommended method:
For a confirmed ordinary HDD, reconnect through a supported native connection
and rerun this script when the listed blockers are resolved. It can zero every
accessible logical sector and perform full direct-I/O read-back verification.
Retired or hidden sectors may remain inaccessible to an ordinary overwrite.

For SSD/NVMe media, obtain the exact model's documented vendor sanitization
utility or an independently qualified protocol-specific backend. Consult the
vendor instructions for this exact model and firmware. Prefer supported block
sanitization. Do not infer crypto-erase coverage from an encryption capability.
No generic hardware command is supplied because its coverage has not been
qualified. Identify ALL affected namespaces/controllers/subsystem storage and
protect boot/system/script drives before following the vendor procedure.

Confirmation and completion:
Confirm the physical drive identity and the procedure's affected scope before
submitting any destructive command. Record sanitization status before submission
and monitor the NEW operation until documented successful completion and all
required checks pass. Submission success is not completion. Hardware-erased reads
need not return zeros. Health statistics are separate from erasure evidence.
For an overwrite, require the exact full byte count, flush completion, complete
read-back and no errors, short reads or mismatches. This proves accessible-sector
coverage only, not complete physical-media sanitization.

Failure/interruption:
Do not release a drive with write/read errors, mismatches or unknown completion.
An interrupted overwrite is incomplete. An interrupted hardware monitor may
leave the drive erasing internally. Reconfirm identity before checking again;
never automatically resume or switch destructive methods. If the drive is too
faulty to sanitize or inaccessible-sector coverage matters, arrange professional
physical destruction suitable for its media and the sensitivity of its data.

Formatting, partition deletion, wipefs and ordinary discard/TRIM are not substitutes.
Do not initialise a new partition table/filesystem until erasure is established.

Remaining uncertainty: vendor-specific sanitization scope and physical-sector
coverage have not been established by these instructions. Resolve every blocker
above. This document itself is stored on the target and will be lost when erased.
''' % (fields, clean(info['media']), reasons)


def ext_metadata(path, fs, pass_fds=()):
    # dumpe2fs -h reads this filesystem's superblock/internal journal only.
    # Refuse external journal references BEFORE e2fsck or a journaled mount
    # can open another drive. Duplicate fields are ambiguous, not evidence.
    need('dumpe2fs')
    header = run(['dumpe2fs', '-h', path], timeout=60, pass_fds=pass_fds).stdout
    def field(name, required=False):
        values = re.findall(r'^' + re.escape(name) + r':[ \t]*(.*)$', header, re.M)
        if len(values) > 1 or (required and len(values) != 1):
            raise Refusal('Missing or ambiguous ext filesystem metadata: ' + name)
        return values[0].strip() if values else None
    state = field('Filesystem state', required=True)
    features = set(field('Filesystem features', required=True).split())
    if state != 'clean' or 'needs_recovery' in features:
        raise Refusal('Filesystem is dirty, needs journal recovery or has unknown state')
    if ('journal_dev' in features or field('Journal UUID') is not None or
            field('Journal device') is not None):
        raise Refusal('External journals are unsupported: saving must affect only the selected target')
    # A stored kernel option string can redirect a journal or disable safety
    # options. Do not silently apply settings supplied by the target filesystem.
    if field('Mount options') not in (None, '', '(none)'):
        raise Refusal('Stored ext filesystem mount options cannot be safely admitted for TXT saving')
    inode = field('Journal inode')
    if fs in {'ext3', 'ext4'}:
        if 'has_journal' not in features or not inode or not re.fullmatch(r'[1-9][0-9]*', inode):
            raise Refusal('A supported internal ext journal was not established')
    elif 'has_journal' in features or inode is not None:
        raise Refusal('Journaled filesystem does not match the selected ext2 type')


def fs_clean(path, fs, pass_fds=()):
    # Every checker is explicitly non-repairing; never use -a/-p/-y or ntfsfix.
    if fs in {'ext2', 'ext3', 'ext4'}:
        need('dumpe2fs', 'e2fsck')
        ext_metadata(path, fs, pass_fds=pass_fds)
        say('Checking existing filesystem without repairs; this can take time.')
        # System e2fsck.conf can enable log files (even with -n), and inherited
        # debug/test-I/O variables can redirect I/O. Use a minimal environment
        # and an empty configuration rather than writing on unrelated storage.
        checker_env = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C',
                       'BLKID_FILE': '/dev/null', 'E2FSCK_CONFIG': '/dev/null'}
        result = run(['e2fsck', '-f', '-n', path], timeout=None, check=False,
                     pass_fds=pass_fds, env=checker_env)
        if result.returncode:
            raise Refusal('Read-only filesystem check did not establish a clean filesystem: ' + result.stdout + result.stderr)
    elif fs == 'vfat':
        need('fsck.fat')
        result = run(['fsck.fat', '-n', path], timeout=None, check=False, pass_fds=pass_fds)
        text = result.stdout + result.stderr
        if result.returncode or re.search(r'dirty bit is set|corrupt|unrecoverable|read error', text, re.I):
            raise Refusal('FAT filesystem is dirty or inconsistent: ' + text)
    elif fs == 'exfat':
        need('fsck.exfat')
        result = run(['fsck.exfat', '-n', path], timeout=None, check=False, pass_fds=pass_fds)
        text = result.stdout + result.stderr
        if result.returncode or re.search(r'dirty|corrupt(?:ed)?\s*[:=]\s*[1-9]|read error', text, re.I):
            raise Refusal('exFAT filesystem is dirty or inconsistent: ' + text)
    elif fs == 'ntfs':
        need('ntfs-3g', 'ntfs-3g.probe', 'ntfsinfo')
        # The read-write probe can perform metadata updates. Only a read-only
        # probe and volume/journal metadata query are permitted as checks.
        run(['ntfs-3g.probe', '--readonly', path], timeout=60, pass_fds=pass_fds)
        metadata = run(['ntfsinfo', '-m', path], timeout=60, pass_fds=pass_fds).stdout
        flags = re.search(r'Volume Flags:\s*0x([A-Fa-f0-9]+)', metadata)
        restart = re.search(r'Restart state:\s*(\S+)', metadata)
        if not flags or int(flags[1], 16) != 0 or not restart or restart[1] != 'CLEAN':
            raise Refusal('NTFS volume/journal state is dirty, restricted or unknown')
        # The actual mount below uses norecover and must remain writable;
        # hibernation/Fast Startup must be rejected by the NTFS driver.
    else:
        raise Refusal('Filesystem is not on the TXT-saving allowlist')


def require_volatile_mtab():
    try:
        if not os.path.samefile('/etc/mtab', '/proc/self/mounts'):
            raise Refusal('NTFS saving requires /etc/mtab to reference the volatile kernel mount table')
    except OSError as exc:
        raise Refusal('Cannot establish a volatile NTFS mount table: ' + str(exc)) from exc


def mount_fs(path, destination, fs, readonly=False, before_mount=None):
    flags = ['ro' if readonly else 'rw', 'nodev', 'nosuid', 'noexec', 'noatime']
    driver = 'ext4' if fs == 'ext3' else fs
    if fs in {'ext2', 'ext3', 'ext4'}:
        ext_metadata(path, fs)
    if fs in {'ext3', 'ext4'}:
        if readonly:
            flags += ['noload']
        else:
            flags += ['data=ordered', 'barrier=1', 'errors=remount-ro', 'noinit_itable', 'nodiscard']
    if fs == 'ntfs':
        # FUSE helpers may update a traditional on-disk /etc/mtab. Only use
        # them when mtab is the kernel's volatile mount view.
        require_volatile_mtab()
        flags += ['norecover']
    # Metadata/driver checks can take time. Revalidate the handover immediately
    # before the mount syscall/helper, after those checks, rather than before.
    if before_mount is not None:
        before_mount()
    if fs == 'ntfs':
        run(['ntfs-3g', path, destination, '-o', ','.join(flags)], timeout=60)
    else:
        # -i forbids unexpected executable mount helpers from target metadata.
        # Providing both source and target prevents implicit fstab selection.
        run(['mount', '-i', '-n', '-t', driver, '-o', ','.join(flags), '--', path, destination], timeout=60)
    rows = list(flatten(run_json(['findmnt', '--json', '--mountpoint', destination,
                  '--output', 'ID,TARGET,SOURCE,FSTYPE,MAJ:MIN,OPTIONS'])['filesystems']))
    if len(rows) != 1:
        raise Refusal('Could not establish the new mount identity')
    mount = rows[0]
    source = mount['source'].split('[', 1)[0]
    if number_of(source) != number_of(path):
        raise Refusal('Mounted filesystem does not belong to the chosen target partition')
    options = set(mount['options'].split(','))
    if not {'nodev', 'nosuid', 'noexec'}.issubset(options) or ('ro' if readonly else 'rw') not in options:
        raise Refusal('Restricted writable/read-only mount options were not established')
    if mount['fstype'] not in ({'fuseblk', 'ntfs-3g'} if fs == 'ntfs' else {driver}):
        raise Refusal('Unexpected filesystem driver')
    if fs in {'ext3', 'ext4'}:
        if readonly and not {'noload', 'norecovery'}.intersection(options):
            raise Refusal('Read-only ext journal suppression was not established')
        # Kernels can omit unchanged defaults (including data=ordered) from
        # findmnt's mount view. Reject conflicting reported values; the fixed
        # mount command above explicitly requests the safe journaling settings.
        if not readonly and {'noload', 'norecovery', 'nobarrier', 'barrier=0',
                             'data=writeback', 'data=journal'} & options:
            raise Refusal('Writable ext journaling protections were not established')
    if not re.fullmatch(r'[1-9][0-9]*', str(mount.get('id', ''))):
        raise Refusal('Mounted filesystem identity is unavailable')
    return mount


@contextlib.contextmanager
def instruction_directory(destination, expected_mount=None):
    directory = os.open(destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        if expected_mount is not None:
            info = os.fstat(directory)
            number = '%d:%d' % (os.major(info.st_dev), os.minor(info.st_dev))
            mount_id = re.search(r'^mnt_id:\s*([0-9]+)\s*$',
                                text_file('/proc/self/fdinfo/' + str(directory)), re.M)
            if (number != expected_mount['maj:min'] or not mount_id or
                    mount_id[1] != str(expected_mount['id'])):
                raise Refusal('Instruction mount changed before opening its directory; no file access permitted')
        # A retained directory descriptor keeps all relative accesses bound to
        # this filesystem even if its pathname is unmounted or overmounted.
        yield directory
    finally:
        os.close(directory)


def write_exclusive(destination, payload, expected_mount=None):
    with instruction_directory(destination, expected_mount) as directory:
        fd = os.open(NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=directory)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise Refusal('Instruction destination is not a new regular file')
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise Refusal('Short instruction-file write')
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        # FAT/FUSE may not support directory fsync; refuse rather than assert
        # durability after an unsupported flush. Clean unmount is also required.
        os.fsync(directory)


def verify_text(destination, payload, expected_mount=None):
    with instruction_directory(destination, expected_mount) as directory:
        # Nonblocking open allows fstat to reject a substituted FIFO/device
        # without waiting indefinitely for a peer before checking file type.
        fd = os.open(NAME, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                     dir_fd=directory)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_size != len(payload):
                raise Refusal('Saved file type or size is wrong')
            data = bytearray()
            while len(data) <= len(payload):
                chunk = os.read(fd, min(65536, len(payload) + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            if data != payload:
                raise Refusal('Saved instructions failed read-back comparison')
        finally:
            os.close(fd)


class MountCleanup:
    def __init__(self, destination):
        self.destination = destination

    def __enter__(self):
        return self

    def __exit__(self, kind, _value, _trace):
        error = None
        handlers = {sig: signal.signal(sig, signal.SIG_IGN)
                    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        try:
            if os.path.ismount(self.destination):
                try:
                    run(['umount', '-n', '--', self.destination], timeout=120)
                except (Refusal, OSError) as exc:
                    error = str(exc)
                    say('Cleanup failure: target remains mounted at', self.destination, ':', error)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
        if error and kind is None:
            raise Refusal('Could not cleanly unmount the instruction destination')
        return False


def save_instructions(target, info, text, run_dir):
    global PHASE
    if not info['stable'] or not target.get('diskseq'):
        raise Refusal('Identity is not established strongly enough for saving')
    if target.get('tran') == 'usb' and info['media'] not in {'HDD', 'SSD'}:
        raise Refusal('USB media is not established as an external HDD/SSD; flash sticks are excluded')
    if target.get('tran') == 'usb' and (not info.get('media_identity') or not info.get('smart') or info['smart'].get('device', {}).get('protocol') not in {'ATA', 'NVMe'}):
        raise Refusal('USB bridge does not establish physical HDD/SSD media identity')
    if target['physical_path'].startswith('/sys/devices/virtual/') or target.get('ro'):
        raise Refusal('Virtual or read-only target cannot receive instructions')
    revalidate(target)
    choices = [p for p in target['parts'] if p.get('fstype') in {'ntfs', 'vfat', 'ext2', 'ext3', 'ext4', 'exfat'} and not p.get('ro')]
    if not target['parts'] and target.get('fstype') in {'ntfs', 'vfat', 'ext2', 'ext3', 'ext4', 'exfat'}:
        choices = [target]
    if not choices:
        raise Refusal('No existing allowed writable filesystem on this target; no formatting or unlocking will be attempted')
    for i, part in enumerate(choices, 1):
        say('[%d]' % i, part['path'], part['fstype'], '| label:', part.get('label'))
    if len(choices) > 1:
        answer = ask('Choose the target filesystem number, or anything else to cancel: ')
        if not re.fullmatch(r'[1-9][0-9]{0,5}', answer) or int(answer) > len(choices):
            raise Refusal('No destination was selected')
        part = choices[int(answer) - 1]
    else:
        part = choices[0]
    say('Saving modifies existing filesystem metadata on', part['path'], 'and may take time for read-only consistency checks.')
    if ask('Type SAVE to authorize mounting and creating the instruction file on this target: ') != 'SAVE':
        raise Refusal('Saving cancelled')
    need('mount', 'umount')
    destination = os.path.join(run_dir, 'target-mount')
    os.mkdir(destination, 0o700)
    mounted = False
    parent_fd = None
    partition_fd = None
    PHASE = 'instruction saving'
    try:
        with Preparation() as prep, MountCleanup(destination):
            unmount_target(target)
            check_raw_users(target)
            # Keep a parent descriptor and generation checks throughout saving.
            with defer_signals():
                parent_fd = os.open(target['path'], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            fcntl.flock(parent_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            check_bound(parent_fd, target)
            # The selected partition belongs directly to this drive; no mapper,
            # RAID, LVM or multi-device filesystem is admitted to the allowlist.
            with exclusive_filesystem(part, target, parent_fd) as claimed_fd:
                revalidate(target, require_idle=True)
                check_raw_users(target, allowed=(os.getpid(),))
                # Checkers open the retained device, rather than a reusable
                # /dev pathname, and inherit it until they have been reaped.
                fs_clean('/proc/self/fd/' + str(claimed_fd), part['fstype'], pass_fds=(claimed_fd,))
                revalidate(target, require_idle=True)
                check_raw_users(target, allowed=(os.getpid(),))
                # Retain an independently opened, validated generation handle
                # while handing the exclusive kernel claim over to the mount.
                with defer_signals():
                    partition_fd = os.open(part['path'], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
                check_filesystem_bound(partition_fd, part, target, parent_fd)
                prep.check()
            # A mount needs its own kernel claim, so the checker claim must be
            # closed first. Recheck protection, users and both retained handles
            # at this transition; a competing claim makes mount fail, not retry.
            revalidate(target, require_idle=True)
            check_raw_users(target, allowed=(os.getpid(),))
            check_filesystem_bound(partition_fd, part, target, parent_fd)
            prep.check()
            def mount_ready():
                revalidate(target, require_idle=True)
                check_raw_users(target, allowed=(os.getpid(),))
                check_filesystem_bound(partition_fd, part, target, parent_fd)
                prep.check()
            try:
                writable_mount = mount_fs(part['path'], destination, part['fstype'], before_mount=mount_ready)
            finally:
                # Even a mount-validation error must clean up an actual mount.
                mounted = os.path.ismount(destination)
            check_filesystem_bound(partition_fd, part, target, parent_fd)
            require_runtime_directory()
            payload = text.encode('utf-8')
            write_exclusive(destination, payload, expected_mount=writable_mount)
            check_filesystem_bound(partition_fd, part, target, parent_fd)
            run(['umount', '-n', '--', destination], timeout=120)
            mounted = False
            revalidate(target, require_idle=True)
            check_raw_users(target, allowed=(os.getpid(),))
            check_filesystem_bound(partition_fd, part, target, parent_fd)
            prep.check()
            try:
                readonly_mount = mount_fs(part['path'], destination, part['fstype'], readonly=True, before_mount=mount_ready)
            finally:
                mounted = os.path.ismount(destination)
            check_filesystem_bound(partition_fd, part, target, parent_fd)
            verify_text(destination, payload, expected_mount=readonly_mount)
            run(['umount', '-n', '--', destination], timeout=120)
            mounted = False
            check_filesystem_bound(partition_fd, part, target, parent_fd)
            prep.check()
        say('Instructions saved, flushed and verified:', part['path'] + '/' + NAME)
    finally:
        handlers = {sig: signal.signal(sig, signal.SIG_IGN)
                    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        try:
            if mounted and os.path.ismount(destination):
                try:
                    run(['umount', '-n', '--', destination], timeout=120)
                    mounted = False
                except (Refusal, OSError) as exc:
                    say('Cleanup failure: filesystem remains mounted at', destination, ':', exc)
            else:
                mounted = False
            if partition_fd is not None:
                os.close(partition_fd)
            if parent_fd is not None:
                os.close(parent_fd)
            if not mounted:
                os.rmdir(destination)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
        PHASE = 'inspection'


def manual(target, info, run_dir):
    text = instructions(target, info)
    display_text(text)
    if ask('Save these instructions on the selected target drive? [yes/NO] ') == 'yes':
        try:
            save_instructions(target, info, text, run_dir)
        except (Refusal, OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
            say('Saving impossible or failed:', exc)
            failure_details(exc)
            say('No other destination will be used. A partial file may remain on the selected target.')
            display_text(text)
        except Interrupted:
            say('Instruction saving interrupted; no alternate destination was used.')
            display_text(text)
            raise
    say('Outcome: manual procedure required. No erasure was performed by this selection.')


def namespace_check():
    # Do not operate with a partial view of the running system's storage.
    for namespace in ('mnt', 'user', 'net'):
        if os.readlink('/proc/self/ns/' + namespace) != os.readlink('/proc/1/ns/' + namespace):
            raise Refusal('System %s namespace differs: self=%s PID1=%s. Run directly on the host; '
                          'an isolated view cannot establish protection of the running OS' %
                          (namespace, os.readlink('/proc/self/ns/' + namespace),
                           os.readlink('/proc/1/ns/' + namespace)))


class SessionOutcome:
    """In-memory per-drive outcomes; later success cannot hide earlier failure."""
    def __init__(self):
        self.status = 0
        self.results = []

    def record(self, status, target):
        if status not in (0, 2, 3):
            raise ValueError('Unexpected session outcome')
        self.results.append({'status': status, 'model': target.get('model'),
                             'serial': target.get('serial'), 'wwn': target.get('wwn')})
        if status == 2 or (status == 3 and self.status == 0):
            self.status = status

    def finish(self):
        if self.status:
            say('Session exit status:', self.status,
                '(an earlier failure/refusal)' if self.status == 2 else '(manual procedure required)')
        return self.status


def main():
    global TTY, PHASE, WRITE_STARTED, WRITE_FINISHED, VERIFIED, CURRENT_TARGET, OP_STARTED
    no_core_dumps()
    namespace_check()
    graph = Graph()
    if sys.argv[1] == '--check':
        inventory(graph)
        return 2 if graph.blockers else 0
    TTY = open('/dev/tty', 'r', encoding='utf-8', errors='strict')
    require_runtime_directory()
    # Abstract Unix socket: single-instance lock without a persistent lock file.
    lock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        lock.bind('\0erase-all-data.session.v2')
    except OSError as exc:
        lock.close()
        if exc.errno == errno.EADDRINUSE:
            raise Refusal('Another script instance is running') from exc
        raise
    run_dir = tempfile.mkdtemp(prefix='erase-all-data-', dir='/run')
    os.chmod(run_dir, 0o700)
    outcome = SessionOutcome()
    try:
        while True:
            PHASE = 'inspection'
            WRITE_STARTED = WRITE_FINISHED = VERIFIED = False
            CURRENT_TARGET = OP_STARTED = None
            LAST_BYTES.clear()
            graph = Graph()
            candidates = inventory(graph)
            answer = ask('Drive number, r to refresh, or q to quit: ')
            if answer == 'q':
                return outcome.finish()
            if answer == 'r':
                continue
            if not re.fullmatch(r'[1-9][0-9]{0,5}', answer) or int(answer) > len(candidates):
                say('Choose a displayed number; arbitrary device paths are not accepted.')
                continue
            target = candidates[int(answer) - 1]
            CURRENT_TARGET = target
            describe(target)
            if ask('Type INSPECT to inspect this drive, or anything else to cancel: ') != 'INSPECT':
                continue
            try:
                current = Graph()
                fresh = current.drive(target['kname'])
                if fingerprint(fresh) != fingerprint(target) or fresh['protected']:
                    raise Refusal('Selection changed or became protected; refresh required')
                info = inspection(target, current)
                if not info['eligible']:
                    # Record before asking about TXT saving: EOF there must not
                    # silently convert this manual-only result into success.
                    outcome.record(3, target)
                    manual(target, info, run_dir)
                    continue
                if not confirmation(target, info):
                    say('Erasure cancelled; no destructive operation started.')
                    continue
                started = time.monotonic()
                OP_STARTED = started
                with Preparation() as prep:
                    # Repeat protection and the read-only recommendation after
                    # confirmation, before any filesystem unmount or overwrite.
                    checked_graph, _fresh = revalidate(target)
                    checked_info = inspection(target, checked_graph)
                    if not checked_info['eligible']:
                        raise Refusal('Eligibility changed after confirmation; inspect again')
                    if method_fingerprint(checked_info) != method_fingerprint(info):
                        raise Refusal('Identity/capability/security evidence changed; inspect and confirm again')
                    hdd_backend(target, checked_info, prep)
                if not VERIFIED:
                    raise Refusal('Verification evidence is incomplete')
                say('')
                say('All accessible sectors overwritten and verified.')
                say('Drive:', target.get('model'), '| serial:', target.get('serial'),
                    '| WWN:', target.get('wwn'), '| path at selection:', target['path'])
                say('Method: one zero pass; scope:', target['size'], 'accessible bytes; duration: %.1f minutes.' % ((time.monotonic() - started) / 60))
                say('Evidence: exact write count, flush success, exact direct-I/O read count and complete zero comparison.')
                say('Limitations: inaccessible/retired physical sectors may retain data. Health is separate from this result.')
                say('No partition table or filesystem was created. Initialise the drive only when ready for reuse.')
                outcome.record(0, target)
            except (Refusal, OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
                say('')
                say('Outcome: failed/refused:', exc)
                failure_details(exc)
                if WRITE_STARTED:
                    say('Drive:', target.get('model'), '| serial:', target.get('serial'),
                        '| WWN:', target.get('wwn'), '| scope:', target['size'], 'accessible bytes.')
                    say('Method: zero overwrite + full direct read-back; observed progress:', LAST_BYTES)
                    if OP_STARTED is not None:
                        say('Duration: %.1f minutes.' % ((time.monotonic() - OP_STARTED) / 60))
                    if WRITE_FINISHED:
                        say('Overwrite completed; verification or completion handling failed. Do not release this drive.')
                    else:
                        say('Erasure incomplete. Do not release this drive.')
                else:
                    say('No overwrite was started. No automatic destructive fallback will be attempted.')
                outcome.record(2, target)
                say('Refresh and inspect again before any further operation.')
    except EOFError:
        say('Cancelled: end of input. No automatic resume.')
        if WRITE_STARTED and not VERIFIED and CURRENT_TARGET is not None:
            outcome.record(2, CURRENT_TARGET)
        return outcome.finish()
    finally:
        # Never remove a mounted target or use recursive deletion on its files.
        try:
            if os.listdir(run_dir):
                say('RAM working directory retained for cleanup:', run_dir)
            else:
                os.rmdir(run_dir)
        finally:
            lock.close()
            if TTY is not None:
                TTY.close()


try:
    sys.exit(main())
except EOFError:
    # Normal terminal EOF is handled inside main(), where session outcomes are
    # available. Unexpected startup EOF must not fabricate a successful result.
    say('Refused: unexpected end of input during startup. No automatic resume.')
    sys.exit(2)
except Interrupted as exc:
    if CURRENT_TARGET is not None:
        say('')
        say('Selected drive:', CURRENT_TARGET.get('model'), '| serial:', CURRENT_TARGET.get('serial'),
            '| WWN:', CURRENT_TARGET.get('wwn'), '| accessible bytes:', CURRENT_TARGET['size'])
    if WRITE_STARTED and not WRITE_FINISHED:
        say('')
        print('Interrupted — erasure incomplete. Do not release this drive.', flush=True)
    elif WRITE_FINISHED and not VERIFIED:
        say('')
        say('Overwrite completed; verification incomplete. Do not release this drive.')
    elif VERIFIED:
        say('')
        say('Interrupted during completion handling. Verification completed; review cleanup before releasing the drive.')
    else:
        say('')
        say('Interrupted during', PHASE + '. No overwrite was started.')
    sys.exit(128 + exc.signum)
except (Refusal, OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
    say('Refused:', exc)
    failure_details(exc)
    sys.exit(2)
finally:
    # A registered child must not outlive a normal exit, refusal or interruption.
    # atexit supplies a second safety net if interruption reaches this boundary.
    cleanup_errors = cleanup_registered_processes()
    if cleanup_errors:
        for cleanup_error in cleanup_errors:
            say(cleanup_error)
        sys.exit(2)
PY
