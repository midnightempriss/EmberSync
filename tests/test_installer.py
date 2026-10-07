import sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
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

    def test_partial_copy_failure_leaves_no_final_file_and_retry_succeeds(self):
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'fixture.exe';source.write_bytes(b'complete fixture')
            destination=Path(folder)/'new-app'
            def failing_copy(src,dst):
                dst.write(src.read(3));raise OSError('fixture disk failure')
            with patch('windows_installer.shutil.copyfileobj',side_effect=failing_copy):
                with self.assertRaises(OSError):install_payload(source,destination)
            self.assertEqual(list(destination.iterdir()),[])
            target=install_payload(source,destination)
            self.assertEqual(target.read_bytes(),b'complete fixture')

    def test_destination_created_during_copy_never_overwrites_it(self):
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'fixture.exe';source.write_bytes(b'new fixture')
            destination=Path(folder)/'new-app';target=destination/'EmberSync-Preview.exe'
            def racing_copy(src,dst):
                dst.write(src.read());target.write_bytes(b'existing fixture')
            with patch('windows_installer.shutil.copyfileobj',side_effect=racing_copy):
                with self.assertRaises(FileExistsError):install_payload(source,destination)
            self.assertEqual(target.read_bytes(),b'existing fixture')
            self.assertEqual(list(destination.iterdir()),[target])
