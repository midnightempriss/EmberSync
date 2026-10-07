"""Offline, data-only roster journal reader. Never evaluates Lua or uploads data."""
import hashlib
import json
import math
import re
import sqlite3
import time
from pathlib import Path

MAX_BYTES = 8 * 1024 * 1024
TOKEN = re.compile(r'\s*(?:(--[^\n]*(?:\n|$))|("(?:[^"\\\n\r]|\\.)*"|\'(?:[^\'\\\n\r]|\\.)*\')|(-?\d+(?:\.\d+)?)|([A-Za-z_][A-Za-z_0-9]*)|([{}\[\]=,;]))')

def lua_string(token):
    text = token[1:-1]
    def unescape(match):
        value = match.group(1)
        if value.isdigit():
            number = int(value)
            if number > 255: raise ValueError('Invalid byte escape')
            return chr(number)
        if value in {'n','r','t','\\','"',"'"}:
            return {'n':'\n','r':'\r','t':'\t'}.get(value, value)
        raise ValueError('Unsupported Lua escape')
    return re.sub(r'\\(\d{1,3}|.)', unescape, text)

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
    result['entries'] = list(entries.values())
    if len(entries) > 512 or any(not isinstance(x,str) or len(x) > 256000 for x in result['entries']): raise ValueError('Invalid journal entries')
    return result

def stable_read(path):
    path = Path(path)
    a = path.stat()
    if a.st_size > MAX_BYTES: raise ValueError('Export exceeds 8 MiB')
    data = path.read_bytes()
    time.sleep(0.1)
    b = path.stat(); repeat = path.read_bytes()
    if (a.st_size,a.st_mtime_ns) != (b.st_size,b.st_mtime_ns) or data != repeat: raise OSError('Export is still being saved; retry later')
    return parse_saved_variables(data.decode('utf-8-sig'))

def validate_record(record):
    if not isinstance(record,dict): raise ValueError('Invalid record')
    if record.get('kind') not in ['roster','log','coverage']: raise ValueError('Unknown dataset')
    for key in ['guild','epoch']:
        if not isinstance(record.get(key),str) or not 1 <= len(record[key]) <= 200: raise ValueError('Missing scope')
    if record['guild'] not in ['main','alts']: raise ValueError('Unknown guild')
    for key in ['seq','collectedAt']:
        number=record.get(key)
        if isinstance(number,bool) or not isinstance(number,int) or not 0 < number < 2**53: raise ValueError('Invalid sequence/time')
    if record.get('coverage') not in ['complete','partial','unavailable','unsupported']: raise ValueError('Invalid coverage')
    if 'dropped' in record and (type(record['dropped']) is not int or not 0 <= record['dropped'] < 2**53): raise ValueError('Invalid drop marker')
    if 'build' in record and (not isinstance(record['build'],str) or len(record['build']) > 80): raise ValueError('Invalid build')
    if record['kind'] == 'roster':
        members=record.get('members')
        if not isinstance(members,list) or len(members)>2000: raise ValueError('Invalid roster')
        ids=set()
        for member in members:
            if not isinstance(member,dict) or set(member)-{'id','name','online'}: raise ValueError('Unexpected member fields')
            if any(not isinstance(member.get(k),str) or not 1 <= len(member[k]) <= 200 for k in ['id','name']): raise ValueError('Invalid identity')
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
                if row.get(k) is not None and (not isinstance(row[k],str) or len(row[k])>200): raise ValueError('Invalid actor')
            age=row.get('age')
            if not isinstance(age,list) or len(age)!=4 or any(type(x) is not int or x<0 or x>10000 for x in age): raise ValueError('Invalid relative age')
    if record['kind']!='roster' and 'members' in record: raise ValueError('Unexpected roster fields')
    if record['kind']!='log' and 'rows' in record: raise ValueError('Unexpected log fields')
    if set(record)-{'kind','guild','epoch','seq','collectedAt','coverage','members','rows','build','dropped'}: raise ValueError('Unexpected export fields')
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
    def metrics(self,guild):
        records=[json.loads(row[0]) for row in self.db.execute('SELECT payload FROM evidence WHERE guild=? ORDER BY seq',(guild,))]
        epochs={r['epoch'] for r in records}
        if len(epochs)>1: return {'coverage':'ambiguous_collectors_or_reset','joins':None,'departures':None,'net':None,'members':None,'online':None,'topInviters':[],'unknownInviters':None}
        complete=[r for r in records if r['kind']=='roster' and r['coverage']=='complete']
        joins=departures=0; previous=None
        for r in complete:
            current={m['id'] for m in r['members']}
            if previous is not None: joins+=len(current-previous); departures+=len(previous-current)
            previous=current
        latest=complete[-1] if complete else None
        # Windows are immutable observations; overlapping/repeated activity is not summed.
        log=next((r for r in reversed(records) if r['kind']=='log' and r['coverage']=='complete'),None)
        inviters={}; unknown=0
        if log:
            for row in log['rows']:
                if row['type']=='invite':
                    actor=row.get('player1')
                    if actor: inviters[actor]=inviters.get(actor,0)+1
                    else: unknown+=1
        tracking=len(complete)>1
        gaps=(bool(records) and records[0]['seq']!=1) or any(b['seq'] != a['seq']+1 for a,b in zip(records,records[1:])) or any(r.get('dropped',0)>0 for r in records)
        coverage='observed_snapshot_intervals' if tracking else 'baseline_only' if latest else 'unavailable'
        if gaps: coverage='coverage_gaps'
        last_roster=next((r for r in reversed(records) if r['kind'] in ['roster','coverage']),None)
        if last_roster and last_roster['coverage'] != 'complete': coverage='last_good_roster_latest_coverage_'+last_roster['coverage']
        return {'coverage':coverage,'joins':joins if tracking else None,'departures':departures if tracking else None,'net':joins-departures if tracking else None,'members':len(latest['members']) if latest else None,'online':sum(m['online'] for m in latest['members']) if latest else None,'topInviters':sorted(inviters.items(),key=lambda x:(-x[1],x[0])),'unknownInviters':unknown if log else None,'inviterScope':'latest log window: invitations issued, not confirmed joins','collectedAt':latest['collectedAt'] if latest else None,'evidence':records}
    def guilds(self): return [row[0] for row in self.db.execute('SELECT DISTINCT guild FROM evidence ORDER BY guild')]
    def close(self): self.db.close()
