"""Real Lua adapter fixtures; no upstream GRM code or game client is executed."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
import test_addon


class ProviderTests(unittest.TestCase):
    def make(self, setup=""):
        return test_addon.AddonTests.make(self, '''
        issecretvalue=function(value) return type(value)=="table" and rawget(value,"secret")==true end
        C_AddOns={
            DoesAddOnExist=function() return true end,
            GetAddOnMetadata=function() return "1.99422" end,
            IsAddOnLoaded=function() return true,true end
        }
        GRM={GetLog=function(name) requestedGuild=name; return grmRows or {} end}
        ''' + setup)

    def records(self, lua):
        return test_addon.AddonTests.records(self, lua)

    def collect(self, lua):
        lua.execute('SlashCmdList.EMBERSYNC("plugin grm on");SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        return self.records(lua)[-1]

    def test_optional_opt_in_and_global_pause(self):
        lua = self.make('grmRows={{8,"private formatted text",true,"Alice","Bob",{7,10,2026,14,25},false}}')
        lua.execute('SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        self.assertNotIn('providerLogs', self.records(lua)[-1])
        record = self.collect(lua)
        self.assertEqual(record['providerLogs'][0]['rows'][0]['subject'], 'Bob')
        count = len(self.records(lua))
        lua.execute('SlashCmdList.EMBERSYNC("stop");handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        self.assertEqual(len(self.records(lua)), count)
        lua.execute('SlashCmdList.EMBERSYNC("plugin grm off");SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        self.assertNotIn('providerLogs', self.records(lua)[-1])

    def test_join_and_rejoin_only_whitelisted_fields_without_reading_private_data(self):
        lua = self.make('''
        privateReads=0
        local private={__index=function() privateReads=privateReads+1;error("private field accessed") end}
        grmRows={
            setmetatable({[1]=8,[3]=true,[4]="|cff00ccffAlice|r",[5]="|cffaabbccBob|r",[6]={7,10,2026,14,25},[7]=false},private),
            setmetatable({[1]=7,[3]=true,[4]="Alice",[5]="Returner",[6]={7,10,2026,15,25}},private),
            setmetatable({[1]=9,[3]=true,[4]="Carol",[5]="Another",[6]={7,10,2026,16,25}},private),
            {8,"DO NOT EXPORT FORMATTED NOTES",false,"Unknown inviter","Observed join",{7,10,2026,17,25},true,"PRIVATE LEVEL","PRIVATE NOTES"}
        }''')
        record = self.collect(lua)
        self.assertEqual(lua.globals().privateReads, 0)
        provider = record['providerLogs'][0]
        self.assertEqual(provider['coverage'], 'partial')
        self.assertEqual(provider['provider'], 'guild-roster-manager')
        self.assertEqual(provider['version'], '1.99422')
        self.assertEqual(provider['rows'], [
            {'type': 'join', 'subject': 'Bob', 'invitedBy': 'Alice', 'calendarDate': [7, 10, 2026, 14, 25]},
            {'type': 'rejoin', 'subject': 'Returner', 'invitedBy': 'Alice', 'calendarDate': [7, 10, 2026, 15, 25]},
            {'type': 'rejoin', 'subject': 'Another', 'invitedBy': 'Carol', 'calendarDate': [7, 10, 2026, 16, 25]},
            {'type': 'rejoin', 'subject': 'Observed join', 'calendarDate': [7, 10, 2026, 17, 25]},
        ])
        self.assertEqual(record['rows'][0]['type'], 'invite')
        self.assertNotIn('PRIVATE', json.dumps(provider))
        self.assertNotIn('invite', [row['type'] for row in provider['rows']])

    def test_departures_exclude_notes_reason_alts_and_actor_inference(self):
        lua = self.make('''grmRows={
            {10,"private", "Leaver",false,"private age",{}, {"private alt"},"private main","public note","officer note",{1,2,2026,0,0},true,80,false,"custom note"},
            {10,"private", "Removed",true,"private age",{}, {"private alt"},"private main","public note","officer note",{2,2,2026,1,2},true,80,false,"custom note"},
            {10,"private", "Unknown action",nil}
        }''')
        rows = self.collect(lua)['providerLogs'][0]['rows']
        self.assertEqual(rows, [
            {'type': 'quit', 'subject': 'Leaver', 'calendarDate': [1, 2, 2026, 0, 0]},
            {'type': 'remove', 'subject': 'Removed', 'calendarDate': [2, 2, 2026, 1, 2]},
        ])

    def test_secret_values_unknown_attribution_and_malformed_markup(self):
        lua = self.make('''grmRows={
            {8,"private",{secret=true},"Alice","Secret flag"},
            {8,"private",true,{secret=true},"Secret inviter"},
            {8,"private",true,"Alice",{secret=true}},
            {8,"private",true,"|Hplayer:Alice|hAlice|h","Hyperlink actor"},
            {8,"private",true,"Alice","|Ttexture|t"},
            {8,"private",true,"Alice",string.char(10).."Bad"},
            {8,"private",true,"Alice",string.rep("X",201)},
            {8,"private",true,"|cxyzAlice|r","Broken color"}
        }''')
        rows = self.collect(lua)['providerLogs'][0]['rows']
        self.assertEqual(rows, [
            {'type': 'join', 'subject': 'Secret flag'},
            {'type': 'join', 'subject': 'Secret inviter'},
            {'type': 'join', 'subject': 'Hyperlink actor'},
            {'type': 'join', 'subject': 'Broken color'},
        ])

    def test_calendar_is_real_gregorian_label_without_utc_inference(self):
        lua = self.make('''grmRows={
            {8,"private",false,nil,"Leap valid",{29,2,2024,23,59}},
            {8,"private",false,nil,"Century valid",{29,2,2000,0,0}},
            {8,"private",false,nil,"Nonleap",{29,2,2026,1,2}},
            {8,"private",false,nil,"Century nonleap",{29,2,2100,1,2}},
            {8,"private",false,nil,"Short month",{31,4,2026,1,2}},
            {8,"private",false,nil,"Fraction",{1,2,2026,1,2.5}},
            {8,"private",false,nil,"Secret",{1,2,2026,{secret=true},2}},
            {8,"private",false,nil,"Old format",{1,2,26,1,2}},
            {8,"private",false,nil,"Infinity",{1,2,2026,math.huge,2}}
        }''')
        rows = self.collect(lua)['providerLogs'][0]['rows']
        self.assertEqual(rows[0]['calendarDate'], [29, 2, 2024, 23, 59])
        self.assertEqual(rows[1]['calendarDate'], [29, 2, 2000, 0, 0])
        for row in rows[2:]:
            self.assertNotIn('calendarDate', row)
        for row in rows:
            self.assertNotIn('timestamp', row)

    def test_exact_guild_keys_no_other_guild_and_no_mutation(self):
        for guild, realm, expected in [
            ('Raining Embers', 'Dalaran', 'Raining Embers-Dalaran'),
            ('Raining Embers Alts', 'Wyrmrest Accord', 'Raining Embers Alts-WyrmrestAccord'),
        ]:
            with self.subTest(guild=guild):
                lua = self.make('''grmRows={{8,"private",true,"Alice","Bob",{7,10,2026,14,25},false}};
                GetGuildInfo=function() return "''' + guild + '''",nil,nil,"''' + realm + '''" end''')
                self.collect(lua)
                self.assertEqual(lua.globals().requestedGuild, expected)
                self.assertEqual(lua.globals().grmRows[1][2], 'private')
                self.assertEqual(lua.globals().grmRows[1][4], 'Alice')
        lua = self.make('GetGuildInfo=function() return "Other Guild",nil,nil,"Dalaran" end')
        lua.execute('SlashCmdList.EMBERSYNC("plugin grm on");SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        self.assertEqual(self.records(lua), [])
        self.assertIsNone(lua.globals().requestedGuild)

    def test_missing_disabled_loading_unsupported_and_fault_states(self):
        cases = [
            ('C_AddOns.DoesAddOnExist=function() return false end', 'unavailable', '1.99422'),
            ('C_AddOns.IsAddOnLoaded=function() return false,false end', 'unavailable', '1.99422'),
            ('C_AddOns.IsAddOnLoaded=function() return true,false end', 'unavailable', '1.99422'),
            ('C_AddOns.IsAddOnLoaded=function() return true,{secret=true} end', 'unavailable', '1.99422'),
            ('C_AddOns.GetAddOnMetadata=function() return "1.99423" end', 'unsupported', '1.99423'),
            ('C_AddOns.GetAddOnMetadata=function() return string.char(10).."bad" end', 'unsupported', 'unknown'),
            ('GRM.GetLog=nil', 'unsupported', '1.99422'),
            ('GRM.GetLog=function() error("private failure details") end', 'unavailable', '1.99422'),
            ('GRM.GetLog=function() return nil end', 'unavailable', '1.99422'),
            ('GRM.GetLog=function() return {secret=true} end', 'unavailable', '1.99422'),
        ]
        for setup, coverage, version in cases:
            with self.subTest(setup=setup):
                lua = self.make(setup)
                record = self.collect(lua)
                self.assertEqual(record['coverage'], 'complete')
                self.assertEqual(record['rows'][0]['type'], 'invite')
                self.assertEqual(record['providerLogs'][0], {'provider': 'guild-roster-manager', 'version': version, 'coverage': coverage, 'rows': []})

    def test_provider_fault_never_prevents_native_evidence(self):
        lua = self.make('EmberSyncProviders={Collect=function() error("private plugin failure") end}')
        # setup runs before addon files: inject the fault after initialization.
        lua.execute('EmberSyncProviders.Collect=function() error("private plugin failure") end;SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        record = self.records(lua)[-1]
        self.assertEqual(record['coverage'], 'complete')
        self.assertEqual(record['rows'][0]['type'], 'invite')
        self.assertNotIn('providerLogs', record)

    def test_native_unavailable_does_not_hide_independent_provider_history(self):
        for setup, coverage in [
            ('GetNumGuildEvents=function() error("restricted") end', 'unavailable'),
            ('GetGuildEventInfo=nil', 'unsupported'),
            ('QueryGuildEventLog=function() error("restricted") end', 'unavailable'),
            ('QueryGuildEventLog=nil', 'unsupported'),
        ]:
            with self.subTest(setup=setup):
                lua = self.make('grmRows={{8,"private",true,"Alice","Bob",{7,10,2026,14,25},false}};' + setup)
                lua.execute('SlashCmdList.EMBERSYNC("plugin grm on");SlashCmdList.EMBERSYNC("start")')
                if setup.startswith('Get'):
                    lua.execute('handler(nil,"GUILD_EVENT_LOG_UPDATE")')
                record = self.records(lua)[-1]
                self.assertEqual(record['kind'], 'log')
                self.assertEqual(record['coverage'], coverage)
                self.assertEqual(record['rows'], [])
                self.assertEqual(record['providerLogs'][0]['rows'][0]['subject'], 'Bob')

    def test_collection_rows_and_inspected_window_are_bounded(self):
        lua = self.make('grmRows={};for i=1,1200 do grmRows[i]={8,"private",false,nil,"Member"..i} end')
        rows = self.collect(lua)['providerLogs'][0]['rows']
        self.assertEqual(len(rows), 200)
        self.assertEqual(rows[0]['subject'], 'Member1001')
        self.assertEqual(rows[-1]['subject'], 'Member1200')
        lua = self.make('grmRows={};for i=1,1200 do grmRows[i]=i<=200 and {8,"private",false,nil,"Member"..i} or {4,"private note change"} end')
        self.assertEqual(self.collect(lua)['providerLogs'][0]['rows'], [])

    def test_optional_history_cannot_displace_native_record_at_byte_limit(self):
        lua = self.make('''
        GetNumGuildEvents=function() return 200 end
        GetGuildEventInfo=function() return "invite",string.rep(string.char(1),75),string.rep(string.char(2),75),nil,0,0,0,1 end
        grmRows={};for i=1,200 do grmRows[i]={8,"private",true,string.rep("A",200),string.rep("B",200)} end
        ''')
        record = self.collect(lua)
        self.assertEqual(record['kind'], 'log')
        self.assertEqual(record['coverage'], 'complete')
        self.assertEqual(len(record['rows']), 200)
        self.assertNotIn('providerLogs', record)
        self.assertEqual(record['dropped'], 0)

    def test_retention_counter_growth_drops_optional_window_before_native_record(self):
        lua = self.make('''
        GetNumGuildEvents=function() return 200 end
        GetGuildEventInfo=function() return "invite",string.rep(string.char(1),60),string.rep(string.char(2),60),nil,0,0,0,1 end
        grmRows={};for i=1,200 do grmRows[i]={8,"private",true,string.rep("A",200),string.rep("B",200)} end
        ''')
        db = lua.globals().EmberSyncJournalV2
        db.epoch, db.seq, db.dropped = 'retention', 7, 99
        record = self.collect(lua)
        self.assertIn('providerLogs', record)
        padding, extra = divmod(256000 - len(db.entries[1]), 200)
        self.assertLessEqual(60 + padding + 1, 200)
        lua.execute('GetGuildEventInfo=function(i) return "invite",string.rep(string.char(1),60)..string.rep("X",' + str(padding) + '+(i<=' + str(extra) + ' and 1 or 0)),string.rep(string.char(2),60),nil,0,0,0,1 end')
        old = json.dumps({'kind': 'coverage', 'guild': 'main', 'epoch': 'retention', 'seq': 1, 'collectedAt': 1700000000, 'coverage': 'unavailable', 'dropped': 0}, sort_keys=True, separators=(',', ':'))
        remaining = 1500000 - 256000 + 1 - len(old)
        fixture = [old]
        for index in range(5):
            size = min(256000, remaining-(4-index)*len(old))
            fixture.append(old + ' ' * (size-len(old)))
            remaining -= size
        self.assertEqual(remaining, 0)
        db.seq, db.dropped, db.entries = 7, 99, lua.table_from(fixture)
        lua.execute('handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        record = self.records(lua)[-1]
        self.assertEqual(record['seq'], 8)
        self.assertEqual(record['dropped'], 100)
        self.assertEqual(record['kind'], 'log')
        self.assertEqual(len(record['rows']), 200)
        self.assertNotIn('providerLogs', record)
        self.assertLessEqual(sum(len(db.entries[i]) for i in range(1, len(db.entries)+1)), 1500000)

    def test_guild_switch_during_provider_read_discards_entire_record(self):
        lua = self.make('''GRM.GetLog=function(name)
            requestedGuild=name
            GetGuildInfo=function() return "Raining Embers Alts",nil,nil,"Wyrmrest Accord" end
            return {{8,"private",true,"Alice","Bob"}}
        end''')
        lua.execute('SlashCmdList.EMBERSYNC("plugin grm on");SlashCmdList.EMBERSYNC("start");handler(nil,"GUILD_EVENT_LOG_UPDATE")')
        self.assertEqual(lua.globals().requestedGuild, 'Raining Embers-Dalaran')
        self.assertEqual(self.records(lua), [])

    def test_actual_lua_export_round_trips_desktop_without_combining_metrics(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'desktop'))
        from pipeline import parse_saved_variables, JournalStore
        for setup, expected_native_invites in [('', 1), ('GetNumGuildEvents=function() error("restricted") end', None)]:
            with self.subTest(setup=setup):
                lua = self.make('grmRows={{8,"private",true,"Provider inviter","Provider member",{7,10,2026,14,25},false}};' + setup)
                record = self.collect(lua)
                entries = lua.globals().EmberSyncJournalV2.entries
                raw = [entries[i] for i in range(1, len(entries)+1)]
                saved = 'EmberSyncJournalV2={version=2,providers={["guild-roster-manager"]=true},entries={' + ','.join(json.dumps(value, ensure_ascii=False) for value in raw) + '}}'
                parsed = parse_saved_variables(saved)
                with tempfile.TemporaryDirectory() as temporary:
                    store = JournalStore(Path(temporary) / 'journal.sqlite')
                    try:
                        self.assertEqual(store.ingest(parsed), len(raw))
                        self.assertEqual(store.ingest(parsed), 0)
                        metrics = store.metrics('main', now=1700000001)
                        invitation_window = metrics['invitationWindow']
                        self.assertEqual(invitation_window['issuedInvitations'] if invitation_window else None, expected_native_invites)
                        self.assertEqual(metrics['providerWindows'][0]['rows'], record['providerLogs'][0]['rows'])
                        self.assertIsNone(metrics['joins'])
                    finally:
                        store.close()

    def test_invalid_utf8_never_contaminates_the_export(self):
        lua = self.make('''grmRows={
            {8,"private",true,"Alice",string.char(192,128)},
            {8,"private",true,"Alice",string.char(237,160,128)},
            {8,"private",true,"Alice",string.char(244,144,128,128)},
            {8,"private",true,string.char(255),"Good subject"},
            {8,"private",true,"Élodie","Åsa"}
        }''')
        self.assertEqual(self.collect(lua)['providerLogs'][0]['rows'], [
            {'type': 'join', 'subject': 'Good subject'},
            {'type': 'join', 'subject': 'Åsa', 'invitedBy': 'Élodie'},
        ])

    def test_malformed_journal_or_provider_settings_are_preserved(self):
        lua = self.make('EmberSyncJournalV2={version=2,consent=true,epoch="old",seq="bad",dropped=0,entries={},providers={original=true}}')
        lua.execute('SlashCmdList.EMBERSYNC("plugin grm on")')
        self.assertIsNone(lua.globals().EmberSyncJournalV2.providers['guild-roster-manager'])
        self.assertTrue(lua.globals().EmberSyncJournalV2.providers.original)
        for setting in ['"preserve me"', '{secret=true}']:
            with self.subTest(setting=setting):
                lua = self.make()
                lua.execute('EmberSyncJournalV2.providers=' + setting + ';SlashCmdList.EMBERSYNC("plugin grm on")')
                self.assertFalse(lua.globals().EmberSyncProviders.Enabled())
                if setting.startswith('"'):
                    self.assertEqual(lua.globals().EmberSyncJournalV2.providers, 'preserve me')
                else:
                    self.assertTrue(lua.globals().EmberSyncJournalV2.providers.secret)

    def test_legacy_addon_api_is_a_safe_fallback(self):
        lua = self.make('''C_AddOns=nil;
        GetAddOnInfo=function() return "Guild_Roster_Manager" end
        GetAddOnMetadata=function() return "1.99422" end
        IsAddOnLoaded=function() return true end
        grmRows={{8,"private",true,"Alice","Bob"}}''')
        self.assertEqual(self.collect(lua)['providerLogs'][0]['rows'][0]['invitedBy'], 'Alice')

    def test_checklist_colors_text_opt_in_toggle_and_no_install_mutations(self):
        lua = self.make()
        lua.execute('''
        widgets={}; local function widget(kind)
            local w={kind=kind,scripts={}}
            for _,name in ipairs({"SetSize","SetPoint","SetWidth","SetJustifyH"}) do w[name]=function() end end
            w.SetText=function(self,value) self.text=value end
            w.SetColorTexture=function(self,r,g,b,a) self.color={r,g,b,a} end
            w.SetScript=function(self,key,fn) self.scripts[key]=fn end
            w.Show=function(self) self.shown=true end
            w.CreateFontString=function() return widget("text") end
            w.CreateTexture=function() return widget("dot") end
            widgets[#widgets+1]=w;return w
        end
        CreateFrame=function(kind) return widget(kind) end
        C_AddOns.LoadAddOn=function() error("must not install or load addon") end
        C_AddOns.EnableAddOn=function() error("must not change addon permissions") end
        SlashCmdList.EMBERSYNC("plugins")
        ''')
        widgets = lua.globals().widgets
        values = [widgets[i] for i in range(1, len(widgets) + 1)]
        dot = next(item for item in values if item.kind == 'dot')
        self.assertEqual([dot.color[i] for i in range(1, 5)], [0.15, 0.85, 0.25, 1])
        status = next(item for item in values if item.text and 'Guild Roster Manager:' in item.text)
        self.assertIn('Installed', status.text)
        self.assertIn('Compatible', status.text)
        toggle = next(item for item in values if item.text == 'Enable GRM contribution')
        toggle.scripts.OnClick()
        self.assertTrue(lua.globals().EmberSyncProviders.Enabled())
        self.assertEqual(toggle.text, 'Disable GRM contribution')
        lua.execute('C_AddOns.DoesAddOnExist=function() return false end;SlashCmdList.EMBERSYNC("plugins")')
        self.assertEqual([dot.color[i] for i in range(1, 5)], [0.9, 0.2, 0.2, 1])
        self.assertIn('Not installed', status.text)
        lua.execute('C_AddOns.DoesAddOnExist=function() return true end;C_AddOns.GetAddOnMetadata=function() return "2.0" end;SlashCmdList.EMBERSYNC("plugins")')
        self.assertIn('Unsupported version/API', status.text)


if __name__ == '__main__':
    unittest.main()
