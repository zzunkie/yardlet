---
name: footer
description: 새 멀티라인 제출 입력 화면은 공유 분기 + footer 계약으로 통일
source: learned
---
TUI에 Enter=줄바꿈/Ctrl+S=전송 입력 화면을 추가·수정할 때: (1) 키 분기는 손으로 match 하지 말고 src/ui/text_input.rs의 action_for_key(code, mods, keyboard_enhancement)를 재사용해 TextInputAction으로 처리한다(Ctrl+S가 리터럴 's'를 삽입하는 회귀를 원천 차단). (2) 화면 고유의 스크롤 키(PgUp/PgDn 등)는 action_for_key 호출 전에 조기 반환으로 처리한다. (3) 해당 footer 문자열을 *_footers_match_the_multiline_submit_contract 형태 테스트에 넣어 Enter/Ctrl+S/Ctrl+Enter/Esc 포함 및 'Shift/Alt' 미포함을 EN+KO 모두 단언한다. (4) Cancel 분기는 input_clear()로 초안과 화면별 상태를 함께 비워 오염 없는 취소를 보장한다.
