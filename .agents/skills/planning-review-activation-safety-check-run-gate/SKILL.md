---
name: planning-review-activation-safety-check-run-gate
description: planning-review-activation-safety-check에 run-gate 보존 확인 추가
source: learned
---
빠른 시작(planning start / TUI s) 검토 시 코어 우회 확인에 더해, 신규 start 경로의 run 진입이 기존 실행 게이트를 보존하는지도 grep으로 확인하라: CLI와 TUI 양쪽 start 호출부가 run::run_auto(ws, false, .., false, ..) 즉 bypass=false, accept_ambiguity=false로 부르는지 본다. 그리고 fast-path가 기존 상세 경로를 약화하지 않았음을 isolated_review_accepts_then_confirms_only_the_displayed_head / _surfaces_stale_head / _rejects_* 회귀가 --all-features에서 그대로 통과하는지로 재확인하라.
