//! Bounded, foreground-only local observation loop.

use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use chrono::Local;
use serde::Serialize;

use crate::state::Workspace;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Until {
    Success,
    Failure,
    OutputContains(String),
    PathExists(PathBuf),
    PathChanged(PathBuf),
}

impl Until {
    pub fn parse(value: &str) -> Result<Self> {
        let value = value.trim();
        if value.eq_ignore_ascii_case("success") {
            return Ok(Self::Success);
        }
        if value.eq_ignore_ascii_case("failure") {
            return Ok(Self::Failure);
        }
        for (prefix, make) in [("output:", 0_u8), ("exists:", 1_u8), ("changed:", 2_u8)] {
            if let Some(rest) = value.strip_prefix(prefix).map(str::trim) {
                if rest.is_empty() {
                    bail!("watch --until {prefix} requires a value");
                }
                return Ok(match make {
                    0 => Self::OutputContains(rest.to_string()),
                    1 => Self::PathExists(PathBuf::from(rest)),
                    _ => Self::PathChanged(PathBuf::from(rest)),
                });
            }
        }
        bail!("unsupported --until condition '{value}'; use success, failure, output:<text>, exists:<path>, or changed:<path>")
    }

    fn label(&self) -> String {
        match self {
            Self::Success => "success".to_string(),
            Self::Failure => "failure".to_string(),
            Self::OutputContains(v) => format!("output:{v}"),
            Self::PathExists(v) => format!("exists:{}", v.display()),
            Self::PathChanged(v) => format!("changed:{}", v.display()),
        }
    }
}

