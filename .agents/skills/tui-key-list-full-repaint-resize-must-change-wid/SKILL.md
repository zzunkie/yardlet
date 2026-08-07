---
name: tui-key-list-full-repaint-resize-must-change-wid
description: tui-key-list-full-repaint-resize-must-change-width
source: learned
---
tui_key_list_process 에서 스크롤된 tail 문구를 seen()/wait_for_marker 로 확인하려면 full repaint 가 필수다(Ratatui 는 변경 셀만 방출하므로 접두사를 공유하는 doc 은 조각나 비연속 바이트열이 됨). full repaint 강제용 resize 는 반드시 '현재와 다른 폭'으로 가야 한다: resize(A)->resize(현재폭) 을 sleep 없이 연속 호출하면 두 TIOCSWINSZ 가 하나의 SIGWINCH(최종=현재폭, 무변경)로 합쳐져 repaint 가 안 일어난다(증상: 문구의 한 글자 셀이 미재방출돼 'workspace'->'workspac' 처럼 빠짐). 안전 패턴: resize(다른폭 139, 줄바꿈 없는 폭) 한 번 -> 각 문구를 wait_for_marker 로 데드라인 폴링(첫 폴링이 repaint 도착을 동기화) -> resize(140) 로 계약 폭 복원. 고정 sleep+단발 drain+부분 프레임 슬라이스는 쓰지 말 것.
