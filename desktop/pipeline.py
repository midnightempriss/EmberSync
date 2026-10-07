"""Offline, data-only roster journal reader. Never evaluates Lua or uploads data."""
import hashlib
import json
import math
import re
import sqlite3
import time
from pathlib import Path

MAX_BYTES = 8 * 1024 * 1024
PROVIDER_SCOPE = 'Latest optional Guild Roster Manager history window from this collector and epoch. These partial records are separate from Blizzard invitations issued and observed roster changes. GRM calendar dates have no specified timezone, so the selected activity period is not applied and exact event timestamps are not inferred.'
TOKEN = re.compile(r'\s*(?:(--[^\n]*(?:\n|$))|("(?:[^"\\\n\r]|\\.)*"|\'(?:[^\'\\\n\r]|\\.)*\')|(-?\d+(?:\.\d+)?)|([A-Za-z_][A-Za-z_0-9]*)|([{}\[\]=,;]))')

def lua_string(token):
    # WoW SavedVariables decimal escapes represent bytes, including UTF-8.
    text=token[1:-1]; result=bytearray(); position=0
    for match in re.finditer(r'\\(\d{1,3}|.)',text):
        result.extend(text[position:match.start()].encode('utf-8','strict'))
        value=match.group(1)
        if value.isdigit():
            number=int(value)
            if number>255: raise ValueError('Invalid byte escape')
            result.append(number)
        elif value in {'n','r','t','\\','"',"'"}:
            result.extend({'n':'\n','r':'\r','t':'\t'}.get(value,value).encode('utf-8'))
        else: raise ValueError('Unsupported Lua escape')
        position=match.end()
    result.extend(text[position:].encode('utf-8','strict'))
    try: return result.decode('utf-8','strict')
    except UnicodeError: raise ValueError('Invalid UTF-8 Lua string') from None

def parse_saved_variables(text):
    if len(text.encode('utf-8')) > MAX_BYTES: raise ValueError('Export exceeds 8 MiB')
    tokens = []; pos = 0
    while pos < len(text):
        match = TOKEN.match(text, pos)
        if not match:
            if not text[pos:].strip(): break
            raise ValueError('Export is not literal SavedVariables')
        pos = match.end()
        if match.group(1): continue
        tokens.append(next(x for x in match.groups()[1:] if x is not None))
        if len(tokens) > 250000: raise ValueError('Too many values')
    i = 0
    def take(expected=None):
        nonlocal i
        if i >= len(tokens): raise ValueError('Truncated export')
        value = tokens[i]; i += 1
        if expected is not None and value != expected: raise ValueError('Unexpected Lua token')
        return value
    def value(depth=0):
        if depth > 12: raise ValueError('Export nesting exceeds limit')
        token = take()
        if token == '{':
            result = {}; index = 1
            while i < len(tokens) and tokens[i] != '}':
                if tokens[i] == '[':
                    take('['); key = value(depth+1); take(']'); take('=')
                elif i+1 < len(tokens) and tokens[i+1] == '=':
                    key = take(); take('=')
                else: key = index; index += 1
                if not isinstance(key, (str, int)) or isinstance(key, bool) or key in result: raise ValueError('Duplicate or invalid key')
                result[key] = value(depth+1)
                if i < len(tokens) and tokens[i] in [',',';']: take()
                elif i < len(tokens) and tokens[i] != '}': raise ValueError('Missing separator')
            take('}')
            return result
        if token.startswith(('"', "'")): return lua_string(token)
        if re.fullmatch(r'-?\d+(?:\.\d+)?', token): return float(token) if '.' in token else int(token)
        if token in ['true','false','nil']: return {'true':True,'false':False,'nil':None}[token]
        raise ValueError('Executable Lua is prohibited')
    take('EmberSyncJournalV2'); take('='); result = value()
    if i != len(tokens): raise ValueError('Trailing code')
    if not isinstance(result,dict) or result.get('version') != 2: raise ValueError('Unsupported journal version')
    entries = result.get('entries',{})
    if not isinstance(entries,dict) or set(entries) != set(range(1,len(entries)+1)): raise ValueError('Invalid journal array')
    result['entries'] = [entries[index] for index in range(1,len(entries)+1)]
    if len(entries) > 512 or any(not isinstance(x,str) or len(x) > 256000 for x in result['entries']): raise ValueError('Invalid journal entries')
    return result

