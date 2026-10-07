import sys,unittest,tempfile,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'desktop'))
from pipeline import JournalStore
from sync import DeliveryWorker
from test_pipeline import roster,journal
class DeliveryTests(unittest.TestCase):
    def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.store=JournalStore(Path(self.tmp.name)/'queue.sqlite');self.store.ingest(journal(roster(1,['A'])))
    def tearDown(self):self.store.close();self.tmp.cleanup()
    def worker(self,transport,token='fixture-only',clock=lambda:100):return DeliveryWorker(self.store,'https://rainingembers.org/api/embersync/v2/ingest',lambda:token,transport,clock)
    def test_ack_retry_and_persistent_receipt(self):
        def transport(body,token):return 200,{'batchHash':json.loads(body)['batchHash'],'committed':True}
        w=self.worker(transport);self.assertEqual(w.drain_once(),'acknowledged');self.assertEqual(w.drain_once(),'idle')
        self.assertEqual(self.store.ingest(journal(roster(1,['A']))),0)
    def test_auth_pauses_and_invalid_quarantines(self):
        w=self.worker(lambda *_:(401,{}));self.assertEqual(w.drain_once(),'reauthorization_required');self.assertEqual(w.drain_once(),'paused')
        w=self.worker(lambda *_:(422,{}));self.assertEqual(w.drain_once(),'quarantined');self.assertEqual(w.drain_once(),'idle')
    def test_stale_ack_and_backoff_never_mark_committed(self):
        w=self.worker(lambda *_:(200,{'batchHash':'wrong','committed':True}));self.assertEqual(w.drain_once(),'retry_later');self.assertEqual(w.drain_once(),'idle')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM receipts').fetchone()[0],0)
    def test_missing_credential_makes_no_request(self):
        w=self.worker(lambda *_:self.fail('network call'),token=None);self.assertEqual(w.drain_once(),'pairing_required')
