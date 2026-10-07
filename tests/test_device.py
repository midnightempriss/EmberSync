import sys, unittest, base64, hashlib, json, types
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '.build-tools'))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'desktop'))
from device import (NativeVault, VaultError, new_pairing_request, sign_request_headers,
                    secure_backend, validate_credential, validate_metadata, SERVICE)
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

DEVICE = '12345678-1234-1234-1234-123456789abc'
SCOPE = {'version': 2, 'guild': 'main', 'sourceCharacterId': 1,
         'sourceName': 'Fixture', 'sourceRealm': 'dalaran',
         'datasets': ['roster', 'log', 'coverage']}


class FakeBackend:
    priority = 5
    def __init__(self): self.values = {}; self.writes = 0
    def get_password(self, service, username): return self.values.get((service, username))
    def set_password(self, service, username, value): self.values[(service, username)] = value; self.writes += 1
    def delete_password(self, service, username): self.values.pop((service, username), None)


class SigningTests(unittest.TestCase):
    def test_signature_covers_wire_method_path_identity_time_nonce(self):
        request, private = new_pairing_request()
        body = b'{"test":"fixture only"}'
        credential = {'deviceId': DEVICE, 'privateKey': private}
        h = sign_request_headers(body, credential, now_ms=1700000000000, nonce='a' * 32)
        message = f"EmberSync-v2\nPOST\n/api/embersync/v2/ingest\n{DEVICE}\n1700000000000\n{'a' * 32}\n{hashlib.sha256(body).hexdigest()}".encode()
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(request['publicKey']))
        signature = base64.b64decode(h['x-embersync-signature'])
        key.verify(signature, message)
        for changed in (message + b'changed', message.replace(b'POST', b'GET'),
                        message.replace(b'/ingest', b'/devices/revoke'), message.replace(DEVICE.encode(), b'new')):
            with self.assertRaises(InvalidSignature): key.verify(signature, changed)

    def test_pairing_identities_and_signing_context_are_strict(self):
        request, private = new_pairing_request()
        for identity, path in (('new', '/api/embersync/v2/pairing/start'),
                               ('pair:' + 'f' * 64, '/api/embersync/v2/pairing/poll')):
            h = sign_request_headers(b'{}', {'privateKey': private}, path=path,
                                     identity=identity, now_ms=1700000000000, nonce='a' * 32)
            self.assertEqual(h['x-embersync-device'], identity)
        for bad in ({'path': '/api/other'}, {'method': 'GET'}, {'identity': DEVICE + '\nnew'},
                    {'identity': 'new'}, {'identity': 'pair:' + 'f' * 64},
                    {'nonce': ''}, {'nonce': 'G' * 32}, {'now_ms': 1}):
            with self.assertRaises(ValueError):
                sign_request_headers(b'{}', {'deviceId': DEVICE, 'privateKey': private}, **bad)


class VaultTests(unittest.TestCase):
    def setUp(self):
        request, self.private = new_pairing_request()
        self.metadata = {'deviceId': DEVICE, 'publicKey': request['publicKey'], 'scope': dict(SCOPE)}
        self.backend = FakeBackend(); self.vault = NativeVault(self.backend)

    def test_save_restart_scope_binding_delete_and_idempotence(self):
        self.assertEqual(self.vault.save(self.metadata, self.private), self.metadata)
        self.vault.save(self.metadata, self.private)
        self.assertEqual(self.backend.writes, 1)
        self.assertEqual(list(self.backend.values), [(SERVICE + '/' + DEVICE, DEVICE)])
        credential = NativeVault(self.backend).load(self.metadata)
        self.assertEqual(credential['privateKey'], self.private)
        self.assertEqual(validate_credential(credential)['scope'], SCOPE)
        changed = {**self.metadata, 'scope': {**SCOPE, 'guild': 'alts'}}
        with self.assertRaises(VaultError): self.vault.load(changed)
        with self.assertRaises(VaultError): self.vault.save(changed, self.private)
        self.vault.delete(DEVICE); self.vault.delete(DEVICE)
        self.assertIsNone(self.vault.load(self.metadata))

    def test_malformed_key_and_scope_never_write(self):
        other, private = new_pairing_request()
        for metadata, key in ((self.metadata, b'bad'), (self.metadata, private),
                              ({**self.metadata, 'scope': {**SCOPE, 'sourceCharacterId': True}}, self.private)):
            with self.assertRaises(ValueError): self.vault.save(metadata, key)
        self.assertEqual(self.backend.writes, 0)
        with self.assertRaises(ValueError): validate_metadata({**self.metadata, 'privateKey': 'secret'})

    def test_vault_failures_and_corruption_never_echo_secret(self):
        target = (SERVICE + '/' + DEVICE, DEVICE)
        for raw in ('not-json fixture-secret', json.dumps({**self.metadata, 'privateKey': 'bad'}),
                    json.dumps({**self.metadata, 'privateKey': base64.b64encode(b'bad').decode()})):
            self.backend.values[target] = raw
            with self.assertRaises(VaultError) as error: self.vault.load(self.metadata)
            self.assertNotIn(raw, str(error.exception))
        with patch.object(self.backend, 'get_password', side_effect=RuntimeError('fixture-secret')):
            with self.assertRaises(VaultError) as error: self.vault.load(self.metadata)
            self.assertEqual(str(error.exception), 'native_vault_read_failed')

    def test_native_backend_selection_and_windows_pc_only_persistence(self):
        for platform, module, class_name in (('win32', 'keyring.backends.Windows', 'WinVaultKeyring'),
                                              ('darwin', 'keyring.backends.macOS', 'Keyring'),
                                              ('linux', 'keyring.backends.SecretService', 'Keyring')):
            fake = types.ModuleType(module); setattr(fake, class_name, FakeBackend)
            with patch.dict(sys.modules, {module: fake}), patch('device.sys.platform', platform):
                backend = secure_backend()
                self.assertIsInstance(backend, FakeBackend)
                if platform == 'win32': self.assertEqual(backend.persist, 'local machine')
        with patch('device.sys.platform', 'unsupported'):
            with self.assertRaises(VaultError): secure_backend()