def stable_read(path):
    path = Path(path)
    a = path.stat()
    if a.st_size > MAX_BYTES: raise ValueError('Export exceeds 8 MiB')
    with path.open('rb') as source: data=source.read(MAX_BYTES+1)
    if len(data)>MAX_BYTES: raise ValueError('Export exceeds 8 MiB')
    time.sleep(0.1)
    b = path.stat()
    if b.st_size>MAX_BYTES: raise ValueError('Export exceeds 8 MiB')
    with path.open('rb') as source: repeat=source.read(MAX_BYTES+1)
    if len(repeat)>MAX_BYTES: raise ValueError('Export exceeds 8 MiB')
    if (a.st_size,a.st_mtime_ns) != (b.st_size,b.st_mtime_ns) or data != repeat: raise OSError('Export is still being saved; retry later')
    return parse_saved_variables(data.decode('utf-8-sig'))

def valid_text(value,maximum=200):
    if not isinstance(value,str) or not value: return False
    try: return len(value.encode('utf-16-le','strict'))//2<=maximum
    except UnicodeError: return False

def validate_provider_logs(providers):
    if not isinstance(providers,list) or len(providers)>1: raise ValueError('Invalid provider window')
    for provider in providers:
        if not isinstance(provider,dict) or set(provider)-{'provider','version','coverage','rows'}: raise ValueError('Unexpected provider fields')
        if provider.get('provider')!='guild-roster-manager' or not valid_text(provider.get('version'),80): raise ValueError('Unsupported provider')
        coverage=provider.get('coverage'); rows=provider.get('rows')
        if coverage not in ['partial','unavailable','unsupported'] or not isinstance(rows,list) or len(rows)>200: raise ValueError('Invalid provider coverage')
        if coverage!='partial' and rows: raise ValueError('Unavailable provider cannot supply history')
        if coverage=='partial' and provider['version']!='1.99422': raise ValueError('Unsupported provider source version')
        for row in rows:
            if not isinstance(row,dict) or set(row)-{'type','subject','invitedBy','calendarDate'}: raise ValueError('Unexpected provider log fields')
            if row.get('type') not in ['join','rejoin','quit','remove'] or not valid_text(row.get('subject')): raise ValueError('Invalid provider activity')
            if 'invitedBy' in row and (row['type'] not in ['join','rejoin'] or not valid_text(row['invitedBy'])): raise ValueError('Invalid provider inviter')
            if 'calendarDate' in row:
                date=row['calendarDate']
                if not isinstance(date,list) or len(date)!=5 or any(type(x) is not int for x in date): raise ValueError('Invalid provider calendar date')
                day,month,year,hour,minute=date
                if not 2000<=year<=9999 or not 1<=month<=12 or not 1<=day or not 0<=hour<=23 or not 0<=minute<=59: raise ValueError('Invalid provider calendar date')
                days=[31,29 if year%4==0 and (year%100!=0 or year%400==0) else 28,31,30,31,30,31,31,30,31,30,31]
                if day>days[month-1]: raise ValueError('Invalid provider calendar date')

