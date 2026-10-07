import sys, unittest, json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'.build-tools'))
from lupa import LuaRuntime

class AddonTests(unittest.TestCase):
    def make(self, setup=None):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute('''SlashCmdList={}; print=function() end; handler=nil; C_Timer={NewTicker=function() end}; C_GuildInfo={GuildRoster=function() end}; QueryGuildEventLog=function() end
        CreateFrame=function() return {RegisterEvent=function() end,SetScript=function(_,_,f) handler=f end} end
        GetBuildInfo=function() return "12.1.0","69587",nil,120100 end
        GetServerTime=function() return 1700000000 end
        GetGuildInfo=function() return "Raining Embers",nil,nil,"Dalaran" end
        GetNumGuildMembers=function() return 2 end
        issecretvalue=function(v) return type(v)=="table" and v.secret==true end
        GetGuildRosterInfo=function(i) return "Member"..i.."-Dalaran",nil,nil,nil,nil,nil,nil,nil,true,nil,nil,nil,nil,nil,nil,nil,"Player-"..i end
        GetNumGuildEvents=function() return 1 end
        GetGuildEventInfo=function() return "invite","Alice-Dalaran","Bob-Dalaran",nil,0,0,0,1 end
        ''')
        if setup: lua.execute(setup)
        addon_path = Path(__file__).resolve().parents[1]/'addon/EmberSync'
        for filename in ('Providers.lua', 'EmberSync.lua'):
            lua.execute((addon_path/filename).read_text())
        lua.execute('handler(nil,"ADDON_LOADED","EmberSync")');return lua
    def records(self, lua):
        entries=lua.globals().EmberSyncJournalV2.entries
        return [json.loads(entries[i]) for i in range(1,len(entries)+1)]
    def test_consent_complete_and_log_serialization(self):
        lua=self.make();lua.execute('handler(nil,"GUILD_ROSTER_UPDATE")');self.assertEqual(len(lua.globals().EmberSyncJournalV2.entries),0)
        lua.execute('SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_ROSTER_UPDATE");handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        entries=lua.globals().EmberSyncJournalV2.entries
        r=json.loads(entries[1]);self.assertEqual(r['coverage'],'complete');self.assertEqual(len(r['members']),2)
        log=json.loads(entries[2]);self.assertEqual(log['rows'][0]['player1'],'Alice-Dalaran')
    def test_secret_partial_empty_unsupported_wrong_guild_and_bound(self):
        lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");GetGuildRosterInfo=function() return {secret=true} end;handler(nil,"GUILD_ROSTER_UPDATE")')
        self.assertEqual(json.loads(lua.globals().EmberSyncJournalV2.entries[1])['coverage'],'partial')
        lua.execute('GetNumGuildMembers=function() return 0 end;handler(nil,"GUILD_ROSTER_UPDATE")')
        self.assertEqual(json.loads(lua.globals().EmberSyncJournalV2.entries[2])['coverage'],'unavailable')
        lua.execute('for i=1,600 do handler(nil,"GUILD_ROSTER_UPDATE") end');self.assertEqual(len(lua.globals().EmberSyncJournalV2.entries),512)
        lua.execute('GetGuildInfo=function() return "Other",nil,nil,"Dalaran" end;handler(nil,"GUILD_ROSTER_UPDATE")');self.assertEqual(len(lua.globals().EmberSyncJournalV2.entries),512)
        lua=self.make();lua.execute('GetBuildInfo=function() return "12.0.7","1",nil,120007 end;handler(nil,"ADDON_LOADED","EmberSync");SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_ROSTER_UPDATE")');self.assertEqual(len(lua.globals().EmberSyncJournalV2.entries),0)
    def test_guid_unavailable_is_partial_and_serialized_retention_fits_reader(self):
        lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");GetGuildRosterInfo=function(i) return "Member"..i.."-Dalaran",nil,nil,nil,nil,nil,nil,nil,true,nil,nil,nil,nil,nil,nil,nil,{secret=true} end;handler(nil,"GUILD_ROSTER_UPDATE")')
        self.assertEqual(json.loads(lua.globals().EmberSyncJournalV2.entries[1])['coverage'],'partial')
        lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");GetNumGuildMembers=function() return 2000 end;for i=1,30 do handler(nil,"GUILD_ROSTER_UPDATE") end')
        rows=[lua.globals().EmberSyncJournalV2.entries[i] for i in range(1,len(lua.globals().EmberSyncJournalV2.entries)+1)]
        serialized='EmberSyncJournalV2={version=2,entries={'+','.join(json.dumps(r,ensure_ascii=False) for r in rows)+'}}'
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'desktop'))
        from pipeline import parse_saved_variables,MAX_BYTES
        self.assertLess(len(serialized.encode()),MAX_BYTES)
        parsed=parse_saved_variables(serialized);self.assertEqual(len(parsed['entries']),len(rows));self.assertGreater(json.loads(rows[-1])['dropped'],0)
    def test_invalid_counts_and_ages_never_establish_complete_coverage(self):
        for api,event,values in [
            ('GetNumGuildMembers','GUILD_ROSTER_UPDATE',['0.5','2001','{secret=true}','0/0','math.huge']),
            ('GetNumGuildEvents','GUILD_EVENT_LOG_UPDATE',['0.5','201','{secret=true}','0/0','math.huge']),
        ]:
            for value in values:
                with self.subTest(api=api,value=value):
                    lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");'+api+'=function() return '+value+' end;handler(nil,"'+event+'")')
                    self.assertEqual(self.records(lua)[-1]['coverage'],'unavailable')
        for age in ['0.5','10001','{secret=true}']:
            with self.subTest(age=age):
                lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");GetGuildEventInfo=function() return "invite","Alice","Bob",nil,0,0,0,'+age+' end;handler(nil,"GUILD_EVENT_LOG_UPDATE")')
                record=self.records(lua)[-1]
                self.assertEqual(record['coverage'],'partial');self.assertEqual(record['rows'],[])
    def test_api_failures_are_explicit_and_good_rows_survive(self):
        for api,event in [('GetNumGuildMembers','GUILD_ROSTER_UPDATE'),('GetNumGuildEvents','GUILD_EVENT_LOG_UPDATE')]:
            with self.subTest(api=api):
                lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");'+api+'=function() error("restricted") end;handler(nil,"'+event+'")')
                self.assertEqual(self.records(lua)[-1]['coverage'],'unavailable')
        lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");local original=GetGuildRosterInfo;GetGuildRosterInfo=function(i) if i==2 then error("restricted") end return original(i) end;handler(nil,"GUILD_ROSTER_UPDATE")')
        record=self.records(lua)[-1]
        self.assertEqual(record['coverage'],'partial');self.assertEqual([m['id'] for m in record['members']],['Player-1'])
        lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");GetNumGuildEvents=function() return 2 end;local original=GetGuildEventInfo;GetGuildEventInfo=function(i) if i==2 then error("restricted") end return original(i) end;handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        record=self.records(lua)[-1]
        self.assertEqual(record['coverage'],'partial');self.assertEqual(len(record['rows']),1)
    def test_missing_api_does_not_prevent_independent_requests(self):
        lua=self.make('rosterRequests=0;C_GuildInfo.GuildRoster=function() rosterRequests=rosterRequests+1 end;QueryGuildEventLog=nil')
        lua.execute('SlashCmdList.EMBERSYNC("start")')
        self.assertEqual(lua.globals().rosterRequests,1);self.assertEqual(self.records(lua)[-1]['coverage'],'unsupported')
        lua.execute('GetGuildRosterInfo=nil;handler(nil,"GUILD_ROSTER_UPDATE")')
        self.assertEqual(self.records(lua)[-1]['coverage'],'unsupported')
        lua=self.make('QueryGuildEventLog=function() error("restricted") end')
        lua.execute('SlashCmdList.EMBERSYNC("start")')
        self.assertEqual(self.records(lua)[-1]['coverage'],'unavailable')
    def test_counts_changing_during_reads_are_partial(self):
        for api,event,first,last in [('GetNumGuildMembers','GUILD_ROSTER_UPDATE',2,1),('GetNumGuildEvents','GUILD_EVENT_LOG_UPDATE',1,2)]:
            with self.subTest(api=api):
                lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");local calls=0;'+api+'=function() calls=calls+1;if calls==1 then return '+str(first)+' end return '+str(last)+' end;handler(nil,"'+event+'")')
                self.assertEqual(self.records(lua)[-1]['coverage'],'partial')
    def test_same_count_changing_contents_are_partial(self):
        lua=self.make();lua.execute('''SlashCmdList.EMBERSYNC("start")
        local calls=0;GetGuildRosterInfo=function(i)
            calls=calls+1;local id=i;if calls>=2 then id=i==1 and 4 or 3 end
            return "Member"..id.."-Dalaran",nil,nil,nil,nil,nil,nil,nil,true,nil,nil,nil,nil,nil,nil,nil,"Player-"..id
        end
        handler(nil,"GUILD_ROSTER_UPDATE")''')
        record=self.records(lua)[-1]
        self.assertEqual(record['coverage'],'partial')
        self.assertEqual([m['id'] for m in record['members']],['Player-1','Player-3'])
        lua=self.make();lua.execute('''SlashCmdList.EMBERSYNC("start")
        local calls=0;GetGuildEventInfo=function()
            calls=calls+1;return "invite",calls==1 and "Alice-Dalaran" or "Carol-Dalaran","Bob-Dalaran",nil,0,0,0,1
        end
        handler(nil,"GUILD_EVENT_LOG_UPDATE")''')
        record=self.records(lua)[-1]
        self.assertEqual(record['coverage'],'partial');self.assertEqual(record['rows'][0]['player1'],'Alice-Dalaran')
    def test_identity_and_actor_positions_are_preserved_without_inference(self):
        lua=self.make();lua.execute('''SlashCmdList.EMBERSYNC("start")
        GetGuildRosterInfo=function(i) return "Member"..i.."-OtherRealm","Rank",5,80,"Class","Area","public","officer",false,7,"ClassFile",10,11,false,false,8,"Player-GUID-"..i end
        handler(nil,"GUILD_ROSTER_UPDATE")
        GetNumGuildEvents=function() return 2 end
        GetGuildEventInfo=function() return "invite",{secret=true},"Target-OtherRealm","Rank",1,2,3,4 end
        handler(nil,"GUILD_EVENT_LOG_UPDATE")''')
        roster,log=self.records(lua)
        self.assertEqual(roster['coverage'],'complete')
        self.assertEqual(roster['members'][0],{'id':'Player-GUID-1','name':'Member1-OtherRealm','online':False})
        self.assertEqual(log['coverage'],'complete');self.assertEqual(len(log['rows']),2)
        self.assertNotIn('player1',log['rows'][0]);self.assertEqual(log['rows'][0]['player2'],'Target-OtherRealm');self.assertEqual(log['rows'][0]['age'],[1,2,3,4])
        self.assertEqual(log['rows'][0],log['rows'][1])
        lua.execute('GetGuildRosterInfo=function() return "",nil,nil,nil,nil,nil,nil,nil,true,nil,nil,nil,nil,nil,nil,nil,"" end;handler(nil,"GUILD_ROSTER_UPDATE")')
        self.assertEqual(self.records(lua)[-1]['coverage'],'partial')
    def test_canonical_guild_realm_and_scope_change_fail_closed(self):
        for realm in ['nil','{secret=true}','"OtherRealm"','"Da la ran"']:
            with self.subTest(realm=realm):
                lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");GetRealmName=function() return "Dalaran" end;GetGuildInfo=function() return "Raining Embers",nil,nil,'+realm+' end;handler(nil,"GUILD_ROSTER_UPDATE")')
                self.assertEqual(self.records(lua),[])
        for realm in ['Wyrmrest Accord','WyrmrestAccord']:
            with self.subTest(realm=realm):
                lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");GetGuildInfo=function() return "Raining Embers Alts",nil,nil,"'+realm+'" end;handler(nil,"GUILD_ROSTER_UPDATE")')
                self.assertEqual(self.records(lua)[-1]['guild'],'alts')
        for event in ['GUILD_ROSTER_UPDATE','GUILD_EVENT_LOG_UPDATE']:
            with self.subTest(event=event):
                lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");local calls=0;GetGuildInfo=function() calls=calls+1;if calls==1 then return "Raining Embers",nil,nil,"Dalaran" end return "Raining Embers Alts",nil,nil,"WyrmrestAccord" end;handler(nil,"'+event+'")')
                self.assertEqual(self.records(lua),[])
    def test_secret_detector_and_server_time_fail_closed(self):
        for detector in ['nil','function() error("restricted") end']:
            with self.subTest(detector=detector):
                lua=self.make();lua.execute('issecretvalue='+detector+';handler(nil,"ADDON_LOADED","EmberSync");SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_ROSTER_UPDATE")')
                self.assertEqual(self.records(lua),[])
        for timestamp in ['{secret=true}','0','0.5']:
            with self.subTest(timestamp=timestamp):
                lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");GetServerTime=function() return '+timestamp+' end;handler(nil,"GUILD_ROSTER_UPDATE")')
                self.assertEqual(self.records(lua),[]);self.assertEqual(lua.globals().EmberSyncJournalV2.seq,0)
        lua=self.make('GetServerTime=function() error("restricted") end')
        lua.execute('SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_ROSTER_UPDATE")')
        self.assertEqual(self.records(lua),[])
    def test_malformed_saved_journal_is_preserved_and_paused(self):
        for field in ['seq="invalid"','seq=0.5','epoch=""','dropped=-1','entries={[2]="original"}','entries={false}']:
            with self.subTest(field=field):
                lua=self.make('EmberSyncJournalV2={version=2,consent=true,epoch="original-epoch",seq=0,dropped=0,entries={}};'+ 'EmberSyncJournalV2.'+field)
                lua.execute('SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_ROSTER_UPDATE")')
                self.assertTrue(lua.globals().EmberSyncJournalV2.consent)
                self.assertEqual(lua.globals().EmberSyncJournalV2.version,2)
                entries=lua.globals().EmberSyncJournalV2.entries
                if field=='entries={[2]="original"}': self.assertEqual(entries[2],'original')
                elif field=='entries={false}': self.assertFalse(entries[1])
                else: self.assertEqual(len(entries),0)
    def test_retention_accounts_for_drop_counter_digit_growth(self):
        lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_ROSTER_UPDATE")')
        expected=self.records(lua)[0];expected.update(epoch='retention',seq=8,dropped=99)
        expected_raw=json.dumps(expected,sort_keys=True,separators=(',',':'))
        old={'kind':'coverage','guild':'main','epoch':'retention','seq':1,'collectedAt':1700000000,'build':'12.1.0','coverage':'unavailable','dropped':0}
        oldest=json.dumps(old,sort_keys=True,separators=(',',':'))
        self.assertLess(len(oldest),len(expected_raw))
        remaining=1500000-len(expected_raw)
        fixture=[oldest]
        for i in range(6):
            size=min(256000,remaining-(5-i)*len(oldest))
            fixture.append(oldest+' '*(size-len(oldest)));remaining-=size
        self.assertEqual(remaining,0)
        db=lua.globals().EmberSyncJournalV2
        db.epoch='retention';db.seq=7;db.dropped=99;db.entries=lua.table_from(fixture)
        self.assertLessEqual(sum(map(len,fixture)),1500000)
        lua.execute('handler(nil,"GUILD_ROSTER_UPDATE")')
        rows=[db.entries[i] for i in range(1,len(db.entries)+1)]
        self.assertLessEqual(sum(map(len,rows)),1500000)
        self.assertEqual(json.loads(rows[-1])['dropped'],101)
    def test_retention_cannot_expand_a_record_over_the_reader_limit(self):
        lua=self.make();db=lua.globals().EmberSyncJournalV2
        lua.execute('SlashCmdList.EMBERSYNC("start");GetNumGuildMembers=function() return 600 end;GetGuildRosterInfo=function(i) return string.rep("N",170),nil,nil,nil,nil,nil,nil,nil,true,nil,nil,nil,nil,nil,nil,nil,string.rep("G",196)..string.format("%04d",i) end')
        db.epoch='retention';db.seq=7;db.dropped=99
        lua.execute('handler(nil,"GUILD_ROSTER_UPDATE")')
        base,extra=divmod(256000-len(db.entries[1]),600)
        self.assertLessEqual(170+base+1,200)
        lua.execute('GetGuildRosterInfo=function(i) return string.rep("N",170+'+str(base)+'+(i<='+str(extra)+' and 1 or 0)),nil,nil,nil,nil,nil,nil,nil,true,nil,nil,nil,nil,nil,nil,nil,string.rep("G",196)..string.format("%04d",i) end')
        old=json.dumps({'kind':'coverage','guild':'main','epoch':'retention','seq':1,'collectedAt':1700000000,'build':'12.1.0','coverage':'unavailable','dropped':0},sort_keys=True,separators=(',',':'))
        remaining=1500000-256000+1-len(old);fixture=[old]
        for i in range(5):
            size=min(256000,remaining-(4-i)*len(old));fixture.append(old+' '*(size-len(old)));remaining-=size
        self.assertEqual(remaining,0)
        db.seq=7;db.dropped=99;db.entries=lua.table_from(fixture)
        lua.execute('handler(nil,"GUILD_ROSTER_UPDATE")')
        rows=[db.entries[i] for i in range(1,len(db.entries)+1)]
        self.assertEqual(rows,fixture);self.assertEqual(db.dropped,100);self.assertEqual(db.seq,8)
    def test_counters_cannot_overflow_reader_integer_bounds(self):
        lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");EmberSyncJournalV2.dropped=9007199254740991;handler(nil,"GUILD_ROSTER_UPDATE")')
        self.assertEqual(self.records(lua),[]);self.assertEqual(lua.globals().EmberSyncJournalV2.dropped,9007199254740991)
        lua=self.make();lua.execute('SlashCmdList.EMBERSYNC("start");EmberSyncJournalV2.seq=9007199254740991;handler(nil,"GUILD_ROSTER_UPDATE")')
        self.assertEqual(self.records(lua),[]);self.assertEqual(lua.globals().EmberSyncJournalV2.seq,9007199254740991)

if __name__=='__main__':unittest.main()
