---
name: i18n-home-key-doc-tui-key-list-process
description: i18n Home-key doc 길이 변경 시 tui_key_list_process 다회 재실행
source: learned
---
src/ui/i18n.rs의 Home-key doc 문구(key_doc_*)를 길게 바꾸면 PTY 테스트 tui_key_list_process가 flaky해질 수 있다. 이 테스트는 고정 sleep(40ms/300ms) 뒤 단발 drain 후 바이트 스트림 부분 문자열('reload the workspace' 등)을 매칭하므로, 프레임당 바이트가 늘면 하단 g 행이 방출 도중 캡처돼 seen()이 실패한다. 검증 절차: (1) cargo test --test tui_key_list_process를 4회 이상 반복해 flaky 여부 확인, (2) 인과 판정은 문제 문구만 이전 값으로 되돌려 4회 반복(통과) 후 git checkout으로 원복해 대조. 스크롤 클램프(max_scroll_offset)는 140열에서 대개 줄바꿈이 없어 레이아웃이 아니라 타이밍이 원인이다.
