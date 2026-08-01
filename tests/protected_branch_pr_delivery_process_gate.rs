//! Names what a local `cargo test` did not run (#105).
//!
//! `protected_branch_pr_delivery_process` is in the slow process tier. This exists so the skip appears in the
//! test list by name instead of the tier vanishing from the output — a run that
//! silently omits 56% of its wall clock reads as "everything passed".

#[cfg(not(feature = "slow-process-tests"))]
#[test]
fn protected_branch_pr_delivery_process_is_gated_off_run_with_features_slow_process_tests() {
    eprintln!(
        "skipped: the protected-branch PR delivery process fixtures need \
         `cargo test --features slow-process-tests` (CI always runs them)"
    );
}
