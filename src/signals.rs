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
use std::sync::{Mutex, Once, OnceLock};

static REQUESTED: AtomicBool = AtomicBool::new(false);
static INSTALL: Once = Once::new();
static INSTALLED: AtomicBool = AtomicBool::new(false);

/// Workers this process started and has not yet reaped.
///
/// The emergency exit needs them: a second interrupt that leaves the process
/// without taking its workers down produces the exact orphan #107 is about, only
/// faster. Yardlet is still the only holder of these pids.
fn live_workers() -> &'static Mutex<Vec<u32>> {
    static LIVE: OnceLock<Mutex<Vec<u32>>> = OnceLock::new();
    LIVE.get_or_init(|| Mutex::new(Vec::new()))
}

/// Tracks one worker for as long as this value lives.
///
/// RAII because a hand-placed untrack is a leak waiting to happen, and an
/// independent review found two: the provenance-failure path and the reader-error
/// path both return before reaching it. A pid left tracked after being reaped is
/// a recycled-pid kill — the emergency exit would SIGKILL whatever the OS handed
/// that number to next. Same defect this branch already fixed in `PidFileGuard`.
pub struct TrackedWorker {
    pid: u32,
}

impl TrackedWorker {
    pub fn new(pid: u32) -> Self {
        if let Ok(mut live) = live_workers().lock() {
            live.push(pid);
        }
        Self { pid }
    }
}

impl Drop for TrackedWorker {
    fn drop(&mut self) {
        if let Ok(mut live) = live_workers().lock() {
            live.retain(|tracked| *tracked != self.pid);
        }
    }
}

/// Take down every worker this process still owns. Used by the emergency exit,
/// which cannot rely on the normal teardown running.
fn kill_tracked_workers() {
    let pids = match live_workers().lock() {
        Ok(live) => live.clone(),
        // A poisoned lock means a panic while holding it; the pid list is still
        // the best information available and leaking workers is the worse
        // outcome.
        Err(poisoned) => poisoned.into_inner().clone(),
    };
    for pid in pids {
        crate::workers::terminate_worker_tree(pid, crate::workers::Signal::Kill);
    }
}

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
            // The FIRST request asks for an orderly stop: set a flag and let the
            // polling side do the teardown, which takes locks and signals
            // processes.
            //
            // The SECOND means the operator is done waiting, and must actually
            // work. Replacing the default disposition otherwise makes Ctrl-C
            // unable to end the process at all — during the stop grace period, or
            // if a teardown ever wedges. `ctrlc` runs this on its own thread, not
            // in a raw handler, so exiting from here is allowed.
            if REQUESTED.swap(true, Ordering::SeqCst) {
                // Take the workers with us BEFORE exiting. `process::exit` runs
                // no destructors, so an emergency exit that skipped this would
                // produce the very orphan #107 is about, just faster.
                kill_tracked_workers();
                eprintln!(
                    "\nyardlet: second interrupt — workers killed, exiting now. \
                     Run `yardlet recover` to settle the interrupted run."
                );
                std::process::exit(130); // 128 + SIGINT, what a shell reports
            }
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
