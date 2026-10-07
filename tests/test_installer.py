import sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'desktop'))
from windows_installer import install_payload
class InstallerTests(unittest.TestCase):
    def test_install_to_temporary_fixture_never_overwrites(self):
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'fixture.exe';source.write_bytes(b'fixture payload')
            target=install_payload(source,Path(folder)/'new-app')
            self.assertEqual(target.read_bytes(),b'fixture payload')
            source.write_bytes(b'changed')
            with self.assertRaises(FileExistsError):install_payload(source,target.parent)
            self.assertEqual(target.read_bytes(),b'fixture payload')
