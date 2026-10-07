import copy
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'desktop'))
from pipeline import JournalStore, validate_record

def provider(rows=None):
    return {'provider':'guild-roster-manager','version':'1.99422','coverage':'partial','rows':rows if rows is not None else [
        {'type':'join','subject':'Joined','invitedBy':'ActualInviter','calendarDate':[7,10,2026,15,30]},
        {'type':'rejoin','subject':'Returned'},{'type':'quit','subject':'Left'},{'type':'remove','subject':'Removed'}]}
def record(seq=1,**updates):
    return dict(kind='log',guild='main',epoch='provider-fixture',seq=seq,collectedAt=1700000000+seq,coverage='complete',
        rows=[{'type':'invite','player1':'NativeInviter','age':[0,0,0,1]}],providerLogs=[provider()],**updates)
def journal(*records): return {'entries':[json.dumps(r,ensure_ascii=False) for r in records]}

class ProviderPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=JournalStore(Path(self.temp.name)/'queue.sqlite')
    def tearDown(self):self.store.close();self.temp.cleanup()
    def test_provider_data_is_canonical_immutable_and_preserves_unknown_inviter(self):
        r=record();self.store.ingest(journal(r));raw=json.dumps(r,sort_keys=True,separators=(',',':'),ensure_ascii=False)
        digest,payload=self.store.db.execute('SELECT hash,payload FROM evidence').fetchone()
        self.assertEqual(payload,raw);self.assertEqual(digest,hashlib.sha256(raw.encode()).hexdigest())
        result=self.store.metrics('main',now=1700000200)
        self.assertEqual(result['topInviters'],[('NativeInviter',1)]);self.assertIsNone(result['joins'])
        self.assertEqual(result['evidence'][0]['providerLogs'][0]['rows'][0]['invitedBy'],'ActualInviter')
        self.assertNotIn('invitedBy',result['evidence'][0]['providerLogs'][0]['rows'][1]);self.assertNotIn('eventAt',result['evidence'][0]['providerLogs'][0]['rows'][0])
        reordered=dict(reversed(list(r.items())));self.assertEqual(self.store.ingest(journal(reordered)),0)
        window=result['providerWindows'][0];self.assertEqual(window['rows'],r['providerLogs'][0]['rows']);self.assertFalse(window['periodApplied'])
        self.assertEqual(window['sequence'],1);self.assertFalse(window['stale']);self.assertIn('no specified timezone',window['scope'])
    def test_invalid_optional_data_rolls_back_the_entire_journal(self):
        self.store.ingest(journal(record()))
        bad=record(3);bad['providerLogs'][0]['rows'][0]['officerNote']='SECRET-NOTE'
        with self.assertRaises(ValueError):self.store.ingest(journal(record(2),bad))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM evidence').fetchone()[0],1)
        self.assertFalse(any('SECRET-' in value[0] for value in self.store.db.execute('SELECT payload FROM evidence')))
    def test_provider_sequence_collision_preserves_original_evidence(self):
        self.store.ingest(journal(record()));collision=record();collision['providerLogs'][0]['rows'][0]['invitedBy']='DifferentInviter'
        with self.assertRaisesRegex(ValueError,'Sequence collision'):self.store.ingest(journal(collision))
        payload=self.store.db.execute('SELECT payload FROM evidence').fetchone()[0];self.assertIn('ActualInviter',payload);self.assertNotIn('DifferentInviter',payload)
    def test_native_log_failure_accepts_provider_history_without_native_zero_counts(self):
        for state in ['unavailable','unsupported']:
            with self.subTest(state=state):
                r=record();r.update(coverage=state,rows=[]);validate_record(r)
                self.store.ingest(journal(r));m=self.store.metrics('main',now=1700000200)
                self.assertIsNone(m['invitationWindow']);self.assertIsNone(m['unknownInviters']);self.assertIsNone(m['joins'])
                self.store.db.execute('DELETE FROM evidence');self.store.db.execute('DELETE FROM outbox');self.store.db.commit()
    def test_unsupported_status_accepts_version_only_with_empty_history(self):
        for coverage in ['unavailable','unsupported']:
            r=record();r['providerLogs']=[{'provider':'guild-roster-manager','version':'1.99999','coverage':coverage,'rows':[]}]
            self.assertEqual(validate_record(r),r)
        r=record();r['providerLogs'][0]['version']='1.99999'
        with self.assertRaises(ValueError):validate_record(r)
    def test_unknown_private_and_out_of_scope_fields_are_rejected(self):
        base=record()
        invalid=[
            {'provider':'unknown-addon'}, {'officerNote':'SECRET-NOTE'}, {'coverage':'complete'}, {'version':''},
            {'rows':[{'type':'invite','subject':'A'}]}, {'rows':[{'type':'quit','subject':'A','invitedBy':'Inviter'}]},
            {'rows':[{'type':'join','subject':'A','invitedBy':None}]}, {'rows':[{'type':'join','subject':'A','notes':'SECRET-NOTE'}]},
            {'rows':[{'type':'join','subject':'\ud800'}]}, {'rows':[{'type':'join','subject':'x'*201}]},
            {'coverage':'unavailable'}, {'rows':[{'type':'join','subject':'A'}]*201},
        ]
        for change in invalid:
            with self.subTest(change=repr(change)):
                r=copy.deepcopy(base);r['providerLogs'][0].update(change)
                with self.assertRaises(ValueError):validate_record(r)
        for providers in [{},[provider(),provider()]]:
            r=record();r['providerLogs']=providers
            with self.assertRaises(ValueError):validate_record(r)
        r=record();r['kind']='coverage';r.pop('rows')
        with self.assertRaises(ValueError):validate_record(r)
        r=record();r['coverage']='unavailable'
        with self.assertRaises(ValueError):validate_record(r)
    def test_calendar_is_real_gregorian_local_date_without_timezone_inference(self):
        for date in [[29,2,2024,23,59],[29,2,2000,0,0],[31,12,9999,23,59]]:
            r=record();r['providerLogs'][0]['rows'][0]['calendarDate']=date;self.assertEqual(validate_record(r),r)
        for date in [[29,2,2100,0,0],[31,4,2026,0,0],[1,1,1999,0,0],[1,1,10000,0,0],[1,1,2026,24,0],[1,1,2026,0,60],[True,1,2026,0,0],[1.0,1,2026,0,0],[1,1,2026,0],[1,1,2026,0,0,'UTC']]:
            with self.subTest(date=date):
                r=record();r['providerLogs'][0]['rows'][0]['calendarDate']=date
                with self.assertRaises(ValueError):validate_record(r)
    def test_provider_data_stays_in_its_original_guild_and_epoch(self):
        main=record();alt=record();alt.update(guild='alts',epoch='alt-fixture');alt['providerLogs'][0]['rows'][0]['subject']='AltOnly'
        reset=record();reset['epoch']='reset-fixture';reset['providerLogs'][0]['rows'][0]['subject']='ResetOnly'
        self.store.ingest(journal(main,alt,reset))
        selected=self.store.metrics('main','provider-fixture',now=1700000200)
        self.assertEqual(len(selected['evidence']),1);self.assertEqual(selected['evidence'][0]['providerLogs'][0]['rows'][0]['subject'],'Joined')
        ambiguous=self.store.metrics('main',now=1700000200);self.assertEqual(ambiguous['evidence'],[])
        self.assertEqual(ambiguous['providerWindows'],[]);self.assertEqual(selected['providerWindows'][0]['rows'][0]['subject'],'Joined')
    def test_provider_projection_uses_latest_window_and_never_recounts_history(self):
        first=record();second=record(2);second['providerLogs'][0]['rows']=[{'type':'join','subject':'Newest'}]
        self.store.ingest(journal(second,first));m=self.store.metrics('main',now=1700000200)
        self.assertEqual(m['providerWindows'][0]['rows'],[{'type':'join','subject':'Newest'}]);self.assertEqual(m['topInviters'],[('NativeInviter',1)])
        third=record(3);third['providerLogs']=[];self.store.ingest(journal(third));self.assertEqual(self.store.metrics('main',now=1700000200)['providerWindows'],[])
    def test_regressed_future_and_stale_provider_evidence_are_explicit(self):
        first=record();bad=record(2);bad['collectedAt']=1700000000;bad['providerLogs'][0]['rows'][0]['subject']='WrongClock'
        future=record(3);future['collectedAt']=1700005000;future['providerLogs'][0]['rows'][0]['subject']='Future'
        self.store.ingest(journal(future,bad,first));window=self.store.metrics('main',now=1700003601)['providerWindows'][0]
        self.assertEqual(window['rows'][0]['subject'],'Joined');self.assertTrue(window['stale']);self.assertEqual(window['collectedAt'],1700000001)

if __name__=='__main__':unittest.main()
