"""Device key workflow; callers must obtain explicit enrollment consent first."""
import base64
import hashlib
import json
import secrets
import sys
import time
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

def new_pairing_request():
    key=Ed25519PrivateKey.generate()
    private=key.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption())
    public=key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
    return {'publicKey':base64.b64encode(public).decode()},private

def secure_backend():
    import keyring
    backend=keyring.get_keyring()
    module=type(backend).__module__.lower()
    expected='windows' if sys.platform=='win32' else 'os_x' if sys.platform=='darwin' else 'secretservice'
    if expected not in module:raise RuntimeError('An unlocked native OS credential vault is required; no file fallback')
    return keyring

def save_registered_device(device_id,private_key):
    if len(private_key)!=32:raise ValueError('Invalid device key')
    secure_backend().set_password('RainingEmbers.EmberSyncV2',device_id,base64.b64encode(private_key).decode())

def load_registered_device(device_id):
    encoded=secure_backend().get_password('RainingEmbers.EmberSyncV2',device_id)
    if not encoded:return None
    return {'deviceId':device_id,'privateKey':base64.b64decode(encoded,validate=True)}

def sign_headers(body,credential,now_ms=None,nonce=None):
    timestamp=str(now_ms if now_ms is not None else int(time.time()*1000));nonce=nonce or secrets.token_hex(16)
    message=f"{credential['deviceId']}\n{timestamp}\n{nonce}\n{hashlib.sha256(body).hexdigest()}".encode()
    signature=Ed25519PrivateKey.from_private_bytes(credential['privateKey']).sign(message)
    return {'x-embersync-device':credential['deviceId'],'x-embersync-time':timestamp,'x-embersync-nonce':nonce,'x-embersync-signature':base64.b64encode(signature).decode()}
