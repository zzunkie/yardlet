---
name: uncommitted-red-behavior-toggle
description: uncommitted-red-behavior-toggle
source: learned
---
스키마(신규 필드/타입)와 배선이 한 working tree에 섞여 커밋 전 RED를 재현해야 할 때: (1) git diff > green.patch로 전체를 보존한다. (2) 스키마는 남기고 배선 지점만 pre-fix로 되돌리는 최소 토글(수 곳, 'RED-TOGGLE' 주석)을 넣고 신규 테스트를 실행해 실패 메시지를 결함 증상과 1:1 대조한다. (3) git checkout -- <토글 파일> 후 git apply --include=<파일> green.patch로 원복하고 동일 테스트 GREEN + grep -c RED-TOGGLE == 0 + git status 청결을 확인한다. base revision 이식이 불가능한(신규 심볼 의존) RED에 쓰는 red/red-base 스킬의 working-tree 변형이다.
