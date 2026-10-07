import sys, unittest, json, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'desktop'))
from pipeline import parse_saved_variables, JournalStore, MAX_BYTES

class ParserTests(unittest.TestCase):
    def test_literal_journal_and_malicious_code(self):
        self.assertEqual(parse_saved_variables('EmberSyncJournalV2 = { ["version"] = 2, ["entries"] = { [1] = "{}", }, }')['entries'], ['{}'])
        for bad in ['EmberSyncJournalV2 = os.execute("calc")', 'EmberSyncJournalV2 = {}; print("oops")']:
            with self.assertRaises(ValueError): parse_saved_variables(bad)

    def test_limits_duplicate_keys_and_truncation(self):
        for bad in ['EmberSyncJournalV2={version=2,version=2,entries={}}','EmberSyncJournalV2={version=2,entries={[2]="{}"}}','EmberSyncJournalV2={','x'* (MAX_BYTES+1),'EmberSyncJournalV2={version=2,entries={x=function() end}}']:
            with self.assertRaises(ValueError): parse_saved_variables(bad)

def roster(seq,ids,coverage='complete',epoch='epoch-a',guild='main'):
    return dict(kind='roster',guild=guild,epoch=epoch,seq=seq,collectedAt=1700000000+seq,coverage=coverage,members=[dict(id=x,name=x+'-Dalaran',online=True) for x in ids])
def journal(*rows):return {'entries':[json.dumps(r) for r in rows]}

class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.path=Path(self.temp.name)/'queue.sqlite'; self.store=JournalStore(self.path)
    def tearDown(self):self.store.close();self.temp.cleanup()
    def test_baseline_partial_join_departure_rejoin_and_restart(self):
        self.store.ingest(journal(roster(1,['A','B'])))
        self.assertIsNone(self.store.metrics('main')['joins'])
        self.store.ingest(journal(roster(2,['A'],'partial'),roster(3,['A','B','C']),roster(4,['B','C']),roster(5,['A','B','C'])))
        m=self.store.metrics('main');self.assertEqual((m['joins'],m['departures'],m['net']),(2,1,1))
        self.store.close();self.store=JournalStore(self.path)
        self.assertEqual(self.store.ingest(journal(roster(5,['A','B','C']))),0)
        self.assertEqual(self.store.metrics('main')['members'],3)
    def test_empty_duplicate_identity_collision_and_privacy_rollback(self):
        self.store.ingest(journal(roster(1,['A'])))
        for bad in [roster(1,['B']),roster(2,[]),roster(2,['A','A']),{**roster(2,['A']),'notes':'private'},{**roster(2,['A']),'dropped':'bad'},{**roster(2,['A']),'build':{}}]:
            with self.assertRaises(ValueError):self.store.ingest(journal(roster(3,['A','B']),bad))
        self.assertEqual(self.store.metrics('main')['members'],1)
    def test_first_eviction_and_latest_partial_report_coverage(self):
        self.store.ingest(journal(roster(2,['A']),roster(3,['A','B'])))
        self.assertEqual(self.store.metrics('main')['coverage'],'coverage_gaps')
        self.store.ingest(journal(roster(4,['A'],'partial')))
        self.assertEqual(self.store.metrics('main')['coverage'],'last_good_roster_latest_coverage_partial')
    def test_guild_isolation_multiple_collectors_and_late_arrival(self):
        self.store.ingest(journal(roster(2,['A','B']),roster(1,['A']),roster(1,['X'],guild='alts')))
        self.assertEqual(self.store.metrics('main')['joins'],1);self.assertEqual(self.store.metrics('alts')['members'],1)
        self.store.ingest(journal(roster(3,['A','B'],epoch='other-collector')))
        self.assertIsNone(self.store.metrics('main')['joins'])
    def test_invites_separate_from_joins_windows_not_summed(self):
        log=dict(kind='log',guild='main',epoch='epoch-a',seq=1,collectedAt=1700000001,coverage='complete',rows=[{'type':'invite','player1':'Alice-Dalaran','player2':'Bob-Dalaran','age':[0,0,0,1]},{'type':'invite','player2':'Carol-Dalaran','age':[0,0,0,1]}])
        self.store.ingest(journal(log,{**log,'seq':2}))
        m=self.store.metrics('main');self.assertEqual(m['topInviters'],[('Alice-Dalaran',1)]);self.assertEqual(m['unknownInviters'],1);self.assertIsNone(m['joins'])

if __name__ == '__main__': unittest.main()
