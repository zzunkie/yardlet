---
name: worktree-fixture-spawn-block-3
description: worktree 준비 경로 fixture에 기존 파일을 심는 법과 spawn-block 정리 판정 3종
source: learned
---
serial/parallel 준비 경로는 fresh worktree를 HEAD에서 만든다. destination에 '기존 파일'을 심으려면 fixture repo의 HEAD에 그 파일을 커밋하라(작업 트리에만 쓰면 worktree에 안 나타남). spawn 전 차단 검증은 3종 세트로: (1) spawn_marker 파일 부재, (2) .agents/worktrees read_dir 빈 상태, (3) git branch --list 'yard/<task-id>/*' 빈 출력. 추가로 root의 커밋 바이트가 무손상인지 비교하면 fail-closed 증명이 완성된다.
