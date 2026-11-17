#!/usr/bin/env python3
"""Guest-only block/filesystem integration. NEVER run on the working computer.

sudo python3 vm-integration.py --disposable-vm

Requires a separate disposable systemd Linux VM without host disks passed through.
Creates its own RAM-backed image files and loop devices; accepts no device paths.
Checks real exclusive block claims, direct-I/O workers, mount restrictions,
filesystem cleanliness and target-file read-back. This does not qualify hardware
erase, native SATA firmware behavior, or the physical protection of a real host.
"""
import contextlib
import errno
import importlib.util
import os
from pathlib import Path
import signal
import stat
import sys
import tempfile
from unittest.mock import patch


def load_validation():
    path = Path(__file__).with_name('offline-validation.py')
    spec = importlib.util.spec_from_file_location('erase_validation', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class OwnedLoop:
    """Only devices attached here to a newly created private image are writable."""
    def __init__(self, helper, directory, label, size):
        self.h = helper
        self.image = Path(directory) / (label + '.img')
        self.path = None
        self.target = None
        fd = os.open(self.image, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.ftruncate(fd, size)
            if label == 'worker':
                remaining = size
                pattern = b'\x5a' * 1048576
                while remaining:
                    count = os.write(fd, pattern[:min(remaining, len(pattern))])
                    if count <= 0:
                        raise RuntimeError('Short test-image initialization')
                    remaining -= count
        finally:
            os.close(fd)
        try:
            result = self.h.run(['losetup', '--find', '--show', '--nooverlap', '--', str(self.image)])
            self.path = result.stdout.strip()
            if not self.path.startswith('/dev/loop') or not self.path[9:].isdigit():
                raise RuntimeError('Unexpected newly allocated loop path')
            self.target = self.read_target()
            self.assert_owned()
        except BaseException:
            # Never detach an unvalidated pathname from command output.
            if self.path and self.target:
                self.close()
            raise

    def read_target(self):
        rows = self.h.run_json(['lsblk', '--json', '--bytes', '--nodeps',
                               '--output', self.h.COLS, '--', self.path])['blockdevices']
        if len(rows) != 1 or rows[0]['type'] != 'loop' or rows[0]['path'] != self.path:
            raise RuntimeError('Test device is not the allocated loop')
        row = rows[0]
        node = Path('/sys/class/block') / row['kname']
        row.update(physical_path=str(node.resolve(strict=True)),
                   diskseq=self.h.text_file(node / 'diskseq'),
                   zoned=self.h.text_file(node / 'queue/zoned'), parts=[],
                   holders={row['kname']: [p.name for p in (node / 'holders').iterdir()]},
                   protected=[], vendor='guest-owned loop')
        return row

    def assert_owned(self):
        info = os.lstat(self.image)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1:
            raise RuntimeError('Test image ownership/type changed')
        loops = self.h.run_json(['losetup', '--json', '--list', '--output', 'NAME,BACK-FILE'])['loopdevices']
        matches = [r for r in loops if r['name'] == self.path]
        if len(matches) != 1 or not os.path.samefile(matches[0]['back-file'], self.image):
            raise RuntimeError('Loop no longer belongs to this test image')
        fresh = self.read_target()
        if self.h.fingerprint(fresh) != self.h.fingerprint(self.target):
            raise RuntimeError('Loop identity, capacity or generation changed')
        if any(fresh['holders'].values()):
            raise RuntimeError('Test loop has active holders')
        fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            self.h.check_bound(fd, self.target)
        finally:
            os.close(fd)
        return fresh

    def idle(self, target=None, require_idle=False, partitions=True):
        fresh = self.assert_owned()
        mounts = self.h.run_json(['findmnt', '--json', '--kernel', '--output',
                                 'TARGET,SOURCE,FSTYPE,MAJ:MIN,OPTIONS'])['filesystems']
        for mount in self.h.flatten(mounts):
            source = mount.get('source', '').split('[', 1)[0]
            number = mount['maj:min']
            if source.startswith('/dev/'):
                number = self.h.number_of(source)
            if number == fresh['maj:min']:
                raise RuntimeError('Test loop is mounted; refusing worker execution')
        self.h.require_runtime_directory()
        return None, fresh

    def close(self):
        self.idle()
        self.h.run(['losetup', '--detach', '--', self.path])
        loops = self.h.run_json(['losetup', '--json', '--list', '--output', 'NAME,BACK-FILE'])['loopdevices']
        if any(row['name'] == self.path and row.get('back-file') == str(self.image) for row in loops):
            raise RuntimeError('Loop detach is still pending; retaining its RAM image')
        self.path = None
        self.image.unlink()


def worker_checks(h, loop, prep):
    loop.idle()
    # Production rejects virtual disks. This test-only adapter restricts that
    # virtual scope to the one RAM image we allocated, while keeping real block
    # identity, claims, fuser, progress, I/O and verification checks intact.
    with patch.object(h, 'unmount_target', loop.idle), patch.object(h, 'revalidate', loop.idle):
        with h.exclusive_drive(loop.target):
            try:
                second = os.open(loop.path, os.O_RDONLY | os.O_EXCL | os.O_NOFOLLOW)
            except OSError as exc:
                if exc.errno != errno.EBUSY:
                    raise
            else:
                os.close(second)
                raise RuntimeError('Exclusive block claim did not reject a second claimant')
        h.hdd_backend(loop.target, {'eligible': True}, prep)
        if not h.VERIFIED:
            raise RuntimeError('Block-device verification did not complete')
    print('PASS: real exclusive claim, exact overwrite and complete direct read-back', flush=True)


def filesystem_checks(h, loop, destination, filesystem, formatter):
    loop.idle()
    # formatter is fixed by the test source; no metadata-supplied commands.
    h.run(formatter + [loop.path], timeout=120)
    loop.assert_owned()
    parent_fd = os.open(loop.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        h.fcntl.flock(parent_fd, h.fcntl.LOCK_EX | h.fcntl.LOCK_NB)
        with h.exclusive_filesystem(loop.target, loop.target, parent_fd) as claimed_fd:
            try:
                second = os.open(loop.path, os.O_RDONLY | os.O_EXCL | os.O_NOFOLLOW)
            except OSError as exc:
                if exc.errno != errno.EBUSY:
                    raise
            else:
                os.close(second)
                raise RuntimeError('Filesystem check claim admitted a second claimant')
            h.fs_clean('/proc/self/fd/' + str(claimed_fd), filesystem, pass_fds=(claimed_fd,))
            loop.assert_owned()
            h.check_raw_users(loop.target, allowed=(os.getpid(),))
    finally:
        os.close(parent_fd)
    payload = ('Guest-only instruction round trip: ' + filesystem + '\n').encode()
    with h.MountCleanup(destination):
        loop.assert_owned()
        writable_mount = h.mount_fs(loop.path, destination, filesystem, before_mount=loop.idle)
        if filesystem in {'ext3', 'ext4'}:
            if writable_mount['fstype'] != 'ext4' or {'noload', 'norecovery'} & set(writable_mount['options'].split(',')):
                raise RuntimeError('Writable internal-journal ext4-driver mount was not established')
        h.write_exclusive(destination, payload, expected_mount=writable_mount)
        try:
            h.write_exclusive(destination, b'must not replace the existing file',
                              expected_mount=writable_mount)
        except FileExistsError:
            pass
        else:
            raise RuntimeError('Existing instruction file was replaced')
        h.run(['umount', '-n', '--', destination], timeout=120)
        loop.assert_owned()
        readonly_mount = h.mount_fs(loop.path, destination, filesystem, readonly=True, before_mount=loop.idle)
        h.verify_text(destination, payload, expected_mount=readonly_mount)
        h.run(['umount', '-n', '--', destination], timeout=120)
    loop.idle()
    print('PASS: clean restricted mount, exclusive TXT creation and read-back:', filesystem, flush=True)


def main():
    if sys.argv[1:] != ['--disposable-vm']:
        raise SystemExit(__doc__)
    validation = load_validation()
    validation.require_disposable_vm()
    if os.geteuid() != 0:
        raise SystemExit('Refused: this guest-only suite requires root inside the disposable VM.')
    h = validation.load_helper()
    h.no_core_dumps()
    h.namespace_check()
    h.require_runtime_directory()
    h.need('losetup', 'lsblk', 'findmnt', 'dd', 'cmp', 'fuser')
    previous = {sig: signal.signal(sig, h.on_signal)
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    directory = tempfile.mkdtemp(prefix='erase-vm-test-', dir='/run')
    destination = os.path.join(directory, 'mount')
    os.mkdir(destination, 0o700)
    loops = []
    skipped = []
    try:
        with h.Preparation() as prep:
            loop = OwnedLoop(h, directory, 'worker', 4194816)
            loops.append(loop)
            worker_checks(h, loop, prep)
            formats = [('ext2', ['mkfs.ext2', '-F'], ['dumpe2fs', 'e2fsck']),
                       ('ext3', ['mkfs.ext3', '-F'], ['dumpe2fs', 'e2fsck']),
                       ('ext4', ['mkfs.ext4', '-F'], ['dumpe2fs', 'e2fsck']),
                       ('vfat', ['mkfs.fat', '-F', '32'], ['fsck.fat']),
                       ('exfat', ['mkfs.exfat'], ['fsck.exfat']),
                       ('ntfs', ['mkntfs', '-F', '-Q'], ['ntfs-3g', 'ntfs-3g.probe', 'ntfsinfo'])]
            for filesystem, formatter, checkers in formats:
                if not all(h.shutil.which(tool) for tool in [formatter[0]] + checkers):
                    skipped.append(filesystem)
                    print('NOT VALIDATED: missing tools for', filesystem, flush=True)
                    continue
                loop = OwnedLoop(h, directory, filesystem, 64 * 1024 * 1024)
                loops.append(loop)
                filesystem_checks(h, loop, destination, filesystem, formatter)
            prep.check()
        return 3 if skipped else 0
    finally:
        # No recursive deletion: never traverse a filesystem left mounted after
        # a failure. Failed cleanup deliberately retains its RAM image and loop.
        handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in previous}
        original_exception = sys.exc_info()[0]
        cleanup_errors = []
        try:
            for loop in reversed(loops):
                if loop.path:
                    try:
                        loop.close()
                    except Exception as exc:
                        cleanup_errors.append(str(exc))
                        print('Cleanup incomplete; retained', loop.path, ':', exc, flush=True)
            if not os.path.ismount(destination):
                os.rmdir(destination)
            if not os.listdir(directory):
                os.rmdir(directory)
            else:
                print('Retained RAM test directory:', directory, flush=True)
                cleanup_errors.append('test directory still contains resources')
            if cleanup_errors and original_exception is None:
                raise RuntimeError('Guest cleanup failed: ' + '; '.join(cleanup_errors))
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
            for sig, handler in previous.items():
                signal.signal(sig, handler)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except BaseException as exc:
        if isinstance(exc, SystemExit):
            raise
        print('Guest integration failed:', exc, file=sys.stderr, flush=True)
        sys.exit(128 + exc.signum if hasattr(exc, 'signum') else 2)
