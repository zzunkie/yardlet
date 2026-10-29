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
import json
from pathlib import Path
import statistics
import sys

FLOORS = {'Ms': 2.0, 'Percent': 1.0, 'MiB': 15.0, 'PerSecond': 20.0, 'Count': 2.0}
LAUNCH_FLOOR_MS = 50.0
# The numbers the summary table shows for each phase; the rest are compared all the same.
HEADLINE = ['process.yardletCPUPercent', 'process.appFootprintMiB', 'mainThread.cpuPercent',
            'mainThread.passP95Ms', 'mainThread.passesOver50MsCount', 'frames.missedPercent', 'frames.latenessP95Ms',
            'events.codexState.cpuP95Ms', 'events.transcriptPublication.cpuP95Ms', 'events.agentRunState.cpuP95Ms',
            'events.agentRunEvent.cpuP95Ms']


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
    numbers['browserProcessCount'] = len(groups['browser'])
    return numbers


def flatten(prefix, value, into):
    if isinstance(value, dict):
        for key, inner in value.items():
            flatten(f'{prefix}.{key}' if prefix else key, inner, into)
    elif isinstance(value, (int, float)) and not isinstance(value, bool) and unit(prefix):
        into[prefix] = value


def collect_round(folder):
    scene = json.loads((folder / 'scene.json').read_text()) if (folder / 'scene.json').exists() else None
    run = json.loads((folder / 'run.json').read_text()) if (folder / 'run.json').exists() else {}
    if scene is None:
        return None
    samples = {}
    for path in sorted((folder / 'samples').glob('*.json')):
        try:
            samples[path.stem.split('-', 1)[1]] = json.loads(path.read_text())
        except (ValueError, IndexError):
            pass
    phases = {}
    for phase in scene.get('phases', []):
        numbers = {}
        flatten('mainThread', phase.get('mainThread', {}), numbers)
        flatten('frames', phase.get('frames', {}), numbers)
        flatten('events', phase.get('events', {}), numbers)
        if phase['name'] in samples:
            flatten('process', process_numbers(samples[phase['name']], scene.get('pid')), numbers)
        phases[phase['name']] = {
            'numbers': numbers,
            'notes': {'sampled': phase.get('sampled'), 'published': phase.get('published'),
                      'shownTaskItems': phase.get('shownTaskItems'), 'shownTaskRunning': phase.get('shownTaskRunning')},
        }
    launch = {}
    flatten('launch', scene.get('launch', {}), launch)
    return {'launch': launch, 'phases': phases, 'problems': scene.get('problems', []),
            'loadBefore': run.get('loadBefore'), 'reopens': run.get('reopens'),
            'extra': {key: scene[key] for key in ('window', 'screen', 'sidebar', 'browser') if key in scene}}


def median_of(rounds, pick):
    values = [pick(r) for r in rounds]
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 2) if values else None


def collect(folder):
    meta = json.loads((folder / 'meta.json').read_text())
    result = {'version': 1, **meta, 'scenes': {}, 'micro': {}}
    for scene_folder in sorted((folder / 'scenes').glob('*')) if (folder / 'scenes').exists() else []:
        rounds = [r for r in (collect_round(p) for p in sorted(scene_folder.iterdir()) if p.is_dir()) if r]
        if not rounds:
            result['scenes'][scene_folder.name] = {'problems': ['no result']}
            continue
        scene = {'rounds': len(rounds), 'launch': {}, 'phases': {},
                 'problems': sorted({p for r in rounds for p in r['problems']}),
                 'loadBefore': [r['loadBefore'] for r in rounds], 'extra': rounds[-1]['extra']}
        for name in rounds[0]['launch']:
            scene['launch'][name] = median_of(rounds, lambda r: r['launch'].get(name))
        for phase in rounds[0]['phases']:
            numbers = {}
            for name in rounds[0]['phases'][phase]['numbers']:
                numbers[name] = median_of(rounds, lambda r: r['phases'].get(phase, {}).get('numbers', {}).get(name))
            scene['phases'][phase] = {'numbers': numbers, 'notes': rounds[-1]['phases'][phase]['notes']}
        result['scenes'][scene_folder.name] = scene
    micro = folder / 'micro.jsonl'
    if micro.exists():
        grouped = {}
        for line in micro.read_text().splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            for key, value in record.get('metrics', {}).items():
                grouped.setdefault(record['name'], {}).setdefault(key, []).append(value)
        result['micro'] = {name: {key: round(statistics.median(values), 3) for key, values in metrics.items()}
                           for name, metrics in grouped.items()}
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
        if old is None or value is None:
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
            if value is None:
                failures.append({'where': where, 'metric': name, 'limit': limit, 'value': None})
            elif value > limit:
                failures.append({'where': where, 'metric': name, 'limit': limit, 'value': value})
    for scene, data in result.get('scenes', {}).items():
        for problem in data.get('problems', []):
            failures.append({'where': scene, 'metric': 'problem', 'limit': None, 'value': problem})
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


def main(arguments):
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
        target.write_text(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + '\n')
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
