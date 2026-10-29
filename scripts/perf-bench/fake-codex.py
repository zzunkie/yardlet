#!/usr/bin/python3
"""A stand-in for `codex app-server` for the performance bench (scripts/perf-bench/run.sh).

It speaks the App Server's JSON-RPC lines on stdin and stdout, as the real one does, and asks no model
anything: no network, no shell command, no account. A resumed thread is read from
`<bench>/threads/<thread id>.json` (written by the app's perf fixture, `PerfBenchFixture`), and a turn
does what its request says:

  perf hold                 the turn starts, its reasoning starts, and it runs until interrupted
  perf stream <seconds> [n] reasoning, commands with output and answers stream into the turn for
                            that long (about 30 frames a second, as a working agent sends them),
                            then the turn completes; with n, the turn first holds n finished
                            commands with output, as a long turn of a subagent does

The streamed shapes are those `ConcurrentStreamingPerformanceTests` (LongCodexDriver) sends through
the fake transport there. Anything else gets an empty answer.
"""
import json
import os
from pathlib import Path
import sys
import threading
import time

if '--version' in sys.argv:
    print('codex-cli 0.160.0')
    sys.exit(0)

bench = Path(__file__).resolve().parent.parent
(bench / 'logs').mkdir(exist_ok=True)
journal = open(bench / 'logs' / f'codex-{os.getpid()}.log', 'a', buffering=1)
lock = threading.Lock()
threads = {}
active = {}  # thread id -> turn id
counter = 0


def send(value):
    line = json.dumps(value, ensure_ascii=False)
    with lock:
        sys.stdout.write(line + '\n')
        sys.stdout.flush()
        if 'id' in value and 'method' not in value:
            journal.write(f'{time.time():.3f} answered {value["id"]}\n')


def notify(method, thread_id, **params):
    send({'method': method, 'params': {'threadId': thread_id, **params}})


def respond(request, result):
    send({'id': request['id'], 'result': result})


def thread(thread_id, cwd):
    if thread_id not in threads:
        path = bench / 'threads' / f'{thread_id}.json'
        turns = json.loads(path.read_text()) if path.exists() else []
        threads[thread_id] = {'id': thread_id, 'preview': 'Performance bench', 'cwd': cwd,
                              'status': {'type': 'idle'}, 'turns': turns}
    return threads[thread_id]


def without_turns(state):
    return {key: value for key, value in state.items() if key != 'turns'}


def turn_page(turns, before, limit):
    """Up to `limit` turns before index `before`, newest first, and the cursor to the ones before them."""
    start = max(0, before - limit)
    page = list(reversed(turns[start:before]))
    return {'data': page, 'nextCursor': f'turns:{start}' if start > 0 else None, 'backwardsCursor': None}


