import sys,unittest,base64,hashlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'.build-tools'))
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'desktop'))
from device import new_pairing_request,sign_headers
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
class SigningTests(unittest.TestCase):
    def test_ephemeral_fixture_signature_covers_exact_wire_bytes(self):
        request,private=new_pairing_request();body=b'{"test":"fixture only"}';device='12345678-1234-1234-1234-123456789abc'
        h=sign_headers(body,{'deviceId':device,'privateKey':private},1700000000000,'a'*32)
        message=f"{device}\n1700000000000\n{'a'*32}\n{hashlib.sha256(body).hexdigest()}".encode()
        key=Ed25519PublicKey.from_public_bytes(base64.b64decode(request['publicKey']));key.verify(base64.b64decode(h['x-embersync-signature']),message)
        from cryptography.exceptions import InvalidSignature
        with self.assertRaises(InvalidSignature):key.verify(base64.b64decode(h['x-embersync-signature']),message+b'changed')
