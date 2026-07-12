---
name: failed-check
description: failed-check 재검토 폐쇄 확인법
source: learned
---
재검토(feedback cycle)에서 이전 리뷰의 failed check를 닫을 때는 diff를 믿지 말고, 각 FC가 in-memory 변조 테스트로 스위트에 흡수되었는지 확인하라. 기준 테스트가 무변조에서 긍정 결과를, 변조 테스트가 같은 fixture의 clone 변조에서 부정 결과를 동시에 pass하면 predicate가 해당 필드를 실제로 읽는다는 red-green 증명이 fixture 파일을 건드리지 않고 성립한다.