def text(length, seed):
    words = f'{seed} reads the module, checks the failing case and explains the change. '
    return (words * (length // len(words) + 1))[:length]


def command(item_id, status, output):
    return {'id': item_id, 'type': 'commandExecution', 'command': 'swift build', 'cwd': '/tmp/workspace',
            'processId': None, 'source': 'agent', 'status': status, 'commandActions': [],
            'aggregatedOutput': output, 'exitCode': None if output is None else 0, 'durationMs': None}


def stream_item(thread_id, turn_id, item_id, kind, rate, seconds, deadline):
    if kind == 'reasoning':
        started = {'id': item_id, 'type': kind, 'summary': [], 'content': []}
    elif kind == 'agentMessage':
        started = {'id': item_id, 'type': kind, 'text': ''}
    else:
        started = command(item_id, 'inProgress', None)
    notify('item/started', thread_id, turnId=turn_id, item=started)
    written = ''
    step = 0
    end = min(deadline, time.monotonic() + seconds)
    while time.monotonic() < end and active.get(thread_id) == turn_id:
        step += 1
        if kind == 'commandExecution':
            fragment = f'[{step}/400] Compiling Module{step}.swift and linking its objects\n'
        elif step % 25 == 0:
            fragment = f'\n\n- point {step} '
        else:
            fragment = f'{item_id}-{step} streamed words, '
        written += fragment
        if kind == 'reasoning':
            notify('item/reasoning/summaryTextDelta', thread_id, turnId=turn_id, itemId=item_id, delta=fragment,
                   summaryIndex=0)
        elif kind == 'agentMessage':
            notify('item/agentMessage/delta', thread_id, turnId=turn_id, itemId=item_id, delta=fragment)
        else:
            notify('item/commandExecution/outputDelta', thread_id, turnId=turn_id, itemId=item_id, delta=fragment)
        time.sleep(1 / rate)
    if kind == 'reasoning':
        completed = {'id': item_id, 'type': kind, 'summary': [written], 'content': []}
    elif kind == 'agentMessage':
        completed = {'id': item_id, 'type': kind, 'text': written}
    else:
        completed = command(item_id, 'completed', written)
    notify('item/completed', thread_id, turnId=turn_id, item=completed)
    return completed


def stream(thread_id, turn, seconds, burst=0):
    turn_id = turn['id']
    for index in range(burst):
        item = command(f'{turn_id}-done-{index}', 'completed', text(1_500, f'{turn_id}-done-{index}'))
        turn['items'].append(item)
        notify('item/completed', thread_id, turnId=turn_id, item=item)
        if index % 20 == 19:
            time.sleep(0.01)
    deadline = time.monotonic() + seconds
    pattern = [('reasoning', 20, 2), ('commandExecution', 40, 4), ('agentMessage', 30, 4),
               ('commandExecution', 40, 2), ('agentMessage', 30, 2)]
    index = 0
    while time.monotonic() < deadline and active.get(thread_id) == turn_id:
        kind, rate, length = pattern[index % len(pattern)]
        turn['items'].append(stream_item(thread_id, turn_id, f'{turn_id}-{index}', kind, rate, length, deadline))
        index += 1
    if active.get(thread_id) == turn_id:
        del active[thread_id]
        turn['status'] = 'completed'
        notify('turn/completed', thread_id, turn={**turn, 'items': []})


def start_turn(request):
    global counter
    params = request.get('params', {})
    thread_id = params.get('threadId', 'perf-thread')
    state = thread(thread_id, params.get('cwd', '/tmp'))
    words = ' '.join(part.get('text', '') for part in params.get('input', []) if isinstance(part, dict)).split()
    counter += 1
    turn_id = f'perf-{os.getpid()}-{counter}'
    request_item = {'id': f'{turn_id}-request', 'type': 'userMessage', 'content': params.get('input', [])}
    turn = {'id': turn_id, 'status': 'inProgress', 'itemsView': 'full', 'items': [request_item],
            'startedAt': int(time.time())}
    state['turns'].append(turn)
    active[thread_id] = turn_id
    respond(request, {'turn': {**turn, 'items': []}})
    notify('turn/started', thread_id, turn={**turn, 'items': []})
    notify('item/completed', thread_id, turnId=turn_id, item=request_item)
    if words[:2] == ['perf', 'stream']:
        seconds = float(words[2]) if len(words) > 2 else 30
        burst = int(words[3]) if len(words) > 3 else 0
        threading.Thread(target=stream, args=(thread_id, turn, seconds, burst), daemon=True).start()
    else:
        notify('item/started', thread_id, turnId=turn_id,
               item={'id': f'{turn_id}-thinking', 'type': 'reasoning', 'summary': [], 'content': []})


for line in sys.stdin:
    try:
        request = json.loads(line)
    except ValueError:
        continue
    method = request.get('method')
    journal.write(f'{time.time():.3f} received {method} {request.get("id")}\n')
    if method is None or 'id' not in request:
        continue
    params = request.get('params') or {}
    if method == 'initialize':
        respond(request, {'platformOs': 'macos', 'userAgent': 'codex-cli 0.160.0'})
    elif method in ('thread/resume', 'thread/read', 'thread/start'):
        thread_id = params.get('threadId') or f'perf-new-{os.getpid()}'
        state = thread(thread_id, params.get('cwd', '/tmp'))
        if method == 'thread/resume' and params.get('excludeTurns'):
            page = params.get('initialTurnsPage') or {}
            result = {'thread': without_turns(state)}
            if page:
                result['initialTurnsPage'] = turn_page(state['turns'], len(state['turns']), int(page.get('limit', 3)))
            respond(request, result)
        elif method == 'thread/read' and not params.get('includeTurns', True):
            respond(request, {'thread': without_turns(state)})
        else:
            respond(request, {'thread': state})
    elif method == 'thread/turns/list':
        state = thread(params.get('threadId', 'perf-thread'), '/tmp')
        cursor = params.get('cursor') or ''
        before = int(cursor.split(':')[1]) if cursor.startswith('turns:') else len(state['turns'])
        page = turn_page(state['turns'], before, int(params.get('limit') or 10))
        if params.get('sortDirection') == 'asc':
            page['data'] = list(reversed(page['data']))
        respond(request, page)
    elif method == 'turn/start':
        start_turn(request)
    elif method == 'turn/interrupt':
        thread_id = params.get('threadId', 'perf-thread')
        turn_id = active.pop(thread_id, None)
        respond(request, {})
        if turn_id:
            notify('turn/completed', thread_id, turn={'id': turn_id, 'status': 'interrupted', 'items': []})
    elif method == 'config/read':
        respond(request, {'config': {}})
    else:
        respond(request, {'data': []})
