---
name: codex-cli-help
description: codex CLI 플래그 실재는 설치된 바이너리 help로 검증
source: learned
---
worker adapter가 codex CLI 플래그를 추가/이동하면 fixture 통과만 믿지 말고 설치된 codex로 `codex exec --help`, `codex exec <subcmd> --help`, 그리고 `codex exec <flags> <subcmd> --help` 파싱 성공까지 확인해 플래그 소속(subcommand 위치)을 검증한다. help 호출은 read-only라 리뷰에서 안전하다.