def validate_record(record):
    if not isinstance(record,dict): raise ValueError('Invalid record')
    if record.get('kind') not in ['roster','log','coverage']: raise ValueError('Unknown dataset')
    for key in ['guild','epoch']:
        if not valid_text(record.get(key)): raise ValueError('Missing scope')
    if record['guild'] not in ['main','alts']: raise ValueError('Unknown guild')
    for key in ['seq','collectedAt']:
        number=record.get(key)
        if isinstance(number,bool) or not isinstance(number,int) or not 0 < number < 2**53: raise ValueError('Invalid sequence/time')
    if record.get('coverage') not in ['complete','partial','unavailable','unsupported']: raise ValueError('Invalid coverage')
    if 'dropped' in record and (type(record['dropped']) is not int or not 0 <= record['dropped'] < 2**53): raise ValueError('Invalid drop marker')
    if 'build' in record and not valid_text(record['build'],80): raise ValueError('Invalid build')
    if record['kind'] == 'roster':
        members=record.get('members')
        if not isinstance(members,list) or len(members)>2000: raise ValueError('Invalid roster')
        ids=set()
        for member in members:
            if not isinstance(member,dict) or set(member)-{'id','name','online'}: raise ValueError('Unexpected member fields')
            if any(not valid_text(member.get(k)) for k in ['id','name']): raise ValueError('Invalid identity')
            if member['id'] in ids: raise ValueError('Duplicate member')
            ids.add(member['id'])
            if type(member.get('online')) is not bool: raise ValueError('Invalid presence')
        if record['coverage']=='complete' and not members: raise ValueError('Empty roster cannot establish completeness')
    if record['kind']=='log':
        rows=record.get('rows')
        if not isinstance(rows,list) or len(rows)>200: raise ValueError('Invalid log window')
        for row in rows:
            if not isinstance(row,dict) or set(row)-{'type','player1','player2','age'}: raise ValueError('Unexpected log fields')
            if row.get('type') not in ['invite','join','quit','remove','promote','demote']: raise ValueError('Invalid activity')
            for k in ['player1','player2']:
                if row.get(k) is not None and not valid_text(row[k]): raise ValueError('Invalid actor')
            age=row.get('age')
            if not isinstance(age,list) or len(age)!=4 or any(type(x) is not int or x<0 or x>10000 for x in age): raise ValueError('Invalid relative age')
    if record['kind']!='roster' and 'members' in record: raise ValueError('Unexpected roster fields')
    if record['kind']!='log' and 'rows' in record: raise ValueError('Unexpected log fields')
    if 'providerLogs' in record:
        if record['kind']!='log': raise ValueError('Unexpected provider window')
        if record['coverage'] in ['unavailable','unsupported'] and record['rows']: raise ValueError('Unavailable native log cannot supply provider-associated native rows')
        validate_provider_logs(record['providerLogs'])
    if set(record)-{'kind','guild','epoch','seq','collectedAt','coverage','members','rows','providerLogs','build','dropped'}: raise ValueError('Unexpected export fields')
    return record

