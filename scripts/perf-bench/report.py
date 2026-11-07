#!/usr/bin/python3
"""Collects a performance bench run (scripts/perf-bench/run.sh) into one result and compares it with an
earlier one.

  report.py collect <run folder> <result.json> [--compare <earlier result.json>] [--tolerance 0.15]
      [--budgets budgets.json]
  report.py compare <earlier result.json> <result.json> [--tolerance 0.15] [--budgets budgets.json]

A run folder has meta.json, scenes/<scene>/<round>/{scene.json, run.json, samples/<n>-<phase>.json} and
micro.jsonl. Every number in a result is a cost, so a larger value is worse, and its name ends in its
unit: Ms, Percent, MiB, PerSecond or Count. A number is marked worse when it grew by more than the
tolerance and by more than its unit's floor (FLOORS), so that noise around small values is not.

budgets.json holds each phase's limits, '<scene>/<phase>': {'<number>': <largest allowed>}. A number over
its limit, a limited number the run did not measure, or a scene's problem fails the run: the result's
`budgets` lists them and the command exits with status 1.
"""
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import sys

FLOORS = {'Ms': 2.0, 'Percent': 1.0, 'MiB': 15.0, 'PerSecond': 20.0, 'Count': 2.0}
LAUNCH_FLOOR_MS = 50.0
# The numbers the summary table shows for each phase; the rest are compared all the same.
HEADLINE = ['process.yardletCPUPercent', 'process.appFootprintMiB', 'mainThread.cpuPercent',
            'mainThread.passP95Ms', 'mainThread.passesOver50MsCount', 'frames.missedPercent', 'frames.latenessP95Ms',
            'events.codexState.cpuP95Ms', 'events.transcriptPublication.cpuP95Ms', 'events.agentRunState.cpuP95Ms',
            'events.agentRunEvent.cpuP95Ms', 'switches.longestPassMedianMs', 'memory.footprintGrowthMiB',
            'memory.retainedGrowthMiB', 'process.yardletPeakFootprintMiB',
            'input.responseMedianMs', 'input.responseP95Ms', 'input.responseMaxMs']


def unit(name):
    for suffix in FLOORS:
        if name.endswith(suffix):
            return suffix
    return None


def floor(name):
    if name.startswith('launch.'):
        return LAUNCH_FLOOR_MS
    return FLOORS.get(unit(name), 0)


def process_numbers(sample, app_pid):
    """The app's own process, the browser engine's processes, and the agent CLIs it runs (the fakes)."""
    groups = {'app': [], 'browser': [], 'agents': []}
    for process in sample.get('processes', []):
        path = process.get('path', '')
        if process.get('pid') == app_pid:
            groups['app'].append(process)
        elif 'Yardlet Browser Host' in path:
            groups['browser'].append(process)
        else:
            groups['agents'].append(process)

    def total(group, key):
        return round(sum(process.get(key, 0) for process in groups[group]), 2)

    numbers = {
        'appCPUPercent': total('app', 'cpuPercent'),
        'appFootprintMiB': total('app', 'footprintMiB'),
        'appResidentMiB': total('app', 'residentMiB'),
        'appWakeupsPerSecond': total('app', 'wakeupsPerSecond'),
        'browserCPUPercent': total('browser', 'cpuPercent'),
        'browserFootprintMiB': total('browser', 'footprintMiB'),
        'agentCPUPercent': total('agents', 'cpuPercent'),
    }
    numbers['yardletCPUPercent'] = round(numbers['appCPUPercent'] + numbers['browserCPUPercent'], 2)
    numbers['yardletFootprintMiB'] = round(numbers['appFootprintMiB'] + numbers['browserFootprintMiB'], 2)
    numbers['browserProcessCount'] = sum(process.get('isRunning', True) for process in groups['browser'])
    # The main process has one identity. A sum of other processes' individual peaks is not
    # a simultaneous browser peak, so their raw samples stay in roundData instead.
    for key, value in sample.get('aggregate', {}).items():
        if key in ('appPeakFootprintMiB', 'browserPeakFootprintMiB', 'yardletPeakFootprintMiB'):
            numbers[key] = value
    return numbers


