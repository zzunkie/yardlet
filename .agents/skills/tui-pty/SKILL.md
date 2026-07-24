---
name: tui-pty
description: TUI 첫 프레임 PTY 계측
source: learned
---
첫 프레임 성능은 terminal init escape가 아니라 loading 화면의 고유 visible marker까지 PTY에서 측정하라. recovery delay와 fake worker --version delay를 함께 주입하고 loading 중 실행 키가 sentinel을 만들지 않는지도 확인하라.
