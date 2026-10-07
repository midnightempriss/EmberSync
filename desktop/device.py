"""Narrow device credentials and domain-separated request signatures.

Only approved keys enter the native OS vault. Public metadata may be stored by
the GUI; private keys, browser sessions and pairing grants may not.
"""
import base64
import hashlib
import json
import re
import secrets
import sys
import time

SERVICE = 'RainingEmbers.EmberSyncV2'
APP_VERSION = '2.0.0-preview.2'
DEVICE_ID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
PATHS = frozenset('/api/embersync/v2/' + suffix for suffix in
                  ('ingest', 'pairing/start', 'pairing/poll', 'devices/revoke'))


class VaultError(RuntimeError):
    """Safe, bounded code; never include a vault exception message."""


def _private_key(raw):
    if not isinstance(raw, bytes) or len(raw) != 32:
        raise ValueError('invalid_device_key')
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    return Ed25519PrivateKey.from_private_bytes(raw)


def public_key_for(private):
    from cryptography.hazmat.primitives import serialization
    public = _private_key(private).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(public).decode('ascii')


def new_pairing_request():
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
    key = Ed25519PrivateKey.generate()
    private = key.private_bytes(serialization.Encoding.Raw,
                                serialization.PrivateFormat.Raw,
                                serialization.NoEncryption())
    return {'publicKey': public_key_for(private)}, private


def _text(value, maximum=200):
    if not isinstance(value, str) or not value or len(value.encode('utf-16-le', 'strict')) // 2 > maximum:
        raise ValueError('invalid_device_metadata')
    return value


def validate_scope(scope):
    fields = {'version', 'guild', 'sourceCharacterId', 'sourceName', 'sourceRealm', 'datasets'}
    if not isinstance(scope, dict) or set(scope) != fields or type(scope.get('version')) is not int or scope['version'] != 2:
        raise ValueError('invalid_device_scope')
    if scope['guild'] not in ('main', 'alts') or type(scope['sourceCharacterId']) is not int or not 0 < scope['sourceCharacterId'] < 2**53:
        raise ValueError('invalid_device_scope')
    _text(scope['sourceName']); _text(scope['sourceRealm'])
    datasets = scope['datasets']
    if datasets != ['roster', 'log', 'coverage'] or not isinstance(datasets, list):
        raise ValueError('invalid_device_scope')
    return json.loads(json.dumps(scope, ensure_ascii=False))


def validate_metadata(metadata):
    if not isinstance(metadata, dict) or set(metadata) != {'deviceId', 'publicKey', 'scope'}:
        raise ValueError('invalid_device_metadata')
    if not isinstance(metadata['deviceId'], str) or not DEVICE_ID.fullmatch(metadata['deviceId']):
        raise ValueError('invalid_device_id')
    encoded = metadata['publicKey']
    try:
        if not isinstance(encoded, str) or len(base64.b64decode(encoded, validate=True)) != 32:
            raise ValueError('invalid_public_key')
        if base64.b64encode(base64.b64decode(encoded, validate=True)).decode('ascii') != encoded:
            raise ValueError('invalid_public_key')
    except (ValueError, TypeError):
        raise ValueError('invalid_public_key') from None
    return {'deviceId': metadata['deviceId'], 'publicKey': encoded, 'scope': validate_scope(metadata['scope'])}


def validate_credential(credential):
    if not isinstance(credential, dict) or set(credential) != {'deviceId', 'publicKey', 'scope', 'privateKey'}:
        raise ValueError('invalid_credentials')
    metadata = validate_metadata({k: credential[k] for k in ('deviceId', 'publicKey', 'scope')})
    if public_key_for(credential['privateKey']) != metadata['publicKey']:
        raise ValueError('invalid_credentials')
    return {**metadata, 'privateKey': credential['privateKey']}


def secure_backend():
    """Use the actual native backend directly; configured file fallbacks fail closed."""
    try:
        if sys.platform == 'win32':
            from keyring.backends.Windows import WinVaultKeyring
            backend = WinVaultKeyring()
            backend.persist = 'local machine'
        elif sys.platform == 'darwin':
            from keyring.backends.macOS import Keyring
            backend = Keyring()
        elif sys.platform.startswith('linux'):
            from keyring.backends.SecretService import Keyring
            backend = Keyring()
        else:
            raise VaultError('native_vault_unavailable')
        if backend.priority <= 0:
            raise VaultError('native_vault_unavailable')
        return backend
    except Exception:
        raise VaultError('native_vault_unavailable') from None


