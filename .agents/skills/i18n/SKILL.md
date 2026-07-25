---
name: i18n
description: i18n 마커 문구는 다른 문구의 부분문자열과 겹치지 않게
source: learned
---
TUI 렌더 텍스트를 str::find로 위치 검증하는 테스트를 쓸 때, 마커용 i18n 문구(예: planning_target_marker='accept/reject target')가 같은 화면의 다른 문구(힌트/푸터, 예: planning_select_hint)에 부분문자열로 포함되면 find()가 엉뚱한 위치를 집는다. 마커 문구는 화면 내 다른 문구와 겹치지 않는 고유 어구로 잡고, EN/KO 양쪽에서 겹침 여부를 확인하라.
