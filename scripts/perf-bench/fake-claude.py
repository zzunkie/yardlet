#!/usr/bin/python3
"""A stand-in for `claude --print --output-format stream-json` for the performance bench
(scripts/perf-bench/run.sh).

It reads the stream-json frames Yardlet writes on stdin and answers in Claude Code's own frame shapes,
with partial messages, and asks no model anything: no network, no shell command, no account. A message
does what it says:

  perf hold                 the turn starts and thinks, and runs until stdin closes
  perf stream <seconds>     thinking, answer text, and a Bash call with its output, over and over for
                            that long (about 30 fragments a second), then the turn's result

Control requests (the handshake, permission mode changes) are answered with success.
"""
import json
import os
from pathlib import Path
import sys
import threading
import time
import uuid

if '--version' in sys.argv:
    print('2.1.291 (Claude Code)')
    sys.exit(0)

session_id = next((argument.split('=', 1)[1] for argument in sys.argv
                   if argument.startswith(('--session-id=', '--resume='))), str(uuid.uuid4()))
lock = threading.Lock()
running = threading.Event()
logs = Path(__file__).resolve().parent.parent / 'logs'
logs.mkdir(exist_ok=True)
journal = open(logs / f'claude-{os.getpid()}.log', 'a', buffering=1)
journal.write(f'{time.time():.3f} started {" ".join(sys.argv[1:])}\n')


def send(value):
    value.setdefault('session_id', session_id)
    value.setdefault('uuid', str(uuid.uuid4()))
    line = json.dumps(value, ensure_ascii=False)
    with lock:
        sys.stdout.write(line + '\n')
        sys.stdout.flush()


def event(value):
    send({'type': 'stream_event', 'parent_tool_use_id': None, 'event': value})


def assistant(blocks):
    send({'type': 'assistant', 'parent_tool_use_id': None,
          'message': {'id': f'msg_{uuid.uuid4().hex[:12]}', 'type': 'message', 'role': 'assistant',
                      'model': 'claude-opus-5-5', 'content': blocks, 'stop_reason': None,
                      'usage': {'input_tokens': 3, 'output_tokens': 120, 'cache_read_input_tokens': 40000}}})


def deltas(kind, seconds, rate, deadline, seed):
    """Streams one content block for `seconds` and returns its text."""
    event({'type': 'content_block_start', 'index': 0,
           'content_block': {'type': kind, kind: ''} if kind == 'thinking' else {'type': 'text', 'text': ''}})
    written = ''
    step = 0
    end = min(deadline, time.monotonic() + seconds)
    while time.monotonic() < end:
        step += 1
        fragment = f'\n\n- point {step} ' if step % 25 == 0 else f'{seed}-{step} streamed words, '
        written += fragment
        delta = {'type': 'thinking_delta', 'thinking': fragment} if kind == 'thinking' \
            else {'type': 'text_delta', 'text': fragment}
        event({'type': 'content_block_delta', 'index': 0, 'delta': delta})
        time.sleep(1 / rate)
    event({'type': 'content_block_stop', 'index': 0})
    return written


def stream(seconds):
    deadline = time.monotonic() + seconds
    call = 0
    while time.monotonic() < deadline:
        call += 1
        event({'type': 'message_start', 'message': {'id': f'msg_{call}', 'role': 'assistant', 'content': []}})
        thinking = deltas('thinking', 1, 30, deadline, f'thinking{call}')
        assistant([{'type': 'thinking', 'thinking': thinking, 'signature': 's'}])
        answer = deltas('text', 2, 30, deadline, f'answer{call}')
        assistant([{'type': 'text', 'text': answer}])
        tool_id = f'toolu_perf_{call}_{uuid.uuid4().hex[:8]}'
        assistant([{'type': 'tool_use', 'id': tool_id, 'name': 'Bash',
                    'input': {'command': 'swift test --filter ParserTests', 'description': 'Run the parser tests'}}])
        time.sleep(0.5)
        output = '\n'.join(f'[{line}/40] Compiling Module{line}.swift' for line in range(1, 41))
        send({'type': 'user', 'parent_tool_use_id': None,
              'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool_id,
                                                       'content': output}]}})
    event({'type': 'message_start', 'message': {'id': 'msg_last', 'role': 'assistant', 'content': []}})
    assistant([{'type': 'text', 'text': 'The parser tests pass now.'}])
    send({'type': 'result', 'subtype': 'success', 'is_error': False, 'duration_ms': int(seconds * 1000),
          'num_turns': call, 'result': 'The parser tests pass now.',
          'usage': {'input_tokens': 3, 'output_tokens': 120 * call, 'cache_read_input_tokens': 40000}})
    running.clear()


def hold():
    event({'type': 'message_start', 'message': {'id': 'msg_hold', 'role': 'assistant', 'content': []}})
    event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'thinking', 'thinking': ''}})
    event({'type': 'content_block_delta', 'index': 0,
           'delta': {'type': 'thinking_delta', 'thinking': 'Reading the parser before changing it.'}})


for line in sys.stdin:
    try:
        frame = json.loads(line)
    except ValueError:
        continue
    journal.write(f'{time.time():.3f} received {frame.get("type")} {(frame.get("request") or {}).get("subtype", "")}\n')
    if frame.get('type') == 'control_request':
        request = frame.get('request') or {}
        response = {'commands': [], 'models': [], 'output_style': 'default'} \
            if request.get('subtype') == 'initialize' else {}
        send({'type': 'control_response', 'response': {
            'subtype': 'success', 'request_id': frame.get('request_id'), 'response': response}})
        continue
    if frame.get('type') != 'user' or running.is_set():
        continue
    content = frame.get('message', {}).get('content', '')
    if isinstance(content, list):
        content = ''.join(block.get('text', '') for block in content if isinstance(block, dict))
    words = content.split()
    running.set()
    send({'type': 'system', 'subtype': 'init', 'cwd': '', 'tools': ['Bash', 'Read', 'Edit'],
          'model': 'claude-opus-5-5', 'permissionMode': 'default', 'apiKeySource': 'none'})
    if words[:2] == ['perf', 'stream']:
        seconds = float(words[2]) if len(words) > 2 else 30
        threading.Thread(target=stream, args=(seconds,), daemon=True).start()
    else:
        hold()
