"""Controller QA uses temporary journals, a fixture server and an in-memory vault."""
import json, sys, tempfile, threading, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'desktop'))
from device import NativeVault
from pairing import PairingClient
from runtime import DesktopWorker, read_metadata, save_metadata, write_json_exclusive
from test_device import FakeBackend, DEVICE
from test_pairing import Clock, FixtureServer
from test_sync import acknowledge


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.clock = Clock(); self.server = FixtureServer(self.clock)
        self.backend = FakeBackend(); self.vault = NativeVault(self.backend)
        self.client = PairingClient(transport=self.server, now=self.clock, vault=self.vault)
        self.revocations = []
        def revoke(credential):
            self.revocations.append(credential['deviceId'])
            return {'revoked': True, 'deviceId': credential['deviceId']}
        self.revoke = revoke
        self.worker = self.make_worker()

    def make_worker(self):
        worker = DesktopWorker(self.path, pairing_factory=lambda **_: self.client,
                               credential_loader=self.vault.load, revoke=self.revoke,
                               forget=self.vault.delete, transport=acknowledge)
        def cleanup(): worker.close(); worker.thread.join(3)
        self.addCleanup(cleanup)
        self.assertTrue(worker.ready.wait(3)); self.assertIsNone(worker.startup_error)
        return worker

    def result(self, action, value=None, worker=None):
        worker = worker or self.worker
        self.assertTrue(worker.submit(action, value))
        return worker.results.get(timeout=3)

    def pair(self):
        start = self.result('pair'); self.assertTrue(start['ok'])
        self.clock.advance(5); self.server.approved = True
        result = self.result('poll'); self.assertTrue(result['ok'])
        return result['metadata']

    def test_controller_pair_restart_scope_and_revoke_do_not_export_keys(self):
        metadata = self.pair()
        self.assertEqual(read_metadata(self.path / 'device.json'), metadata)
        raw = (self.path / 'device.json').read_text('utf-8')
        self.assertNotIn('privateKey', raw); self.assertNotIn('deviceCode', raw)
        self.worker.close(); self.worker.thread.join(3)
        replacement = self.make_worker()
        self.assertEqual(self.result('resume', metadata, replacement)['status'], 'ready')
        self.assertEqual(self.result('revoke', metadata, replacement)['status'], 'revoked')
        self.assertIsNone(read_metadata(self.path / 'device.json'))
        self.assertIsNone(self.vault.load(metadata)); self.assertEqual(self.revocations, [DEVICE])

    def test_cancel_on_restarted_worker_preserves_existing_installed_identity(self):
        metadata = self.pair()
        self.worker.close(); self.worker.thread.join(3)
        replacement = self.make_worker()
        result = self.result('cancel', worker=replacement)
        self.assertTrue(result['ok']); self.assertEqual(result['status'], 'no_pending_pairing')
        self.assertEqual(read_metadata(self.path / 'device.json'), metadata)
        self.assertIsNotNone(self.vault.load(metadata)); self.assertEqual(self.revocations, [])
        self.assertFalse(self.result('pair', worker=replacement)['ok'])

    def test_cancel_queued_during_approval_revokes_and_removes_both_records(self):
        self.result('pair'); self.clock.advance(5); self.server.approved = True
        entered = threading.Event(); release = threading.Event(); original = self.client.persist
        self.addCleanup(release.set)
        def persist(callback=None):
            entered.set(); release.wait(3); return original(callback)
        with patch.object(self.client, 'persist', side_effect=persist):
            self.worker.submit('poll'); self.assertTrue(entered.wait(3))
            self.worker.submit('cancel'); release.set()
            approved = self.worker.results.get(timeout=3); cancelled = self.worker.results.get(timeout=3)
        self.assertEqual(approved['status'], 'approved')
        self.assertEqual(cancelled, {'action': 'cancel', 'ok': True, 'status': 'cancelled', 'deviceRemoved': True})
        self.assertIsNone(read_metadata(self.path / 'device.json'))
        self.assertIsNone(self.vault.load(approved['metadata']))
        self.assertEqual(self.revocations, [DEVICE])

    def test_unconfirmed_cancel_ack_preserves_vault_and_public_metadata(self):
        metadata = self.pair()
        self.worker.revoke = lambda _: {'deviceId': 'other', 'revoked': True}
        result = self.result('cancel')
        self.assertFalse(result['ok'])
        self.assertEqual(read_metadata(self.path / 'device.json'), metadata)
        self.assertIsNotNone(self.vault.load(metadata))

    def test_failed_pairing_metadata_commit_can_cancel_registered_key(self):
        self.result('pair'); self.clock.advance(5); self.server.approved = True
        with patch('runtime.save_metadata', side_effect=OSError('fixture-private-path')):
            failed = self.result('poll')
        self.assertFalse(failed['ok']); self.assertNotIn('fixture-private-path', json.dumps(failed))
        self.assertEqual(self.backend.writes, 1); self.assertFalse((self.path / 'device.json').exists())
        self.assertEqual(self.result('cancel')['status'], 'cancelled')
        self.assertEqual(self.backend.values, {})
        self.assertEqual(self.server.calls[-1][1], '/api/embersync/v2/devices/revoke')

    def test_metadata_unlink_failure_can_retry_after_key_was_removed(self):
        metadata = self.pair(); original = Path.unlink
        def failed_unlink(path, *args, **kwargs):
            if path == self.path / 'device.json': raise OSError('fixture path failure')
            return original(path, *args, **kwargs)
        with patch.object(Path, 'unlink', failed_unlink):failed = self.result('revoke', metadata)
        self.assertFalse(failed['ok']); self.assertIsNone(self.vault.load(metadata))
        self.assertEqual(read_metadata(self.path / 'device.json'), metadata)
        self.assertEqual(self.result('revoke', metadata)['status'], 'revoked')
        self.assertIsNone(read_metadata(self.path / 'device.json')); self.assertEqual(self.revocations, [DEVICE])

    def test_delete_failure_preserves_identity_and_idempotent_revoke_retry(self):
        metadata = self.pair(); original = self.worker.forget
        self.worker.forget = lambda _: (_ for _ in ()).throw(OSError('fixture-secret'))
        failed = self.result('revoke', metadata)
        self.assertFalse(failed['ok']); self.assertEqual(failed['error'], 'OSError')
        self.assertNotIn('fixture-secret', json.dumps(failed))
        self.assertEqual(read_metadata(self.path / 'device.json'), metadata)
        self.assertIsNotNone(self.vault.load(metadata))
        self.worker.forget = original
        self.assertEqual(self.result('revoke', metadata)['status'], 'revoked')
        self.assertIsNone(self.vault.load(metadata)); self.assertEqual(self.revocations, [DEVICE, DEVICE])

    def test_failed_job_does_not_stall_queued_explicit_revoke(self):
        metadata = self.pair()
        self.worker.submit('scan', self.path / 'missing.lua'); self.worker.submit('revoke', metadata)
        first = self.worker.results.get(timeout=3); second = self.worker.results.get(timeout=3)
        self.assertFalse(first['ok']); self.assertEqual(first['action'], 'scan')
        self.assertTrue(second['ok']); self.assertEqual(second['status'], 'revoked')

    def test_second_worker_cannot_enroll_in_same_data_directory(self):
        second = DesktopWorker(self.path, pairing_factory=lambda **_: self.fail('second pairing'))
        self.addCleanup(lambda: (second.close(), second.thread.join(3)))
        self.assertTrue(second.ready.wait(3)); second.thread.join(3)
        self.assertIsNotNone(second.startup_error)
        result = second.results.get(timeout=3)
        self.assertFalse(result['ok']); self.assertEqual(result['action'], 'startup')
        self.assertEqual(self.backend.writes, 0)

    def test_close_finishes_inflight_vault_metadata_commit_and_rejects_new_jobs(self):
        self.result('pair'); self.clock.advance(5); self.server.approved = True
        entered = threading.Event(); release = threading.Event(); original = self.client.persist
        self.addCleanup(release.set)
        def persist(callback=None):
            entered.set(); release.wait(3); return original(callback)
        with patch.object(self.client, 'persist', side_effect=persist):
            self.worker.submit('poll'); self.assertTrue(entered.wait(3)); self.worker.close()
            self.assertFalse(self.worker.submit('upload', {})); release.set(); self.worker.thread.join(3)
        self.assertFalse(self.worker.thread.is_alive())
        self.assertEqual(read_metadata(self.path / 'device.json')['deviceId'], DEVICE)
        self.assertEqual(self.backend.writes, 1)

    def test_invalid_public_registry_preserves_file_and_blocks_new_enrollment(self):
        filename = self.path / 'device.json'; filename.write_text('invalid fixture', encoding='utf-8')
        result = self.result('pair')
        self.assertFalse(result['ok']); self.assertEqual(filename.read_text('utf-8'), 'invalid fixture')
        self.assertEqual(self.backend.writes, 0)


