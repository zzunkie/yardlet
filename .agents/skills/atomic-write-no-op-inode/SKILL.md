---
name: atomic-write-no-op-inode
description: atomic-write no-op 증명은 inode 비교로
source: learned
---
이 레포의 write_bytes_atomic은 tmp 파일 생성 후 rename이라 같은 바이트를 다시 써도 inode가 바뀐다. '기존 파일을 건드리지 않는 no-op' 요구를 테스트로 고정할 때는 std::os::unix::fs::MetadataExt::ino()를 호출 전후로 비교하라. 내용 비교만으로는 재작성과 no-op을 구분할 수 없어 RED가 성립하지 않는다.
