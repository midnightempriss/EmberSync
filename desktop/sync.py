"""Durable delivery adapter. Disabled until an approved revocable device is paired.

Credentials are supplied by an OS-vault adapter at runtime, never persisted here.
No endpoint is enabled by default and no production requests occur during tests.
"""
import hashlib
import json
import time
import urllib.error
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None

class DeliveryWorker:
    def __init__(self,store,endpoint,credential_provider,transport=None,now=time.time):
        if endpoint != 'https://rainingembers.org/api/embersync/v2/ingest': raise ValueError('Unapproved endpoint')
        self.store=store;self.endpoint=endpoint;self.credentials=credential_provider;self.now=now
        self.transport=transport or self.request
        self.paused=False;self.running=False
        store.db.executescript('''CREATE TABLE IF NOT EXISTS delivery_state(hash TEXT PRIMARY KEY,attempts INTEGER DEFAULT 0,next_at REAL DEFAULT 0,error TEXT);
        CREATE TABLE IF NOT EXISTS receipts(hash TEXT PRIMARY KEY,server_ack_at REAL NOT NULL);''')
    def request(self,body,token):
        from device import sign_headers
        req=urllib.request.Request(self.endpoint,data=body,headers={'Content-Type':'application/json',**sign_headers(body,token)},method='POST')
        try:
            with urllib.request.build_opener(NoRedirect()).open(req,timeout=20) as r:
                raw=r.read(65537)
                if len(raw)>65536: raise ValueError('Oversized acknowledgement')
                return r.status,json.loads(raw)
        except urllib.error.HTTPError as error:return error.code,{}
    def drain_once(self):
        if self.running or self.paused:return 'paused'
        token=self.credentials()
        if not token:return 'pairing_required'
        row=self.store.db.execute('''SELECT o.hash,o.payload,COALESCE(d.attempts,0) FROM outbox o LEFT JOIN delivery_state d ON d.hash=o.hash
        WHERE o.status='pending' AND COALESCE(d.next_at,0)<=? ORDER BY o.rowid LIMIT 1''',(self.now(),)).fetchone()
        if not row:return 'idle'
        digest,payload,attempts=row
        self.running=True
        try:
            body=json.dumps({'version':2,'batchHash':digest,'evidence':json.loads(payload)},separators=(',',':')).encode()
            try:status,ack=self.transport(body,token)
            except (OSError,ValueError,TimeoutError):status,ack=503,{}
            if status in [401,403]:self.paused=True;return 'reauthorization_required'
            if status in [200,201] and isinstance(ack,dict) and ack.get('batchHash')==digest and ack.get('committed') is True:
                with self.store.db:
                    self.store.db.execute('INSERT OR IGNORE INTO receipts VALUES(?,?)',(digest,self.now()))
                    self.store.db.execute("UPDATE outbox SET status='acknowledged' WHERE hash=? AND payload=?",(digest,payload))
                return 'acknowledged'
            with self.store.db:
                if status in [400,409,413,422]:
                    self.store.db.execute("UPDATE outbox SET status='quarantined' WHERE hash=? AND payload=?",(digest,payload));return 'quarantined'
                delay=min(3600,30*2**min(attempts,7))
                self.store.db.execute('INSERT INTO delivery_state VALUES(?,?,?,?) ON CONFLICT(hash) DO UPDATE SET attempts=excluded.attempts,next_at=excluded.next_at,error=excluded.error',(digest,attempts+1,self.now()+delay,'retry_pending'))
            return 'retry_later'
        finally:self.running=False
