"""User-level pairing-ready installer. Build only; never run during packaging."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
import tkinter as tk
from tkinter import messagebox,ttk

def install_payload(source,destination):
    destination=Path(destination)
    destination.mkdir(parents=True,exist_ok=True)
    target=destination/'EmberSync-Preview.exe'
    if target.exists():raise FileExistsError('Existing installation')
    staging=None
    try:
        # Complete and close the staging file before creating the final name.
        # A hard link on the same user volume atomically refuses collisions on
        # Windows and POSIX, unlike rename() which overwrites on POSIX.
        descriptor,name=tempfile.mkstemp(prefix='.EmberSync-install-',suffix='.tmp',dir=destination)
        staging=Path(name)
        with os.fdopen(descriptor,'wb') as dst,open(source,'rb') as src:
            shutil.copyfileobj(src,dst);dst.flush();os.fsync(dst.fileno())
        os.link(staging,target)
    finally:
        if staging is not None:staging.unlink(missing_ok=True)
    return target

def main():
    root=tk.Tk();root.title('EmberSync Preview Setup');root.geometry('640x340')
    frame=ttk.Frame(root,padding=24);frame.pack(fill='both',expand=True)
    ttk.Label(frame,text='EmberSync Preview',font=('Segoe UI',22,'bold')).pack(anchor='w')
    ttk.Label(frame,text='Install the roster evidence desktop for this Windows user.\nWebsite upload requires approval from your existing member account\nand a supported operating system credential vault.\nLocal review works offline. Unsigned build. No addon files are installed.',wraplength=570).pack(anchor='w',pady=20)
    destination=Path(os.environ['LOCALAPPDATA'])/'EmberSync-Preview-2.0.0-preview.2'
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
