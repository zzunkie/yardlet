#!/usr/bin/env python3
"""Provider-free Codex App Server for usage resets. Copy into a temporary directory to run.

Each account is a CODEX_HOME holding `account.json` (its plan), `rate-limits.json` (the
`account/rateLimits/read` result) and optionally `consume.json` (how
`account/rateLimitResetCredit/consume` answers: `{"outcome": ...}` or `{"error": ...}`). A
`reset` outcome takes the reset the request names, or the first one, and lowers the count, so a
later read shows it. Every consume request's params are appended to `consume-requests.jsonl` in
that home. Nothing else is recorded.
"""
import json
import os
from pathlib import Path
import sys

if '--version' in sys.argv:
    print('codex-cli 0.163.0')
    sys.exit(0)

home = Path(os.environ['CODEX_HOME'])


def read(name, default):
    path = home / name
    return json.loads(path.read_text()) if path.exists() else default


for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request.get('method')
    params = request.get('params') or {}
    reply = {'id': request['id']}
    if method == 'initialize':
        reply['result'] = {'platformOs': 'macos'}
    elif method == 'account/read':
        account = read('account.json', {'planType': 'pro'})
        reply['result'] = {'account': {'type': 'chatgpt', 'email': account.get('email', 'owner@example.test'),
                                       'planType': account['planType']},
                           'requiresOpenaiAuth': True}
    elif method == 'account/rateLimits/read':
        reply['result'] = read('rate-limits.json', {'rateLimits': {}})
    elif method == 'account/rateLimitResetCredit/consume':
        with (home / 'consume-requests.jsonl').open('a') as log:
            log.write(json.dumps(params) + '\n')
        answer = read('consume.json', {'outcome': 'reset'})
        if 'error' in answer:
            reply['error'] = answer['error']
        else:
            reply['result'] = {'outcome': answer['outcome']}
            if answer['outcome'] == 'reset':
                limits = read('rate-limits.json', {})
                summary = limits.get('rateLimitResetCredits') or {'availableCount': 0, 'credits': []}
                credits = summary.get('credits') or []
                used = next((c for c in credits if c['id'] == params.get('creditId')), credits[0] if credits else None)
                summary['credits'] = [c for c in credits if c is not used]
                summary['availableCount'] = max(0, summary['availableCount'] - 1)
                limits['rateLimitResetCredits'] = summary
                (home / 'rate-limits.json').write_text(json.dumps(limits))
    elif method.startswith('account/'):
        reply['result'] = {}
    else:
        reply['error'] = {'code': -32601, 'message': f'{method} is not part of this fixture'}
    print(json.dumps(reply), flush=True)
