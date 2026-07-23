---
name: committed-red-detached-worktree-3
description: committed 단일 커밋의 스키마 의존 RED는 detached 리뷰 worktree에서 배선 토글 3점으로
source: learned
---
fix+테스트가 한 커밋이고 테스트가 신규 스키마에 의존하면 fix~1 이식(red 스킬)이 불가하다. 대신: (1) 리뷰 커밋의 detached worktree에서 스키마(struct/receipt 필드/반환형)는 유지한 채 배선 지점만 각각 따로 pre-fix로 토글한다(RED-TOGGLE 주석). YARD-013 기준 3점 = serial evidence 분리 retain, parallel evidence 분리 retain, finalize parity .or_else. (2) 토글당 focused 테스트를 돌려 실패 메시지를 이슈 증상과 1:1 대조하고, 실패한 테스트가 남긴 temp fixture의 partial-reason/run.yaml을 읽어 pre-fix 동작을 특정한다. (3) git checkout -- <파일>로 원복, 동일 테스트 GREEN + grep -c RED-TOGGLE == 0 + git status clean을 확인하고 잔여 fixture temp dir를 삭제한다.
