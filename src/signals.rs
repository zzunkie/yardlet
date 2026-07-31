//! One place that knows the operator asked this process to stop.
//!
//! Yardlet starts workers in their own process group on purpose (issue #52), so
//! they survive the terminal that launched them. The cost is that nothing
//! outside Yardlet can clean one up: not the shell, whose signal goes to its own
//! foreground group; not a test harness, which has no handle on a group it did
//! not create. Yardlet is the only process that knows the worker's pid, so
//! Yardlet has to be the one that takes it down.
//!
//! Before this, it did not. `terminate_worker_tree` existed and was correct, and
//! nothing called it when the orchestrator itself was asked to stop, so a
//! Ctrl-C on `yardlet run` killed the parent and left the worker holding the run
//! directory (issue #107 — the likely source of the four `yardlet` processes
//! found alive 26 hours later in #64).
//!
//! `ctrlc::set_handler` may only be installed once per process, so this owns the
//! single installation and everything else reads the flag.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Once;

static REQUESTED: AtomicBool = AtomicBool::new(false);
static INSTALL: Once = Once::new();
static INSTALLED: AtomicBool = AtomicBool::new(false);

/// Install the process-wide stop handler. Idempotent, and safe to call from any
/// command; the second call is a no-op rather than the `MultipleHandlers` error
/// `ctrlc` returns for a second registration.
///
/// Returns whether a handler is in place. A platform that refuses one is not
/// fatal — the caller simply never sees a request — but it is worth reporting,
/// because it means an interrupted run reverts to the old behaviour.
pub fn install_stop_handler() -> bool {
    INSTALL.call_once(|| {
        let installed = ctrlc::set_handler(|| {
            // Signal-handler context: set a flag and return. The teardown that
            // follows takes locks and spawns processes, neither of which is safe
            // here, so the polling side does that work.
            REQUESTED.store(true, Ordering::SeqCst);
        })
        .is_ok();
        INSTALLED.store(installed, Ordering::SeqCst);
    });
    INSTALLED.load(Ordering::SeqCst)
}

/// Has the operator asked this process to stop?
pub fn stop_requested() -> bool {
    REQUESTED.load(Ordering::SeqCst)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The flag starts clear, so a run that is never interrupted takes no
    /// teardown path it did not ask for.
    #[test]
    fn nothing_is_requested_until_a_signal_arrives() {
        assert!(!stop_requested());
    }

    /// Installing twice must not fail. `watch` already registers a handler, and
    /// a second registration is exactly what `ctrlc` refuses.
    #[test]
    fn installing_twice_is_not_an_error() {
        let first = install_stop_handler();
        let second = install_stop_handler();
        assert_eq!(
            first, second,
            "the second install must report the same state, not a fresh attempt"
        );
    }
}
