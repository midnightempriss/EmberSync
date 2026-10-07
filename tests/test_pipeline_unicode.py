import json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'desktop'))
from pipeline import lua_string,parse_saved_variables,validate_record
class WireParityTests(unittest.TestCase):
    def test_utf8_byte_escapes_and_numeric_array_order(self):
        self.assertEqual(lua_string(r'"Jos\195\169"'),'José')
        self.assertEqual(lua_string(r'"雪\240\159\148\165"'),'雪🔥')
        self.assertEqual(parse_saved_variables('EmberSyncJournalV2={version=2,entries={[2]="second",[1]="first"}}')['entries'],['first','second'])
        for bad in (r'"\255"',r'"\256"',r'"\195"'):
            with self.assertRaises(ValueError):lua_string(bad)
    def test_unicode_caps_empty_labels_and_unpaired_surrogates(self):
        base=dict(kind='coverage',guild='main',epoch='epoch',seq=1,collectedAt=1700000000,coverage='unavailable')
        for fields in ({'epoch':'\ud800'},{'epoch':'🔥'*101},{'build':''},{'build':'🔥'*41}):
            with self.assertRaises(ValueError):validate_record({**base,**fields})
        self.assertEqual(validate_record({**base,'epoch':'🔥'*100})['epoch'],'🔥'*100)
        for actor in ('','\udfff','🔥'*101):
            bad={**base,'kind':'log','rows':[{'type':'invite','player1':actor,'age':[0,0,0,1]}]}
            with self.assertRaises(ValueError):validate_record(bad)
if __name__=='__main__':unittest.main()
