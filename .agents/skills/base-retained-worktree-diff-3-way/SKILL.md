---
name: base-retained-worktree-diff-3-way
description: base 전진 시 retained worktree diff의 3-way 재이식
source: learned
---
partial 이어받기에서 retained worktree의 uncommitted diff를 회수할 때: (1) 두 worktree의 HEAD를 비교해 base 전진 여부를 먼저 확인, (2) 전진했으면 파일 복사 금지, git -C <retained> diff > patch 후 git apply -3로 적용, (3) upstream이 같은 위치에 자체 fixture/테스트를 추가해 충돌이 인터리브되면 양쪽 함수를 모두 보존하는 방향으로 재구성, (4) upstream 스키마 변화(새 struct 필드)를 이식한 fixture에 반영, (5) cargo fmt 후 focused test → full test 순으로 포그라운드 검증.
