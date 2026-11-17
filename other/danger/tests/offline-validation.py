#!/usr/bin/env python3
"""Run only in a separate disposable Linux VM, never on the working computer.

python3 offline-validation.py --disposable-vm

Loads the script's helper without its entry point. Unit cases use synthetic
metadata. Integration cases overwrite ONLY newly-created regular files in a
private temporary directory. They never open a physical block device. Production
eligibility/protection gates have no test override in the shipped script.

Requires GNU dd/cmp and a VM filesystem supporting aligned O_DIRECT on files.
This suite does not qualify ATA/NVMe hardware sanitization.
It now exercises the real protection graph and session flow with synthetic
tool/sysfs boundaries, plus actual SIGINT and GNU worker I/O on private files.
Run vm-integration.py separately for real guest loop-device claims and filesystem
mounting. Both suites require detected virtualization and an explicit flag;
neither may be run on the working computer, including a locally hosted VM.
"""
import ast
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch


def load_helper():
    source = Path(__file__).resolve().parents[1] / 'erase-all-data.sh'
    body = source.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
    tree = ast.parse(body)
    # The final try is the only program entry point. Remove it and the signal
    # registration loop; definitions are loaded without starting any workflow.
    assert isinstance(tree.body[-1], ast.Try)
    tree.body = [node for node in tree.body[:-1] if not
                 (isinstance(node, ast.For) and isinstance(node.target, ast.Name)
                  and node.target.id == 'sig')]
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader('erase_helper', loader=None))
    with patch.object(sys, 'argv', [str(source), 'offline-tests', str(source)]):
        exec(compile(tree, str(source), 'exec'), module.__dict__)
    return module


H = None


def drive():
    return dict(path='/dev/sdb', kname='sdb', **{'maj:min': '8:16', 'log-sec': 512,
                'phy-sec': 4096}, model='EXAMPLE HDD', serial='UNIQUE', wwn='0x123',
                size=4194816, tran='sata', ro=False, rota=True, rm=False,
                diskseq='123', physical_path='/sys/devices/pci/ata/block/sdb',
                zoned='none', parts=[], holders={'sdb': []}, protected=[], vendor='EXAMPLE')


def require_disposable_vm():
    result = subprocess.run(['systemd-detect-virt', '--vm'], capture_output=True, text=True)
    if result.returncode or not result.stdout.strip() or result.stdout.strip() == 'none':
        raise SystemExit('Refused: a detected disposable VM on a separate test machine is required.')


class StorageFixture:
    """Synthetic tool/sysfs boundary; unexpected reads or commands are errors."""
    def __init__(self):
        self.rows = []
        self.files = {'/proc/cmdline': 'boot=live'}
        self.dirs = {}
        self.resolved = {}
        self.swaps = []
        self.file_mounts = {}
        self.fstab = []
        self.mutations = []
        self.media = 'HDD'
        self.efi = None
        self.add_disk('sda', '8:0')
        self.add_disk('sdb', '8:16')
        self.add_partition('sda1', 'sda', '8:1')
        self.add_partition('sdb1', 'sdb', '8:17')
        self.mounts = [self.mount('/', 'sda1'), self.mount('/run/live/medium', 'sda1')]

    def mount(self, destination, name):
        row = next(r for r in self.rows if r['kname'] == name)
        return {'target': destination, 'source': row['path'], 'fstype': 'ext4',
                'maj:min': row['maj:min'], 'options': 'rw'}

    def add_disk(self, name, number):
        row = drive()
        row.update(kname=name, path='/dev/' + name, type='disk', pkname=None,
                   serial='SERIAL-' + name, wwn='WWN-' + name)
        row['maj:min'] = number
        self.rows.append(row)
        node = '/sys/class/block/' + name
        self.resolved[node] = '/sys/devices/pci/ata1/block/' + name
        self.files.update({node + '/diskseq': str(len(self.rows)), node + '/queue/zoned': 'none',
                           node + '/device/vendor': 'EXAMPLE'})
        self.dirs[node + '/holders'] = []
        self.dirs[node + '/slaves'] = []
        return row

    def add_partition(self, name, parent, number):
        self.rows.append(dict(kname=name, path='/dev/' + name, type='part', pkname=parent,
                              size=4096, ro=False, fstype='ext4', uuid=name, partuuid=name,
                              **{'maj:min': number}))
        self.dirs['/sys/class/block/' + name + '/holders'] = []

    def add_nvme(self, controller='nvme0', subsystem='nvme-subsys0', count=2):
        base = '/sys/class/nvme-subsystem/' + subsystem
        group_path = '/sys/devices/virtual/nvme-subsystem/' + subsystem
        ctrl_path = '/sys/devices/pci/' + controller + '/nvme/' + controller
        ctrl = '/sys/class/nvme/' + controller
        nqn = 'nqn.2014-08.org.example:' + subsystem
        self.dirs.setdefault('/sys/class/nvme-subsystem', []).append(base)
        self.dirs[base] = [base + '/' + controller, base + '/subsysnqn']
        self.resolved.update({base: group_path, base + '/' + controller: ctrl_path,
                              ctrl: ctrl_path})
        self.files.update({base + '/subsysnqn': nqn, ctrl + '/subsysnqn': nqn,
                           ctrl + '/serial': 'NVME-' + controller, ctrl + '/model': 'NVME',
                           ctrl + '/transport': 'pcie'})
        for index in range(1, count + 1):
            name = controller + 'n' + str(index)
            self.add_disk(name, '259:' + str(len(self.rows)))['tran'] = 'nvme'
            self.resolved['/sys/class/block/' + name] = ctrl_path + '/' + name

    def query(self, args):
        if args[0] == 'lsblk':
            return {'blockdevices': copy.deepcopy(self.rows)}
        if args[0] == 'findmnt' and '--target' in args:
            destination = args[args.index('--target') + 1]
            if destination == '/run':
                return {'filesystems': [{'target': '/run', 'fstype': 'tmpfs'}]}
            if destination == '/fixture/script':
                return {'filesystems': [copy.deepcopy(self.mounts[0])]}
            if destination in self.file_mounts:
                return {'filesystems': [copy.deepcopy(self.file_mounts[destination])]}
        if args[0] == 'findmnt' and '--kernel' in args:
            return {'filesystems': copy.deepcopy(self.mounts)}
        raise AssertionError('Unexpected structured query: ' + repr(args))

    def command(self, args, **kwargs):
        if args == ['efibootmgr', '-v'] and self.efi is not None:
            return subprocess.CompletedProcess(args, 0, stdout=self.efi, stderr='')
        if args[:2] == ['findmnt', '--fstab']:
            return subprocess.CompletedProcess(args, 0, stdout=json.dumps({'filesystems': self.fstab}), stderr='')
        if args[0] == 'umount':
            self.mutations.append(args)
            self.mounts = [m for m in self.mounts if m['target'] != args[-1]]
            return subprocess.CompletedProcess(args, 0, stdout='', stderr='')
        if args[:3] == ['smartctl', '--json', '--all']:
            row = next(r for r in self.rows if r['path'] == args[3])
            data = {'device': {'protocol': 'ATA'}, 'serial_number': row['serial'],
                    'rotation_rate': 7200 if self.media == 'HDD' else 0,
                    'user_capacity': {'bytes': row['size']}, 'smart_status': {'passed': True}}
            return subprocess.CompletedProcess(args, 0, stdout=json.dumps(data), stderr='')
        if args[:2] == ['hdparm', '-I']:
            return subprocess.CompletedProcess(args, 0, stdout='Security:\n\tnot enabled\n\tnot locked\n'
                                                'Nominal Media Rotation Rate: 7200\n', stderr='')
        if args[:2] == ['hdparm', '-N']:
            row = next(r for r in self.rows if r['path'] == args[2])
            sectors = row['size'] // row['log-sec']
            return subprocess.CompletedProcess(args, 0, stdout='max sectors = %d/%d' %
                                               (sectors, sectors), stderr='')
        if args in (['dd', '--version'], ['cmp', '--version']):
            return subprocess.CompletedProcess(args, 0, stdout='GNU fixture', stderr='')
        raise AssertionError('Unexpected command: ' + repr(args))

    def resolve(self, path, **kwargs):
        value = str(path)
        if value not in self.resolved:
            raise FileNotFoundError(value)
        return Path(self.resolved[value])

    def read(self, path, **kwargs):
        value = str(path)
        if value not in self.files:
            raise FileNotFoundError(value)
        return self.files[value]

    def entries(self, path):
        value = str(path)
        if value not in self.dirs:
            raise FileNotFoundError(value)
        return iter(Path(p) for p in self.dirs[value])

    def device_stat(self, path):
        if str(path) in self.file_mounts:
            return SimpleNamespace(st_mode=stat.S_IFREG)
        real = self.resolved.get(str(path), str(path))
        row = next((r for r in self.rows if r['path'] == real), None)
        if row is None:
            raise AssertionError('Unexpected stat: ' + str(path))
        major, minor = map(int, row['maj:min'].split(':'))
        return SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(major, minor))

    def read_bytes(self, path):
        if str(path) != '/proc/swaps':
            raise AssertionError('Unexpected byte read: ' + str(path))
        if '/proc/swaps' in self.files:
            return self.files['/proc/swaps'].encode('utf-8')
        def escape(value):
            for char, replacement in [('\\', r'\134'), (' ', r'\040'),
                                      ('\t', r'\011'), ('\n', r'\012')]:
                value = value.replace(char, replacement)
            return value
        return ('Filename\tType\tSize\tUsed\tPriority\n' + ''.join(
            escape(path) + '\t' + ('file' if path in self.file_mounts else 'partition') +
            '\t4096\t0\t-2\n' for path in self.swaps)).encode('utf-8')

    @contextlib.contextmanager
    def active(self):
        with contextlib.ExitStack() as stack:
            replacements = [(H, 'SCRIPT', '/fixture/script'), (H, 'run_json', self.query),
                            (H, 'run', self.command),
                            (H.os.path, 'realpath', lambda path: self.resolved.get(str(path), str(path))),
                            (H.os.path, 'exists', lambda path: str(path) == '/fixture/script' or
                             str(path) in self.files or str(path) in self.file_mounts or
                             any(r['path'] == str(path) for r in self.rows)),
                            (H.os.path, 'isdir', lambda path: self.efi is not None and
                             str(path) == '/sys/firmware/efi'),
                            (H.os, 'stat', self.device_stat),
                            (H.os, 'lstat', lambda path: SimpleNamespace(st_mode=stat.S_IFDIR | 0o755,
                                                                       st_uid=0))]
            for owner, name, value in replacements:
                stack.enter_context(patch.object(owner, name, value))
            stack.enter_context(patch.object(Path, 'resolve', autospec=True, side_effect=self.resolve))
            stack.enter_context(patch.object(Path, 'read_text', autospec=True, side_effect=self.read))
            stack.enter_context(patch.object(Path, 'read_bytes', autospec=True, side_effect=self.read_bytes))
            stack.enter_context(patch.object(Path, 'iterdir', autospec=True, side_effect=self.entries))
            stack.enter_context(patch.object(Path, 'exists', autospec=True,
                               side_effect=lambda path: str(path) in self.files or str(path) in self.dirs))
            yield


