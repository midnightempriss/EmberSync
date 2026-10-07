"""Delivery for an explicitly paired device; credentials are never persisted here.

The journal and legacy outbox remain immutable delivery sources. Receipts, retries,
authorization pauses and claims belong to one device and guild. No network is
enabled by default, and tests use a transport supplied by the caller.
"""
import hashlib
import json
import sqlite3
import time
import urllib.error
import urllib.request
import uuid

from pipeline import validate_record

ENDPOINT = 'https://rainingembers.org/api/embersync/v2/ingest'
INGEST_PATH = '/api/embersync/v2/ingest'
MAX_BODY_BYTES = 300000
MAX_ACK_BYTES = 65536
CLAIM_SECONDS = 60


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _credential(value):
    """Validate runtime metadata and take an immutable per-request snapshot."""
    from device import validate_credential
    return validate_credential(value)


class DeliveryWorker:
    def __init__(self, store, endpoint, credential_provider, transport=None, now=time.time):
        if endpoint != ENDPOINT:
            raise ValueError('Unapproved endpoint')
        self.store = store
        self.endpoint = endpoint
        self.credentials = credential_provider
        self.now = now
        self.transport = transport or self.request
        self.paused = False
        self.running = False
        store.db.executescript('''
        CREATE TABLE IF NOT EXISTS scoped_delivery_state(
            device_id TEXT NOT NULL,guild TEXT NOT NULL,hash TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,
            next_at REAL NOT NULL DEFAULT 0,error TEXT,lease_until REAL NOT NULL DEFAULT 0,
            claim_id TEXT,PRIMARY KEY(device_id,guild,hash));
        CREATE TABLE IF NOT EXISTS scoped_receipts(
            device_id TEXT NOT NULL,guild TEXT NOT NULL,hash TEXT NOT NULL,
            server_ack_at REAL NOT NULL,PRIMARY KEY(device_id,guild,hash));
        ''')

    @staticmethod
    def _read_ack(response):
        raw = response.read(MAX_ACK_BYTES + 1)
        if len(raw) > MAX_ACK_BYTES:
            raise ValueError('Oversized acknowledgement')
        ack = json.loads(raw.decode('utf-8'))
        if not isinstance(ack, dict):
            raise ValueError('Invalid acknowledgement')
        return ack

    def request(self, body, credential):
        from device import sign_request_headers
        headers = sign_request_headers(body, credential, method='POST', path=INGEST_PATH)
        request = urllib.request.Request(self.endpoint, data=body,
                                        headers={'Content-Type': 'application/json', **headers}, method='POST')
        try:
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
                return response.status, self._read_ack(response)
        except urllib.error.HTTPError as error:
            try:
                return error.code, self._read_ack(error)
            except (ValueError, UnicodeError, OSError):
                return error.code, {}
            finally:
                error.close()

    def pause(self):
        self.paused = True

    def resume(self):
        """Clear a manual pause and retry authorization for the current device."""
        self.paused = False
        try:
            credential = _credential(self.credentials())
            scope = (credential['deviceId'], credential['scope']['guild'])
            with self.store.db:
                self.store.db.execute("""UPDATE scoped_delivery_state SET status='pending',
                    next_at=0,error=NULL,lease_until=0,claim_id=NULL
                    WHERE device_id=? AND guild=? AND status IN ('reauthorization_required','capacity_paused')""", scope)
        except Exception:
            return False
        return True

    def _claim(self, credential):
        device = credential['deviceId']
        guild = credential['scope']['guild']
        if self.store.db.execute("""SELECT 1 FROM scoped_delivery_state
            WHERE device_id=? AND guild=? AND status IN ('reauthorization_required','capacity_paused') LIMIT 1""", (device, guild)).fetchone():
            return 'paused', None
        datasets = credential['scope']['datasets']
        placeholders = ','.join('?' for _ in datasets)
        now = self.now()
        row = self.store.db.execute(f'''SELECT o.hash,o.payload,COALESCE(d.attempts,0)
            FROM outbox o LEFT JOIN scoped_delivery_state d
                ON d.device_id=? AND d.guild=? AND d.hash=o.hash
            WHERE EXISTS(SELECT 1 FROM evidence e WHERE e.hash=o.hash AND e.guild=?)
                AND json_extract(o.payload,'$.kind') IN ({placeholders})
                AND NOT EXISTS(SELECT 1 FROM scoped_receipts r
                    WHERE r.device_id=? AND r.guild=? AND r.hash=o.hash)
                AND COALESCE(d.status,'pending')='pending'
                AND COALESCE(d.next_at,0)<=? AND COALESCE(d.lease_until,0)<=?
            ORDER BY o.rowid LIMIT 1''', (device, guild, guild, *datasets, device, guild, now, now)).fetchone()
        if not row:
            return 'idle', None
        digest, payload, attempts = row
        claim = str(uuid.uuid4())
        with self.store.db:
            changed = self.store.db.execute('''INSERT INTO scoped_delivery_state
                (device_id,guild,hash,status,attempts,next_at,lease_until,claim_id)
                SELECT ?,?,?,'pending',?,0,?,?
                WHERE NOT EXISTS(SELECT 1 FROM scoped_delivery_state
                    WHERE device_id=? AND guild=? AND status IN ('reauthorization_required','capacity_paused'))
                    AND NOT EXISTS(SELECT 1 FROM scoped_receipts
                        WHERE device_id=? AND guild=? AND hash=?)
                ON CONFLICT(device_id,guild,hash)
                DO UPDATE SET lease_until=excluded.lease_until,claim_id=excluded.claim_id
                WHERE scoped_delivery_state.status='pending'
                    AND scoped_delivery_state.next_at<=? AND scoped_delivery_state.lease_until<=?
                    AND NOT EXISTS(SELECT 1 FROM scoped_receipts r WHERE r.device_id=? AND r.guild=? AND r.hash=?)''',
                (device, guild, digest, attempts, now + CLAIM_SECONDS, claim,
                 device, guild, device, guild, digest, now, now, device, guild, digest)).rowcount
        if changed != 1:
            return 'busy', None
        return 'claimed', (digest, payload, attempts, claim)

    def _transition(self, credential, row, status, error=None, retry=False):
        digest, _, attempts, claim = row
        delay = min(3600, 30 * 2**min(attempts, 7)) if retry else 0
        with self.store.db:
            changed = self.store.db.execute('''UPDATE scoped_delivery_state SET status=?,attempts=?,
                next_at=?,error=?,lease_until=0,claim_id=NULL
                WHERE device_id=? AND guild=? AND hash=? AND claim_id=? AND status='pending'
                AND NOT EXISTS(SELECT 1 FROM scoped_receipts r
                    WHERE r.device_id=? AND r.guild=? AND r.hash=?)''',
                (status, attempts + (1 if retry else 0), self.now() + delay if retry else 0, error,
                 credential['deviceId'], credential['scope']['guild'], digest, claim,
                 credential['deviceId'], credential['scope']['guild'], digest)).rowcount
        return changed == 1

    def _transition_result(self, credential, row, result, status, error=None, retry=False):
        if self._transition(credential, row, status, error, retry):
            return result
        receipt = self.store.db.execute('''SELECT 1 FROM scoped_receipts
            WHERE device_id=? AND guild=? AND hash=?''',
            (credential['deviceId'], credential['scope']['guild'], row[0])).fetchone()
        return 'acknowledged' if receipt else 'busy'

    def drain_once(self):
        if self.paused:
            return 'paused'
        if self.running:
            return 'busy'
        self.running = True
        try:
            try:
                supplied = self.credentials()
            except Exception:
                return 'credentials_unavailable'
            if supplied is None:
                return 'pairing_required'
            try:
                credential = _credential(supplied)
            except (ValueError, TypeError):
                return 'invalid_credentials'
            except Exception:
                return 'credentials_unavailable'
            result, row = self._claim(credential)
            if row is None:
                return result
            digest, payload, _, _ = row
            try:
                evidence = validate_record(json.loads(payload))
                if evidence['guild'] != credential['scope']['guild'] or evidence['kind'] not in credential['scope']['datasets'] or hashlib.sha256(payload.encode('utf-8')).hexdigest() != digest:
                    raise ValueError('Invalid local evidence')
                # Reuse the stored canonical payload so Unicode cannot expand into
                # ASCII escapes and the signed bytes are exactly those transmitted.
                body = ('{"version":2,"batchHash":"' + digest + '","evidence":' + payload + '}').encode('utf-8')
                if len(body) > MAX_BODY_BYTES:
                    raise ValueError('Oversized local evidence')
            except (ValueError, TypeError, RecursionError):
                return self._transition_result(credential, row, 'quarantined', 'quarantined', 'invalid_local_evidence')
            try:
                response = self.transport(body, credential)
                if not isinstance(response, tuple) or len(response) != 2:
                    raise ValueError('Invalid transport result')
                status, ack = response
                if type(status) is not int or not 100 <= status <= 599 or not isinstance(ack, dict) or len(json.dumps(ack, ensure_ascii=True).encode('ascii')) > MAX_ACK_BYTES:
                    raise ValueError('Invalid transport result')
            except Exception:
                status, ack = 503, {}
            if status in (401, 403):
                errors = {'device_revoked_or_unknown': 'device_revoked',
                          'fresh_owned_source_required': 'source_refresh_required',
                          'cross_guild_denied': 'scope_denied',
                          'cross_guild_or_dataset_denied': 'scope_denied'}
                code = ack.get('error')
                reason = errors.get(code, 'reauthorization_required') if isinstance(code, str) else 'reauthorization_required'
                return self._transition_result(credential, row, reason, 'reauthorization_required', reason)
            if status == 507 and ack.get('error') == 'storage_capacity_reached':
                return self._transition_result(credential, row, 'storage_capacity_reached',
                                               'capacity_paused', 'storage_capacity_reached')
            if status in (200, 201) and ack.get('batchHash') == digest and ack.get('committed') is True:
                ack_at = ack.get('serverAckAt')
                if type(ack_at) is not int or not 0 < ack_at < 2**53:
                    ack_at = int(self.now() * 1000)
                binding = (credential['deviceId'], credential['scope']['guild'], digest)
                with self.store.db:
                    self.store.db.execute('INSERT OR IGNORE INTO scoped_receipts VALUES(?,?,?,?)', (*binding, ack_at))
                    self.store.db.execute("""UPDATE scoped_delivery_state SET status='acknowledged',
                        error=NULL,lease_until=0,claim_id=NULL WHERE device_id=? AND guild=? AND hash=?""", binding)
                return 'acknowledged'
            if status in (400, 409, 413, 422):
                return self._transition_result(credential, row, 'quarantined', 'quarantined', 'invalid_or_conflicting_evidence')
            return self._transition_result(credential, row, 'retry_later', 'pending', 'retry_pending', retry=True)
        except sqlite3.Error:
            return 'store_unavailable'
        finally:
            self.running = False
