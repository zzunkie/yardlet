#!/usr/bin/env python3
"""Outcome contracts for the benchmark; no app, model, or Swift build is started."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bench_report', Path(__file__).with_name('report.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class BenchmarkOutcomeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='yardlet-bench-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.budgets = {'stream-codex/streaming': {'events.codexState.cpuP95Ms': 2}}
        self.meta = {'repeat': 3, 'plan': {'scenes': {'stream-codex': ['streaming']}, 'micro': []}}
        self.write('meta.json', self.meta)
        self.write('artifact.json', {key: 'a' * 64 for key in
                   ('executableSHA256', 'qaExecutableSHA256', 'diffSHA256', 'sourceSHA256')})
        for round_number in range(1, 4):
            self.round(round_number)

    def write(self, name, value):
        path = self.folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def round(self, number, cpu=0.5, phases=('streaming',)):
        base = f'scenes/stream-codex/{number}'
        self.write(f'{base}/run.json', {'loadBefore': 2})
        self.write(f'{base}/scene.json', {'pid': 123, 'phases': [
            {'name': phase, 'sampled': True, 'events': {'codexState': {'cpuP95Ms': cpu}}}
            for phase in phases]})
        for index, phase in enumerate(phases, 1):
            self.write(f'{base}/samples/{index}-{phase}.json', {'processes': [
                {'pid': 123, 'path': '/fixture/Yardlet', 'footprintMiB': 50, 'cpuPercent': 1}]})

    def result(self):
        value = report.collect(self.folder)
        return value, report.check_budgets(value, self.budgets)

    def assertFails(self, phrase):
        value, outcome = self.result()
        self.assertTrue(outcome['failures'], value)
        self.assertIn(phrase, json.dumps(outcome))

    def test_all_planned_rounds_pass_and_preserve_their_measurements(self):
        self.round(2, cpu=3)
        value, outcome = self.result()
        self.assertEqual(outcome['failures'], [])  # The documented budget is the repeats' median.
        scene = value['scenes']['stream-codex']
        self.assertEqual(scene['completedRounds'], 3)
        self.assertEqual(scene['phases']['streaming']['numbers']['events.codexState.cpuP95Ms'], .5)
        self.assertEqual(scene['roundData'][1]['phases']['streaming']['numbers']['events.codexState.cpuP95Ms'], 3)

    def test_missing_round_cannot_pass_on_the_remaining_two(self):
        (self.folder / 'scenes/stream-codex/3/scene.json').unlink()
        self.assertFails('round 3')

    def test_a_selected_scene_with_no_directory_is_a_failure(self):
        self.meta['plan']['scenes']['idle-running'] = ['idle']
        self.write('meta.json', self.meta)
        self.assertFails('idle-running')

    def test_missing_unbudgeted_phase_is_a_failure(self):
        self.meta['plan']['scenes']['stream-codex'].append('after-stream')
        self.write('meta.json', self.meta)
        self.assertFails('missing phase: after-stream')

    def test_missing_budgeted_metric_in_one_round_is_not_hidden_by_median(self):
        self.write('scenes/stream-codex/2/scene.json', {'pid': 123, 'phases': [{'name': 'streaming', 'sampled': True}]})
        self.assertFails('stream-codex/streaming round 2')

    def test_required_measurement_without_a_budget_cannot_be_omitted(self):
        self.meta['plan']['metrics'] = {'stream-codex': {'streaming': ['input.responseP95Ms']}}
        self.write('meta.json', self.meta)
        self.assertFails('input.responseP95Ms: required measurement missing')

    def test_sampler_failure_or_empty_process_list_is_not_zero_cpu(self):
        for sample in [None, {'processes': []}, {'processes': [{'pid': 123, 'footprintMiB': 50}]}]:
            with self.subTest(sample=sample):
                path = self.folder / 'scenes/stream-codex/1/samples/1-streaming.json'
                if sample is None:
                    path.unlink()
                else:
                    path.write_text(json.dumps(sample))
                self.assertFails('streaming: no ')

    def test_missing_plan_cannot_establish_a_valid_run(self):
        del self.meta['plan']
        self.write('meta.json', self.meta)
        self.assertFails('missing or invalid run plan')

    def test_missing_artifact_identity_fails(self):
        self.write('artifact.json', {})
        self.assertFails('missing or invalid executableSHA256')

    def test_nonfinite_measurements_fail_and_remain_valid_json(self):
        for value in [float('nan'), float('inf'), -float('inf')]:
            with self.subTest(value=value):
                self.round(2, cpu=value)
                result, outcome = self.result()
                self.assertTrue(outcome['failures'])
                json.dumps(report.json_safe(result), allow_nan=False)

    def micro(self, exit_code=0, state='passed', records=True):
        self.meta['plan']['micro'] = [{'test': 'FixtureTests/testBenchmark', 'records': ['fixture-cost']}]
        self.write('meta.json', self.meta)
        self.write('micro-status.json', {'exitCode': exit_code})
        (self.folder / 'micro.log').write_text(
            f"Test Case '-[NativeHarnessClientTests.FixtureTests testBenchmark]' {state} (1.0 seconds).\n")
        if records:
            (self.folder / 'micro.jsonl').write_text(json.dumps({'name': 'fixture-cost', 'metrics': {'cpuMs': 1}}) + '\n')

    def test_micro_requires_successful_execution_and_recorded_measurements(self):
        self.micro()
        value, outcome = self.result()
        self.assertEqual(outcome['failures'], [])
        self.assertEqual(value['microTests']['FixtureTests/testBenchmark'], ['passed'])

    def test_micro_process_failure_is_not_a_warning_only(self):
        self.micro(exit_code=1)
        self.assertFails('micro tests exited with 1')

    def test_successful_process_with_missing_or_skipped_test_fails(self):
        for state in ['skipped', 'failed']:
            with self.subTest(state=state):
                self.micro(state=state)
                self.assertFails('micro test did not pass')
        (self.folder / 'micro.log').write_text('No matching tests were run\n')
        self.assertFails('micro test did not pass')

    def test_test_pass_without_measurement_or_exit_status_fails(self):
        self.micro(records=False)
        self.assertFails('missing micro measurement')
        (self.folder / 'micro-status.json').unlink()
        self.assertFails('micro run status')

    def test_invalid_micro_records_are_not_silently_dropped(self):
        self.micro()
        with (self.folder / 'micro.jsonl').open('a') as stream:
            stream.write('{unfinished\n')
        self.assertFails('micro record 2')

    def test_legacy_results_are_still_compared_without_a_new_plan(self):
        earlier = {'commit': 'earlier', 'scenes': {'stream-codex': {'phases': {'streaming': {'numbers': {'costMs': 1}}}}}}
        now = {'commit': 'later', 'scenes': {'stream-codex': {'phases': {'streaming': {'numbers': {'costMs': 5}}}}}}
        comparison = report.compare(earlier, now, .15)
        self.assertEqual(len(comparison['worse']), 1)
        self.assertEqual(comparison['worse'][0]['after'], 5)

    def test_exited_browser_process_is_not_counted_as_running_or_lost_from_cpu(self):
        sample = {'processes': [{'pid': 123, 'footprintMiB': 20, 'cpuPercent': 1},
            {'pid': 124, 'path': '/Yardlet Browser Host/helper', 'footprintMiB': 0, 'cpuPercent': 2, 'isRunning': False}],
            'aggregate': {'yardletPeakFootprintMiB': 150}}
        numbers = report.process_numbers(sample, 123)
        self.assertEqual(numbers['browserProcessCount'], 0)
        self.assertEqual(numbers['yardletCPUPercent'], 3)
        self.assertEqual(numbers['yardletPeakFootprintMiB'], 150)

    def test_reused_app_must_match_both_the_executable_and_source_manifest(self):
        app = self.folder / 'Yardlet.app'
        executable = app / 'Contents/MacOS/Yardlet'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'fixture app')
        state = {'commit': 'a'*40, 'diffSHA256': 'b'*64, 'sourceSHA256': 'c'*64}
        before = self.folder / 'source.json'; before.write_text(json.dumps(state))
        with patch.object(report, 'source_state', return_value=state):
            with self.assertRaisesRegex(ValueError, 'no benchmark build identity'):
                report.artifact_identity(self.folder, app)
            built = report.artifact_identity(self.folder, app, before)
            reused = report.artifact_identity(self.folder, app)
            self.assertEqual(built['executableSHA256'], reused['executableSHA256'])
            executable.write_bytes(b'another app')
            with self.assertRaisesRegex(ValueError, 'differs'):
                report.artifact_identity(self.folder, app)

    def test_source_changed_during_build_is_rejected(self):
        app = self.folder / 'Yardlet.app'
        executable = app / 'Contents/MacOS/Yardlet'
        executable.parent.mkdir(parents=True); executable.write_bytes(b'fixture app')
        before = self.folder / 'source.json'; before.write_text('{"commit":"before"}')
        with patch.object(report, 'source_state', return_value={'commit': 'after'}):
            with self.assertRaisesRegex(ValueError, 'changed during the build'):
                report.artifact_identity(self.folder, app, before)

    def test_contract_selectors_still_name_source_tests(self):
        root = Path(__file__).resolve().parents[2]
        sources = [p.read_text() for p in (root/'Tests/NativeHarnessClientTests').glob('*.swift')]
        contract = json.loads(Path(__file__).with_name('contract.json').read_text())
        for item in contract['micro']:
            cls, method = item['test'].split('/')
            self.assertTrue(any(f'class {cls}:' in source and f'func {method}(' in source for source in sources), item['test'])


if __name__ == '__main__':
    unittest.main()