class ProtectionWorkflowTests(unittest.TestCase):
    def test_uefi_loader_and_live_image_on_different_drives_are_both_protected(self):
        fixture = StorageFixture()
        fixture.add_disk('sdc', '8:32')
        fixture.add_partition('sdc1', 'sdc', '8:33')
        guid = '12345678-1234-1234-1234-123456789abc'
        fixture.rows[-1]['partuuid'] = guid
        fixture.efi = 'BootCurrent: 0001\nBoot0001* Loader HD(1,GPT,' + guid + ',0x800,0x1000)/File(loader.efi)\n'
        with fixture.active(), patch.object(H.shutil, 'which', return_value='/fixture/tool'):
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertTrue(graph.drive('sda')['protected'])
            self.assertTrue(graph.drive('sdc')['protected'])
            self.assertEqual([r['kname'] for r in graph.candidates()], ['sdb'])

    def test_uefi_mbr_boot_partition_is_resolved(self):
        fixture = StorageFixture()
        fixture.rows[2]['partuuid'] = '1234abcd-01'
        fixture.efi = 'BootCurrent: 0002\nBoot0002* USB HD(1,MBR,0x1234abcd,0x800,0x1000)/File(loader.efi)\n'
        with fixture.active(), patch.object(H.shutil, 'which', return_value='/fixture/tool'):
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertTrue(graph.drive('sda')['protected'])

    def test_live_image_evidence_never_bypasses_unsupported_uefi_boot_chain(self):
        for entry in ('CDROM(1,0x20,0x1000)/File(loader.efi)', 'File(chainloader.efi)',
                      'HD(1,GPT,12345678-1234-1234-1234-123456789abc,0x800,0x1000)'):
            fixture = StorageFixture()
            fixture.efi = 'BootCurrent: 0001\nBoot0001* USB ' + entry + '\n'
            with fixture.active(), patch.object(H.shutil, 'which', return_value='/fixture/tool'):
                graph = H.Graph()
                self.assertTrue(graph.boot_known)  # live medium is independently known
                self.assertTrue(graph.blockers)
                self.assertTrue(graph.drive('sda')['protected'])
                with self.assertRaises(H.Refusal):
                    H.revalidate(graph.drive('sdb'))
                self.assertFalse(fixture.mutations)

    def test_duplicate_uefi_partition_identity_blocks_automatic_operations(self):
        fixture = StorageFixture()
        guid = '12345678-1234-1234-1234-123456789abc'
        for row in fixture.rows:
            if row['type'] == 'part':
                row['partuuid'] = guid
        fixture.efi = 'BootCurrent: 0001\nBoot0001* USB HD(1,GPT,' + guid + ',0x800,0x1000)\n'
        with fixture.active(), patch.object(H.shutil, 'which', return_value='/fixture/tool'):
            graph = H.Graph()
            self.assertTrue(any('matched 2 inventory entries' in reason for reason in graph.blockers))

    def test_real_graph_excludes_system_and_all_its_partitions(self):
        fixture = StorageFixture()
        with fixture.active():
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertEqual([r['kname'] for r in graph.candidates()], ['sdb'])
            self.assertTrue(graph.drive('sda')['protected'])

    def test_revalidation_refuses_replaced_device_and_any_mutation(self):
        fixture = StorageFixture()
        with fixture.active():
            target = H.Graph().drive('sdb')
            fixture.files['/sys/class/block/sdb/diskseq'] = '999'
            with self.assertRaises(H.Refusal):
                H.unmount_target(target)
            self.assertFalse(fixture.mutations)

    def test_clean_unmount_uses_current_graph_and_revalidates(self):
        fixture = StorageFixture()
        fixture.mounts.append(fixture.mount('/mnt/target', 'sdb1'))
        with fixture.active():
            target = H.Graph().drive('sdb')
            H.unmount_target(target)
            self.assertEqual(fixture.mutations, [['umount', '-n', '--', '/mnt/target']])

    def test_holders_refuse_before_unmount(self):
        fixture = StorageFixture()
        with fixture.active():
            target = H.Graph().drive('sdb')
            fixture.dirs['/sys/class/block/sdb1/holders'] = ['/sys/class/block/sdb1/holders/dm-0']
            with self.assertRaises(H.Refusal):
                H.unmount_target(target)
            self.assertFalse(fixture.mutations)

    def test_nvme_system_namespace_protects_peers_but_not_other_device(self):
        fixture = StorageFixture()
        fixture.add_nvme()
        fixture.add_nvme('nvme1', 'nvme-subsys1')
        fixture.mounts[0] = fixture.mount('/', 'nvme0n1')
        with fixture.active():
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertTrue(graph.drive('nvme0n2')['protected'])
            self.assertFalse(graph.drive('nvme1n1')['protected'])
            with self.assertRaises(H.Refusal):
                H.revalidate(graph.drive('nvme0n2'))

    def test_nvme_scope_change_invalidates_confirmation(self):
        fixture = StorageFixture()
        fixture.add_nvme()
        with fixture.active():
            target = H.Graph().drive('nvme0n1')
            fixture.files['/sys/class/block/nvme0n2/diskseq'] = '999'
            with self.assertRaises(H.Refusal):
                H.revalidate(target)

    def test_conflicting_nvme_relationship_blocks_all_writes(self):
        fixture = StorageFixture()
        fixture.add_nvme()
        fixture.files['/sys/class/nvme/nvme0/subsysnqn'] = 'conflicting'
        with fixture.active():
            graph = H.Graph()
            self.assertTrue(graph.blockers)
            self.assertTrue(graph.drive('nvme0n2')['protected'])
            with self.assertRaises(H.Refusal):
                H.revalidate(graph.drive('sdb'))

    def test_multipath_namespace_head_uses_subsystem_relationship(self):
        fixture = StorageFixture()
        fixture.add_nvme()
        fixture.resolved['/sys/class/block/nvme0n2'] = (
            '/sys/devices/virtual/nvme-subsystem/nvme-subsys0/nvme0n2')
        fixture.mounts[0] = fixture.mount('/', 'nvme0n1')
        with fixture.active():
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertTrue(graph.drive('nvme0n2')['protected'])

    def test_duplicate_subsystem_identifiers_fail_closed(self):
        fixture = StorageFixture()
        fixture.add_nvme()
        fixture.add_nvme('nvme1', 'nvme-subsys1')
        nqn = fixture.files['/sys/class/nvme-subsystem/nvme-subsys0/subsysnqn']
        fixture.files['/sys/class/nvme-subsystem/nvme-subsys1/subsysnqn'] = nqn
        with fixture.active():
            graph = H.Graph()
            self.assertTrue(graph.blockers)
            self.assertTrue(all(graph.drive(name)['protected'] for name in graph.nvme_names()))

    def test_zram_backing_partition_protects_whole_drive(self):
        fixture = StorageFixture()
        fixture.add_disk('zram0', '252:0')
        fixture.resolved['/sys/class/block/zram0'] = '/sys/devices/virtual/block/zram0'
        fixture.files['/sys/class/block/zram0/backing_dev'] = '/dev/sdb1'
        fixture.swaps = ['/dev/zram0']
        with fixture.active():
            self.assertTrue(H.Graph().drive('sdb')['protected'])
            H.require_runtime_directory()  # writeback protects its drive, not the whole session
            self.assertFalse(H.Graph().blockers)

    def test_ram_only_zram_allowed(self):
        fixture = StorageFixture()
        fixture.add_disk('zram0', '252:0')
        fixture.resolved['/sys/class/block/zram0'] = '/sys/devices/virtual/block/zram0'
        fixture.files['/sys/class/block/zram0/backing_dev'] = 'none'
        fixture.swaps = ['/dev/zram0']
        with fixture.active():
            H.require_runtime_directory()
            self.assertFalse(H.Graph().blockers)
            self.assertFalse(H.Graph().drive('sdb')['protected'])
            self.assertEqual([row['kname'] for row in H.Graph().candidates()], ['sdb'])

    def test_zram_without_writeback_attribute_needs_no_kernel_config(self):
        fixture = StorageFixture()
        fixture.resolved['/sys/class/block/zram0'] = '/sys/devices/virtual/block/zram0'
        with fixture.active():
            self.assertIsNone(H.zram_backing('zram0'))

    def test_unreadable_zram_state_is_not_assumed_safe(self):
        fixture = StorageFixture()
        fixture.resolved['/sys/class/block/zram0'] = '/sys/devices/virtual/block/zram0'
        with fixture.active(), patch.object(Path, 'read_text', side_effect=PermissionError('denied')):
            with self.assertRaises(H.Refusal):
                H.zram_backing('zram0')

    def test_non_kernel_zram_is_not_assumed_ram_only(self):
        fixture = StorageFixture()
        fixture.resolved['/sys/class/block/zram0'] = '/sys/devices/pci/fake/zram0'
        with fixture.active(), self.assertRaises(H.Refusal):
            H.zram_backing('zram0')


