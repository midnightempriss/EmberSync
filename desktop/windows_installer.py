"""User-level preview installer. Build only; do not run during packaging."""
import os
from pathlib import Path
import shutil
import sys
import tkinter as tk
from tkinter import messagebox,ttk

def install_payload(source,destination):
    destination=Path(destination)
    destination.mkdir(parents=True,exist_ok=True)
    target=destination/'EmberSync-Preview.exe'
    with open(source,'rb') as src,open(target,'xb') as dst:shutil.copyfileobj(src,dst)
    return target

def main():
    root=tk.Tk();root.title('EmberSync Preview Setup');root.geometry('640x340')
    frame=ttk.Frame(root,padding=24);frame.pack(fill='both',expand=True)
    ttk.Label(frame,text='EmberSync Preview',font=('Segoe UI',22,'bold')).pack(anchor='w')
    ttk.Label(frame,text='Install the offline roster evidence desktop preview for this Windows user.\nAutomatic site sync is not enabled. No addon files are installed.\nUnsigned local build; macOS/Linux installers are not included.',wraplength=570).pack(anchor='w',pady=20)
    destination=Path(os.environ['LOCALAPPDATA'])/'EmberSync-Preview-2.0.0'
    ttk.Label(frame,text=f'Install folder: {destination}',wraplength=570).pack(anchor='w')
    def install():
        try:
            source=Path(getattr(sys,'_MEIPASS',Path(__file__).parent))/'EmberSync-Preview.exe'
            target=install_payload(source,destination)
            messagebox.showinfo('Installed',f'Created {target}\nOpen this executable to use the preview. To uninstall, remove this installation folder. Local evidence remains in EmberSyncV2.');root.destroy()
        except FileExistsError:messagebox.showerror('Existing installation','An existing executable was found. Nothing was overwritten. Choose a separate preview version or remove it yourself.')
        except OSError:messagebox.showerror('Install unavailable','Installation could not complete. Check available disk space and access to your user application folder.')
    ttk.Button(frame,text='Install preview',command=install).pack(anchor='e',pady=20);root.mainloop()
if __name__=='__main__':main()