class JournalStore:
    def __init__(self,path):
        self.db=sqlite3.connect(path,timeout=1)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''CREATE TABLE IF NOT EXISTS evidence(guild TEXT,epoch TEXT,seq INTEGER,hash TEXT,payload TEXT,saved_at INTEGER,PRIMARY KEY(guild,epoch,seq));
        CREATE TABLE IF NOT EXISTS outbox(hash TEXT PRIMARY KEY,payload TEXT,status TEXT DEFAULT 'pending');''')
    def ingest(self,journal):
        records=[validate_record(json.loads(raw)) for raw in journal['entries']]
        count=0
        with self.db:
            for r in records:
                raw=json.dumps(r,sort_keys=True,separators=(',',':'),ensure_ascii=False)
                digest=hashlib.sha256(raw.encode()).hexdigest()
                previous=self.db.execute('SELECT hash FROM evidence WHERE guild=? AND epoch=? AND seq=?',(r['guild'],r['epoch'],r['seq'])).fetchone()
                if previous and previous[0]!=digest: raise ValueError('Sequence collision: original evidence preserved')
                if previous: continue
                self.db.execute('INSERT INTO evidence VALUES(?,?,?,?,?,?)',(r['guild'],r['epoch'],r['seq'],digest,raw,int(time.time())))
                self.db.execute('INSERT OR IGNORE INTO outbox(hash,payload) VALUES(?,?)',(digest,raw)); count+=1
        return count
    def epochs(self,guild):
        return [row[0] for row in self.db.execute('SELECT DISTINCT epoch FROM evidence WHERE guild=? ORDER BY epoch',(guild,))]
    def metrics(self,guild,epoch=None,*,now=None,stale_after=3600):
        from bisect import bisect_left, bisect_right
        if epoch is not None and not isinstance(epoch,str): raise ValueError('Invalid journal epoch')
        now=time.time() if now is None else now
        if isinstance(now,bool) or not isinstance(now,(int,float)) or not math.isfinite(now) or now<0: raise ValueError('Invalid current time')
        if isinstance(stale_after,bool) or not isinstance(stale_after,(int,float)) or not math.isfinite(stale_after) or stale_after<0: raise ValueError('Invalid freshness interval')
        choices=self.epochs(guild)
        result={'coverage':'unavailable','epoch':epoch,'epochs':choices,'joins':None,'departures':None,'net':None,'members':None,'online':None,
            'topInviters':[],'unknownInviters':None,'inviterCoverage':'unavailable','invitationWindow':None,
            'inviterScope':'latest log window: invitations issued, not confirmed joins','collectedAt':None,'rosterStale':None,'staleAt':None,
            'latestRosterCoverage':None,'latestLogCoverage':None,'intervals':[],'intervalsObserved':0,
            'gaps':[],'hasGaps':False,'hasDefiniteLoss':False,'droppedEntries':0,'sequenceGaps':[],'sequenceCoverage':'unavailable','evidence':[],'providerWindows':[]}
        if epoch is None:
            if len(choices)>1: result['coverage']='ambiguous_collectors_or_reset';return result
            if choices: epoch=choices[0];result['epoch']=epoch
        if epoch not in choices: return result
        records=[json.loads(row[0]) for row in self.db.execute('SELECT payload FROM evidence WHERE guild=? AND epoch=? ORDER BY seq',(guild,epoch))]
        result['evidence']=records
        # The addon counter is shared across its guild scopes. Observing a gap
        # within this guild alone is not proof that a guild observation was lost.
        other_sequences=[row[0] for row in self.db.execute('SELECT DISTINCT seq FROM evidence WHERE epoch=? AND guild<>? ORDER BY seq',(epoch,guild))]
        previous_seq=0
        for record in records:
            start,end=previous_seq+1,record['seq']-1
            if start<=end:
                known=bisect_right(other_sequences,end)-bisect_left(other_sequences,start)
                missing=end-start+1-known
                result['sequenceGaps'].append({'fromSequence':start,'toSequence':end,'observedOtherGuildRecords':known,'unobservedSequences':missing})
                if missing: result['gaps'].append({'type':'unobserved_sequences','fromSequence':start,'toSequence':end,'count':missing})
            previous_seq=record['seq']
        result['sequenceCoverage']='unobserved_sequences' if any(g['unobservedSequences'] for g in result['sequenceGaps']) else 'shared_journal_other_guild_records' if result['sequenceGaps'] else 'observed_sequence'
        usable=[];last_time=0;drop_marker=None
        for record in records:
            dropped=record.get('dropped')
            if dropped is not None:
                if drop_marker is not None and dropped<drop_marker: result['gaps'].append({'type':'drop_marker_regression','fromSequence':record['seq'],'toSequence':record['seq']})
                drop_marker=dropped;result['droppedEntries']=max(result['droppedEntries'],dropped)
            if record['collectedAt']>now:
                result['gaps'].append({'type':'future_observation','fromSequence':record['seq'],'toSequence':record['seq']});continue
            if record['collectedAt']<last_time:
                result['gaps'].append({'type':'clock_regression','fromSequence':record['seq'],'toSequence':record['seq']});continue
            last_time=record['collectedAt'];usable.append(record)
            if record['coverage']!='complete': result['gaps'].append({'type':'incomplete_observation','fromSequence':record['seq'],'toSequence':record['seq'],'coverage':record['coverage']})
        if result['droppedEntries']:
            result['hasDefiniteLoss']=True
            result['gaps'].append({'type':'dropped_entries','count':result['droppedEntries'],'scope':'shared_journal'})
        complete=[record for record in usable if record['kind']=='roster' and record['coverage']=='complete']
        latest=complete[-1] if complete else None
        joins=departures=0
        for before,after in zip(complete,complete[1:]):
            a={member['id'] for member in before['members']};b={member['id'] for member in after['members']}
            arrived,left=len(b-a),len(a-b)
            included=after['collectedAt']>before['collectedAt']
            result['intervals'].append({'from':before['collectedAt'],'to':after['collectedAt'],'fromSequence':before['seq'],'toSequence':after['seq'],
                'joins':arrived,'departures':left,'net':arrived-left,'included':included,'exclusion':None if included else 'indeterminate_collection_interval'})
            if included: joins+=arrived;departures+=left;result['intervalsObserved']+=1
            else: result['gaps'].append({'type':'indeterminate_collection_interval','fromSequence':before['seq'],'toSequence':after['seq']})
        if result['intervalsObserved']: result.update(joins=joins,departures=departures,net=joins-departures)
        last_roster=next((record for record in reversed(usable) if record['kind']=='roster' or record['kind']=='coverage' and record['coverage']!='complete'),None)
        result['latestRosterCoverage']=last_roster['coverage'] if last_roster else None
        result['coverage']='observed_snapshot_intervals' if result['intervalsObserved'] else 'baseline_only' if len(complete)==1 else 'period_unobserved' if complete else 'unavailable'
        result['hasGaps']=bool(result['gaps'])
        if result['hasGaps']:
            result['coverage']='unobserved_sequences' if all(g['type']=='unobserved_sequences' for g in result['gaps']) else 'coverage_gaps'
        if latest:
            result.update(members=len(latest['members']),online=sum(member['online'] for member in latest['members']),collectedAt=latest['collectedAt'],
                staleAt=latest['collectedAt']+stale_after,rosterStale=now>=latest['collectedAt']+stale_after)
            if last_roster and last_roster['coverage']!='complete': result['coverage']='last_good_roster_latest_coverage_'+last_roster['coverage']
            elif result['rosterStale']: result['coverage']='last_good_roster_stale'
        # Keep one immutable complete window; newer incomplete observations and
        # staleness remain visible instead of implying its counts are current.
        log=next((record for record in reversed(usable) if record['kind']=='log' and record['coverage']=='complete'),None)
        last_log=next((record for record in reversed(usable) if record['kind']=='log' or record['kind']=='coverage' and record['coverage']!='complete'),None)
        result['latestLogCoverage']=last_log['coverage'] if last_log else None
        if log:
            inviters={};unknown=issued=0
            for row in log['rows']:
                if row['type']=='invite':
                    issued+=1;actor=row.get('player1')
                    if actor and actor.strip(): inviters[actor]=inviters.get(actor,0)+1
                    else: unknown+=1
            result.update(topInviters=sorted(inviters.items(),key=lambda item:(-item[1],item[0])),unknownInviters=unknown)
            latest_coverage=last_log['coverage'] if last_log else None
            result['inviterCoverage']='last_complete_log_latest_'+latest_coverage if latest_coverage in ['partial','unavailable','unsupported'] else 'latest_complete_log_window'
            result['invitationWindow']={'sequence':log['seq'],'collectedAt':log['collectedAt'],'rows':len(log['rows']),'issuedInvitations':issued,
                'stale':now>=log['collectedAt']+stale_after,'latestCoverage':latest_coverage,'latestObservationAt':last_log['collectedAt'] if last_log else None,'periodApplied':False}
        # A provider history window overlaps its earlier windows. Use the latest
        # usable log only, including an explicit disabled/unavailable status;
        # never combine GRM accepted joins with native issued invitations.
        provider_log=next((record for record in reversed(usable) if record['kind']=='log'),None)
        if provider_log:
            result['providerWindows']=[dict(provider,
                rows=[dict(row,**({'calendarDate':list(row['calendarDate'])} if 'calendarDate' in row else {})) for row in provider['rows']],
                sequence=provider_log['seq'],collectedAt=provider_log['collectedAt'],stale=now>=provider_log['collectedAt']+stale_after,
                periodApplied=False,scope=PROVIDER_SCOPE) for provider in provider_log.get('providerLogs',[])]
        return result
    def guilds(self): return [row[0] for row in self.db.execute('SELECT DISTINCT guild FROM evidence ORDER BY guild')]
    def close(self): self.db.close()
