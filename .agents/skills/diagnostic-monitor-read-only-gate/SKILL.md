---
name: diagnostic-monitor-read-only-gate
description: diagnostic-monitor-read-only-gate
source: learned
---
Monitor의 워커 변형 키를 게이트할 땐 순수 함수 monitor_control_action(code, diagnostic, can_stop)->MonitorControl로 뽑고, 실제 표시되는 footer(footer_monitor_diagnostic vs footer_monitor)가 이미 그 키를 안내하는지 대조하라. diagnostic footer가 x/p를 안 보이면 게이트는 안내와 동작의 기존 불일치를 닫는 것이므로 view.rs 편집 없이 핸들러만 고치면 된다.