def flatten(prefix, value, into):
    if isinstance(value, dict):
        for key, inner in value.items():
            flatten(f'{prefix}.{key}' if prefix else key, inner, into)
    elif isinstance(value, (int, float)) and not isinstance(value, bool) and unit(prefix):
        into[prefix] = value


def read_json(path, problems, label):
    try:
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise ValueError('expected an object')
        return value
    except (OSError, ValueError) as error:
        problems.append(f'{label}: {error}')
        return None


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def collect_round(folder, required_phases=(), required_metrics=None):
    problems = []
    scene = read_json(folder / 'scene.json', problems, 'scene result')
    run = read_json(folder / 'run.json', problems, 'run metadata') or {}
    if scene is None:
        return {'launch': {}, 'phases': {}, 'problems': problems, 'loadBefore': run.get('loadBefore'), 'extra': {}}
    samples = {}
    for path in sorted((folder / 'samples').glob('*.json')):
        try:
            samples[path.stem.split('-', 1)[1]] = json.loads(path.read_text())
        except (ValueError, IndexError, OSError) as error:
            problems.append(f'process sample {path.name}: {error}')
    phases = {}
    for phase in scene.get('phases', []):
        numbers = {}
        flatten('mainThread', phase.get('mainThread', {}), numbers)
        flatten('frames', phase.get('frames', {}), numbers)
        flatten('events', phase.get('events', {}), numbers)
        flatten('switches', phase.get('switches', {}), numbers)
        flatten('memory', phase.get('memory', {}), numbers)
        flatten('bodies', phase.get('bodies', {}), numbers)
        flatten('input', phase.get('input', {}), numbers)
        if phase['name'] in samples:
            flatten('process', process_numbers(samples[phase['name']], scene.get('pid')), numbers)
        name = phase['name']
        if name in phases:
            problems.append(f'duplicate phase: {name}')
        if required_phases and phase.get('sampled') is not True:
            problems.append(f'{name}: sampler did not start')
        if required_phases and name not in samples:
            problems.append(f'{name}: no process sample')
        elif required_phases and not any(process.get('pid') == scene.get('pid')
                                         and finite(process.get('footprintMiB'))
                                         and finite(process.get('cpuPercent'))
                                         for process in samples[name].get('processes', [])):
            problems.append(f'{name}: no valid root process reading')
        for metric, value in numbers.items():
            if not finite(value):
                problems.append(f'{name}/{metric}: not a finite measurement')
        for metric in (required_metrics or {}).get(name, []):
            if not finite(numbers.get(metric)):
                problems.append(f'{name}/{metric}: required measurement missing or not finite')
        phases[name] = {
            'numbers': numbers,
            'notes': {'sampled': phase.get('sampled'), 'published': phase.get('published'),
                      'shownTaskItems': phase.get('shownTaskItems'), 'shownTaskRunning': phase.get('shownTaskRunning'),
                      'objectsAtStart': phase.get('objectsAtStart'), 'objectsAtEnd': phase.get('objectsAtEnd')},
        }
    launch = {}
    flatten('launch', scene.get('launch', {}), launch)
    for metric, value in launch.items():
        if not finite(value):
            problems.append(f'{metric}: not a finite measurement')
    for name in required_phases:
        if name not in phases:
            problems.append(f'missing phase: {name}')
    return {'launch': launch, 'phases': phases, 'problems': scene.get('problems', []) + problems,
            'processSamples': samples,
            'loadBefore': run.get('loadBefore'), 'reopens': run.get('reopens'),
            'extra': {key: scene[key] for key in ('window', 'screen', 'sidebar', 'browser', 'memoryCycle', 'diagnostics') if key in scene}}


