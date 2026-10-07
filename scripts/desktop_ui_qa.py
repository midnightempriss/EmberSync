"""Drive actual Tk controls with temporary evidence and a fixture-only vault/server.

No credentials, browser, network endpoint, installed files or real SavedVariables
are accessed. Linux runners require xvfb-run; this is separate from unit discovery.
"""
import hashlib, json, os, sys, tempfile, threading, time
from pathlib import Path
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'));sys.path.insert(0,str(ROOT/'desktop'))
import app
from device import NativeVault
from pairing import PairingClient,START_PATH
from pipeline import JournalStore
from runtime import DesktopWorker,read_metadata
from test_device import FakeBackend,DEVICE
from test_pairing import Clock,FixtureServer
from test_pipeline import roster
from test_sync import acknowledge


def run():
    with tempfile.TemporaryDirectory() as folder:
        path=Path(folder);saved=path/'fixture.lua';export=path/'review.json'
        provider={'kind':'log','guild':'main','epoch':'epoch-a','seq':3,'collectedAt':1700000003,'coverage':'partial','rows':[],
                  'providerLogs':[{'provider':'guild-roster-manager','version':'1.99422','coverage':'partial','rows':[
                      {'type':'join','subject':'B','invitedBy':'Fixture Inviter','calendarDate':[7,10,2026,11,20]},
                      {'type':'rejoin','subject':'C'}]}]}
        records=[roster(1,['A']),roster(2,['A','B']),roster(1,['Alt'],guild='alts'),provider]
        entries=','.join(json.dumps(json.dumps(row)) for row in records)
        saved.write_text('EmberSyncJournalV2={version=2,entries={'+entries+'}}',encoding='utf-8')
        clock=Clock();server=FixtureServer(clock);backend=FakeBackend();vault=NativeVault(backend)
        entered=threading.Event();release=threading.Event();mode={'blockStart':True,'capacity':True}
        revocations=[];errors=[];browser=[];checks=[];workers=[]
        def transport(method,endpoint,body,headers):
            if endpoint==START_PATH and mode['blockStart']:
                entered.set()
                if not release.wait(5):raise RuntimeError('fixture start timeout')
            return server(method,endpoint,body,headers)
        def pairing_factory(**options):return PairingClient(transport=transport,now=clock,vault=vault,**options)
        def revoke(credential):
            revocations.append(credential['deviceId'])
            return {'revoked':True,'deviceId':credential['deviceId']}
        def delivery(body,credential):
            return (507,{'error':'storage_capacity_reached'}) if mode['capacity'] else acknowledge(body,credential)
        def worker_factory(data_dir):
            worker=DesktopWorker(data_dir,pairing_factory=pairing_factory,credential_loader=vault.load,
                                 revoke=revoke,forget=vault.delete,transport=delivery)
            workers.append(worker);return worker
        def driver(root,ui):
            root.withdraw();deadline=time.monotonic()+20
            def failed(error):
                errors.append(error);release.set();ui['close']()
            root.report_callback_exception=lambda kind,error,tb:failed(error)
            def check(value,label):
                if not value:raise AssertionError(label)
                checks.append(label)
            def controls(widget):
                for child in widget.winfo_children():
                    yield child;yield from controls(child)
            def button(label):return next(w for w in controls(root) if w.winfo_class()=='TButton' and w.cget('text')==label)
            def checkbox():return next(w for w in controls(root) if w.winfo_class()=='TCheckbutton')
            def wait(condition,action):
                def tick():
                    try:
                        if time.monotonic()>deadline:raise AssertionError('GUI fixture timed out: '+ui['status'].get())
                        if condition():action()
                        else:root.after(20,tick)
                    except Exception as error:failed(error)
                root.after(20,tick)
            def query(sql):
                store=JournalStore(path/'journal.sqlite')
                try:return store.db.execute(sql).fetchone()[0]
                finally:store.close()
            def after_scan():
                check('Members: 2' in ui['text'].get('1.0','end'),'actual scan displays current members')
                check('Observed arrivals: 1' in ui['text'].get('1.0','end'),'actual scan displays observed arrivals')
                check('Roster freshness: stale' in ui['text'].get('1.0','end'),'stale fixture is labelled')
                check('Invited by: Fixture Inviter' in ui['text'].get('1.0','end'),'sanitized GRM join attribution is displayed separately')
                check('Invited by: Unknown' in ui['text'].get('1.0','end'),'GRM unknown attribution remains unknown')
                check('(timezone unknown)' in ui['text'].get('1.0','end'),'provider calendar is not presented as an exact UTC timestamp')
                ui['guild'].set('alts');ui['show']()
                check('Members: 1' in ui['text'].get('1.0','end'),'guild selector isolates alt roster')
                ui['guild'].set('main');ui['show']()
                button('Export for review').invoke();before=export.read_bytes();button('Export for review').invoke()
                check(export.read_bytes()==before and bool(dialog_errors),'export collision preserves complete existing file')
                button('Pair this computer').invoke()
                wait(entered.is_set,cancel_start)
            def cancel_start():
                button('Cancel pairing').invoke();release.set()
                wait(lambda:ui['pairStatus'].get()=='Pairing cancelled.',after_cancel)
            def after_cancel():
                check(backend.writes==0 and not (path/'device.json').exists(),'cancel while start is busy creates no installed credential')
                mode['blockStart']=False;button('Pair this computer').invoke()
                wait(lambda:'Compare code' in ui['pairStatus'].get(),approve)
            def approve():
                button('Open approval page').invoke()
                check(len(browser)==1 and browser[0].startswith('https://rainingembers.org/members/embersync?code='),'approval button uses validated official URI')
                server.approved=True;clock.advance(5);ui['periodicPair']()
                wait(lambda:ui['pairStatus'].get().startswith('Paired:'),after_approval)
            def after_approval():
                metadata=read_metadata(path/'device.json')
                check(metadata['deviceId']==DEVICE and backend.writes==1,'approval persists one fake-vault credential and public registry')
                check('privateKey' not in (path/'device.json').read_text('utf-8'),'public registry excludes private key')
                check(ui['syncEnabled'].get(),'approved GUI enables its scoped uploads')
                checkbox().invoke();check(not ui['syncEnabled'].get(),'upload toggle can pause')
                checkbox().invoke()
                wait(lambda:'Server delivery: ready.' in ui['status'].get(),send_at_capacity)
            def send_at_capacity():
                ui['periodicUpload']()
                wait(lambda:'Website evidence storage is full.' in ui['status'].get(),retry)
            def retry():
                check(not ui['syncEnabled'].get(),'507 disables GUI uploads with explanatory status')
                check(query('SELECT count(*) FROM evidence')==4 and query('SELECT count(*) FROM scoped_receipts')==0,'capacity pause preserves all queued evidence')
                mode['capacity']=False;checkbox().invoke()
                wait(lambda:'Server delivery: ready.' in ui['status'].get(),send_after_resume)
            def send_after_resume():
                ui['periodicUpload']()
                wait(lambda:'Server delivery: acknowledged.' in ui['status'].get(),revoke_device)
            def revoke_device():
                check(query('SELECT count(*) FROM scoped_receipts')==1,'explicit retry records one exact acknowledgement')
                button('Revoke device').invoke()
                wait(lambda:ui['pairStatus'].get()=='Device revoked and local vault key removed.',finish)
            def finish():
                check(revocations==[DEVICE] and backend.values=={} and not (path/'device.json').exists(),'revoke button removes acknowledged device key and public registry')
                check(not ui['syncEnabled'].get(),'revocation keeps upload toggle paused')
                ui['close']()
            button('Choose SavedVariables').invoke()
            wait(lambda:'new observations saved locally.' in ui['status'].get(),after_scan)
        dialog_errors=[]
        try:
            with patch('app.filedialog.askopenfilename',return_value=str(saved)), \
                 patch('app.filedialog.asksaveasfilename',return_value=str(export)), \
                 patch('app.messagebox.showerror',side_effect=lambda *args:dialog_errors.append(args)), \
                 patch('app.webbrowser.open',side_effect=lambda uri:browser.append(uri) or True):
                app.create_ui(path,worker_factory=worker_factory,test_driver=driver)
        finally:
            release.set()
            for worker in workers:worker.close();worker.thread.join(5)
        if errors:raise errors[0]
        if not checks or len(checks)<15:raise AssertionError('GUI fixture did not complete all scenarios')
        sources=['desktop/app.py','desktop/runtime.py','desktop/device.py','desktop/pairing.py','desktop/sync.py','desktop/pipeline.py','scripts/desktop_ui_qa.py']
        report=ROOT/'.build/source-gui-qa.json';report.parent.mkdir(parents=True,exist_ok=True)
        report.write_text(json.dumps({'passed':True,'checks':len(checks),'fixtureOnly':True,'sourceCommit':os.environ.get('GITHUB_SHA'),
                                     'sourceHashes':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sources}},indent=2)+'\n',encoding='utf-8')
        print(f'EmberSync actual-control GUI QA passed: {len(checks)} checks; fake vault/server, temporary files only')


if __name__=='__main__':run()
