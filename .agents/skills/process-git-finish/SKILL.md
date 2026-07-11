---
name: process-git-finish
description: 실제 process Git finish 중단 복구 검증
source: learned
---
git wrapper로 prepared 직후와 remote update 직후를 멈추고, wrapper PID가 속한 전용 process group 전체를 종료한다. 모든 자식 종료를 확인한 뒤 중단 전 record를 복사하고 두 recover를 동시에 실행해 Prepared 보존, worker 수 불변, 실제 push 1회, 독립 remote OID, queue/run/telemetry/final report 수렴을 함께 검증한다. 종료 owner 회수는 PID 디렉터리 삭제 경합이 아니라 프로세스 종료 시 커널이 해제하는 advisory lock으로 검증한다.
