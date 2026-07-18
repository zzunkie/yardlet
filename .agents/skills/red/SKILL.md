---
name: red
description: 단일 커밋 RED 독립 재검증(테스트 이식)
source: learned
---
fix와 테스트가 한 커밋에 있으면 RED를 직접 재현할 수 없다. git worktree add <tmp> <fix>~1로 수정 전 tree를 만들고, HEAD의 신규 process 테스트 파일과 fixture 디렉터리는 통째로 복사, src 내부 unit 테스트는 해당 fn 블록만 부모 tests 모듈에 이식한 뒤 targeted cargo test를 실행한다. exit 101과 assertion 메시지 값이 구현자의 RED 기록과 일치하는지 대조하고, 검증 후 git worktree remove --force로 정리한다.
