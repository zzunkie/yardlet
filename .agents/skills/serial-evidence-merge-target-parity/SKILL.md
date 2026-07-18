---
name: serial-evidence-merge-target-parity
description: serial-evidence-merge-target-parity
source: learned
---
직렬 worktree의 forbidden-gate evidence를 검증할 때, evidence가 worktree HEAD가 아니라 integrate_worktree가 실제로 merge할 branch ref(baseline..<branch>^{commit})를 기준으로 계산되는지 확인하라. worker가 커밋 후 `git checkout --detach HEAD~1`로 HEAD를 브랜치 팁에서 떼는 red-green 재현으로 분기 우회가 닫혔는지 본다. 대상 canonical 파일은 반드시 main에서 tracked인 것(.agents/*-policy.yaml)으로 잡아라. untracked(workers.yaml)는 merge가 untracked-overwrite conflict로 우연히 막혀 우회가 은폐된다.
