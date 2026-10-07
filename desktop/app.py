"""EmberSync desktop: local journal review and browser-approved device uploads."""
import argparse,json,queue,webbrowser
from pathlib import Path
import tkinter as tk
from tkinter import filedialog,messagebox,ttk
from pipeline import JournalStore
from runtime import DesktopWorker,default_data_dir,read_metadata,write_json_exclusive

def create_ui(data_dir,smoke=False,worker_factory=None,test_driver=None):
    data_dir=Path(data_dir);data_dir.mkdir(parents=True,exist_ok=True)
    root=tk.Tk();root.title('EmberSync · Guild roster evidence');root.geometry('920x780');root.minsize(660,560)
    try:store=JournalStore(data_dir/'journal.sqlite');worker=(worker_factory or DesktopWorker)(data_dir)
    except Exception:root.destroy();raise
    if smoke:root.withdraw()
    selected=tk.StringVar();guild=tk.StringVar(value='main');epoch=tk.StringVar();status=tk.StringVar(value='Choose SavedVariables after /reload or logout.');pair_status=tk.StringVar(value='No active pairing.');sync_enabled=tk.BooleanVar(value=False)
    pending_jobs=0;pending_actions={};pairing=None;metadata=None;broken=False;metadata_broken=False
    try:metadata=read_metadata(data_dir/'device.json')
    except Exception:metadata_broken=True;status.set('Device metadata unavailable. Prior files preserved; uploads paused. Local scans are available.')
    frame=ttk.Frame(root,padding=20);frame.pack(fill='both',expand=True)
    ttk.Label(frame,text='EmberSync',font=('Segoe UI',24,'bold')).pack(anchor='w')
    ttk.Label(frame,text='Roster activity · Joins · Departures · Top Inviters').pack(anchor='w',pady=(0,12))
    ttk.Label(frame,text='Uploads require browser approval and a supported operating system vault.').pack(anchor='w')
    ttk.Label(frame,textvariable=selected,wraplength=840).pack(anchor='w',pady=8)
    buttons=ttk.Frame(frame);buttons.pack(fill='x')
    sources=ttk.Frame(frame);sources.pack(fill='x',pady=8)
    ttk.Label(sources,text='Collector epoch:').pack(side='left')
    source_select=ttk.Combobox(sources,textvariable=epoch,state='readonly');source_select.pack(side='left',fill='x',expand=True,padx=8)
    review=ttk.Frame(frame);review.pack(fill='both',expand=True,pady=8)
    text=tk.Text(review,wrap='word',height=17,state='disabled',font=('Segoe UI',11));text.pack(side='left',fill='both',expand=True)
    scroll=ttk.Scrollbar(review,orient='vertical',command=text.yview);scroll.pack(side='right',fill='y');text.configure(yscrollcommand=scroll.set)
    connection=ttk.LabelFrame(frame,text='Website connection',padding=12);connection.pack(fill='x')
    ttk.Label(connection,textvariable=pair_status,wraplength=820).pack(anchor='w')
    connection_buttons=ttk.Frame(connection);connection_buttons.pack(fill='x')
    ttk.Label(frame,textvariable=status,wraplength=840).pack(anchor='w',pady=8)
    def connection_label():
        if metadata:
            s=metadata['scope'];pair_status.set(f"Paired: {s['sourceName']} · {s['sourceRealm']} · {s['guild']}\nDevice: {metadata['deviceId']} · Uploads {'enabled' if sync_enabled.get() else 'paused'}")
    def show():
        try:
            options=store.epochs(guild.get());source_select['values']=options
            if epoch.get() not in options:epoch.set(options[0] if len(options)==1 else '')
            result=store.metrics(guild.get(),epoch.get() or None)
            fmt=lambda v:'Unavailable' if v is None else str(v)
            text.configure(state='normal');text.delete('1.0','end')
            text.insert('end',f"Guild: {guild.get()}\nCoverage: {result['coverage']}\n\nMembers: {fmt(result['members'])}\nOnline at collection: {fmt(result['online'])}\nObserved arrivals: {fmt(result['joins'])}\nObserved departures: {fmt(result['departures'])}\nNet change: {fmt(result['net'])}\n\nTop Inviters\n")
            text.insert('end','Invitations issued in the latest log window; these are separate from confirmed joins.\n')
            for actor,count in result['topInviters']:text.insert('end',f'{actor}: {count}\n')
            text.insert('end',f"Unknown invited by: {fmt(result['unknownInviters'])}\n\nBaseline membership is not a historical join. Choose one collector epoch; missing coverage is unavailable. Online presence is an observation, not playtime.\n")
            text.insert('end',f"Roster freshness: {'stale' if result.get('rosterStale') else 'current' if result['members'] is not None else 'unavailable'}\nLatest roster coverage: {result.get('latestRosterCoverage','unavailable')}\nLatest log coverage: {result.get('latestLogCoverage','unavailable')}\nInvitation attribution coverage: {result.get('inviterCoverage','unavailable')}\n")
            if result.get('hasGaps'):text.insert('end','Observation gaps are present; changes are limited to the observed complete intervals.\n')
            if result.get('hasDefiniteLoss'):text.insert('end','The addon journal reports discarded observations. Historical coverage is incomplete.\n')
            providers=result.get('providerWindows',[])
            text.insert('end','\nOptional addon data\n')
            if not providers:
                text.insert('end','No provider evidence in the selected observation. In game, use /embersync plugins to check or enable Guild Roster Manager.\n')
            for provider in providers:
                text.insert('end',f"Guild Roster Manager {provider['version']} · {provider['coverage']} coverage · {'stale observation' if provider['stale'] else 'current observation'}\n")
                text.insert('end',provider['scope']+'\n')
                rows=provider['rows']
                text.insert('end',f"Retained history: {len(rows)} rows. Showing at most 20 rows. These rows do not add to invitations or roster changes above.\n")
                for row in rows[:20]:
                    date=row.get('calendarDate');date_label=''
                    if date:date_label=f" · Provider calendar {date[2]:04d}-{date[1]:02d}-{date[0]:02d} {date[3]:02d}:{date[4]:02d} (timezone unknown)"
                    attribution=f" · Invited by: {row.get('invitedBy','Unknown')}" if row['type'] in ('join','rejoin') else ''
                    text.insert('end',f"{row['type'].capitalize()}: {row['subject']}{attribution}{date_label}\n")
        except Exception:status.set('Local metrics temporarily unavailable; retry after the current save finishes.')
        finally:text.configure(state='disabled')
    def submit(action,value=None,explicit=False):
        nonlocal pending_jobs
        if broken or (metadata_broken and action!='scan'):
            if explicit:status.set('Device connection unavailable; prior files are preserved. Local review remains available.')
            return False
        if pending_jobs and not explicit:return False
        if not worker.submit(action,value):
            if explicit:status.set('Desktop is closing. This action was not queued.')
            return False
        pending_jobs+=1;pending_actions[action]=pending_actions.get(action,0)+1;return True
    def scan(explicit=False):
        if selected.get():submit('scan',selected.get(),explicit)
    def choose():
        filename=filedialog.askopenfilename(title='Choose EmberSync SavedVariables',filetypes=[('Lua SavedVariables','*.lua')])
        if filename:selected.set(filename);scan(True)
    def export():
        filename=filedialog.asksaveasfilename(title='Export local evidence for review',defaultextension='.json',filetypes=[('JSON','*.json')])
        if not filename:return
        try:
            write_json_exclusive(filename,store.metrics(guild.get(),epoch.get() or None))
            status.set('Review export created. It contains guild observations; share only with authorized members.')
        except FileExistsError:messagebox.showerror('File exists','Choose a new filename. Exports are never overwritten.')
        except Exception:messagebox.showerror('Export unavailable','Prior evidence is preserved. Check folder access and retry.')
    def start_pair():
        if metadata is not None:status.set('Revoke the current device before registering a replacement.');return
        if pending_actions.get('pair') or pending_actions.get('cancel'):status.set('The pairing action is already queued.');return
        if submit('pair',explicit=True):status.set('Requesting a browser approval code. Cancel pairing remains available while this request finishes.')
    def open_approval():
        if pairing:
            try:
                if not webbrowser.open(pairing['verificationUri']):status.set('Browser could not open. Retry Open approval page.')
            except Exception:status.set('Browser could not open. Retry Open approval page.')
    def cancel_pair():
        if not pairing and not pending_actions.get('pair') and not pending_actions.get('poll'):status.set('No pending pairing to cancel. Use Revoke device for the installed credential.');return
        sync_enabled.set(False)
        if submit('cancel',explicit=True):status.set('Cancellation queued. A completed approval will be revoked before its credential is removed.')
    def revoke():
        if metadata:
            sync_enabled.set(False);connection_label()
            if submit('revoke',metadata,True):status.set('Revocation queued. Uploads are paused until its server acknowledgement.')
    def toggle_uploads():
        if not metadata:sync_enabled.set(False);status.set('Pair and approve this computer first.');return
        connection_label()
        if sync_enabled.get() and not submit('resume',metadata,True):sync_enabled.set(False);connection_label()
    ttk.Button(buttons,text='Choose SavedVariables',command=choose).pack(side='left')
    ttk.Button(buttons,text='Rescan',command=lambda:scan(True)).pack(side='left',padx=8)
    ttk.Button(buttons,text='Export for review',command=export).pack(side='left')
    guild_select=ttk.Combobox(buttons,textvariable=guild,values=['main','alts'],state='readonly',width=8);guild_select.pack(side='right');guild_select.bind('<<ComboboxSelected>>',lambda _:show());source_select.bind('<<ComboboxSelected>>',lambda _:show())
    ttk.Button(connection_buttons,text='Pair this computer',command=start_pair).pack(side='left')
    ttk.Button(connection_buttons,text='Open approval page',command=open_approval).pack(side='left',padx=8)
    ttk.Button(connection_buttons,text='Cancel pairing',command=cancel_pair).pack(side='left')
    ttk.Button(connection_buttons,text='Revoke device',command=revoke).pack(side='left',padx=8)
    ttk.Checkbutton(connection,text='Enable uploads',variable=sync_enabled,command=toggle_uploads).pack(anchor='w',pady=(6,0))
    def poll_results():
        nonlocal pending_jobs,pairing,metadata,broken
        try:
            while True:
                result=worker.results.get_nowait();pending_jobs=max(0,pending_jobs-1);action=result['action'];pending_actions[action]=max(0,pending_actions.get(action,0)-1)
                if not result['ok']:
                    if action=='startup':broken=True
                    if action in ('upload','resume'):sync_enabled.set(False);connection_label()
                    status.set(f"{action.capitalize()} deferred ({result['error']}). Prior evidence remains available. Retry or use the website device manager.")
                elif action=='scan':status.set(f"{result['count']} new observations saved locally.");show()
                elif action=='pair':pairing=result['pairing'];pair_status.set(f"Compare code {pairing['userCode']} on the website, choose your verified source and approve.")
                elif action=='poll':
                    if result['status']=='approved':metadata=result['metadata'];pairing=None;sync_enabled.set(True);connection_label();status.set('Approved device key saved in the OS vault. Uploads enabled for its guild.')
                    elif result['status'] in ('expired','cancelled'):pairing=None;pair_status.set('Pairing '+result['status']+'. Start again when ready.')
                elif action=='cancel':
                    if result['status']=='cancelled':
                        pairing=None
                        if result.get('deviceRemoved'):metadata=None;sync_enabled.set(False)
                        pair_status.set('Pairing cancelled.');status.set('Cancelled approval was revoked; no device credential remains.' if result.get('deviceRemoved') else 'Pending approval cancelled on this computer.')
                    else:status.set('No pending pairing to cancel.');connection_label()
                elif action=='revoke':metadata=None;pairing=None;sync_enabled.set(False);pair_status.set('Device revoked and local vault key removed.');status.set('Further uploads from this device are denied.')
                elif action in ('upload','resume'):
                    status.set('Server delivery: '+result['status']+'. Local review is still available.')
                    if result['status']=='storage_capacity_reached':status.set('Website evidence storage is full. Uploads are paused; queued observations remain on this computer. Retry Enable uploads after capacity is available.')
                    if result['status'] in ('paused','device_revoked','source_refresh_required','scope_denied','reauthorization_required','credentials_unavailable','invalid_credentials','pairing_required','storage_capacity_reached'):sync_enabled.set(False);connection_label()
        except queue.Empty:pass
        root.after(150,poll_results)
    def periodic_pair():
        if pairing:submit('poll')
        root.after(5000,periodic_pair)
    def periodic_upload():
        if metadata and sync_enabled.get():submit('upload',metadata)
        root.after(3000,periodic_upload)
    def periodic_scan():scan();root.after(30000,periodic_scan)
    def close():worker.close();store.close();root.destroy()
    root.protocol('WM_DELETE_WINDOW',close);show();connection_label()
    if smoke:
        try:
            if not worker.ready.wait(3) or worker.startup_error:raise RuntimeError('desktop_worker_startup_failed')
            root.update()
        finally:close();worker.thread.join(timeout=3)
        if worker.thread.is_alive():raise RuntimeError('desktop_worker_shutdown_failed')
        return
    root.after(150,poll_results);root.after(5000,periodic_pair);root.after(3000,periodic_upload);root.after(30000,periodic_scan)
    if test_driver is not None:root.after(0,lambda:test_driver(root,{'status':status,'pairStatus':pair_status,'syncEnabled':sync_enabled,'selected':selected,'guild':guild,'epoch':epoch,'close':close,'pollResults':poll_results,'periodicPair':periodic_pair,'periodicUpload':periodic_upload,'show':show,'text':text,'worker':worker}))
    root.mainloop()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--self-test',action='store_true');parser.add_argument('--ui-smoke-test',action='store_true');parser.add_argument('--data-dir',type=Path);args=parser.parse_args()
    if args.self_test:
        import tempfile
        import base64,hashlib,importlib,sys
        from device import new_pairing_request,sign_request_headers
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        # Native QA uses an in-memory fixture key. Importing the backend verifies
        # packaging without credential access or D-Bus unlock attempts.
        request,private=new_pairing_request();body=b'{"nativeFixture":true}'
        identity='12345678-1234-1234-1234-123456789abc';nonce='a'*32
        headers=sign_request_headers(body,{'deviceId':identity,'privateKey':private},now_ms=1700000000000,nonce=nonce)
        message=f'EmberSync-v2\nPOST\n/api/embersync/v2/ingest\n{identity}\n1700000000000\n{nonce}\n{hashlib.sha256(body).hexdigest()}'.encode()
        Ed25519PublicKey.from_public_bytes(base64.b64decode(request['publicKey'])).verify(base64.b64decode(headers['x-embersync-signature']),message)
        backend=importlib.import_module('keyring.backends.'+('Windows' if sys.platform=='win32' else 'macOS' if sys.platform=='darwin' else 'SecretService'))
        if sys.platform=='win32' and backend.missing_deps:raise RuntimeError('native_vault_dependency_missing')
        if sys.platform=='darwin' and not hasattr(backend,'api'):raise RuntimeError('native_vault_dependency_missing')
        if sys.platform.startswith('linux') and not hasattr(backend,'secretstorage'):raise RuntimeError('native_vault_dependency_missing')
        with tempfile.TemporaryDirectory() as folder:
            store=JournalStore(Path(folder)/'test.sqlite');assert store.guilds()==[];store.close()
        print('EmberSync desktop self-test passed');return
    if args.ui_smoke_test:
        import tempfile
        with tempfile.TemporaryDirectory() as folder:create_ui(folder,smoke=True)
        print('EmberSync complete window smoke-test passed');return
    create_ui(args.data_dir or default_data_dir())
if __name__=='__main__':main()
