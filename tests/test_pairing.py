import sys, unittest, json, base64, hashlib, io
from pathlib import Path
from unittest.mock import patch
from email.message import Message
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '.build-tools'))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'desktop'))
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from device import NativeVault, VaultError
from pairing import (PairingClient, PairingError, request_json, revoke_device,
                     START_PATH, POLL_PATH, REVOKE_PATH, ORIGIN, MAX_RESPONSE)
from test_device import FakeBackend, DEVICE, SCOPE


class Clock:
    def __init__(self): self.value = 1700000000
    def __call__(self): return self.value
    def advance(self, seconds): self.value += seconds


class FixtureServer:
    def __init__(self, clock):
        self.clock = clock; self.calls = []; self.approved = False; self.public = None
        self.start_override = {}; self.poll_override = {}; self.revoke_ack = {'deviceId': DEVICE, 'revoked': True}
    def __call__(self, method, path, body, headers):
        parsed = json.loads(body); self.calls.append((method, path, parsed))
        if path == START_PATH: self.public = parsed['publicKey']
        identity = ('new' if path == START_PATH else 'pair:' + hashlib.sha256(('1' * 64).encode()).hexdigest()
                    if path == POLL_PATH else DEVICE)
        assert headers['x-embersync-device'] == identity
        message = f"EmberSync-v2\n{method}\n{path}\n{identity}\n{headers['x-embersync-time']}\n{headers['x-embersync-nonce']}\n{hashlib.sha256(body).hexdigest()}".encode()
        Ed25519PublicKey.from_public_bytes(base64.b64decode(self.public)).verify(
            base64.b64decode(headers['x-embersync-signature']), message)
        if path == START_PATH:
            return 201, {'deviceCode': '1' * 64, 'userCode': 'ABCD-EFGH',
                         'verificationUri': ORIGIN + '/members/embersync?code=ABCD-EFGH',
                         'expiresAt': int(self.clock() * 1000) + 600000, 'pollInterval': 5,
                         **self.start_override}
        if path == POLL_PATH:
            assert parsed == {'deviceCode': '1' * 64}
            return 200, ({'status': 'approved', 'deviceId': DEVICE, 'scope': dict(SCOPE),
                          'expiresAt': int(self.clock() * 1000) + 590000, **self.poll_override}
                         if self.approved else {'status': 'pending'})
        assert path == REVOKE_PATH and parsed == {'deviceId': DEVICE}
        return 200, self.revoke_ack


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock(); self.server = FixtureServer(self.clock)
        self.backend = FakeBackend(); self.vault = NativeVault(self.backend)
        self.client = PairingClient('Fixture PC', transport=self.server, now=self.clock,
                                    vault=self.vault, platform='windows')
    def approve(self):
        self.client.start(); self.clock.advance(5); self.server.approved = True
        return self.client.poll()

    def test_signed_browser_pairing_only_persists_after_approval(self):
        start = self.client.start()
        self.assertNotIn('deviceCode', start); self.assertNotIn('privateKey', start)
        self.assertEqual(self.client.start(), start); self.assertEqual(len(self.server.calls), 1)
        with self.assertRaises(PairingError): self.client.persist()
        self.assertEqual(self.backend.writes, 0)
        self.assertEqual(self.client.poll()['status'], 'pending'); self.assertEqual(len(self.server.calls), 1)
        self.clock.advance(5); self.assertEqual(self.client.poll()['status'], 'pending')
        self.server.approved = True; self.clock.advance(5)
        self.assertEqual(self.client.poll()['deviceId'], DEVICE); self.assertEqual(self.backend.writes, 0)
        saved = []; metadata = self.client.persist(saved.append)
        self.assertEqual(saved, [metadata]); self.assertEqual(self.backend.writes, 1)
        self.assertEqual(set(metadata), {'deviceId', 'publicKey', 'scope'})
        self.assertIsNone(self.client._private); self.assertIsNone(self.client._device_code)
        self.assertEqual(self.client.persist(), metadata); self.assertEqual(self.backend.writes, 1)
        credential = NativeVault(self.backend).load(metadata)
        self.assertEqual(revoke_device(credential, self.server, self.clock), {'deviceId': DEVICE, 'revoked': True})

    def test_untrusted_browser_uri_short_grant_and_bad_expiry_are_rejected(self):
        for override in ({'verificationUri': 'https://attacker.example/'},
                         {'verificationUri': ORIGIN + '/members/embersync?code=OTHER-CODE'},
                         {'deviceCode': 'weak'}, {'pollInterval': 0}, {'expiresAt': 1}):
            self.server.start_override = override
            client = PairingClient(transport=self.server, now=self.clock, vault=self.vault)
            with self.assertRaises(PairingError): client.start()
        self.assertEqual(self.backend.writes, 0)

    def test_scope_approval_is_validated_before_any_vault_write(self):
        self.server.poll_override = {'scope': {**SCOPE, 'sourceCharacterId': True}}
        with self.assertRaises(PairingError): self.approve()
        self.assertEqual(self.backend.writes, 0)
        self.assertEqual(self.client.state, 'pending')

    def test_expiry_and_cancel_discard_unapproved_grants(self):
        self.client.start(); self.clock.advance(601)
        self.assertEqual(self.client.poll(), {'status': 'expired'})
        self.assertIsNone(self.client._private); self.assertIsNone(self.client._device_code)
        self.assertEqual(len(self.server.calls), 1)
        client = PairingClient(transport=self.server, now=self.clock, vault=self.vault)
        client.start(); self.assertEqual(client.cancel(), {'status': 'cancelled'})
        self.assertIsNone(client._private); self.assertEqual(self.backend.writes, 0)

    def test_vault_or_metadata_failure_can_retry_without_duplicate_credential(self):
        self.approve()
        with patch.object(self.backend, 'set_password', side_effect=RuntimeError('fixture-secret')):
            with self.assertRaises(VaultError) as error: self.client.persist()
            self.assertNotIn('fixture-secret', str(error.exception))
        def failing_callback(_): raise RuntimeError('fixture-secret')
        with self.assertRaises(PairingError) as error: self.client.persist(failing_callback)
        self.assertEqual(str(error.exception), 'device_metadata_write_failed')
        self.client.persist(); self.assertEqual(self.backend.writes, 1)

    def test_cancel_registered_device_requires_exact_remote_ack_then_deletes(self):
        self.approve(); metadata = self.client.persist()
        self.server.revoke_ack = {'revoked': True, 'deviceId': '87654321-1234-1234-1234-123456789abc'}
        with self.assertRaises(PairingError): self.client.cancel()
        self.assertIsNotNone(self.vault.load(metadata))
        self.server.revoke_ack = {'revoked': True, 'deviceId': DEVICE}
        self.assertEqual(self.client.cancel(), {'status': 'cancelled'})
        self.assertIsNone(self.vault.load(metadata))

    def test_transport_failure_never_echoes_secret(self):
        def failing(*_): raise RuntimeError('fixture-private-and-device-code')
        self.client.transport = failing
        with self.assertRaises(PairingError) as error: self.client.start()
        self.assertEqual(str(error.exception), 'pairing_network_unavailable')

    def test_denied_approval_is_terminal_and_forgets_ephemeral_material(self):
        self.client.start(); self.clock.advance(5)
        self.client.transport = lambda *_: (403, {'status': 'denied'})
        self.assertEqual(self.client.poll(), {'status': 'cancelled'})
        self.assertIsNone(self.client._private); self.assertIsNone(self.client._device_code)
        self.assertEqual(self.backend.writes, 0)


class Response(io.BytesIO):
    def __init__(self, body, status=200, content_type='application/json'):
        super().__init__(body); self.status = status; self.headers = Message()
        self.headers['Content-Type'] = content_type


class TransportTests(unittest.TestCase):
    def test_response_bounds_type_and_fixed_endpoint(self):
        for raw, content_type in ((b'x' * (MAX_RESPONSE + 1), 'application/json'),
                                  (b'[]', 'application/json'), (b'{}', 'text/html'),
                                  (b'\xff', 'application/json')):
            opener = type('Opener', (), {'open': lambda _, *a, **k: Response(raw, content_type=content_type)})()
            with patch('pairing.urllib.request.build_opener', return_value=opener):
                with self.assertRaises(PairingError): request_json('POST', START_PATH, b'{}', {})
        with self.assertRaises(PairingError): request_json('POST', 'https://attacker.example/', b'{}', {})