class SwapCompatibilityTests(unittest.TestCase):
    def parse(self, body):
        with patch.object(Path, 'read_bytes', return_value=body):
            return H.swap_paths()

    def test_empty_swap_inventory(self):
        self.assertEqual(self.parse(b'Filename\tType\tSize\tUsed\tPriority\n'), [])

    def test_kernel_escapes_decoded_once_without_character_whitelist(self):
        names = [('/dev/disk/by-id/ata:example', '/dev/disk/by-id/ata:example'),
                 (r'/swap\040file', '/swap file'), (r'/swap\011file', '/swap\tfile'),
                 (r'/swap\012file', '/swap\nfile'), (r'/swap\134040file', r'/swap\040file'),
                 ('/swap\rfile', '/swap\rfile'), ('/swap-é', '/swap-é')]
        for encoded, expected in names:
            with self.subTest(encoded=encoded):
                body = ('Filename Type Size Used Priority\n' + encoded + '\tfile\t4096\t0\t-2\n').encode()
                self.assertEqual(self.parse(body), [expected])

    def test_bad_swap_records_refuse_with_entry_details(self):
        for entry in (r'/swap\999file file 4096 0 -2', '/swap file 4096',
                      r'/swap\040(deleted) file 4096 0 -2', 'relative file 4096 0 -2',
                      '/swap file unknown 0 -2'):
            with self.subTest(entry=entry), self.assertRaisesRegex(H.Refusal, 'swap|Swap'):
                self.parse(('Filename Type Size Used Priority\n' + entry + '\n').encode())

    def test_invalid_header_not_treated_as_empty_inventory(self):
        with self.assertRaisesRegex(H.Refusal, 'header'):
            self.parse(b'')

    def test_unreadable_inventory_has_source_and_reason(self):
        with patch.object(Path, 'read_bytes', side_effect=PermissionError('denied')):
            with self.assertRaisesRegex(H.Refusal, '/proc/swaps.*denied'):
                H.swap_paths()

    def test_duplicate_swap_entries_refuse(self):
        with self.assertRaisesRegex(H.Refusal, 'Duplicate.*swap'):
            self.parse(b'Filename Type Size Used Priority\n/swap file 4 0 -2\n/swap file 4 0 -2\n')

    def test_disk_swap_does_not_block_unrelated_target(self):
        fixture = StorageFixture()
        fixture.swaps = ['/dev/sda1']
        with fixture.active():
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertTrue(graph.drive('sda')['protected'])
            H.revalidate(graph.drive('sdb'), require_idle=True)

    def test_swap_partition_on_other_disk_protects_whole_disk(self):
        fixture = StorageFixture()
        fixture.swaps = ['/dev/sdb1']
        with fixture.active():
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertTrue(graph.drive('sdb')['protected'])
            self.assertEqual(graph.candidates(), [])

    def test_swap_alias_resolves_by_device_number(self):
        fixture = StorageFixture()
        fixture.swaps = ['/dev/disk/by-id/ata:example']
        fixture.resolved[fixture.swaps[0]] = '/dev/sdb1'
        with fixture.active():
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertTrue(graph.drive('sdb')['protected'])

    def test_swapfile_with_spaces_protects_backing_disk(self):
        fixture = StorageFixture()
        fixture.swaps = ['/mnt/data/swap file']
        fixture.file_mounts[fixture.swaps[0]] = fixture.mount('/mnt/data', 'sdb1')
        with fixture.active():
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertTrue(graph.drive('sdb')['protected'])

    def test_malformed_inventory_blocks_writes_but_allows_diagnosis(self):
        fixture = StorageFixture()
        fixture.files['/proc/swaps'] = 'unexpected format\n'
        with fixture.active():
            graph = H.Graph()
            self.assertTrue(any('/proc/swaps' in reason for reason in graph.blockers))
            with self.assertRaises(H.Refusal):
                H.revalidate(graph.drive('sdb'))

    def test_fstab_optional_unmounted_data_disk_is_selectable(self):
        fixture = StorageFixture()
        fixture.files['/etc/fstab'] = 'fixture'
        fixture.fstab = [{'source': '/dev/sdb1', 'target': '/mnt/archive', 'fstype': 'ext4'}]
        with fixture.active():
            graph = H.Graph()
            self.assertFalse(graph.blockers)
            self.assertFalse(graph.drive('sdb')['protected'])

    def test_fstab_configured_system_disk_is_protected(self):
        for target in ('/boot/efi', '/var', '/home', '/usr/local'):
            with self.subTest(target=target):
                fixture = StorageFixture()
                fixture.files['/etc/fstab'] = 'fixture'
                fixture.fstab = [{'source': '/dev/sdb1', 'target': target, 'fstype': 'ext4'}]
                with fixture.active():
                    graph = H.Graph()
                    self.assertFalse(graph.blockers)
                    self.assertTrue(graph.drive('sdb')['protected'])

    def test_check_does_not_require_tmpfs_work_directory(self):
        fixture = StorageFixture()
        with fixture.active(), patch.object(H, 'no_core_dumps'), patch.object(H, 'namespace_check'), \
                patch.object(H, 'require_runtime_directory', side_effect=H.Refusal('not tmpfs')), \
                patch.object(H.sys, 'argv', ['script', '--check']), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(H.main(), 0)

    def test_swap_activated_after_selection_prevents_erasure(self):
        fixture = StorageFixture()
        with fixture.active():
            target = H.Graph().drive('sdb')
            fixture.swaps = ['/dev/sdb1']
            with self.assertRaisesRegex(H.Refusal, 'protected.*swap'):
                H.revalidate(target, require_idle=True)

    def test_worker_recheck_allows_partition_metadata_destroyed_by_erase(self):
        fixture = StorageFixture()
        with fixture.active():
            target = H.Graph().drive('sdb')
            fixture.rows = [r for r in fixture.rows if r['kname'] != 'sdb1']
            H.revalidate(target, require_idle=True, partitions=False)
            # During selection/preparation, the same change still invalidates confirmation.
            with self.assertRaisesRegex(H.Refusal, 'topology changed'):
                H.revalidate(target, require_idle=True)

    def test_worker_recheck_still_refuses_changed_disk_generation(self):
        fixture = StorageFixture()
        with fixture.active():
            target = H.Graph().drive('sdb')
            fixture.files['/sys/class/block/sdb/diskseq'] = '999'
            with self.assertRaisesRegex(H.Refusal, 'diskseq'):
                H.revalidate(target, require_idle=True, partitions=False)

    def test_worker_recheck_still_refuses_active_swap_backing(self):
        fixture = StorageFixture()
        with fixture.active():
            target = H.Graph().drive('sdb')
            fixture.swaps = ['/dev/sdb1']
            with self.assertRaisesRegex(H.Refusal, 'protected.*swap'):
                H.revalidate(target, require_idle=True, partitions=False)


