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
    def metrics(self,guild='main',epoch=None,**options):
        return self.store.metrics(guild,epoch,now=options.pop('now',1700000100),**options)
    def test_baseline_partial_join_departure_rejoin_and_restart(self):
        self.store.ingest(journal(roster(1,['A','B'])))
        self.assertIsNone(self.metrics()['joins'])
        self.store.ingest(journal(roster(2,['A'],'partial'),roster(3,['A','B','C']),roster(4,['B','C']),roster(5,['A','B','C'])))
        m=self.metrics();self.assertEqual((m['joins'],m['departures'],m['net']),(2,1,1))
        self.store.close();self.store=JournalStore(self.path)
        self.assertEqual(self.store.ingest(journal(roster(5,['A','B','C']))),0)
        self.assertEqual(self.metrics()['members'],3)
    def test_empty_duplicate_identity_collision_and_privacy_rollback(self):
        self.store.ingest(journal(roster(1,['A'])))
        for bad in [roster(1,['B']),roster(2,[]),roster(2,['A','A']),{**roster(2,['A']),'notes':'private'},{**roster(2,['A']),'dropped':'bad'},{**roster(2,['A']),'build':{}}]:
            with self.assertRaises(ValueError):self.store.ingest(journal(roster(3,['A','B']),bad))
        self.assertEqual(self.metrics()['members'],1)
    def test_first_eviction_and_latest_partial_report_coverage(self):
        self.store.ingest(journal(roster(2,['A']),roster(3,['A','B'])))
        self.assertEqual(self.metrics()['coverage'],'unobserved_sequences')
        self.store.ingest(journal(roster(4,['A'],'partial')))
        self.assertEqual(self.metrics()['coverage'],'last_good_roster_latest_coverage_partial')
    def test_guild_isolation_multiple_collectors_and_late_arrival(self):
        self.store.ingest(journal(roster(2,['A','B']),roster(1,['A']),roster(1,['X'],guild='alts')))
        self.assertEqual(self.metrics()['joins'],1);self.assertEqual(self.metrics('alts')['members'],1)
        self.store.ingest(journal(roster(3,['A','B'],epoch='other-collector')))
        self.assertIsNone(self.metrics()['joins'])
    def test_invites_separate_from_joins_windows_not_summed(self):
        log=dict(kind='log',guild='main',epoch='epoch-a',seq=1,collectedAt=1700000001,coverage='complete',rows=[{'type':'invite','player1':'Alice-Dalaran','player2':'Bob-Dalaran','age':[0,0,0,1]},{'type':'invite','player2':'Carol-Dalaran','age':[0,0,0,1]}])
        self.store.ingest(journal(log,{**log,'seq':2}))
        m=self.metrics();self.assertEqual(m['topInviters'],[('Alice-Dalaran',1)]);self.assertEqual(m['unknownInviters'],1);self.assertIsNone(m['joins'])
    def test_epoch_selection_never_combines_collectors_or_resets(self):
        self.store.ingest(journal(roster(1,['A']),roster(2,['A','B']),roster(1,['X','Y','Z'],epoch='epoch-b'),roster(1,['Alt'],epoch='epoch-alt',guild='alts')))
        self.assertEqual(self.store.epochs('main'),['epoch-a','epoch-b'])
        self.assertEqual(self.store.epochs('alts'),['epoch-alt']);self.assertEqual(self.store.epochs('missing'),[])
        ambiguous=self.metrics();self.assertEqual(ambiguous['coverage'],'ambiguous_collectors_or_reset')
        self.assertIsNone(ambiguous['members']);self.assertIsNone(ambiguous['joins']);self.assertEqual(ambiguous['evidence'],[])
        selected=self.metrics(epoch='epoch-a');self.assertEqual((selected['members'],selected['joins']),(2,1))
        self.assertEqual({r['epoch'] for r in selected['evidence']},{'epoch-a'})
        other=self.metrics(epoch='epoch-b');self.assertEqual(other['members'],3);self.assertIsNone(other['joins'])
        unavailable=self.metrics(epoch='unknown');self.assertEqual(unavailable['coverage'],'unavailable');self.assertEqual(unavailable['evidence'],[])
        with self.assertRaises(ValueError): self.metrics(epoch=[])
    def test_clock_regression_and_future_rows_do_not_replace_current_members(self):
        first={**roster(1,['A']),'collectedAt':1700000100}
        regressed={**roster(2,['Wrong']),'collectedAt':1700000099}
        future={**roster(3,['A','B']),'collectedAt':1700000102}
        self.store.ingest(journal(future,regressed,first))
        m=self.metrics(now=1700000101)
        self.assertEqual(m['members'],1);self.assertIsNone(m['joins']);self.assertEqual(m['collectedAt'],1700000100)
        self.assertEqual({g['type'] for g in m['gaps']},{'clock_regression','future_observation'})
        self.assertEqual(len(m['evidence']),3)
        later=self.metrics(now=1700000102)
        self.assertEqual((later['members'],later['joins'],later['departures']),(2,1,0))
    def test_same_second_changes_are_indeterminate_and_not_counted(self):
        self.store.ingest(journal({**roster(1,['A']),'collectedAt':1700000100},{**roster(2,['B']),'collectedAt':1700000100}))
        m=self.metrics(now=1700000101)
        self.assertEqual(m['members'],1);self.assertIsNone(m['joins']);self.assertIsNone(m['departures'])
        self.assertEqual(m['intervalsObserved'],0);self.assertFalse(m['intervals'][0]['included'])
        self.assertEqual(m['intervals'][0]['exclusion'],'indeterminate_collection_interval')
        self.store.ingest(journal({**roster(3,['B','C']),'collectedAt':1700000101}))
        later=self.metrics(now=1700000102)
        self.assertEqual((later['joins'],later['departures'],later['net']),(1,0,1));self.assertEqual(later['intervalsObserved'],1)
    def test_latest_log_coverage_and_freshness_remain_explicit(self):
        log=dict(kind='log',guild='main',epoch='epoch-a',seq=1,collectedAt=1700000001,coverage='complete',rows=[{'type':'invite','player1':'Alice-Dalaran','player2':'Bob-Dalaran','age':[0,0,0,1]},{'type':'invite','player1':' ','age':[0,0,0,1]}])
        self.store.ingest(journal(log))
        for seq,status in enumerate(['partial','unavailable','unsupported'],2):
            with self.subTest(status=status):
                self.store.ingest(journal({**log,'seq':seq,'collectedAt':1700000000+seq,'coverage':status,'rows':[{'type':'invite','player1':'Other-Dalaran','age':[0,0,0,0]}]}))
                m=self.metrics();self.assertEqual(m['inviterCoverage'],'last_complete_log_latest_'+status)
                self.assertEqual(m['topInviters'],[('Alice-Dalaran',1)]);self.assertEqual(m['unknownInviters'],1)
                self.assertEqual(m['invitationWindow']['sequence'],1);self.assertEqual(m['invitationWindow']['latestCoverage'],status)
                self.assertFalse(m['invitationWindow']['stale']);self.assertFalse(m['invitationWindow']['periodApplied'])
        marker=dict(kind='coverage',guild='main',epoch='epoch-a',seq=5,collectedAt=1700000005,coverage='unavailable')
        self.store.ingest(journal(marker,{**roster(6,['A']),'collectedAt':1700005000}))
        m=self.metrics(now=1700005001)
        self.assertFalse(m['rosterStale']);self.assertTrue(m['invitationWindow']['stale'])
        self.assertEqual(m['inviterCoverage'],'last_complete_log_latest_unavailable')
        self.assertEqual(m['invitationWindow']['latestObservationAt'],1700000005)
    def test_clock_regressed_log_does_not_replace_a_newer_window(self):
        log=dict(kind='log',guild='main',epoch='epoch-a',seq=1,collectedAt=1700000010,coverage='complete',rows=[{'type':'invite','player1':'Alice','age':[0,0,0,1]}])
        self.store.ingest(journal(log,{**log,'seq':2,'collectedAt':1700000009,'rows':[{'type':'invite','player1':'Wrong','age':[0,0,0,0]}]}))
        m=self.metrics();self.assertEqual(m['topInviters'],[('Alice',1)])
        self.assertEqual(m['invitationWindow']['sequence'],1);self.assertIn('clock_regression',{g['type'] for g in m['gaps']})
    def test_roster_freshness_uses_real_time_by_default_and_exact_threshold(self):
        from unittest.mock import patch
        self.store.ingest(journal(roster(1,['A'])))
        self.assertFalse(self.metrics(now=1700003600)['rosterStale'])
        with patch('pipeline.time.time',return_value=1700003601): m=self.store.metrics('main')
        self.assertTrue(m['rosterStale']);self.assertEqual(m['coverage'],'last_good_roster_stale');self.assertEqual(m['members'],1)
        self.assertEqual(m['staleAt'],1700003601)
    def test_shared_guild_sequences_are_not_definite_data_loss(self):
        self.store.ingest(journal(roster(1,['A']),roster(2,['Alt'],guild='alts'),roster(3,['A','B'])))
        m=self.metrics();self.assertEqual(m['joins'],1);self.assertFalse(m['hasDefiniteLoss']);self.assertFalse(m['hasGaps'])
        self.assertEqual(m['sequenceCoverage'],'shared_journal_other_guild_records')
        self.assertEqual(m['sequenceGaps'],[{'fromSequence':2,'toSequence':2,'observedOtherGuildRecords':1,'unobservedSequences':0}])
    def test_unobserved_sequences_and_explicit_drops_are_distinct(self):
        self.store.ingest(journal(roster(2,['A']),roster(3,['A','B'])))
        m=self.metrics();self.assertEqual(m['coverage'],'unobserved_sequences');self.assertFalse(m['hasDefiniteLoss'])
        self.assertEqual(m['sequenceGaps'][0]['unobservedSequences'],1)
        self.store.ingest(journal({**roster(4,['A','B']),'dropped':5}))
        dropped=self.metrics();self.assertTrue(dropped['hasDefiniteLoss']);self.assertEqual(dropped['droppedEntries'],5)
        self.assertEqual(dropped['coverage'],'coverage_gaps')
        self.assertEqual(next(g for g in dropped['gaps'] if g['type']=='dropped_entries')['scope'],'shared_journal')
    def test_empty_complete_log_is_zero_but_partial_only_is_unavailable(self):
        log=dict(kind='log',guild='main',epoch='epoch-a',seq=1,collectedAt=1700000001,coverage='partial',rows=[])
        self.store.ingest(journal(log))
        m=self.metrics();self.assertIsNone(m['unknownInviters']);self.assertIsNone(m['invitationWindow']);self.assertEqual(m['latestLogCoverage'],'partial')
        self.store.ingest(journal({**log,'seq':2,'collectedAt':1700000002,'coverage':'complete'}))
        m=self.metrics();self.assertEqual(m['unknownInviters'],0);self.assertEqual(m['invitationWindow']['issuedInvitations'],0)

if __name__ == '__main__': unittest.main()
