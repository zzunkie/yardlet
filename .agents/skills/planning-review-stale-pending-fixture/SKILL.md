---
name: planning-review-stale-pending-fixture
description: planning-review-stale-pending-fixture
source: learned
---
검토 화면에서 '다중 pending 중 하나만 stale' 상태를 만들려면: (1) proposal_projection()로 제안 A(head None) 생성, (2) second_proposal()로 제안 B(head None) 추가해 2 pending, (3) accept_proposal(ws, A_id, None, ...)로 head를 drv_1로 전진(A는 disposed, B는 여전히 pending이면서 authored head None이라 stale), (4) record_answer_exact(ws, msg, Some(drv_1), ...) + record_worker_proposal로 새 head 기준 fresh 제안 C 추가 → B(stale)·C(fresh) 2 pending. stale 판정은 순수 함수 proposal_is_stale(session.current_head, proposal) = (proposal.expected_head != current_head)로, 코어 planning.rs accept의 'proposal.expected_head != expected_head' CAS 거부(stale_head)와 동치. 렌더/판정 변경 시 실제 accept_proposal이 stale_head를 반환하는지 parity로 되짚어라.
