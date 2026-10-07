"""Browser-approved pairing; only public short codes are exposed to the GUI.

The desktop signs requests. It never receives or copies site cookies or Battle.net
tokens. Fixed-origin HTTPS transport rejects redirects and oversized responses.
"""
import hashlib
import http.client
import json
import math
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from device import (APP_VERSION, NativeVault, new_pairing_request, sign_request_headers,
                    validate_credential, validate_metadata, validate_scope)

ORIGIN = 'https://rainingembers.org'
START_PATH = '/api/embersync/v2/pairing/start'
POLL_PATH = '/api/embersync/v2/pairing/poll'
REVOKE_PATH = '/api/embersync/v2/devices/revoke'
APPROVAL_PATH = '/members/embersync'
MAX_RESPONSE = 65536


class PairingError(RuntimeError):
    """Safe bounded code; raw transport responses and secrets stay private."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request_json(method, path, body, headers):
    if method != 'POST' or path not in (START_PATH, POLL_PATH, REVOKE_PATH):
        raise PairingError('unapproved_pairing_endpoint')
    if not isinstance(body, bytes) or len(body) > 4096:
        raise PairingError('invalid_pairing_request')
    request = urllib.request.Request(ORIGIN + path, data=body, method=method,
                                     headers={'Content-Type': 'application/json', **headers,
                                              'User-Agent': 'EmberSync/' + APP_VERSION})
    opener = urllib.request.build_opener(NoRedirect())
    try:
        response = opener.open(request, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    except (OSError, ValueError, http.client.HTTPException):
        raise PairingError('pairing_network_unavailable') from None
    try:
        with response:
            raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise PairingError('invalid_pairing_response')
            if response.headers.get_content_type() != 'application/json':
                raise PairingError('invalid_pairing_response')
            parsed = json.loads(raw.decode('utf-8', 'strict'))
            if not isinstance(parsed, dict):
                raise PairingError('invalid_pairing_response')
            return response.status, parsed
    except PairingError:
        raise
    except Exception:
        raise PairingError('invalid_pairing_response') from None


def _body(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')


def _call(transport, path, value, credential, now, identity=None):
    try:
        body = _body(value)
        headers = sign_request_headers(body, credential, path=path,
                                       now_ms=int(now() * 1000), identity=identity)
        result = transport('POST', path, body, headers)
        if not isinstance(result, tuple) or len(result) != 2 or type(result[0]) is not int or not isinstance(result[1], dict):
            raise PairingError('invalid_pairing_response')
        return result
    except PairingError:
        raise
    except Exception:
        raise PairingError('pairing_network_unavailable') from None


def _expiry(value, now_ms):
    if type(value) is not int or not now_ms < value <= now_ms + 15 * 60 * 1000:
        raise PairingError('invalid_pairing_response')
    return value


def _device_code(value):
    if not isinstance(value, str) or not re.fullmatch(r'(?:[0-9a-f]{64}|[A-Za-z0-9_-]{43})', value):
        raise PairingError('invalid_pairing_response')
    return value


class PairingClient:
    def __init__(self, name='This PC', app_version=APP_VERSION, transport=None,
                 now=time.time, vault=None, platform=None):
        self.name = name
        self.app_version = app_version
        self.platform = platform or ('windows' if sys.platform == 'win32' else
                                     'macos' if sys.platform == 'darwin' else 'linux')
        if self.platform not in ('windows', 'macos', 'linux'):
            raise PairingError('unsupported_platform')
        for value in (name, app_version):
            try:
                if not isinstance(value, str) or not value or len(value.encode('utf-16-le')) // 2 > 80:
                    raise ValueError()
            except (ValueError, UnicodeError):
                raise PairingError('invalid_device_label') from None
        self.transport = transport or request_json
        self.now = now
        self.vault = vault or NativeVault()
        self._private = None
        self._public = None
        self._device_code = None
        self._safe_start = None
        self._approved = None
        self._next_poll = 0
        self.state = 'new'

    def start(self):
        if self.state in ('pending', 'approved', 'persisted'):
            return dict(self._safe_start)
        if self.state in ('cancelled', 'expired'):
            raise PairingError('pairing_finished')
        if self._private is None:
            request, self._private = new_pairing_request()
            self._public = request['publicKey']
        status, result = _call(self.transport, START_PATH,
                               {'publicKey': self._public, 'name': self.name,
                                'platform': self.platform, 'appVersion': self.app_version},
                               {'privateKey': self._private}, self.now, 'new')
        if status not in (200, 201):
            raise PairingError('pairing_not_enabled' if status == 503 else 'pairing_start_rejected')
        now_ms = int(self.now() * 1000)
        code = result.get('userCode')
        if not isinstance(code, str) or not re.fullmatch(r'[A-Z0-9]{4}-[A-Z0-9]{4}', code):
            raise PairingError('invalid_pairing_response')
        uri = ORIGIN + APPROVAL_PATH + '?' + urllib.parse.urlencode({'code': code})
        if result.get('verificationUri') != uri or type(result.get('pollInterval')) is not int or not 5 <= result['pollInterval'] <= 60:
            raise PairingError('invalid_pairing_response')
        expires = _expiry(result.get('expiresAt'), now_ms)
        grant = _device_code(result.get('deviceCode'))
        self._device_code = grant
        self._safe_start = {'userCode': code, 'verificationUri': uri,
                            'expiresAt': expires, 'pollInterval': result['pollInterval']}
        self._next_poll = self.now() + result['pollInterval']
        self.state = 'pending'
        return dict(self._safe_start)

    def poll(self):
        if self.state in ('approved', 'persisted'):
            return {'status': 'approved', 'deviceId': self._approved['deviceId'],
                    'scope': validate_scope(self._approved['scope'])}
        if self.state in ('cancelled', 'expired'):
            return {'status': self.state}
        if self.state != 'pending':
            raise PairingError('pairing_not_started')
        now = self.now()
        if now * 1000 >= self._safe_start['expiresAt']:
            self._clear('expired')
            return {'status': 'expired'}
        if now < self._next_poll:
            return {'status': 'pending', 'retryAfter': max(1, math.ceil(self._next_poll - now))}
        self._next_poll = now + self._safe_start['pollInterval']
        identity = 'pair:' + hashlib.sha256(self._device_code.encode('utf-8')).hexdigest()
        status, result = _call(self.transport, POLL_PATH, {'deviceCode': self._device_code},
                               {'privateKey': self._private}, self.now, identity)
        if status in (404, 410) or result.get('status') == 'expired':
            self._clear('expired')
            return {'status': 'expired'}
        if status == 403 and result.get('status') in ('denied', 'cancelled'):
            self._clear('cancelled')
            return {'status': 'cancelled'}
        if status == 429:
            return {'status': 'pending', 'retryAfter': self._safe_start['pollInterval']}
        if status not in (200, 202):
            raise PairingError('pairing_poll_unavailable' if status >= 500 else 'pairing_poll_rejected')
        if result.get('status') == 'pending':
            return {'status': 'pending', 'retryAfter': self._safe_start['pollInterval']}
        if result.get('status') in ('denied', 'cancelled'):
            self._clear('cancelled')
            return {'status': 'cancelled'}
        if result.get('status') != 'approved':
            raise PairingError('invalid_pairing_response')
        try:
            metadata = validate_metadata({'deviceId': result.get('deviceId'),
                                          'publicKey': self._public, 'scope': result.get('scope')})
            _expiry(result.get('expiresAt'), int(self.now() * 1000))
        except (ValueError, UnicodeError):
            raise PairingError('invalid_pairing_response') from None
        self._approved = metadata
        self.state = 'approved'
        return {'status': 'approved', 'deviceId': metadata['deviceId'], 'scope': validate_scope(metadata['scope'])}

    def persist(self, save_metadata=None):
        if self.state not in ('approved', 'persisted'):
            raise PairingError('approval_required')
        metadata = validate_metadata(self._approved)
        if self.state != 'persisted':
            self.vault.save(metadata, self._private)
        if save_metadata is not None:
            try:
                save_metadata(metadata)
            except Exception:
                raise PairingError('device_metadata_write_failed') from None
        self.state = 'persisted'
        self._private = None
        self._device_code = None
        return metadata

    def cancel(self):
        if self.state in ('approved', 'persisted'):
            credential = (self.vault.load(self._approved) if self.state == 'persisted' else
                          {**self._approved, 'privateKey': self._private})
            if credential is None:
                raise PairingError('device_key_unavailable')
            revoke_device(credential, self.transport, self.now)
            self.vault.delete(self._approved['deviceId'])
        self._clear('cancelled')
        return {'status': 'cancelled'}

    def _clear(self, state):
        self._private = None
        self._public = None
        self._device_code = None
        self._approved = None
        self.state = state


def revoke_device(credential, transport=None, now=time.time):
    try:
        credential = validate_credential(credential)
    except Exception:
        raise PairingError('invalid_credentials') from None
    status, result = _call(transport or request_json, REVOKE_PATH,
                           {'deviceId': credential['deviceId']}, credential, now)
    if status in (200, 201) and result.get('deviceId') == credential['deviceId'] and result.get('revoked') is True:
        return {'deviceId': credential['deviceId'], 'revoked': True}
    raise PairingError('revocation_unconfirmed')
