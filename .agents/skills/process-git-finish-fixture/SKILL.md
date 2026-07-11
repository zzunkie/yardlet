---
name: process-git-finish-fixture
description: 실제-process Git finish 중단 fixture
source: learned
---
prepared 직후와 remote update 직후 wrapper PID 또는 process group을 직접 고정하고 종료하라. snapshot 전에 모든 자식 종료를 확인하고, 두 concurrent recover 뒤 worker 수 불변, push 1회, 독립 remote OID, durable record와 queue/run 수렴을 한 번에 검증하라.

`scripts/run.sh <yardlet-bin> <evidence-dir>`를 실행하면 `/tmp`의 격리 clone과 local bare remote에서 before/after crash 및 outside-to-`.agents` rename을 실제 Yardlet 프로세스로 재현한다. 공개 remote는 읽거나 쓰지 않는다.