def median_of(rounds, pick):
    values = [pick(r) for r in rounds]
    values = [v for v in values if finite(v)]
    return round(statistics.median(values), 2) if values else None


def collect(folder):
    meta = json.loads((folder / 'meta.json').read_text())
    result = {'version': 2, **meta, 'scenes': {}, 'micro': {}, 'problems': []}
    plan = meta.get('plan')
    if not isinstance(plan, dict) or not isinstance(plan.get('scenes'), dict) or not isinstance(plan.get('micro'), list):
        result['problems'].append('missing or invalid run plan')
        plan = None
    elif not plan['scenes'] and not plan['micro']:
        result['problems'].append('no benchmarks were planned')
    if not isinstance(meta.get('repeat'), int) or isinstance(meta.get('repeat'), bool) or meta['repeat'] < 1:
        result['problems'].append('repeat must be a positive integer')
        meta['repeat'] = 1
    scene_names = list(plan['scenes']) if plan else [p.name for p in (folder / 'scenes').glob('*') if p.is_dir()]
    if plan and scene_names:
        result['artifact'] = read_json(folder / 'artifact.json', result['problems'], 'measured artifact')
        if result['artifact'] is not None:
            for key in ('executableSHA256', 'qaExecutableSHA256', 'diffSHA256', 'sourceSHA256'):
                if not re.fullmatch(r'[0-9a-f]{64}', str(result['artifact'].get(key, ''))):
                    result['problems'].append(f'measured artifact: missing or invalid {key}')
    for scene_name in scene_names:
        scene_folder = folder / 'scenes' / scene_name
        round_count = meta.get('repeat', 1)
        round_paths = [scene_folder / str(i) for i in range(1, round_count + 1)]
        if not plan:
            round_paths = sorted(p for p in scene_folder.iterdir() if p.is_dir())
        if not round_paths:
            round_paths = [scene_folder / '1']
        required_phases = plan['scenes'][scene_name] if plan else []
        required_metrics = plan.get('metrics', {}).get(scene_name, {}) if plan else {}
        rounds = [collect_round(p, required_phases, required_metrics) for p in round_paths]
        scene = {'rounds': len(rounds), 'launch': {}, 'phases': {},
                 'problems': [f'round {i}: {p}' for i, r in enumerate(rounds, 1) for p in r['problems']],
                 'loadBefore': [r['loadBefore'] for r in rounds], 'extra': rounds[-1]['extra']}
        scene['roundData'] = rounds
        scene['completedRounds'] = sum(not r['problems'] for r in rounds)
        for name in sorted({k for r in rounds for k in r['launch']}):
            scene['launch'][name] = median_of(rounds, lambda r: r['launch'].get(name))
        for phase in sorted({k for r in rounds for k in r['phases']}):
            numbers = {}
            for name in sorted({k for r in rounds for k in r['phases'].get(phase, {}).get('numbers', {})}):
                numbers[name] = median_of(rounds, lambda r: r['phases'].get(phase, {}).get('numbers', {}).get(name))
            notes = next(r['phases'][phase]['notes'] for r in reversed(rounds) if phase in r['phases'])
            scene['phases'][phase] = {'numbers': numbers, 'notes': notes}
        result['scenes'][scene_name] = scene
    micro = folder / 'micro.jsonl'
    if micro.exists():
        grouped = {}
        for index, line in enumerate(micro.read_text().splitlines(), 1):
            try:
                record = json.loads(line)
                if not isinstance(record.get('name'), str) or not isinstance(record.get('metrics'), dict):
                    raise ValueError('expected a named metrics record')
            except (ValueError, AttributeError) as error:
                result['problems'].append(f'micro record {index}: {error}')
                continue
            for key, value in record.get('metrics', {}).items():
                if not finite(value):
                    result['problems'].append(f'micro/{record["name"]}/{key}: not a finite measurement')
                    continue
                grouped.setdefault(record['name'], {}).setdefault(key, []).append(value)
        result['micro'] = {name: {key: round(statistics.median(values), 3) for key, values in metrics.items()}
                           for name, metrics in grouped.items()}
    if plan and plan.get('micro'):
        result['microRun'] = read_json(folder / 'micro-status.json', result['problems'], 'micro run status')
        if result['microRun'] is not None and result['microRun'].get('exitCode') != 0:
            result['problems'].append(f'micro tests exited with {result["microRun"].get("exitCode")}')
        cases = {}
        try:
            for line in (folder / 'micro.log').read_text().splitlines():
                match = re.match(r"Test Case '-\[[^ ]+\.([^ .]+) ([^\]]+)\]' (passed|failed|skipped) ", line)
                if match:
                    cls, test, state = match.groups()
                    cases.setdefault(f'{cls}/{test}', []).append(state)
        except OSError as error:
            result['problems'].append(f'micro test output: {error}')
        result['microTests'] = cases
        for required in plan['micro']:
            if not cases.get(required['test']) or any(state != 'passed' for state in cases[required['test']]):
                result['problems'].append(f'micro test did not pass: {required["test"]}')
            for name in required['records']:
                if not result['micro'].get(name):
                    result['problems'].append(f'missing micro measurement: {name}')
    return result


