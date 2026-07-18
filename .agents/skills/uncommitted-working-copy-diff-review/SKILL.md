---
name: uncommitted-working-copy-diff-review
description: uncommitted-working-copy-diff-review
source: learned
---
리뷰 대상이 메인 워킹카피의 uncommitted diff일 때: (1) 리뷰 worktree에는 절대 패치를 적용하지 말 것 — 리뷰 run의 change evidence가 오염되고 Done 시 통합 경로가 리뷰어를 저자로 오귀속할 수 있다. (2) diff는 `git -C <repo-root> diff`로 캡처해 /tmp에서 읽는다. (3) 회귀 검증(cargo build/test)은 수정이 실제 존재하는 메인 워킹카피에서 실행하고 로그를 run dir의 validation.log로 복사한다(소스 무수정, target/ 산출물만 생성). (4) 이슈 번호가 태스크 제목에만 있으면 `gh issue view <n> --repo <owner/repo>`로 원문 기대사항을 확보해 AC와 1:1 매핑한다.
