"""EmberSync offline desktop. No network, pairing, credential or addon writes."""
import argparse
import json
import os
from pathlib import Path
import sys
import sqlite3
import threading
import queue
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from pipeline import JournalStore, stable_read

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--self-test', action='store_true'); parser.add_argument('--ui-smoke-test',action='store_true'); parser.add_argument('--data-dir',type=Path)
    args=parser.parse_args()
    if args.ui_smoke_test:
        smoke=tk.Tk();smoke.withdraw();ttk.Label(smoke,text='EmberSync fixture').pack();smoke.update();smoke.destroy();return
    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            store=JournalStore(Path(d)/'test.sqlite'); assert store.guilds()==[]; store.close()
        print('EmberSync desktop self-test passed'); return
    data_dir=args.data_dir or Path(os.environ.get('LOCALAPPDATA',str(Path.home()/'.local'/'share')))/'EmberSyncV2'
    data_dir.mkdir(parents=True,exist_ok=True)
    store=JournalStore(data_dir/'journal.sqlite')
    root=tk.Tk(); root.title('EmberSync · Guild roster evidence'); root.geometry('860x670'); root.minsize(620,500)
    selected=tk.StringVar(); guild=tk.StringVar(value='main'); status=tk.StringVar(value='Choose the addon SavedVariables file after /reload or logout.')
    work_results=queue.Queue(); working=False
    frame=ttk.Frame(root,padding=24); frame.pack(fill='both',expand=True)
    ttk.Label(frame,text='EmberSync',font=('Segoe UI',24,'bold')).pack(anchor='w')
    ttk.Label(frame,text='Roster activity · Joins · Departures · Top Inviters').pack(anchor='w',pady=(0,18))
    ttk.Label(frame,text='Local preview — uploads paused. No credentials or site access created.').pack(anchor='w')
    ttk.Label(frame,textvariable=selected,wraplength=760).pack(anchor='w',pady=10)
    buttons=ttk.Frame(frame); buttons.pack(fill='x')
    text=tk.Text(frame,wrap='word',height=23,state='disabled',font=('Segoe UI',11)); text.pack(fill='both',expand=True,pady=16)
    ttk.Label(frame,textvariable=status,wraplength=760).pack(anchor='w')
    def show():
        result=store.metrics(guild.get()); text.configure(state='normal'); text.delete('1.0','end')
        fmt=lambda v:'Unavailable' if v is None else str(v)
        text.insert('end',f"Guild: {guild.get()}\nCoverage: {result['coverage']}\n\nMembers: {fmt(result['members'])}\nOnline at collection: {fmt(result['online'])}\nObserved arrivals: {fmt(result['joins'])}\nObserved departures: {fmt(result['departures'])}\nNet change: {fmt(result['net'])}\n\nTop Inviters\n")
        text.insert('end','Invitations issued in the latest log window; these are not confirmed joins.\n')
        for actor,count in result['topInviters']: text.insert('end',f'{actor}: {count}\n')
        text.insert('end',f"Unknown invited by: {fmt(result['unknownInviters'])}\n\nBaseline membership is never counted as a historical join.\nCollectors and resets are not combined. Missing coverage is never zero.\n")
        text.configure(state='disabled')
    def scan():
        nonlocal working
        if selected.get() and not working:
            working=True; filename=selected.get()
            def read_worker():
                worker_store=None
                try:
                    parsed=stable_read(filename); worker_store=JournalStore(data_dir/'journal.sqlite'); count=worker_store.ingest(parsed)
                    work_results.put(f'{count} new observations saved locally. Server acknowledgement: unavailable.')
                except (OSError,ValueError,RecursionError,sqlite3.Error) as exc:
                    work_results.put(f'Export deferred: {type(exc).__name__}. Original file and prior evidence preserved.')
                finally:
                    if worker_store: worker_store.close()
            threading.Thread(target=read_worker,daemon=True).start()
    def poll():
        nonlocal working
        try:
            message=work_results.get_nowait();working=False;status.set(message);show()
        except queue.Empty: pass
        root.after(150,poll)
    def choose():
        filename=filedialog.askopenfilename(title='Choose EmberSync SavedVariables',filetypes=[('Lua SavedVariables','*.lua')])
        if filename: selected.set(filename); scan()
    def export():
        filename=filedialog.asksaveasfilename(title='Export local evidence for review',defaultextension='.json',filetypes=[('JSON','*.json')])
        if not filename: return
        try:
            with open(filename,'x',encoding='utf-8') as f: json.dump(store.metrics(guild.get()),f,ensure_ascii=False,indent=2)
            status.set('Local review export created. This file contains guild names; share only with authorized members.')
        except FileExistsError: messagebox.showerror('File exists','Choose a new filename. EmberSync does not overwrite exports.')
        except (OSError,sqlite3.Error): messagebox.showerror('Export unavailable','Check folder access and retry. Prior local evidence is preserved.')
    ttk.Button(buttons,text='Choose SavedVariables',command=choose).pack(side='left')
    ttk.Button(buttons,text='Rescan',command=scan).pack(side='left',padx=8)
    ttk.Button(buttons,text='Export for review',command=export).pack(side='left')
    select=ttk.Combobox(buttons,textvariable=guild,values=['main','alts'],state='readonly',width=8); select.pack(side='right'); select.bind('<<ComboboxSelected>>',lambda _:show())
    def periodic(): scan(); root.after(30000,periodic)
    def close(): store.close(); root.destroy()
    root.protocol('WM_DELETE_WINDOW',close); root.bind('<FocusIn>',lambda event:scan() if event.widget==root else None); show(); root.after(150,poll); root.after(30000,periodic); root.mainloop()

if __name__=='__main__': main()
