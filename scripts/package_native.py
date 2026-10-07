"""Native CI packaging only. No release publish, device keys, or installer execution."""
import hashlib, json, os, platform, plistlib, shutil, subprocess, sys
from pathlib import Path
OUT=Path('releases/native').resolve()
system=platform.system();arch=platform.machine()
source_qa=json.loads(Path('.build/source-gui-qa.json').read_text('utf-8'))
qa_sources={'desktop/app.py','desktop/runtime.py','desktop/device.py','desktop/pairing.py','desktop/sync.py','desktop/pipeline.py','scripts/desktop_ui_qa.py'}
if (source_qa.get('passed') is not True or source_qa.get('fixtureOnly') is not True or
    type(source_qa.get('checks')) is not int or source_qa['checks']<16 or
    source_qa.get('sourceCommit')!=os.environ.get('GITHUB_SHA') or
    not isinstance(source_qa.get('sourceHashes'),dict) or set(source_qa['sourceHashes'])!=qa_sources or
    any(hashlib.sha256(Path(name).read_bytes()).hexdigest()!=digest for name,digest in source_qa['sourceHashes'].items())):
    raise RuntimeError('Current source GUI fixture QA is required before native packaging')
def run(*args):subprocess.run(args,check=True)
if system=='Windows':
    run(str(OUT/'EmberSync-Preview.exe'),'--self-test')
    run(str(OUT/'EmberSync-Preview.exe'),'--ui-smoke-test')
elif system=='Darwin':
    app=OUT/'EmberSync-Preview.app'
    plist=app/'Contents/Info.plist';info=plistlib.loads(plist.read_bytes());info['CFBundleShortVersionString']='2.0.0';info['CFBundleVersion']='2.0.3';plist.write_bytes(plistlib.dumps(info))
    assert info['CFBundleIdentifier']=='org.rainingembers.EmberSyncPreview'
    run('codesign','--force','--deep','--sign','-',str(app));run('codesign','--verify','--deep',str(app))
    run('file',str(app/'Contents/MacOS/EmberSync-Preview'))
    run(str(app/'Contents/MacOS/EmberSync-Preview'),'--self-test')
    run(str(app/'Contents/MacOS/EmberSync-Preview'),'--ui-smoke-test')
    stage=Path('.build/dmg-stage');stage.mkdir(parents=True,exist_ok=False)
    shutil.copytree(app,stage/app.name,symlinks=True)
    (stage/'Applications').symlink_to('/Applications',target_is_directory=True)
    run('hdiutil','create','-volname','EmberSync Preview','-srcfolder',str(stage),'-format','UDZO',str(OUT/f'EmberSync-Preview-macos-{arch}.dmg'))
    run('hdiutil','verify',str(OUT/f'EmberSync-Preview-macos-{arch}.dmg'))
elif system=='Linux':
    binary=OUT/'EmberSync-Preview';run(str(binary),'--self-test')
    run('file',str(binary));run('xvfb-run','-a',str(binary),'--ui-smoke-test')
    stage=Path('.build/deb-stage');stage.mkdir(parents=True,exist_ok=False)
    for folder in ['DEBIAN','opt/embersync-preview','usr/bin','usr/share/applications']:(stage/folder).mkdir(parents=True,exist_ok=True)
    shutil.copy2(binary,stage/'opt/embersync-preview/EmberSync-Preview')
    (stage/'opt/embersync-preview/EmberSync-Preview').chmod(0o755)
    (stage/'usr/bin/embersync-preview').symlink_to('/opt/embersync-preview/EmberSync-Preview')
    (stage/'usr/share/applications/embersync-preview.desktop').write_text('[Desktop Entry]\nType=Application\nName=EmberSync Preview\nComment=Browser-approved guild roster evidence desktop\nExec=/opt/embersync-preview/EmberSync-Preview\nTerminal=false\nCategories=Utility;\n',encoding='utf-8')
    debarch={'x86_64':'amd64','aarch64':'arm64'}[arch]
    (stage/'DEBIAN/control').write_text(f'Package: embersync-preview\nVersion: 2.0.0~preview.3\nSection: utils\nPriority: optional\nArchitecture: {debarch}\nMaintainer: EmberSync Project\nDepends: libc6 (>= 2.39), libx11-6, libxext6, libxrender1, libxft2, libfontconfig1\nDescription: Raining Embers roster evidence desktop\n Browser approval and a native-vault device credential are required for upload.\n Local review works offline. Uploads require an available Secret Service vault.\n',encoding='utf-8')
    run('dpkg-deb','--root-owner-group','--build',str(stage),str(OUT/f'EmberSync-Preview-linux-{debarch}.deb'))
    run('dpkg-deb','--info',str(OUT/f'EmberSync-Preview-linux-{debarch}.deb'))
    run('dpkg-deb','--contents',str(OUT/f'EmberSync-Preview-linux-{debarch}.deb'))
else:raise RuntimeError('Unsupported native platform')
files=[p for p in OUT.iterdir() if p.is_file()]
manifest={'version':'2.0.0-preview.3','platform':system,'osVersion':platform.platform(),'architecture':arch,'pythonVersion':sys.version,'glibc':platform.libc_ver(),'sourceCommit':os.environ.get('GITHUB_SHA'),'sync':'pc_scoped_browser_approval_required','signing':'ad_hoc_unnotarized' if system=='Darwin' else 'unsigned','nativeSelfTest':'passed','tkCreationSmokeTest':'passed','sourceGuiFixtureQA':'passed','sourceGuiFixtureChecks':source_qa['checks'],'installerExecuted':False,'guiInteractionTested':False,'livePairingTested':False,'liveUploadTested':False,'files':{p.name:{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'size':p.stat().st_size} for p in files}}
(OUT/'NATIVE-BUILD.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
# The local executor transfers at most32MiB per artifact. Deliver independently
# hashed20MiB chunks, reassembled byte-for-byte before any installer is used.
package=next(p for p in files if p.name.endswith({'Windows':'-Setup.exe','Darwin':'.dmg','Linux':'.deb'}[system]))
parts=[]
with package.open('rb') as source:
    for index in range(1,5):
        data=source.read(20*1024*1024)
        if not data:break
        destination=Path(f'releases/delivery/part{index}');destination.mkdir(parents=True,exist_ok=False)
        name=package.name+f'.part{index}';(destination/name).write_bytes(data)
        parts.append({'name':name,'sha256':hashlib.sha256(data).hexdigest(),'size':len(data)})
    if source.read(1):raise RuntimeError('Native package exceeds bounded chunk delivery')
delivery={'nativeBuild':manifest,'package':package.name,'sha256':hashlib.sha256(package.read_bytes()).hexdigest(),'size':package.stat().st_size,'parts':parts}
Path('releases/delivery/part1/DELIVERY.json').write_text(json.dumps(delivery,indent=2)+'\n',encoding='utf-8')