#[derive(Debug, Clone)]
pub struct WatchOptions {
    pub interval: Duration,
    pub max_runs: u32,
    pub max_duration: Duration,
    pub until: Until,
    pub command: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Observation {
    pub attempt: u32,
    pub success: bool,
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub condition_met: bool,
    pub note: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct WatchResult {
    pub schema_version: u8,
    pub run_id: String,
    pub status: String,
    pub until: String,
    pub interval_ms: u64,
    pub max_runs: u32,
    pub max_duration_ms: u64,
    pub started_at: String,
    pub finished_at: String,
    pub observations: Vec<Observation>,
    pub reason: String,
}

trait Clock {
    fn elapsed(&self) -> Duration;
    fn sleep(&mut self, duration: Duration);
}

struct RealClock(Instant);

impl Clock for RealClock {
    fn elapsed(&self) -> Duration {
        self.0.elapsed()
    }

    fn sleep(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

trait Observer {
    fn observe(&mut self, attempt: u32) -> Observation;
}

struct LocalObserver {
    root: PathBuf,
    until: Until,
    command: Vec<String>,
    initial_path_fingerprint: Option<u64>,
    cancelled: Arc<AtomicBool>,
    deadline: Instant,
}

impl LocalObserver {
    fn new(
        root: &Path,
        until: Until,
        command: Vec<String>,
        cancelled: Arc<AtomicBool>,
        max_duration: Duration,
    ) -> Self {
        let initial_path_fingerprint = match &until {
            Until::PathChanged(path) => fingerprint(&root.join(path)),
            _ => None,
        };
        Self {
            root: root.to_path_buf(),
            until,
            command,
            initial_path_fingerprint,
            cancelled,
            deadline: Instant::now() + max_duration,
        }
    }
}

impl Observer for LocalObserver {
    fn observe(&mut self, attempt: u32) -> Observation {
        let (success, exit_code, stdout, stderr, note) = if self.command.is_empty() {
            (
                true,
                None,
                String::new(),
                String::new(),
                "path observation".to_string(),
            )
        } else {
            match Command::new(&self.command[0])
                .args(&self.command[1..])
                .current_dir(&self.root)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
            {
                Ok(mut child) => {
                    let stdout = child.stdout.take().map(|mut pipe| {
                        std::thread::spawn(move || {
                            let mut bytes = Vec::new();
                            let _ = pipe.read_to_end(&mut bytes);
                            bytes
                        })
                    });
                    let stderr = child.stderr.take().map(|mut pipe| {
                        std::thread::spawn(move || {
                            let mut bytes = Vec::new();
                            let _ = pipe.read_to_end(&mut bytes);
                            bytes
                        })
                    });
                    let (status, note) = loop {
                        match child.try_wait() {
                            Ok(Some(status)) => {
                                break (Some(status), "command completed".to_string())
                            }
                            Ok(None) if self.cancelled.load(Ordering::SeqCst) => {
                                let _ = child.kill();
                                break (child.wait().ok(), "command cancelled".to_string());
                            }
                            Ok(None) if Instant::now() >= self.deadline => {
                                let _ = child.kill();
                                break (
                                    child.wait().ok(),
                                    "maximum duration interrupted observer".to_string(),
                                );
                            }
                            Ok(None) => std::thread::sleep(Duration::from_millis(25)),
                            Err(error) => {
                                let _ = child.kill();
                                let _ = child.wait();
                                break (None, format!("observer wait failed: {error}"));
                            }
                        }
                    };
                    let stdout = stdout.and_then(|h| h.join().ok()).unwrap_or_default();
                    let stderr = stderr.and_then(|h| h.join().ok()).unwrap_or_default();
                    (
                        status.is_some_and(|v| v.success()),
                        status.and_then(|v| v.code()),
                        String::from_utf8_lossy(&stdout).into_owned(),
                        String::from_utf8_lossy(&stderr).into_owned(),
                        note,
                    )
                }
                Err(error) => (
                    false,
                    None,
                    String::new(),
                    String::new(),
                    format!("observer could not start: {error}"),
                ),
            }
        };
        let combined = format!("{stdout}{stderr}");
        let condition_met = match &self.until {
            Until::Success => success,
            Until::Failure => !success,
            Until::OutputContains(needle) => combined.contains(needle),
            Until::PathExists(path) => self.root.join(path).exists(),
            Until::PathChanged(path) => {
                let current = fingerprint(&self.root.join(path));
                current != self.initial_path_fingerprint
            }
        };
        Observation {
            attempt,
            success,
            exit_code,
            stdout,
            stderr,
            condition_met,
            note,
        }
    }
}

fn fingerprint(path: &Path) -> Option<u64> {
    if path.is_file() {
        let bytes = std::fs::read(path).ok()?;
        let mut hash = DefaultHasher::new();
        bytes.hash(&mut hash);
        return Some(hash.finish());
    }
    if path.is_dir() {
        let mut names: Vec<_> = std::fs::read_dir(path)
            .ok()?
            .flatten()
            .filter_map(|e| e.file_name().into_string().ok())
            .collect();
        names.sort();
        let mut hash = DefaultHasher::new();
        names.hash(&mut hash);
        return Some(hash.finish());
    }
    None
}

fn run_loop(
    options: &WatchOptions,
    observer: &mut dyn Observer,
    clock: &mut dyn Clock,
    cancelled: &AtomicBool,
) -> (String, Vec<Observation>, String) {
    let mut observations = Vec::new();
    for attempt in 1..=options.max_runs {
        if cancelled.load(Ordering::SeqCst) {
            return (
                "cancelled".into(),
                observations,
                "cancel signal received".into(),
            );
        }
        if clock.elapsed() >= options.max_duration {
            return (
                "exhausted".into(),
                observations,
                "maximum duration reached".into(),
            );
        }
        let observation = observer.observe(attempt);
        let met = observation.condition_met;
        observations.push(observation);
        if met {
            return (
                "satisfied".into(),
                observations,
                "until condition satisfied".into(),
            );
        }
        if cancelled.load(Ordering::SeqCst) {
            return (
                "cancelled".into(),
                observations,
                "cancel signal received".into(),
            );
        }
        if attempt < options.max_runs {
            let remaining = options.max_duration.saturating_sub(clock.elapsed());
            if remaining.is_zero() {
                return (
                    "exhausted".into(),
                    observations,
                    "maximum duration reached".into(),
                );
            }
            clock.sleep(options.interval.min(remaining));
        }
    }
    (
        "exhausted".into(),
        observations,
        "maximum observation count reached".into(),
    )
}

pub fn run(ws: &Workspace, options: WatchOptions) -> Result<(String, WatchResult)> {
    if options.max_runs == 0 {
        bail!("watch --max-runs must be at least 1");
    }
    if options.max_duration.is_zero() {
        bail!("watch --max-seconds must be at least 1");
    }
    if options.command.is_empty()
        && !matches!(options.until, Until::PathExists(_) | Until::PathChanged(_))
    {
        bail!("watch requires an observer command after '--' for this --until condition");
    }

    let base = format!("watch-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let (run_id, run_dir) = ws.claim_run_dir(&base)?;
    let started_at = Local::now().to_rfc3339();
    let cancelled = Arc::new(AtomicBool::new(false));
    let signal = Arc::clone(&cancelled);
    ctrlc::set_handler(move || signal.store(true, Ordering::SeqCst))
        .context("installing foreground watch cancel handler")?;
    let mut observer = LocalObserver::new(
        &ws.root,
        options.until.clone(),
        options.command.clone(),
        Arc::clone(&cancelled),
        options.max_duration,
    );
    let mut clock = RealClock(Instant::now());
    let (status, observations, reason) = run_loop(&options, &mut observer, &mut clock, &cancelled);
    let result = WatchResult {
        schema_version: 1,
        run_id: run_id.clone(),
        status,
        until: options.until.label(),
        interval_ms: options.interval.as_millis().min(u64::MAX as u128) as u64,
        max_runs: options.max_runs,
        max_duration_ms: options.max_duration.as_millis().min(u64::MAX as u128) as u64,
        started_at,
        finished_at: Local::now().to_rfc3339(),
        observations,
        reason,
    };
    crate::state::write_str(
        &run_dir.join("watch-result.json"),
        &format!("{}\n", serde_json::to_string_pretty(&result)?),
    )?;
    Ok((run_id, result))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeClock(Duration);
    impl Clock for FakeClock {
        fn elapsed(&self) -> Duration {
            self.0
        }
        fn sleep(&mut self, duration: Duration) {
            self.0 += duration;
        }
    }

    struct FakeObserver(Vec<bool>);
    impl Observer for FakeObserver {
        fn observe(&mut self, attempt: u32) -> Observation {
            let met = self.0.remove(0);
            Observation {
                attempt,
                success: met,
                exit_code: Some(if met { 0 } else { 1 }),
                stdout: String::new(),
                stderr: String::new(),
                condition_met: met,
                note: "controlled".into(),
            }
        }
    }

    fn options() -> WatchOptions {
        WatchOptions {
            interval: Duration::from_secs(5),
            max_runs: 3,
            max_duration: Duration::from_secs(60),
            until: Until::Success,
            command: vec!["test".into()],
        }
    }

    #[test]
    fn controlled_observer_stops_when_condition_is_met_without_real_sleep() {
        let mut observer = FakeObserver(vec![false, true]);
        let mut clock = FakeClock::default();
        let (status, observations, reason) = run_loop(
            &options(),
            &mut observer,
            &mut clock,
            &AtomicBool::new(false),
        );
        assert_eq!(status, "satisfied");
        assert_eq!(observations.len(), 2);
        assert_eq!(clock.0, Duration::from_secs(5));
        assert_eq!(reason, "until condition satisfied");
    }

    #[test]
    fn cap_and_cancel_have_honest_terminal_reasons() {
        let mut observer = FakeObserver(vec![false, false, false]);
        let mut clock = FakeClock::default();
        let (status, observations, reason) = run_loop(
            &options(),
            &mut observer,
            &mut clock,
            &AtomicBool::new(false),
        );
        assert_eq!(
            (status.as_str(), observations.len(), reason.as_str()),
            ("exhausted", 3, "maximum observation count reached")
        );

        let cancelled = AtomicBool::new(true);
        let mut observer = FakeObserver(vec![]);
        let (status, observations, reason) = run_loop(
            &options(),
            &mut observer,
            &mut FakeClock::default(),
            &cancelled,
        );
        assert_eq!(
            (status.as_str(), observations.len(), reason.as_str()),
            ("cancelled", 0, "cancel signal received")
        );
    }

    #[test]
    fn maximum_duration_is_enforced_by_fake_clock() {
        let mut bounded = options();
        bounded.max_duration = Duration::from_secs(4);
        let mut observer = FakeObserver(vec![false]);
        let mut clock = FakeClock::default();
        let (status, observations, reason) =
            run_loop(&bounded, &mut observer, &mut clock, &AtomicBool::new(false));
        assert_eq!(status, "exhausted");
        assert_eq!(observations.len(), 1);
        assert_eq!(clock.0, Duration::from_secs(4));
        assert_eq!(reason, "maximum duration reached");
    }

    #[test]
    fn parses_only_bounded_local_conditions() {
        assert_eq!(
            Until::parse("output:healthy").unwrap(),
            Until::OutputContains("healthy".into())
        );
        assert_eq!(
            Until::parse("exists:tmp/ready").unwrap(),
            Until::PathExists("tmp/ready".into())
        );
        assert!(Until::parse("ask an agent").is_err());
    }

    #[test]
    fn local_observer_preserves_satisfied_result_artifact() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("watch-artifact-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let (run_id, result) = run(
            &ws,
            WatchOptions {
                interval: Duration::ZERO,
                max_runs: 2,
                max_duration: Duration::from_secs(5),
                until: Until::OutputContains("healthy".into()),
                command: vec!["bash".into(), "-c".into(), "printf healthy".into()],
            },
        )
        .unwrap();
        assert_eq!(result.status, "satisfied");
        assert_eq!(result.observations.len(), 1);
        let raw =
            std::fs::read_to_string(ws.runs_dir().join(run_id).join("watch-result.json")).unwrap();
        assert!(raw.contains("\"status\": \"satisfied\""));
        assert!(raw.contains("healthy"));
        let _ = std::fs::remove_dir_all(&root);
    }
}
