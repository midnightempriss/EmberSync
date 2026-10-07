"""GUI work queue. Public metadata only on disk; device keys stay in the OS vault."""
import json,os,queue,sys,tempfile,threading
from pathlib import Path
from pipeline import JournalStore,stable_read
from device import validate_metadata,load_registered_device,forget_registered_device
from pairing import PairingClient,revoke_device
from sync import DeliveryWorker,ENDPOINT

def default_data_dir():
    if sys.platform=='win32':return Path(os.environ.get('LOCALAPPDATA',str(Path.home()/'AppData'/'Local')))/'EmberSyncV2'
    if sys.platform=='darwin':return Path.home()/'Library'/'Application Support'/'EmberSyncV2'
    value=os.environ.get('XDG_DATA_HOME','')
    return (Path(value) if value and Path(value).is_absolute() else Path.home()/'.local'/'share')/'EmberSyncV2'

def read_metadata(path):
    path=Path(path)
    if not path.exists():return None
    with path.open('rb') as source:raw=source.read(65537)
    if len(raw)>65536:raise ValueError('invalid_device_metadata')
    return validate_metadata(json.loads(raw.decode('utf-8')))

def save_metadata(path,metadata):
    path=Path(path);metadata=validate_metadata(metadata)
    existing=read_metadata(path)
    if existing is not None and existing!=metadata:raise ValueError('revoke_existing_device_first')
    if existing==metadata:return
    try:write_json_exclusive(path,metadata)
    except FileExistsError:
        if read_metadata(path)!=metadata:raise ValueError('revoke_existing_device_first') from None

def write_json_exclusive(path,value):
    """Publish a complete export/config atomically without overwriting a collision."""
    path=Path(path)
    raw=json.dumps(value,ensure_ascii=False,separators=(',',':'),allow_nan=False).encode('utf-8')
    fd,name=tempfile.mkstemp(prefix='.embersync-',suffix='.json',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as target:
            target.write(raw);target.flush();os.fsync(target.fileno())
        os.link(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)

class InstanceLock:
    """One enrollment/delivery worker per data directory, including other processes."""
    def __init__(self,path):self.path=Path(path);self.file=None
    def acquire(self):
        self.file=self.path.open('a+b')
        try:
            self.file.seek(0,os.SEEK_END)
            if self.file.tell()==0:self.file.write(b'0');self.file.flush()
            self.file.seek(0)
            if sys.platform=='win32':
                import msvcrt
                msvcrt.locking(self.file.fileno(),msvcrt.LK_NBLCK,1)
            else:
                import fcntl
                fcntl.flock(self.file.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
        except Exception:
            self.file.close();self.file=None
            raise RuntimeError('desktop_already_running') from None
    def release(self):
        if self.file is not None:
            try:
                self.file.seek(0)
                if sys.platform=='win32':
                    import msvcrt
                    msvcrt.locking(self.file.fileno(),msvcrt.LK_UNLCK,1)
                else:
                    import fcntl
                    fcntl.flock(self.file.fileno(),fcntl.LOCK_UN)
            finally:self.file.close();self.file=None

class DesktopWorker:
    def __init__(self,data_dir,pairing_factory=PairingClient,credential_loader=load_registered_device,
                 revoke=revoke_device,forget=forget_registered_device,transport=None):
        self.data_dir=Path(data_dir);self.metadata_path=self.data_dir/'device.json'
        self.jobs=queue.Queue();self.results=queue.Queue();self.pair=None;self.active=None
        self.pairing_factory=pairing_factory;self.load=credential_loader;self.revoke=revoke;self.forget=forget;self.transport=transport
        self.closing=threading.Event();self.ready=threading.Event();self.startup_error=None
        # Finish an in-flight vault/config commit before process exit. Pending
        # periodic work is discarded on close; no keys are lost mid-persistence.
        self.thread=threading.Thread(target=self._run,daemon=False);self.thread.start()
    def submit(self,action,value=None):
        if self.closing.is_set():return False
        self.jobs.put((action,value));return True
    def close(self):self.closing.set();self.jobs.put(('close',None))
    def _run(self):
        store=None;delivery=None;lock=None
        try:
            self.data_dir.mkdir(parents=True,exist_ok=True)
            lock=InstanceLock(self.data_dir/'.desktop.lock');lock.acquire()
            store=JournalStore(self.data_dir/'journal.sqlite')
            delivery=DeliveryWorker(store,ENDPOINT,lambda:self.load(self.active) if self.active else None,transport=self.transport)
            self.ready.set()
            while True:
                action,value=self.jobs.get()
                if action=='close' or self.closing.is_set():break
                try:
                    result=self._perform(action,value,store,delivery)
                    self.results.put({'action':action,'ok':True,**result})
                except Exception as error:
                    # Exception text can contain file paths, transport bytes or vault secrets.
                    self.results.put({'action':action,'ok':False,'error':type(error).__name__})
        except Exception as error:
            self.startup_error=type(error).__name__;self.ready.set()
            self.results.put({'action':'startup','ok':False,'error':type(error).__name__})
        finally:
            if store:store.close()
            if lock:lock.release()
    def _perform(self,action,value,store,delivery):
        if action=='scan':return {'count':store.ingest(stable_read(value))}
        if action=='pair':
            if read_metadata(self.metadata_path) is not None:raise ValueError('revoke_existing_device_first')
            if self.pair is None or self.pair.state in ('expired','cancelled'):self.pair=self.pairing_factory(name='This '+('Windows PC' if sys.platform=='win32' else 'computer'))
            return {'pairing':self.pair.start()}
        if action=='poll':
            if self.pair is None:raise ValueError('pairing_required')
            result=self.pair.poll()
            if result['status']=='approved':
                metadata=self.pair.persist(lambda item:save_metadata(self.metadata_path,item))
                self.active=metadata;return {'status':'approved','metadata':metadata}
            return {'status':result['status']}
        if action=='cancel':
            metadata=read_metadata(self.metadata_path)
            if metadata is not None:
                # Cancel may have been queued while the same pairing was
                # committing. Honor that action only for this pairing, using
                # the same acknowledged removal path as explicit Revoke.
                if self.pair is None or self.pair.state!='persisted' or self.pair._approved!=metadata:
                    return {'status':'no_pending_pairing'}
                self._perform('revoke',metadata,store,delivery)
                return {'status':'cancelled','deviceRemoved':True}
            if self.pair is None:return {'status':'cancelled'}
            result=self.pair.cancel();self.pair=None;return result
        if action in ('upload','resume'):
            self.active=validate_metadata(value)
            if action=='resume':return {'status':'ready' if delivery.resume() else 'credentials_unavailable'}
            return {'status':delivery.drain_once()}
        if action=='revoke':
            metadata=validate_metadata(value);credential=self.load(metadata)
            # A prior successful revocation can be retried after a filesystem
            # failure removed the vault key but retained public metadata.
            if credential is None:
                if getattr(self,'_revoked_metadata',None)!=metadata:raise ValueError('device_key_unavailable')
            else:
                ack=self.revoke(credential)
                if ack.get('revoked') is not True or ack.get('deviceId')!=metadata['deviceId']:raise ValueError('revocation_unconfirmed')
                self._revoked_metadata=metadata
            self.forget(metadata['deviceId']);self.metadata_path.unlink(missing_ok=True)
            self.active=None;self.pair=None;self._revoked_metadata=None;return {'status':'revoked'}
        raise ValueError('unknown_action')