class AtomicExportTests(unittest.TestCase):
    def test_failure_never_leaves_empty_final_file_or_overwrites_collision(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'review.json'
            with patch('runtime.os.fsync', side_effect=OSError('fixture disk failure')):
                with self.assertRaises(OSError): write_json_exclusive(path, {'evidence': ['fixture']})
            self.assertEqual(list(Path(folder).iterdir()), [])
            write_json_exclusive(path, {'evidence': ['fixture']})
            self.assertEqual(json.loads(path.read_text('utf-8')), {'evidence': ['fixture']})
            with self.assertRaises(FileExistsError): write_json_exclusive(path, {'evidence': ['other']})
            self.assertEqual(json.loads(path.read_text('utf-8')), {'evidence': ['fixture']})

    def test_metadata_collision_never_overwrites_another_device(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'device.json'
            client = PairingClient(transport=lambda *_: None, vault=NativeVault(FakeBackend()))
            from device import new_pairing_request
            from test_device import SCOPE
            request, _ = new_pairing_request()
            first = {'deviceId': DEVICE, 'publicKey': request['publicKey'], 'scope': dict(SCOPE)}
            second = {**first, 'deviceId': '22345678-1234-1234-1234-123456789abc'}
            original = __import__('os').link
            def raced_link(source, destination):
                Path(destination).write_text(json.dumps(first), encoding='utf-8')
                original(source, destination)
            with patch('runtime.os.link', side_effect=raced_link):
                with self.assertRaises(ValueError): save_metadata(path, second)
            self.assertEqual(read_metadata(path), first)
