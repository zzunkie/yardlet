# Yardlet managed built-in skills

이 디렉터리는 Yardlet이 배포하는 managed built-in skill의 repo-native 원본이다.
`manifest.yaml`이 member, 계층, immutable upstream pin, 라이선스, 포함·제외 inventory,
adaptation과 잔여 요구의 단일 machine-readable catalog다.

`skills/`의 파일만 설치 가능한 본문이다. Upstream 원문은 그대로 노출하지 않으며,
`adapted`로 표시된 파일은 Yardlet의 deterministic queue, NeedsUser, 기존 권한 gate에
맞춰 고정된 결과다. 분류나 skill 활성화는 network, credential, browser, remote write,
deploy 또는 다른 외부 mutation 권한을 부여하지 않는다.

무결성은 `tests/builtin_skill_bundle_integrity.rs`가 검증한다. Upstream script는 이
bundle을 만들거나 검사할 때 실행하지 않는다.
