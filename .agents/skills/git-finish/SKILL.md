---
name: git-finish
description: git-finish 증거 독립 검증 절차
source: learned
---
git finish 주장 검증 시: (1) grep으로 src/ 전체에서 git push 호출이 src/git_finish.rs 한 곳뿐인지와 force 경로 부재를 확인, (2) cargo test git_finish로 격리 fixture 12개 재실행, (3) evidence의 expected_oid/remote_oid를 git ls-remote --refs <bare remote>로 직접 재조회해 대조, (4) 차단 경로는 clone HEAD 전진에도 remote OID 불변인지 확인, (5) 공개 origin URL·tracking ref를 dogfood-proof.json before/after와 대조, (6) 증거 전체에 credential/secret 패턴 grep.