class NativeVault:
    def __init__(self, backend=None):
        self._backend = backend

    def _native(self):
        if self._backend is None:
            self._backend = secure_backend()
        return self._backend

    @staticmethod
    def _target(device_id):
        if not isinstance(device_id, str) or not DEVICE_ID.fullmatch(device_id):
            raise ValueError('invalid_device_id')
        return SERVICE + '/' + device_id

    def save(self, metadata, private):
        metadata = validate_metadata(metadata)
        validate_credential({**metadata, 'privateKey': private})
        encoded = json.dumps({**metadata, 'privateKey': base64.b64encode(private).decode('ascii')},
                             ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        target = self._target(metadata['deviceId'])
        try:
            backend = self._native()
            existing = backend.get_password(target, metadata['deviceId'])
            if existing is not None:
                if existing != encoded:
                    raise VaultError('device_credential_exists')
                return metadata
            backend.set_password(target, metadata['deviceId'], encoded)
            if backend.get_password(target, metadata['deviceId']) != encoded:
                raise VaultError('credential_verification_failed')
            return metadata
        except VaultError:
            raise
        except Exception:
            raise VaultError('native_vault_write_failed') from None

    def load(self, metadata):
        expected = None if isinstance(metadata, str) else validate_metadata(metadata)
        device_id = metadata if isinstance(metadata, str) else expected['deviceId']
        target = self._target(device_id)
        try:
            encoded = self._native().get_password(target, device_id)
            if encoded is None:
                return None
            if not isinstance(encoded, str) or len(encoded) > 4096:
                raise VaultError('invalid_vault_credential')
            record = json.loads(encoded)
            if not isinstance(record, dict) or not isinstance(record.get('privateKey'), str):
                raise VaultError('invalid_vault_credential')
            record['privateKey'] = base64.b64decode(record['privateKey'], validate=True)
            credential = validate_credential(record)
            if credential['deviceId'] != device_id or (expected is not None and any(credential[k] != expected[k] for k in expected)):
                raise VaultError('vault_metadata_mismatch')
            return credential
        except VaultError:
            raise
        except Exception:
            raise VaultError('native_vault_read_failed') from None

    def delete(self, device_id):
        target = self._target(device_id)
        try:
            backend = self._native()
            if backend.get_password(target, device_id) is not None:
                backend.delete_password(target, device_id)
            if backend.get_password(target, device_id) is not None:
                raise VaultError('credential_delete_failed')
        except VaultError:
            raise
        except Exception:
            raise VaultError('native_vault_delete_failed') from None


def save_registered_device(device_id, private_key, metadata=None, vault=None):
    if metadata is None:
        raise ValueError('approved_device_metadata_required')
    if metadata.get('deviceId') != device_id:
        raise ValueError('invalid_device_id')
    return (vault or NativeVault()).save(metadata, private_key)


def load_registered_device(metadata, vault=None):
    return (vault or NativeVault()).load(metadata)


def forget_registered_device(device_id, vault=None):
    return (vault or NativeVault()).delete(device_id)


def sign_request_headers(body, credential, method='POST', path='/api/embersync/v2/ingest',
                         now_ms=None, nonce=None, identity=None):
    if not isinstance(body, bytes) or len(body) > 300000 or method != 'POST' or path not in PATHS:
        raise ValueError('invalid_signed_request')
    if not isinstance(credential, dict):
        raise ValueError('invalid_credentials')
    identity = identity or credential.get('deviceId')
    if not isinstance(identity, str) or not (DEVICE_ID.fullmatch(identity) or identity == 'new' or re.fullmatch(r'pair:[0-9a-f]{64}', identity)):
        raise ValueError('invalid_signing_identity')
    if ((path.endswith('/pairing/start') and identity != 'new') or
            (path.endswith('/pairing/poll') and not re.fullmatch(r'pair:[0-9a-f]{64}', identity)) or
            (path.endswith(('/ingest', '/devices/revoke')) and not DEVICE_ID.fullmatch(identity))):
        raise ValueError('invalid_signing_identity')
    timestamp = str(int(time.time() * 1000) if now_ms is None else now_ms)
    nonce = secrets.token_hex(16) if nonce is None else nonce
    if not re.fullmatch(r'[0-9]{13}', timestamp) or not isinstance(nonce, str) or not re.fullmatch(r'[0-9a-f]{32}', nonce):
        raise ValueError('invalid_signature_context')
    message = f'EmberSync-v2\n{method}\n{path}\n{identity}\n{timestamp}\n{nonce}\n{hashlib.sha256(body).hexdigest()}'.encode('utf-8')
    signature = _private_key(credential.get('privateKey')).sign(message)
    return {'x-embersync-device': identity, 'x-embersync-time': timestamp,
            'x-embersync-nonce': nonce,
            'x-embersync-signature': base64.b64encode(signature).decode('ascii')}


def sign_headers(body, credential, now_ms=None, nonce=None):
    return sign_request_headers(body, credential, now_ms=now_ms, nonce=nonce)