def numbers(result):
    """Every comparable number of a result, by '<scene>/<phase> <metric>' or 'micro/<name> <metric>'."""
    found = {}
    for scene, value in result.get('scenes', {}).items():
        for name, number in value.get('launch', {}).items():
            found[(f'{scene}/launch', name)] = number
        for phase, data in value.get('phases', {}).items():
            for name, number in data.get('numbers', {}).items():
                found[(f'{scene}/{phase}', name)] = number
    for name, metrics in result.get('micro', {}).items():
        for key, number in metrics.items():
            found[(f'micro/{name}', key)] = number
    return found


def compare(earlier, now, tolerance):
    before, after = numbers(earlier), numbers(now)
    worse, better = [], []
    for key, value in after.items():
        old = before.get(key)
        if not finite(old) or not finite(value):
            continue
        change = value - old
        relative = change / old if old else (float('inf') if change > 0 else 0)
        entry = {'where': key[0], 'metric': key[1], 'before': old, 'after': value,
                 'change': round(relative * 100, 1) if old else None}
        if change > floor(key[1]) and relative > tolerance:
            worse.append(entry)
        elif -change > floor(key[1]) and -relative > tolerance:
            better.append(entry)
    return {'against': earlier.get('file'), 'againstCommit': earlier.get('commit'), 'tolerance': tolerance,
            'worse': worse, 'better': better}


def check_budgets(result, budgets):
    """Each limit of a scene that ran: over it, or not measured. A scene's problems fail it too."""
    failures, checked = [], 0
    for where, limits in budgets.items():
        scene, phase = where.split('/', 1)
        data = result.get('scenes', {}).get(scene)
        if data is None:
            continue
        values = data.get('launch', {}) if phase == 'launch' else data.get('phases', {}).get(phase, {}).get('numbers', {})
        for name, limit in limits.items():
            checked += 1
            value = values.get(name)
            if not finite(value):
                failures.append({'where': where, 'metric': name, 'limit': limit, 'value': None})
            elif value > limit:
                failures.append({'where': where, 'metric': name, 'limit': limit, 'value': value})
            # Budgets use the median of repeats. Every planned repeat must nevertheless
            # contain the measurement; one missing value must not be hidden by that median.
            for index, run in enumerate(data.get('roundData', []), 1):
                round_values = run.get('launch', {}) if phase == 'launch' else run.get('phases', {}).get(phase, {}).get('numbers', {})
                if not finite(round_values.get(name)):
                    failures.append({'where': f'{where} round {index}', 'metric': name, 'limit': limit, 'value': None})
    for scene, data in result.get('scenes', {}).items():
        for problem in data.get('problems', []):
            failures.append({'where': scene, 'metric': 'problem', 'limit': None, 'value': problem})
    for problem in result.get('problems', []):
        failures.append({'where': 'run', 'metric': 'problem', 'limit': None, 'value': problem})
    return {'checked': checked, 'failures': failures}


