import sys, unittest, json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'.build-tools'))
from lupa import LuaRuntime

class AddonTests(unittest.TestCase):
    def make(self):
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
        lua.execute((Path(__file__).resolve().parents[1]/'addon/EmberSync/EmberSync.lua').read_text())
        lua.execute('handler(nil,"ADDON_LOADED","EmberSync")');return lua
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

if __name__=='__main__':unittest.main()
