---
name: fix-red-revision
description: 범위 밖 선행 fix의 RED는 이슈 관찰 revision에서 재현
source: learned
---
리뷰 범위 커밋에 어떤 이슈의 production fix가 없고 fixture만 있으면(구현자가 선행 커밋을 공개한 경우): (1) 새 fixture를 범위 직전 revision에 이식해 GREEN을 실증해 '범위 내 RED 불가'를 기록하고, (2) 이슈 원문의 관찰 revision에 root fix 커밋의 테스트 파일만 git checkout <fix> -- tests/... 로 이식해 RED를 재현한다. 두 증거를 구분 기록하면 fixture-only 커밋도 이슈 종결 근거가 된다.