class AutomountCompatibilityTests(unittest.TestCase):
    def inhibit(self, initial, processes=1):
        prep = H.Preparation()
        commands = []
        def command(args, **kwargs):
            commands.append(args)
            return subprocess.CompletedProcess(args, processes if args[0] == 'pgrep' else 0,
                                               stdout='123' if processes == 0 else '', stderr='')
        with patch.object(prep, 'unit_state', side_effect=[initial,
                {'LoadState': 'masked', 'ActiveState': 'inactive'}]), \
                patch.object(H.os.path, 'lexists', return_value=False), \
                patch.object(H.os, 'lstat', return_value=SimpleNamespace(st_ino=123)), \
                patch.object(H, 'run', side_effect=command):
            prep.inhibit_automount()
        return prep, commands

    def test_absent_udisks_is_masked_without_stop(self):
        prep, commands = self.inhibit({'LoadState': 'not-found', 'ActiveState': 'inactive'})
        self.assertTrue(prep.masked)
        self.assertFalse(prep.restart)
        self.assertIn(['systemctl', 'mask', '--runtime', 'udisks2.service'], commands)
        self.assertNotIn(['systemctl', 'stop', 'udisks2.service'], commands)

    def test_running_udisks_is_stopped_and_marked_for_restart(self):
        prep, commands = self.inhibit({'LoadState': 'loaded', 'ActiveState': 'active'})
        self.assertTrue(prep.restart)
        self.assertIn(['systemctl', 'stop', 'udisks2.service'], commands)

    def test_independent_udisks_process_still_blocks(self):
        with self.assertRaisesRegex(H.Refusal, 'pgrep status=0.*123'):
            self.inhibit({'LoadState': 'not-found', 'ActiveState': 'inactive'}, processes=0)

    def test_unknown_udisks_state_is_reported(self):
        prep = H.Preparation()
        with patch.object(prep, 'unit_state', return_value={'LoadState': 'error', 'ActiveState': 'inactive'}):
            with self.assertRaisesRegex(H.Refusal, "load state.*error"):
                prep.inhibit_automount()


class SessionWorkflowTests(unittest.TestCase):
    def session(self, answers, fixture=None, backend=None, prepare=None):
        fixture = fixture or StorageFixture()
        tty = io.StringIO(answers)
        output = io.StringIO()
        with fixture.active(), contextlib.ExitStack() as stack:
            for owner, name, value in [(H, 'no_core_dumps', lambda: None),
                                       (H, 'namespace_check', lambda: None),
                                       (H.shutil, 'which', lambda name: '/usr/bin/' + name),
                                       (H.os, 'chmod', lambda *args: None),
                                       (H.os, 'listdir', lambda *args: []),
                                       (H.os, 'rmdir', lambda *args: None),
                                       (H.tempfile, 'mkdtemp', lambda **kwargs: '/run/fixture')]:
                stack.enter_context(patch.object(owner, name, value))
            stack.enter_context(patch('builtins.open', return_value=tty))
            stack.enter_context(patch.object(H.sys, 'argv', ['script', 'interactive', '/fixture/script']))
            stack.enter_context(patch.object(H.socket, 'socket'))
            preparation = stack.enter_context(patch.object(H, 'Preparation'))
            if prepare is not None:
                preparation.return_value.__enter__.side_effect = prepare
            worker = stack.enter_context(patch.object(H, 'hdd_backend', side_effect=backend))
            with contextlib.redirect_stdout(output):
                status = H.main()
            return status, worker.call_count, output.getvalue(), fixture.mutations

    def test_quit_and_eof_preserve_failure(self):
        def fail(*args):
            H.WRITE_STARTED = True
            raise H.Refusal('synthetic write failure')
        for ending in ('q\n', ''):
            status, calls, output, mutations = self.session(
                '1\nINSPECT\nERASE SERIAL-sdb\n' + ending, backend=fail)
            self.assertEqual(status, 2)
            self.assertEqual(calls, 1)
            self.assertNotIn('All accessible sectors overwritten and verified.', output)
            self.assertFalse(mutations)

    def test_later_verified_result_does_not_hide_prior_failure(self):
        calls = []
        def backend(*args):
            calls.append(True)
            H.WRITE_STARTED = True
            if len(calls) == 1:
                raise H.Refusal('synthetic first failure')
            H.WRITE_FINISHED = H.VERIFIED = True
        answers = '1\nINSPECT\nERASE SERIAL-sdb\n' * 2 + 'q\n'
        status, count, output, mutations = self.session(answers, backend=backend)
        self.assertEqual(status, 2)
        self.assertEqual(count, 2)
        self.assertEqual(output.count('All accessible sectors overwritten and verified.'), 1)
        self.assertFalse(mutations)

    def test_manual_result_survives_eof_during_save_question(self):
        fixture = StorageFixture()
        fixture.media = 'SSD'
        status, calls, output, mutations = self.session('1\nINSPECT\n', fixture)
        self.assertEqual(status, 3)
        self.assertEqual(calls, 0)
        self.assertFalse(mutations)

    def test_unconfirmed_erasure_never_reaches_worker(self):
        status, calls, output, mutations = self.session('1\nINSPECT\nwrong confirmation\nq\n')
        self.assertEqual(status, 0)
        self.assertEqual(calls, 0)
        self.assertFalse(mutations)

    def test_duplicate_identifiers_never_reach_worker(self):
        fixture = StorageFixture()
        fixture.rows[0]['serial'] = fixture.rows[1]['serial']
        fixture.rows[0]['wwn'] = fixture.rows[1]['wwn']
        status, calls, output, mutations = self.session('1\nINSPECT\nNO\nq\n', fixture)
        self.assertEqual(status, 3)
        self.assertEqual(calls, 0)
        self.assertFalse(mutations)

    def test_missing_identifiers_never_reach_worker(self):
        fixture = StorageFixture()
        fixture.rows[1].update(serial='', wwn='')
        status, calls, output, mutations = self.session('1\nINSPECT\nNO\nq\n', fixture)
        self.assertEqual(status, 3)
        self.assertEqual(calls, 0)
        self.assertFalse(mutations)

    def test_unresolved_boot_protection_never_reaches_worker(self):
        fixture = StorageFixture()
        fixture.files['/proc/cmdline'] = 'root=live:UUID=MISSING boot=live'
        status, calls, output, mutations = self.session('1\nINSPECT\nNO\nq\n', fixture)
        self.assertEqual(status, 3)
        self.assertEqual(calls, 0)
        self.assertFalse(mutations)

    def test_device_change_after_confirmation_never_reaches_worker(self):
        fixture = StorageFixture()
        def change():
            fixture.files['/sys/class/block/sdb/diskseq'] = '999'
        status, calls, output, mutations = self.session('1\nINSPECT\nERASE SERIAL-sdb\nq\n',
                                                        fixture, prepare=change)
        self.assertEqual(status, 2)
        self.assertEqual(calls, 0)
        self.assertFalse(mutations)

    def test_new_zram_backing_after_confirmation_blocks_worker(self):
        fixture = StorageFixture()
        fixture.add_disk('zram0', '252:0')
        fixture.resolved['/sys/class/block/zram0'] = '/sys/devices/virtual/block/zram0'
        fixture.files['/sys/class/block/zram0/backing_dev'] = 'none'
        fixture.swaps = ['/dev/zram0']
        def change():
            fixture.files['/sys/class/block/zram0/backing_dev'] = '/dev/sdb1'
        status, calls, output, mutations = self.session('1\nINSPECT\nERASE SERIAL-sdb\nq\n',
                                                        fixture, prepare=change)
        self.assertEqual(status, 2)
        self.assertEqual(calls, 0)
        self.assertFalse(mutations)

    def test_q_and_eof_before_any_operation_agree(self):
        for answers in ('q\n', ''):
            status, calls, output, mutations = self.session(answers)
            self.assertEqual(status, 0)
            self.assertEqual(calls, 0)
            self.assertFalse(mutations)


