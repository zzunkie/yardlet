#!/usr/bin/env python3
"""Provider-free persistent session fixture. Copy into a temporary directory to run.

Only records CODEX_HOME, method, thread ID and whether the thread is ephemeral; never records the
process environment. Sessions are stored in the selected home so an incorrect resume scope fails
visibly; an ephemeral thread is kept in memory only, as the App Server keeps it.
"""
import json
import os
from pathlib import Path
import sys
import uuid

if '--version' in sys.argv:
    print('codex-cli 0.153.4')
    sys.exit(0)

root = Path(__file__).resolve().parent
home = Path(os.environ['CODEX_HOME'])
sessions = home / 'fixture-sessions'
sessions.mkdir(parents=True, exist_ok=True)
ephemeral = {}


def read_thread(thread_id):
    if thread_id in ephemeral:
        return ephemeral[thread_id]
    return json.loads((sessions / f'{thread_id}.json').read_text())


for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if 'id' not in request:
        continue
    params = request.get('params') or {}
    thread_id = params.get('threadId')
    with (root / 'home-events.jsonl').open('a') as log:
        log.write(json.dumps({'home': str(home), 'method': method, 'threadId': thread_id,
                              'ephemeral': params.get('ephemeral')}) + '\n')
    try:
        if method == 'initialize':
            result = {'platformOs': 'macos'}
        elif method in ('thread/start', 'thread/fork'):
            thread = read_thread(thread_id) if thread_id else {
                'name': 'Native fixture', 'status': {'type': 'idle'},
                'cwd': params.get('cwd'), 'turns': []}
            thread = {**thread, 'id': str(uuid.uuid4())}
            if params.get('ephemeral'):
                ephemeral[thread['id']] = thread
            else:
                (sessions / f'{thread["id"]}.json').write_text(json.dumps(thread))
            result = {'thread': thread}
        elif method in ('thread/resume', 'thread/read'):
            result = {'thread': read_thread(thread_id)}
        elif method == 'thread/list':
            result = {'data': [json.loads(p.read_text()) for p in sessions.glob('*.json')],
                      'nextCursor': None}
        elif method == 'account/read':
            result = {'account': None, 'requiresOpenaiAuth': True}
        elif method == 'config/read':
            result = {'config': {}}
        elif method.startswith('account/'):
            result = {}
        else:
            result = {'data': []}
        print(json.dumps({'id': request['id'], 'result': result}), flush=True)
    except FileNotFoundError:
        print(json.dumps({'id': request['id'], 'error': {
            'code': -32000, 'message': 'Session does not exist in this Codex home'}}), flush=True)
