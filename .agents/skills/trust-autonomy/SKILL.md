---
name: trust-autonomy
description: Trust/autonomy 수치를 실제 기록으로 되짚는 검증법
source: learned
---
trust 리포트를 검증할 때: (1) `yardlet trust --json`의 sources.runs_read를 `wc -l .agents/telemetry/runs.jsonl`과, transitions_read를 `.agents/transitions/*.yaml`의 records 총합과 대조해 '수기집계 아님'을 증명한다. (2) done_trust 4분류 합=task_instances, trustworthy_done_rate=evidence_backed/done_reached 항등식을 확인한다. (3) 개별 인스턴스를 telemetry 행(첫 시도가 Done인지)과 transitions의 Done→非Done 역행으로 스팟체크한다. (4) TUI/CLI 동일성은 두 표면이 같은 trust::report_text를 부르는지로 확인하면 렌더 diff 불필요.