class PureSafetyTests(unittest.TestCase):
    def setUp(self):
        H.INTERRUPTING = False
        H.PENDING_SIGNAL = None
        H.SIGNAL_DEFER_DEPTH = 0

    def tearDown(self):
        H.cleanup_registered_processes()
        H.INTERRUPTING = False
        H.PENDING_SIGNAL = None

    def test_interruption_is_deferred_until_child_assignment_boundary(self):
        owned = []
        with self.assertRaises(H.Interrupted):
            with H.defer_signals():
                H.on_signal(signal.SIGINT, None)
                owned.append('assigned')
        self.assertEqual(owned, ['assigned'])
        self.assertEqual(H.SIGNAL_DEFER_DEPTH, 0)
        self.assertIsNone(H.PENDING_SIGNAL)

    def test_repeated_interrupt_does_not_abandon_cancellation_cleanup(self):
        with self.assertRaises(H.Interrupted):
            H.on_signal(signal.SIGINT, None)
        H.on_signal(signal.SIGINT, None)
        H.on_signal(signal.SIGTERM, None)
        self.assertTrue(H.INTERRUPTING)

    def test_changed_mount_is_refused_before_creating_instruction_file(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(H, 'text_file', return_value='mnt_id:\t100\n'):
            info = os.stat(directory)
            mount = {'id': 101, 'maj:min': '%d:%d' % (os.major(info.st_dev), os.minor(info.st_dev))}
            with self.assertRaises(H.Refusal):
                H.write_exclusive(directory, b'instructions', expected_mount=mount)
            self.assertFalse((Path(directory) / H.NAME).exists())

    def test_mount_device_mismatch_is_refused_before_file_creation(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(H, 'text_file', return_value='mnt_id:\t100\n'):
            with self.assertRaises(H.Refusal):
                H.write_exclusive(directory, b'instructions',
                                  expected_mount={'id': 100, 'maj:min': '999:999'})
            self.assertFalse((Path(directory) / H.NAME).exists())

    def test_bound_instruction_directory_supports_round_trip(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(H, 'text_file', return_value='mnt_id:\t100\n'):
            info = os.stat(directory)
            mount = {'id': 100, 'maj:min': '%d:%d' % (os.major(info.st_dev), os.minor(info.st_dev))}
            H.write_exclusive(directory, b'instructions', expected_mount=mount)
            H.verify_text(directory, b'instructions', expected_mount=mount)

    def test_readback_rejects_fifo_without_waiting_for_a_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            os.mkfifo(Path(directory) / H.NAME)
            with self.assertRaises(H.Refusal):
                H.verify_text(directory, b'instructions')

    def test_shell_bootstrap_loads_helper_without_executing_a_heredoc(self):
        source = Path(__file__).resolve().parents[1] / 'erase-all-data.sh'
        shell, helper = source.read_text().split("\n: <<'PY'\n", 1)
        self.assertIn('exec python3 -I -c', shell)
        self.assertNotIn('<<', shell)
        self.assertTrue(shell.rstrip().endswith('# shellcheck disable=SC2317'))
        self.assertIn('\nexit 2\n', shell)

    def test_kernel_mount_table_identity_is_accepted(self):
        with patch.object(H.os.path, 'samefile', return_value=True) as identity:
            H.require_volatile_mtab()
            identity.assert_called_once_with('/etc/mtab', '/proc/self/mounts')

    def test_persistent_or_missing_mount_table_refused(self):
        for value in (False, FileNotFoundError('/etc/mtab')):
            kwargs = {'side_effect': value} if isinstance(value, Exception) else {'return_value': value}
            with patch.object(H.os.path, 'samefile', **kwargs), self.assertRaises(H.Refusal):
                H.require_volatile_mtab()

    def test_mtab_symlinks_and_regular_copy_use_actual_file_identity(self):
        samefile = os.path.samefile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'proc/123').mkdir(parents=True)
            (root / 'proc/123/mounts').write_text('synthetic kernel mount view')
            (root / 'proc/self').symlink_to('123')
            (root / 'proc/mounts').symlink_to('self/mounts')
            mtab = root / 'mtab'
            def compare(left, right):
                self.assertEqual((left, right), ('/etc/mtab', '/proc/self/mounts'))
                return samefile(mtab, root / 'proc/self/mounts')
            with patch.object(H.os.path, 'samefile', side_effect=compare):
                for target in ('proc/self/mounts', 'proc/mounts'):
                    mtab.symlink_to(target)
                    H.require_volatile_mtab()
                    mtab.unlink()
                mtab.write_text('synthetic kernel mount view')
                with self.assertRaises(H.Refusal):
                    H.require_volatile_mtab()

    def test_ntfs_mount_is_not_attempted_without_volatile_mtab(self):
        with patch.object(H.os.path, 'samefile', return_value=False), patch.object(H, 'run') as query:
            with self.assertRaises(H.Refusal):
                H.mount_fs('/synthetic/partition', '/synthetic/mount', 'ntfs')
            query.assert_not_called()

    def test_session_failure_survives_later_success_or_manual_result(self):
        outcome = H.SessionOutcome()
        for status in (2, 0, 3, 0):
            outcome.record(status, drive())
        self.assertEqual(outcome.status, 2)
        self.assertEqual(len(outcome.results), 4)

    def test_session_manual_result_survives_later_success(self):
        outcome = H.SessionOutcome()
        outcome.record(3, drive())
        outcome.record(0, drive())
        self.assertEqual(outcome.status, 3)

    def test_terminal_controls_are_escaped(self):
        displayed = H.clean('\x1b[2J\n\r\u202e')
        for unsafe in ('\x1b', '\n', '\r', '\u202e'):
            self.assertNotIn(unsafe, displayed)

    def test_reused_path_changes_fingerprint(self):
        old = drive()
        for key, value in [('serial', 'OTHER'), ('size', 512), ('diskseq', '124'),
                           ('physical_path', '/sys/devices/another')]:
            changed = dict(old, **{key: value})
            self.assertNotEqual(H.fingerprint(old), H.fingerprint(changed))

    def test_partition_changes_invalidate_confirmation(self):
        old = drive()
        changed = copy.deepcopy(old)
        changed['parts'] = [dict(path='/dev/sdb1', kname='sdb1', size=512)]
        self.assertNotEqual(H.fingerprint(old), H.fingerprint(changed))

    def test_partition_move_invalidates_confirmation_without_uuid_or_size_change(self):
        old = drive()
        old['parts'] = [dict(path='/dev/sdb1', kname='sdb1', size=4096, start=2048,
                             uuid='SAME', partuuid='SAME', fstype='ext4')]
        changed = copy.deepcopy(old)
        changed['parts'][0]['start'] = 4096
        self.assertNotEqual(H.fingerprint(old), H.fingerprint(changed))

    def test_partition_ancestry_protects_whole_drive(self):
        graph = H.Graph.__new__(H.Graph)
        graph.rows = {'sdb': {'type': 'disk'}, 'sdb1': {'type': 'part', 'pkname': 'sdb'}}
        with patch.object(Path, 'iterdir', return_value=iter([])):
            self.assertEqual(graph.block_storage('sdb1'), {'sdb'})

    def test_missing_or_cyclic_parent_refused(self):
        graph = H.Graph.__new__(H.Graph)
        graph.rows = {'sdb1': {'type': 'part', 'pkname': 'sdb1'}}
        with self.assertRaises(H.Refusal):
            graph.block_storage('sdb1')
        with self.assertRaises(H.Refusal):
            graph.block_storage('missing')

    def test_overlay_protects_every_layer(self):
        graph = H.Graph.__new__(H.Graph)
        mount = {'target': '/', 'fstype': 'overlay',
                 'options': 'rw,lowerdir=/lower1:/lower2,upperdir=/upper,workdir=/work'}
        with patch.object(graph, 'path_storage', side_effect=lambda path, seen: {path}) as resolve:
            self.assertEqual(graph.mount_storage(mount), {'/lower1', '/lower2', '/upper', '/work'})
            self.assertEqual(resolve.call_count, 4)

    def test_escaped_overlay_refused(self):
        graph = H.Graph.__new__(H.Graph)
        with self.assertRaises(H.Refusal):
            graph.mount_storage({'target': '/', 'fstype': 'overlay', 'options': r'lowerdir=/a\072b'})

    def test_short_transfer_cannot_succeed(self):
        proc = type('Proc', (), {'poll': lambda self: 0, 'returncode': 0})()
        with patch.object(H, 'check_bound'), patch.object(H.os, 'lseek', return_value=512), patch.object(H, 'progress'):
            with self.assertRaises(H.Refusal):
                H.monitor([proc], 999, drive(), object(), 'Verification')

    def test_comparator_failure_cannot_succeed(self):
        proc = type('Proc', (), {'poll': lambda self: 1, 'returncode': 1})()
        with patch.object(H, 'check_bound'), patch.object(H.os, 'lseek', return_value=drive()['size']), patch.object(H, 'progress'):
            with self.assertRaises(H.Refusal):
                H.monitor([proc], 999, drive(), object(), 'Verification')

    def test_reaped_pid_is_not_signalled(self):
        proc = type('Proc', (), {'poll': lambda self: 0})()
        with patch.object(H.os, 'killpg') as kill:
            H.stop_group(proc)
            kill.assert_not_called()

    def test_raw_users_block_operation(self):
        result = subprocess.CompletedProcess([], 0, stdout='123 456', stderr='')
        with patch.object(H, 'need'), patch.object(H, 'run', return_value=result):
            with self.assertRaises(H.Refusal):
                H.check_raw_users(drive(), [123])
            H.check_raw_users(drive(), [123, 456])

    def test_dirty_ntfs_refused_without_write_probe(self):
        def query(args, **kwargs):
            text = 'Volume Flags: 0x0001 DIRTY\nRestart state: DIRTY\n' if args[0] == 'ntfsinfo' else ''
            self.assertNotIn('--readwrite', args)
            return subprocess.CompletedProcess(args, 0, stdout=text, stderr='')
        with patch.object(H, 'need'), patch.object(H, 'run', side_effect=query):
            with self.assertRaises(H.Refusal):
                H.fs_clean('/synthetic/partition', 'ntfs')

    def test_clean_ntfs_checks_are_read_only(self):
        def query(args, **kwargs):
            self.assertNotIn('--readwrite', args)
            text = 'Volume Flags: 0x0000\nRestart state: CLEAN\n' if args[0] == 'ntfsinfo' else ''
            return subprocess.CompletedProcess(args, 0, stdout=text, stderr='')
        with patch.object(H, 'need'), patch.object(H, 'run', side_effect=query):
            H.fs_clean('/synthetic/partition', 'ntfs')

    def test_dirty_fat_refused_without_repairs(self):
        result = subprocess.CompletedProcess([], 0, stdout='Dirty bit is set', stderr='')
        with patch.object(H, 'need'), patch.object(H, 'run', return_value=result) as query:
            with self.assertRaises(H.Refusal):
                H.fs_clean('/synthetic/partition', 'vfat')
            self.assertEqual(query.call_args[0][0], ['fsck.fat', '-n', '/synthetic/partition'])

    def test_existing_file_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / H.NAME
            destination.write_bytes(b'keep this')
            with self.assertRaises(FileExistsError):
                H.write_exclusive(directory, b'replacement')
            self.assertEqual(destination.read_bytes(), b'keep this')

    def test_instruction_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            other = Path(directory) / 'keep'
            other.write_bytes(b'keep this')
            (Path(directory) / H.NAME).symlink_to(other)
            with self.assertRaises(FileExistsError):
                H.write_exclusive(directory, b'replacement')
            self.assertEqual(other.read_bytes(), b'keep this')

    def test_instruction_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            H.write_exclusive(directory, b'full instructions\n')
            H.verify_text(directory, b'full instructions\n')
            with self.assertRaises(H.Refusal):
                H.verify_text(directory, b'wrong instructions\n')

    def test_instruction_verification_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'other').write_bytes(b'payload')
            (root / H.NAME).symlink_to('other')
            with self.assertRaises(OSError):
                H.verify_text(directory, b'payload')

    def test_full_filesystem_cannot_report_a_successful_save(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(H.os, 'write', side_effect=OSError(28, 'No space left on device')):
            with self.assertRaises(OSError):
                H.write_exclusive(directory, b'instructions')

    def test_unlisted_filesystem_is_declined_without_commands(self):
        with patch.object(H, 'run') as query:
            with self.assertRaises(H.Refusal):
                H.fs_clean('/synthetic/partition', 'unknown')
            query.assert_not_called()


class FilesystemSafetyTests(unittest.TestCase):
    HEADER = 'Filesystem state: clean\nFilesystem features: has_journal extent\nJournal inode: 8\n'

    def metadata_command(self, header, calls):
        def command(args, **kwargs):
            calls.append((args, kwargs))
            return subprocess.CompletedProcess(args, 0,
                stdout=header if args[0] == 'dumpe2fs' else '', stderr='')
        return command

    def test_external_journal_refused_before_checker_or_mount(self):
        for extra in ('Journal UUID: 12345678-1234-1234-1234-123456789abc\n',
                      'Journal device: 0x0811\n', 'Mount options: journal_path=/dev/other\n'):
            for action in ('check', 'mount'):
                calls = []
                with patch.object(H, 'need'), patch.object(H, 'run', self.metadata_command(self.HEADER + extra, calls)):
                    with self.assertRaises(H.Refusal):
                        if action == 'check':
                            H.fs_clean('/synthetic/partition', 'ext4')
                        else:
                            H.mount_fs('/synthetic/partition', '/synthetic/mount', 'ext4')
                self.assertEqual([args[0] for args, kwargs in calls], ['dumpe2fs'])

    def test_dirty_recovery_missing_internal_journal_and_ambiguous_metadata_refused(self):
        headers = [self.HEADER.replace('clean', 'not clean'),
                   self.HEADER.replace('extent', 'extent needs_recovery'),
                   self.HEADER.replace('has_journal', 'journal_dev'),
                   self.HEADER.replace('has_journal', ''),
                   self.HEADER.replace('Journal inode: 8\n', ''),
                   self.HEADER + 'Journal inode: 9\n',
                   self.HEADER + 'Filesystem state: clean\n',
                   self.HEADER + 'Mount options: noload\n']
        for header in headers:
            calls = []
            with patch.object(H, 'need'), patch.object(H, 'run', self.metadata_command(header, calls)):
                with self.assertRaises(H.Refusal):
                    H.fs_clean('/synthetic/partition', 'ext4')
            self.assertEqual([args[0] for args, kwargs in calls], ['dumpe2fs'])

    def test_checkers_inherit_bound_device_and_never_request_repairs(self):
        for fs in ('ext2', 'ext3', 'ext4', 'vfat', 'exfat'):
            header = self.HEADER if fs != 'ext2' else 'Filesystem state: clean\nFilesystem features: filetype\n'
            calls = []
            with patch.object(H, 'need'), patch.object(H, 'say'), \
                    patch.object(H, 'run', self.metadata_command(header, calls)):
                H.fs_clean('/proc/self/fd/42', fs, pass_fds=(42,))
            self.assertTrue(calls)
            for args, kwargs in calls:
                self.assertEqual(kwargs['pass_fds'], (42,))
                self.assertEqual(args[-1], '/proc/self/fd/42')
                self.assertNotIn('-y', args)
                self.assertNotIn('-p', args)
                if args[0] != 'dumpe2fs':
                    self.assertIn('-n', args)
                if args[0] == 'e2fsck':
                    self.assertEqual(kwargs['env']['E2FSCK_CONFIG'], '/dev/null')
                    self.assertEqual(set(kwargs['env']), {'PATH', 'LC_ALL', 'BLKID_FILE', 'E2FSCK_CONFIG'})

    def mounted(self, fs, readonly=False, options=None, result_driver=None):
        calls = []
        row = {'id': 100, 'source': '/synthetic/partition', 'target': '/synthetic/mount',
               'fstype': result_driver or ('ext4' if fs == 'ext3' else fs), 'maj:min': '8:17',
               'options': options or ('ro,nodev,nosuid,noexec,norecovery' if readonly else
                                     'rw,nodev,nosuid,noexec,data=ordered,errors=remount-ro')}
        with patch.object(H, 'need'), patch.object(H, 'run', self.metadata_command(self.HEADER, calls)), \
                patch.object(H, 'run_json', return_value={'filesystems': [row]}), \
                patch.object(H, 'number_of', return_value='8:17'):
            H.mount_fs('/synthetic/partition', '/synthetic/mount', fs, readonly=readonly)
        return calls[-1][0]

    def test_writable_ext3_and_ext4_keep_journaling_and_barriers(self):
        for fs in ('ext3', 'ext4'):
            args = self.mounted(fs)
            self.assertEqual(args[args.index('-t') + 1], 'ext4')
            options = set(args[args.index('-o') + 1].split(','))
            self.assertTrue({'rw', 'data=ordered', 'barrier=1', 'errors=remount-ro', 'noinit_itable'} <= options)
            self.assertFalse({'noload', 'norecovery'} & options)

    def test_readonly_ext3_and_ext4_suppress_journal_replay(self):
        for fs in ('ext3', 'ext4'):
            args = self.mounted(fs, readonly=True)
            options = set(args[args.index('-o') + 1].split(','))
            self.assertTrue({'ro', 'noload'} <= options)
            self.assertNotIn('data=ordered', options)

    def test_bad_driver_or_effective_journal_options_refused(self):
        with self.assertRaises(H.Refusal):
            self.mounted('ext3', result_driver='ext3')  # ext4 was explicitly requested
        for option in ('noload', 'norecovery', 'barrier=0', 'nobarrier', 'data=writeback'):
            with self.assertRaises(H.Refusal):
                self.mounted('ext4', options='rw,nodev,nosuid,noexec,data=ordered,' + option)
        with self.assertRaises(H.Refusal):
            self.mounted('ext4', readonly=True, options='ro,nodev,nosuid,noexec')

    def test_kernel_mount_view_can_omit_safe_defaults(self):
        args = self.mounted('ext4', options='rw,nodev,nosuid,noexec')
        self.assertIn('data=ordered', args[args.index('-o') + 1].split(','))

    def test_mount_handover_revalidates_after_metadata_and_can_prevent_mount(self):
        calls = []
        def refuse():
            self.assertEqual([args[0] for args, kwargs in calls], ['dumpe2fs'])
            raise H.Refusal('simulated changed identity at handover')
        with patch.object(H, 'need'), patch.object(H, 'run', self.metadata_command(self.HEADER, calls)):
            with self.assertRaises(H.Refusal):
                H.mount_fs('/synthetic/partition', '/synthetic/mount', 'ext4', before_mount=refuse)
        self.assertEqual([args[0] for args, kwargs in calls], ['dumpe2fs'])

    def test_kernel_claim_is_readonly_exclusive_and_closes_on_checker_failure(self):
        target = drive()
        part = {'path': '/dev/sdb1', 'kname': 'sdb1'}
        with patch.object(H.os, 'open', return_value=42) as opened, \
                patch.object(H.os, 'close') as closed, patch.object(H.fcntl, 'flock') as locked, \
                patch.object(H, 'check_filesystem_bound') as bound:
            with self.assertRaises(H.Refusal):
                with H.exclusive_filesystem(part, target, 41) as fd:
                    self.assertEqual(fd, 42)
                    raise H.Refusal('simulated consistency-check failure')
            self.assertTrue(opened.call_args.args[1] & os.O_EXCL)
            self.assertEqual(opened.call_args.args[1] & os.O_ACCMODE, os.O_RDONLY)
            bound.assert_called_once_with(42, part, target, 41)
            locked.assert_called_once_with(42, H.fcntl.LOCK_EX | H.fcntl.LOCK_NB)
            closed.assert_called_once_with(42)

    def test_whole_disk_claim_does_not_conflict_with_existing_parent_flock(self):
        target = drive()
        with patch.object(H.os, 'open', return_value=42), patch.object(H.os, 'close'), \
                patch.object(H.fcntl, 'flock') as locked, patch.object(H, 'check_filesystem_bound'):
            with H.exclusive_filesystem(target, target, 41):
                pass
            locked.assert_not_called()

    def test_failed_exclusive_claim_declines_without_checking_filesystem(self):
        with patch.object(H.os, 'open', side_effect=OSError(16, 'busy')), \
                patch.object(H, 'check_filesystem_bound') as bound:
            with self.assertRaises(OSError):
                with H.exclusive_filesystem(drive(), drive(), 41):
                    self.fail('Claim failure permitted filesystem access')
            bound.assert_not_called()

    def test_partition_extent_or_generation_change_is_refused(self):
        target = drive()
        part = {'kname': 'sdb1', 'path': '/dev/sdb1', 'type': 'part', 'pkname': 'sdb',
                'maj:min': '8:17', 'size': 4096, 'start': 2048}
        node = '/sys/class/block/sdb1'
        fields = {node + '/size': '8', node + '/start': '2048', node + '/ro': '0'}
        for changed in ('none', 'start', 'size', 'ro', 'parent', 'generation'):
            values = dict(fields)
            if changed in {'start', 'size', 'ro'}:
                values[node + '/' + changed] = {'start': '4096', 'size': '16', 'ro': '1'}[changed]
            with patch.object(H, 'check_bound'), patch.object(H.os, 'fstat',
                    return_value=SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(8, 17))), \
                    patch.object(H, 'ioctl_value', side_effect=[999 if changed == 'generation' else 123, 4096, 512]), \
                    patch.object(H.os.path, 'realpath', return_value=target['physical_path'] +
                                 ('/other' if changed == 'parent' else '/sdb1')), \
                    patch.object(H, 'number_of', return_value='8:17'), \
                    patch.object(H, 'text_file', side_effect=lambda path: values[str(path)]):
                if changed == 'none':
                    H.check_filesystem_bound(42, part, target, 41)
                else:
                    with self.assertRaises(H.Refusal):
                        H.check_filesystem_bound(42, part, target, 41)


class InstructionSavingWorkflowTests(unittest.TestCase):
    """Real save orchestration; all block access, mounts and file writes mocked."""
    def exercise(self, failure=None):
        target = drive()
        target['parts'] = [{'path': '/dev/sdb1', 'kname': 'sdb1', 'type': 'part', 'pkname': 'sdb',
                            'fstype': 'ext4', 'ro': False, 'maj:min': '8:17', 'size': 4096, 'start': 2048}]
        info = {'stable': True, 'media': 'HDD'}
        events, handles = [], set()
        next_fd = 40
        class Prep:
            def __enter__(self):
                events.append('prepare')
                return self
            def check(self):
                events.append('prep-check')
            def __exit__(self, *args):
                events.append('restore')
        def opened(path, flags):
            nonlocal next_fd
            if flags & os.O_EXCL and failure == 'claim':
                raise OSError(16, 'simulated busy filesystem')
            next_fd += 1
            handles.add(next_fd)
            events.append(('open', next_fd, flags))
            return next_fd
        def closed(fd):
            handles.remove(fd)
            events.append(('close', fd))
        def checked(path, fs, pass_fds=()):
            self.assertEqual((path, fs, pass_fds), ('/proc/self/fd/42', 'ext4', (42,)))
            self.assertIn(42, handles)
            events.append('filesystem-check')
            if failure == 'check':
                raise H.Refusal('simulated failed consistency check')
            if failure == 'interrupt':
                raise H.Interrupted(signal.SIGINT)
        def mounted(path, destination, fs, readonly=False, before_mount=None):
            self.assertNotIn(42, handles)
            self.assertEqual(handles, {41, 43})
            self.assertIsNotNone(before_mount)
            events.append('mount-handover')
            before_mount()
            events.append(('mount', readonly))
            return {'id': 100, 'maj:min': '8:17'}
        def revalidated(*args, **kwargs):
            events.append('revalidate')
            if failure == 'handover' and 'mount-handover' in events:
                raise H.Refusal('simulated changed protection at mount handover')
        def command(args, **kwargs):
            self.assertEqual(args[:3], ['umount', '-n', '--'])
            events.append('unmount')
            return subprocess.CompletedProcess(args, 0, stdout='', stderr='')
        def write(*args, **kwargs):
            self.assertNotIn(42, handles)
            events.append('write')
        def verify(*args, **kwargs):
            events.append('verify')
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            patches = [(H, 'Preparation', Prep), (H, 'MountCleanup', lambda dest: contextlib.nullcontext()),
                       (H, 'need', lambda *args: None), (H, 'say', lambda *args: None),
                       (H, 'ask', lambda *args: 'SAVE'), (H, 'revalidate', revalidated),
                       (H, 'unmount_target', lambda *args: events.append('initial-unmount')),
                       (H, 'check_raw_users', lambda *args, **kwargs: events.append('users')),
                       (H, 'check_bound', lambda *args: None),
                       (H, 'check_filesystem_bound', lambda *args: events.append('bound')),
                       (H, 'fs_clean', checked), (H, 'mount_fs', mounted), (H, 'run', command),
                       (H, 'require_runtime_directory', lambda: None), (H, 'write_exclusive', write),
                       (H, 'verify_text', verify), (H.os, 'open', opened), (H.os, 'close', closed),
                       (H.os.path, 'ismount', lambda *args: False), (H.fcntl, 'flock', lambda *args: None)]
            for owner, name, value in patches:
                stack.enter_context(patch.object(owner, name, value))
            if failure:
                expected = H.Interrupted if failure == 'interrupt' else (H.Refusal, OSError)
                with self.assertRaises(expected):
                    H.save_instructions(target, info, 'complete instructions', directory)
            else:
                H.save_instructions(target, info, 'complete instructions', directory)
            self.assertFalse(handles)
            self.assertFalse((Path(directory) / 'target-mount').exists())
        return events

    def test_successful_save_claims_checks_releases_mounts_writes_and_verifies(self):
        events = self.exercise()
        self.assertLess(events.index('filesystem-check'), events.index(('close', 42)))
        self.assertLess(events.index(('close', 42)), events.index(('mount', False)))
        self.assertLess(events.index(('mount', False)), events.index('write'))
        self.assertLess(events.index('write'), events.index(('mount', True)))
        self.assertLess(events.index(('mount', True)), events.index('verify'))
        self.assertEqual(events.count('unmount'), 2)
        self.assertIn('restore', events)

    def test_busy_claim_failed_check_and_interruption_prevent_mount_and_writes(self):
        for failure in ('claim', 'check', 'interrupt'):
            events = self.exercise(failure)
            self.assertNotIn(('mount', False), events)
            self.assertNotIn('write', events)
            self.assertIn('restore', events)

    def test_changed_protection_during_handover_prevents_file_creation(self):
        events = self.exercise('handover')
        self.assertIn(('close', 42), events)
        self.assertNotIn(('mount', False), events)
        self.assertNotIn('write', events)
        self.assertIn('restore', events)

    def test_unknown_save_metadata_reprints_complete_instructions(self):
        target, info = drive(), {'stable': True, 'media': 'HDD'}
        with patch.object(H, 'instructions', return_value='complete instructions'), \
                patch.object(H, 'ask', return_value='yes'), patch.object(H, 'say'), \
                patch.object(H, 'save_instructions', side_effect=ValueError('ambiguous metadata')), \
                patch.object(H, 'display_text') as display:
            H.manual(target, info, '/synthetic/ram')
            self.assertEqual(display.call_count, 2)
            self.assertEqual(display.call_args.args, ('complete instructions',))


class WorkerIntegrationTests(unittest.TestCase):
    def setUp(self):
        H.INTERRUPTING = False
        H.PENDING_SIGNAL = None
        H.SIGNAL_DEFER_DEPTH = 0
        self.tmp = tempfile.TemporaryDirectory(prefix='erase-disposable-test-')
        self.path = Path(self.tmp.name) / 'disposable.img'
        self.target = drive()
        self.target['path'] = str(self.path)
        # Not a round chunk count: exercises the final aligned partial transfer.
        self.path.write_bytes(b'\x5a' * self.target['size'])
        self.prep = type('Prep', (), {'check': lambda self: None})()
        H.WRITE_STARTED = H.WRITE_FINISHED = H.VERIFIED = False

    def tearDown(self):
        H.cleanup_registered_processes()
        H.INTERRUPTING = False
        H.PENDING_SIGNAL = None
        self.tmp.cleanup()

    @contextlib.contextmanager
    def file_handle(self, target):
        # Test-only adapter is never present in the production helper. Assert
        # ownership/type before any open; there is no supplied device pathname.
        path = Path(target['path'])
        self.assertEqual(path.parent, Path(self.tmp.name))
        self.assertTrue(path.is_file())
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            yield fd
        finally:
            os.close(fd)

    @contextlib.contextmanager
    def isolated(self):
        with contextlib.ExitStack() as stack:
            for name in ('unmount_target', 'check_raw_users', 'check_bound',
                         'revalidate', 'require_runtime_directory', 'progress'):
                stack.enter_context(patch.object(H, name))
            stack.enter_context(patch.object(H, 'exclusive_drive', self.file_handle))
            yield

    def test_exact_zero_write_and_full_direct_verification(self):
        with self.isolated():
            H.hdd_backend(self.target, {'eligible': True}, self.prep)
        self.assertTrue(H.VERIFIED)
        self.assertEqual(self.path.stat().st_size, self.target['size'])
        self.assertEqual(self.path.read_bytes(), b'\0' * self.target['size'])

    def test_tail_mismatch_refused(self):
        monitor = H.monitor
        def corrupt_after_write(procs, fd, target, prep, phase):
            monitor(procs, fd, target, prep, phase)
            if phase == 'Overwrite':
                with self.path.open('r+b') as image:
                    image.seek(target['size'] - 1)
                    image.write(b'\x01')
                    image.flush()
                    os.fsync(image.fileno())
        with self.isolated(), patch.object(H, 'monitor', corrupt_after_write):
            with self.assertRaises(H.Refusal):
                H.hdd_backend(self.target, {'eligible': True}, self.prep)
        self.assertTrue(H.WRITE_FINISHED)
        self.assertFalse(H.VERIFIED)

    def test_short_verification_refused(self):
        popen = H.subprocess.Popen
        def short_reader(args, **kwargs):
            args = list(args)
            if 'iflag=direct,fullblock,count_bytes' in args:
                args[args.index('count=%d' % self.target['size'])] = 'count=%d' % (self.target['size'] - 512)
            return popen(args, **kwargs)
        with self.isolated(), patch.object(H.subprocess, 'Popen', short_reader):
            with self.assertRaises(H.Refusal):
                H.hdd_backend(self.target, {'eligible': True}, self.prep)
        self.assertFalse(H.VERIFIED)

    def test_writer_error_never_marks_verified(self):
        popen = H.subprocess.Popen
        def broken_writer(args, **kwargs):
            args = list(args)
            if 'if=/dev/zero' in args:
                args[args.index('if=/dev/zero')] = 'if=' + str(Path(self.tmp.name) / 'missing-input')
            return popen(args, **kwargs)
        with self.isolated(), patch.object(H.subprocess, 'Popen', broken_writer):
            with self.assertRaises(H.Refusal):
                H.hdd_backend(self.target, {'eligible': True}, self.prep)
        self.assertTrue(H.WRITE_STARTED)
        self.assertFalse(H.WRITE_FINISHED)
        self.assertFalse(H.VERIFIED)

    def test_reader_error_never_marks_verified(self):
        popen = H.subprocess.Popen
        def broken_reader(args, **kwargs):
            args = list(args)
            if 'iflag=direct,fullblock,count_bytes' in args:
                args.append('if=' + str(Path(self.tmp.name) / 'missing-input'))
            return popen(args, **kwargs)
        with self.isolated(), patch.object(H.subprocess, 'Popen', broken_reader):
            with self.assertRaises(H.Refusal):
                H.hdd_backend(self.target, {'eligible': True}, self.prep)
        self.assertTrue(H.WRITE_FINISHED)
        self.assertFalse(H.VERIFIED)

    def test_interruption_never_marks_verified(self):
        def interrupt(*args):
            raise H.Interrupted(2)
        with self.isolated(), patch.object(H, 'monitor', interrupt):
            with self.assertRaises(H.Interrupted):
                H.hdd_backend(self.target, {'eligible': True}, self.prep)
        self.assertFalse(H.VERIFIED)

    def actual_sigint(self, requested_phase):
        ready = threading.Event()
        spawned = []
        monitor = H.monitor
        popen = H.subprocess.Popen
        def tracked_spawn(*args, **kwargs):
            proc = popen(*args, **kwargs)
            spawned.append(proc)
            return proc
        def pause(procs, fd, target, prep, phase):
            if phase == requested_phase:
                ready.set()
                time.sleep(5)
            return monitor(procs, fd, target, prep, phase)
        def interrupt():
            if ready.wait(10):
                os.kill(os.getpid(), signal.SIGINT)
        previous = signal.signal(signal.SIGINT, H.on_signal)
        thread = threading.Thread(target=interrupt)
        thread.start()
        try:
            with self.isolated(), patch.object(H, 'monitor', pause), \
                    patch.object(H.subprocess, 'Popen', tracked_spawn):
                with self.assertRaises(H.Interrupted):
                    H.hdd_backend(self.target, {'eligible': True}, self.prep)
            self.assertTrue(ready.is_set())
            self.assertFalse(H.VERIFIED)
            self.assertEqual(H.WRITE_FINISHED, requested_phase == 'Verification')
            self.assertTrue(all(proc.poll() is not None for proc in spawned))
        finally:
            thread.join(12)
            signal.signal(signal.SIGINT, previous)

    def test_actual_sigint_during_overwrite_reaps_worker(self):
        self.actual_sigint('Overwrite')

    def test_actual_sigint_during_verification_reaps_workers(self):
        self.actual_sigint('Verification')

    def interrupt_spawn(self, kind):
        popen = H.subprocess.Popen
        children = []
        previous = signal.signal(signal.SIGINT, H.on_signal)
        def interrupt(args, **kwargs):
            proc = popen(args, **kwargs)
            children.append(proc)
            match = ((kind == 'writer' and 'if=/dev/zero' in args) or
                     (kind == 'reader' and 'iflag=direct,fullblock,count_bytes' in args) or
                     (kind == 'comparator' and args[0] == 'cmp'))
            if match:
                # Real SIGINT after fork, before Popen returns to its caller.
                os.kill(os.getpid(), signal.SIGINT)
            return proc
        try:
            with self.isolated(), patch.object(H.subprocess, 'Popen', interrupt):
                with self.assertRaises(H.Interrupted):
                    H.hdd_backend(self.target, {'eligible': True}, self.prep)
            self.assertTrue(all(proc.poll() is not None for proc in children))
            self.assertFalse(H.REGISTERED_PROCS)
            self.assertFalse(H.VERIFIED)
            self.assertEqual(H.WRITE_FINISHED, kind != 'writer')
        finally:
            signal.signal(signal.SIGINT, previous)

    def test_sigint_while_writer_is_starting_reaps_registered_child(self):
        self.interrupt_spawn('writer')

    def test_sigint_while_reader_is_starting_reaps_registered_children(self):
        self.interrupt_spawn('reader')

    def test_sigint_while_comparator_is_starting_reaps_registered_children(self):
        self.interrupt_spawn('comparator')

    def test_query_spawn_interruption_reaps_child(self):
        popen = H.subprocess.Popen
        children = []
        previous = signal.signal(signal.SIGINT, H.on_signal)
        def interrupt(args, **kwargs):
            proc = popen(args, **kwargs)
            children.append(proc)
            os.kill(os.getpid(), signal.SIGINT)
            return proc
        try:
            with patch.object(H.subprocess, 'Popen', interrupt), self.assertRaises(H.Interrupted):
                H.run(['sleep', '30'])
            self.assertTrue(all(proc.poll() is not None for proc in children))
            self.assertFalse(H.REGISTERED_PROCS)
        finally:
            signal.signal(signal.SIGINT, previous)

    def test_timed_out_query_reaps_registered_child(self):
        popen = H.subprocess.Popen
        children = []
        def track(*args, **kwargs):
            proc = popen(*args, **kwargs)
            children.append(proc)
            return proc
        with patch.object(H.subprocess, 'Popen', track), self.assertRaises(H.Refusal):
            H.run(['sleep', '30'], timeout=0.01)
        self.assertTrue(all(proc.poll() is not None for proc in children))
        self.assertFalse(H.REGISTERED_PROCS)


if __name__ == '__main__':
    if sys.argv[1:] != ['--disposable-vm']:
        print(__doc__)
        raise SystemExit('Refused: run with --disposable-vm only in a separate disposable VM.')
    require_disposable_vm()
    H = load_helper()
    unittest.main(argv=[sys.argv[0]], verbosity=2)
