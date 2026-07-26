---
name: process-fixture-mutation
description: process fixture 외부 mutation 계수 분리
source: learned
---
crash fixture에서는 command CALL, mutation 시작, mutation 성공을 별도 로그 event로 기록하고 중복 외부 mutation은 성공 event 수로 판정하라.