def show(result, comparison):
    print(f"\nYardlet performance bench at {result.get('commit')}{' (uncommitted changes)' if result.get('dirty') else ''}, "
          f"{result.get('machine', {}).get('chip', '')}, load {result.get('loadAtStart')} at the start")
    before = numbers(comparison['earlier']) if comparison else {}
    marks = {(e['where'], e['metric']): '▲ worse' for e in (comparison or {}).get('worse', [])}
    marks.update({(e['where'], e['metric']): '▼ better' for e in (comparison or {}).get('better', [])})
    rows = []
    for scene, value in result.get('scenes', {}).items():
        for name, number in value.get('launch', {}).items():
            if name in ('launch.processStartToFirstFrameMs', 'launch.processStartToSettledMs'):
                rows.append((f'{scene}/launch', name, number))
        for phase, data in value.get('phases', {}).items():
            for name in HEADLINE:
                if name in data['numbers']:
                    rows.append((f'{scene}/{phase}', name, data['numbers'][name]))
        for problem in value.get('problems', []):
            rows.append((scene, 'PROBLEM', problem))
    for name, metrics in result.get('micro', {}).items():
        for key, number in metrics.items():
            rows.append((f'micro/{name}', key, number))
    width = max((len(r[0]) for r in rows), default=10)
    metric_width = max((len(r[1]) for r in rows), default=10)
    print(f"{'where':<{width}}  {'number':<{metric_width}}  {'before':>9}  {'now':>9}")
    for where, name, number in rows:
        old = before.get((where, name))
        old_text = '' if old is None else f'{old:9.2f}'
        now_text = f'{number:9.2f}' if isinstance(number, (int, float)) else str(number)
        print(f"{where:<{width}}  {name:<{metric_width}}  {old_text:>9}  {now_text:>9}  {marks.get((where, name), '')}")
    if comparison:
        hidden = [e for e in comparison['worse'] if (e['where'], e['metric']) not in {(r[0], r[1]) for r in rows}]
        for entry in hidden:
            print(f"{entry['where']:<{width}}  {entry['metric']:<{metric_width}}  {entry['before']:9.2f}  "
                  f"{entry['after']:9.2f}  ▲ worse")
        print(f"\nCompared with {comparison['againstCommit']} ({comparison['against']}): "
              f"{len(comparison['worse'])} worse, {len(comparison['better'])} better, "
              f"by more than {int(comparison['tolerance'] * 100)}% and the unit's floor.")
        before_load, now_load = comparison['earlier'].get('loadAtStart'), result.get('loadAtStart')
        if before_load and now_load and abs(now_load - before_load) > max(3, 0.3 * min(now_load, before_load)):
            print(f"The Mac was busier in one run (load {before_load} then {now_load} at the start): times and CPU move "
                  "with load, so run both again at a similar load before reading a number as a change.")
    else:
        print('\nNo earlier result to compare with.')
    budgets = result.get('budgets')
    if budgets:
        print(f"Budgets: {budgets['checked']} limits checked, {len(budgets['failures'])} failed.")
        for failure in budgets['failures']:
            if failure['metric'] == 'problem':
                print(f"  FAILED {failure['where']}: {failure['value']}")
            elif failure['value'] is None:
                print(f"  FAILED {failure['where']} {failure['metric']}: not measured (limit {failure['limit']})")
            else:
                print(f"  FAILED {failure['where']} {failure['metric']}: {failure['value']} over {failure['limit']}")


def option(arguments, name, default=None):
    if name in arguments:
        index = arguments.index(name)
        return arguments[index + 1]
    return default


