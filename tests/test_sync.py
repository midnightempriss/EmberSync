"""Offline delivery QA; only published fixed fixtures and mocked HTTP are used."""
import base64
import hashlib
import io
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'desktop'))
from pipeline import JournalStore
from sync import CLAIM_SECONDS, ENDPOINT, INGEST_PATH, MAX_ACK_BYTES, DeliveryWorker
from test_pipeline import journal, roster

# RFC 8032 test vector 1; these public test bytes are never generated or vaulted.
FIXTURE_PRIVATE = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
FIXTURE_PUBLIC = base64.b64encode(bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')).decode('ascii')
DEVICE_MAIN = '12345678-1234-1234-1234-123456789abc'
DEVICE_OTHER = '22345678-1234-1234-1234-123456789abc'


def credential(device=DEVICE_MAIN, guild='main', datasets=None):
    return {'deviceId': device, 'privateKey': FIXTURE_PRIVATE, 'publicKey': FIXTURE_PUBLIC,
            'scope': {'version': 2, 'guild': guild, 'sourceCharacterId': 1,
                      'sourceName': 'Fixture-Dalaran', 'sourceRealm': 'dalaran',
                      'datasets': ['roster', 'log', 'coverage'] if datasets is None else datasets}}


def acknowledge(body, _credential):
    return 200, {'batchHash': json.loads(body)['batchHash'], 'committed': True,
                 'serverAckAt': 1700000000000}


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'queue.sqlite'
        self.store = JournalStore(self.path)
        self.store.ingest(journal(roster(1, ['A'])))
        self.clock = 1700000000

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def worker(self, transport=acknowledge, metadata=None, provider=None, store=None):
        metadata = credential() if metadata is None else metadata
        return DeliveryWorker(store or self.store, ENDPOINT,
                              provider or (lambda: metadata), transport, lambda: self.clock)

    def state(self, device=DEVICE_MAIN, guild='main'):
        return self.store.db.execute('''SELECT status,attempts,next_at,error,lease_until
            FROM scoped_delivery_state WHERE device_id=? AND guild=?''', (device, guild)).fetchone()

    def receipt_count(self):
        return self.store.db.execute('SELECT count(*) FROM scoped_receipts').fetchone()[0]

    def test_acknowledgement_rescan_and_restart_preserve_bound_receipt(self):
        worker = self.worker()
        self.assertEqual(worker.drain_once(), 'acknowledged')
        self.assertEqual(worker.drain_once(), 'idle')
        self.assertEqual(self.store.ingest(journal(roster(1, ['A']))), 0)
        self.assertEqual(self.store.db.execute('SELECT status FROM outbox').fetchone()[0], 'pending')
        self.store.close()
        self.store = JournalStore(self.path)
        self.assertEqual(self.worker().drain_once(), 'idle')
        self.assertEqual(self.receipt_count(), 1)
        self.assertEqual(self.state()[0], 'acknowledged')

    def test_replacement_device_does_not_inherit_receipt_or_legacy_ack(self):
        self.store.db.execute("UPDATE outbox SET status='acknowledged'")
        self.store.db.commit()
        self.assertEqual(self.worker().drain_once(), 'acknowledged')
        replacement = self.worker(metadata=credential(DEVICE_OTHER))
        self.assertEqual(replacement.drain_once(), 'acknowledged')
        self.assertEqual(self.receipt_count(), 2)
        bindings = self.store.db.execute('SELECT device_id,guild FROM scoped_receipts ORDER BY device_id').fetchall()
        self.assertEqual(bindings, [(DEVICE_MAIN, 'main'), (DEVICE_OTHER, 'main')])

    def test_guild_scope_selects_only_authorized_records(self):
        self.store.ingest(journal(roster(1, ['X'], guild='alts'),
                                 {'kind': 'coverage', 'guild': 'main', 'epoch': 'epoch-a',
                                  'seq': 2, 'collectedAt': 1700000002, 'coverage': 'partial'}))
        sent = []
        current = [credential()]
        def transport(body, metadata):
            sent.append((json.loads(body)['evidence'], metadata['deviceId']))
            return acknowledge(body, metadata)
        worker = self.worker(transport, provider=lambda: current[0])
        self.assertEqual(worker.drain_once(), 'acknowledged')
        self.assertEqual(sent[-1][0]['kind'], 'roster')
        self.assertEqual(worker.drain_once(), 'acknowledged')
        self.assertEqual(sent[-1][0]['kind'], 'coverage')
        self.assertEqual(worker.drain_once(), 'idle')
        current[0] = credential(DEVICE_OTHER, 'alts')
        self.assertEqual(worker.drain_once(), 'acknowledged')
        self.assertEqual(sent[-1][0]['guild'], 'alts')
        self.assertEqual(worker.drain_once(), 'idle')
        self.assertEqual(self.receipt_count(), 3)

    def test_storage_capacity_pause_survives_restart_and_preserves_evidence(self):
        worker = self.worker(lambda *_: (507, {'error': 'storage_capacity_reached'}))
        self.assertEqual(worker.drain_once(), 'storage_capacity_reached')
        self.assertEqual(self.state()[0], 'capacity_paused'); self.assertEqual(self.state()[3], 'storage_capacity_reached')
        self.assertEqual(worker.drain_once(), 'paused'); self.assertEqual(self.receipt_count(), 0)
        self.store.close(); self.store = JournalStore(self.path)
        restarted = self.worker(lambda *_: self.fail('paused queue must not send'))
        self.assertEqual(restarted.drain_once(), 'paused')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM evidence').fetchone()[0], 1)
        self.assertEqual(self.store.db.execute('SELECT status FROM outbox').fetchone()[0], 'pending')
        self.assertEqual(self.worker(metadata=credential(DEVICE_OTHER)).drain_once(), 'acknowledged')
        restarted.transport = acknowledge
        self.assertTrue(restarted.resume()); self.assertEqual(restarted.drain_once(), 'acknowledged')
        self.assertEqual(self.receipt_count(), 2)

    def test_current_server_scope_denial_is_explicit_and_durable(self):
        worker = self.worker(lambda *_: (403, {'error': 'cross_guild_or_dataset_denied'}))
        self.assertEqual(worker.drain_once(), 'scope_denied'); self.assertEqual(worker.drain_once(), 'paused')
        self.assertEqual(self.state()[3], 'scope_denied'); self.assertEqual(self.receipt_count(), 0)

    def test_retry_backoff_is_durable_and_does_not_block_replacement(self):
        calls = []
        def unavailable(*args):
            calls.append(1)
            raise TimeoutError('fixture exception must not be persisted')
        worker = self.worker(unavailable)
        self.assertEqual(worker.drain_once(), 'retry_later')
        self.assertEqual(self.state()[1:4], (1, self.clock + 30, 'retry_pending'))
        self.store.close()
        self.store = JournalStore(self.path)
        worker = self.worker(unavailable)
        self.assertEqual(worker.drain_once(), 'idle')
        self.clock += 30
        self.assertEqual(worker.drain_once(), 'retry_later')
        self.assertEqual(self.state()[1:3], (2, self.clock + 60))
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.worker(metadata=credential(DEVICE_OTHER)).drain_once(), 'acknowledged')

    def test_auth_pause_survives_restart_and_resume_is_scoped(self):
        worker = self.worker(lambda *_: (403, {'error': 'fresh_owned_source_required'}))
        self.assertEqual(worker.drain_once(), 'source_refresh_required')
        self.assertEqual(worker.drain_once(), 'paused')
        self.store.close()
        self.store = JournalStore(self.path)
        resumed = self.worker()
        self.assertEqual(resumed.drain_once(), 'paused')
        self.assertEqual(self.worker(metadata=credential(DEVICE_OTHER)).drain_once(), 'acknowledged')
        self.assertTrue(resumed.resume())
        self.assertEqual(resumed.drain_once(), 'acknowledged')
        resumed.pause()
        self.assertEqual(resumed.drain_once(), 'paused')
        self.assertTrue(resumed.resume())
        self.assertEqual(resumed.drain_once(), 'idle')

    def test_quarantine_is_per_device_and_never_removes_evidence(self):
        worker = self.worker(lambda *_: (422, {}))
        self.assertEqual(worker.drain_once(), 'quarantined')
        self.assertEqual(worker.drain_once(), 'idle')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM evidence').fetchone()[0], 1)
        self.assertEqual(self.store.db.execute('SELECT status FROM outbox').fetchone()[0], 'pending')
        self.assertEqual(self.worker(metadata=credential(DEVICE_OTHER)).drain_once(), 'acknowledged')

    def test_exact_hash_and_boolean_commit_are_required(self):
        for ack in ({'batchHash': 'wrong', 'committed': True},
                    {'batchHash': self.store.db.execute('SELECT hash FROM outbox').fetchone()[0], 'committed': 1}):
            with self.subTest(ack=ack):
                self.assertEqual(self.worker(lambda *_: (200, ack)).drain_once(), 'retry_later')
                self.assertEqual(self.receipt_count(), 0)
                self.clock += 3600

    def test_missing_malformed_or_failed_credentials_make_no_request(self):
        no_send = lambda *_: self.fail('unexpected transport call')
        self.assertEqual(self.worker(no_send, provider=lambda: None).drain_once(), 'pairing_required')
        malformed = [False, {}, {**credential(), 'extra': 'private'},
                     {**credential(), 'privateKey': b'wrong'},
                     {**credential(), 'privateKey': b'\0' * 32},
                     {**credential(), 'publicKey': 'invalid'},
                     {**credential(), 'scope': {**credential()['scope'], 'guild': 'other'}},
                     credential(datasets=[]), credential(datasets=['roster', 'roster']),
                     credential(datasets=['coverage']), credential(datasets=['log', 'roster', 'coverage'])]
        for supplied in malformed:
            with self.subTest(type=type(supplied).__name__):
                self.assertEqual(self.worker(no_send, provider=lambda: supplied).drain_once(), 'invalid_credentials')
        def broken_provider():
            raise RuntimeError('vault details must remain private')
        self.assertEqual(self.worker(no_send, provider=broken_provider).drain_once(), 'credentials_unavailable')
        self.assertEqual(self.receipt_count(), 0)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM scoped_delivery_state').fetchone()[0], 0)

    def test_utf8_wire_bytes_reuse_stored_canonical_payload(self):
        self.store.ingest(journal(roster(2, ['\u00e9\U0001f600'])))
        self.assertEqual(self.worker().drain_once(), 'acknowledged')
        captured = []
        def transport(body, metadata):
            captured.append(body)
            return acknowledge(body, metadata)
        self.assertEqual(self.worker(transport).drain_once(), 'acknowledged')
        raw = captured[0]
        self.assertIn('\u00e9\U0001f600'.encode('utf-8'), raw)
        self.assertNotIn(b'\\u00e9', raw)
        payload = self.store.db.execute('SELECT payload FROM outbox ORDER BY rowid DESC').fetchone()[0]
        self.assertEqual(json.loads(raw)['batchHash'], hashlib.sha256(payload.encode('utf-8')).hexdigest())
        self.assertIn(payload.encode('utf-8'), raw)

    def test_oversized_stored_record_is_quarantined_before_transport(self):
        # Exercise a pre-existing oversized queue row independently of the current
        # reader's import limits; updating the application must not send it.
        record = roster(2, [str(i) for i in range(800)])
        for member in record['members']:
            member['name'] = '\u00e9' * 200
        payload = json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        digest = hashlib.sha256(payload.encode('utf-8')).hexdigest()
        with self.store.db:
            self.store.db.execute('INSERT INTO evidence VALUES(?,?,?,?,?,?)',
                                  ('main', 'epoch-a', 2, digest, payload, self.clock))
            self.store.db.execute('INSERT INTO outbox(hash,payload) VALUES(?,?)', (digest, payload))
        self.assertEqual(self.worker().drain_once(), 'acknowledged')
        no_send = self.worker(lambda *_: self.fail('oversized transport call'))
        self.assertEqual(no_send.drain_once(), 'quarantined')
        self.assertEqual(no_send.drain_once(), 'idle')
        self.assertEqual(self.receipt_count(), 1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM evidence').fetchone()[0], 2)

    def test_runtime_credential_mutation_cannot_rebind_an_inflight_receipt(self):
        supplied = credential()
        def transport(body, metadata):
            supplied['deviceId'] = DEVICE_OTHER
            supplied['scope']['guild'] = 'alts'
            self.assertEqual(metadata['deviceId'], DEVICE_MAIN)
            self.assertEqual(metadata['scope']['guild'], 'main')
            return acknowledge(body, metadata)
        worker = self.worker(transport, provider=lambda: supplied)
        self.assertEqual(worker.drain_once(), 'acknowledged')
        self.assertEqual(self.store.db.execute('SELECT device_id,guild FROM scoped_receipts').fetchone(),
                         (DEVICE_MAIN, 'main'))
        self.assertEqual(worker.drain_once(), 'idle')

    def test_two_sqlite_connections_cannot_send_one_active_claim_twice(self):
        other = JournalStore(self.path)
        try:
            calls = []
            second = self.worker(lambda *_: self.fail('duplicate send'), store=other)
            def first_transport(body, metadata):
                calls.append(1)
                self.assertEqual(second.drain_once(), 'idle')
                return acknowledge(body, metadata)
            self.assertEqual(self.worker(first_transport).drain_once(), 'acknowledged')
            self.assertEqual(second.drain_once(), 'idle')
            self.assertEqual(len(calls), 1)
        finally:
            other.close()

    def test_expired_claim_recovers_and_late_failure_cannot_downgrade_receipt(self):
        other = JournalStore(self.path)
        try:
            second = self.worker(store=other)
            def late_failure(_body, _metadata):
                self.clock += CLAIM_SECONDS
                self.assertEqual(second.drain_once(), 'acknowledged')
                return 422, {}
            self.assertEqual(self.worker(late_failure).drain_once(), 'acknowledged')
            self.assertEqual(self.state()[0], 'acknowledged')
            self.assertEqual(self.receipt_count(), 1)
            self.assertEqual(second.drain_once(), 'idle')
        finally:
            other.close()

    def test_crash_after_claim_retries_after_durable_lease_expiry(self):
        worker = self.worker()
        from sync import _credential
        status, row = worker._claim(_credential(credential()))
        self.assertEqual(status, 'claimed')
        self.assertIsNotNone(row)
        self.store.close()
        self.store = JournalStore(self.path)
        replacement = self.worker()
        self.assertEqual(replacement.drain_once(), 'idle')
        self.clock += CLAIM_SECONDS
        self.assertEqual(replacement.drain_once(), 'acknowledged')

    def test_malformed_or_oversized_transport_ack_is_retryable(self):
        replies = [None, [200, {}], (True, {}), (200, []),
                   (200, {'padding': 'x' * (MAX_ACK_BYTES + 1)})]
        for reply in replies:
            with self.subTest(type=type(reply).__name__):
                self.assertEqual(self.worker(lambda *_: reply).drain_once(), 'retry_later')
                self.clock += 3600
        self.assertEqual(self.receipt_count(), 0)
        self.assertEqual(self.state()[3], 'retry_pending')

    def test_endpoint_redirect_and_ack_read_are_bounded(self):
        with self.assertRaises(ValueError):
            DeliveryWorker(self.store, ENDPOINT + '/', lambda: credential())
        from sync import NoRedirect
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.test/'))
        for data in (b'[]', b'not json', b'x' * (MAX_ACK_BYTES + 1)):
            with self.assertRaises(ValueError):
                DeliveryWorker._read_ack(io.BytesIO(data))

    def test_request_signs_exact_method_path_and_bytes_without_real_http(self):
        from device import APP_VERSION
        captured = []
        class Response(io.BytesIO):
            status = 200
        class Opener:
            def open(self, request, timeout):
                captured.append((request, timeout))
                return Response(b'{"committed":true}')
        body = b'{"fixture":"exact bytes"}'
        metadata = credential()
        with patch('device.sign_request_headers', return_value={'x-embersync-signature': 'fixture'}) as signer, \
             patch('sync.urllib.request.build_opener', return_value=Opener()):
            self.assertEqual(self.worker().request(body, metadata), (200, {'committed': True}))
        signer.assert_called_once_with(body, metadata, method='POST', path=INGEST_PATH)
        self.assertEqual(captured[0][0].full_url, ENDPOINT)
        self.assertEqual(captured[0][0].data, body)
        self.assertEqual(captured[0][0].get_method(), 'POST')
        self.assertEqual(captured[0][0].get_header('User-agent'), 'EmberSync/' + APP_VERSION)
        self.assertEqual(captured[0][0].get_header('X-embersync-signature'), 'fixture')
        self.assertEqual(captured[0][0].get_header('Content-type'), 'application/json')
        self.assertIsNone(captured[0][0].get_header('Cookie'))
        self.assertIsNone(captured[0][0].get_header('Authorization'))
        self.assertEqual(captured[0][1], 20)

    def test_http_auth_error_body_is_read_without_leaking_response(self):
        error = urllib.error.HTTPError(ENDPOINT, 403, 'fixture', {},
                                      io.BytesIO(b'{"error":"device_revoked_or_unknown"}'))
        with patch('device.sign_request_headers', return_value={}), \
             patch('sync.urllib.request.build_opener') as opener:
            opener.return_value.open.side_effect = error
            self.assertEqual(self.worker().request(b'{}', credential()),
                             (403, {'error': 'device_revoked_or_unknown'}))


if __name__ == '__main__':
    unittest.main()
