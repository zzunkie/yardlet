---
name: pty-ko-cjk-ansi
description: PTY 통합 테스트에서 ko/CJK 마커는 ANSI+공백 제거 후 매칭
source: learned
---
ratatui는 폭 2 CJK 셀마다 커서 이동 escape(예: ESC[row;colH)를 넣어 한글 단어가 raw PTY 바이트에서 비연속으로 흩어진다(예: '수'ESC[..H'락'). 따라서 tui_startup_process.rs식 'output.windows(marker).any(==)' 바이트 매칭은 ASCII에만 통하고 ko 문구엔 실패한다. 해결: (1) ESC[..final(0x40-0x7e), ESC]..BEL/ST, 기타 2바이트 escape를 제거하는 strip_ansi로 가시 텍스트만 남기고, (2) 셀 사이 공백도 커서 이동으로 나오므로 마커·출력 양쪽의 whitespace를 제거(norm)한 뒤 substring 매칭한다. 또한 첫 마커(화면 title)만 보고 단언하지 말 것: 큰 프레임은 부분 드레인될 수 있으니, 그 화면 고유의 footer 키 마커(예 review의 'e 수정')를 추가로 기다려 프레임 완성을 보장한 뒤 라벨을 단언한다. slow startup은 로딩 마커 존재만이 아니라 Home 도달 경과시간(>= recovery delay)으로 실증한다.