def source_state(root):
    """Identify checkout inputs, including untracked sources but not ignored build output."""
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args])
    digest = hashlib.sha256()
    names = sorted(set(git('ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')) - {b''})
    for name in names:
        path = root / name.decode()
        digest.update(name + b'\0')
        if path.is_symlink():
            digest.update(str(path.readlink()).encode())
        elif path.is_file():
            digest.update(path.read_bytes())
        else:
            digest.update(b'<missing>')
        digest.update(b'\0')
    return {'commit': git('rev-parse', 'HEAD').decode().strip(),
            'diffSHA256': hashlib.sha256(git('diff', '--binary', 'HEAD')).hexdigest(),
            'sourceSHA256': digest.hexdigest()}


def artifact_identity(root, app, built_source=None):
    executable = app / 'Contents' / 'MacOS' / 'Yardlet'
    identity = {'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(), **source_state(root)}
    manifest = Path(str(app) + '.perf-bench.json')
    if built_source:
        if json.loads(built_source.read_text()) != source_state(root):
            raise ValueError('checkout inputs changed during the build; build again before measuring')
        identity['configuration'] = 'debug'
        manifest.write_text(json.dumps(identity, indent=2) + '\n')
    else:
        if not manifest.exists():
            raise ValueError('the app has no benchmark build identity; use --build')
        previous = json.loads(manifest.read_text())
        if any(previous.get(key) != value for key, value in identity.items()):
            raise ValueError('the app or checkout differs from its benchmark build identity; use --build')
        identity['configuration'] = previous['configuration']
    return {**identity, 'builtByThisRun': built_source is not None}


def json_safe(value):
    """Keep failed non-finite readings as null rather than write nonstandard JSON."""
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, dict):
        return {key: json_safe(inner) for key, inner in value.items()}
    if isinstance(value, list):
        return [json_safe(inner) for inner in value]
    return value


def main(arguments):
    if arguments[:1] == ['source-state']:
        print(json.dumps(source_state(Path(arguments[1]))))
        return 0
    if arguments[:1] == ['artifact']:
        try:
            built = option(arguments, '--built-source')
            print(json.dumps(artifact_identity(Path(arguments[1]), Path(arguments[2]), Path(built) if built else None)))
            return 0
        except (OSError, ValueError) as error:
            print(f'error: {error}', file=sys.stderr)
            return 1
    tolerance = float(option(arguments, '--tolerance', 0.15))
    budgets_path = option(arguments, '--budgets', str(Path(__file__).resolve().parent / 'budgets.json'))
    budgets = json.loads(Path(budgets_path).read_text()) if Path(budgets_path).exists() else {}
    if arguments[:1] == ['collect']:
        folder, target = Path(arguments[1]), Path(arguments[2])
        result = collect(folder)
        result['file'] = target.name
        earlier_path = option(arguments, '--compare')
        comparison = None
        if earlier_path:
            earlier = json.loads(Path(earlier_path).read_text())
            earlier.setdefault('file', Path(earlier_path).name)
            comparison = compare(earlier, result, tolerance)
            result['comparison'] = comparison
            comparison = {**comparison, 'earlier': earlier}
        result['budgets'] = check_budgets(result, budgets)
        target.write_text(json.dumps(json_safe(result), indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False) + '\n')
        show(result, comparison)
        print(f'Wrote {target}')
        return 1 if result['budgets']['failures'] else 0
    elif arguments[:1] == ['compare']:
        earlier = json.loads(Path(arguments[1]).read_text())
        earlier.setdefault('file', Path(arguments[1]).name)
        now = json.loads(Path(arguments[2]).read_text())
        comparison = compare(earlier, now, tolerance)
        now['budgets'] = check_budgets(now, budgets)
        show(now, {**comparison, 'earlier': earlier})
        return 1 if now['budgets']['failures'] else 0
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
