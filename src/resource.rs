//! Surface-neutral runtime resource and artifact operations.
//!
//! Workers author proposals. This module validates content and live targets;
//! `state.rs` remains the only canonical `.agents/` writer.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Component, Path};
use std::process::{Command, Stdio};
#[cfg(debug_assertions)]
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};

use crate::schemas::{
    Artifact, ResourceActionReceipt, ResourceActionRecoveryPhase, ResourceActionRecoveryReceipt,
    ResourceActionResult, ResourceActionStatus, ResourceCapability, ResourceEntry,
    ResourceObservation, ResourceOpenTarget, ResourceOperationKind, ResourceOperationRequest,
    ResourceOwnership, ResourceStatus, RunResult, RuntimeResource, RuntimeResourceTarget,
};
use crate::state::{validate_action_id, Workspace};

fn digest_bytes(bytes: &[u8]) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("fnv1a64:{hash:016x}")
}

fn request_digest(request: &ResourceOperationRequest) -> Result<String> {
    Ok(digest_bytes(&serde_json::to_vec(request)?))
}

#[cfg(debug_assertions)]
static TEST_RESOURCE_FAULT_FIRED: AtomicBool = AtomicBool::new(false);

#[cfg(debug_assertions)]
fn test_resource_fault(action_id: &str, point: &str) -> Result<()> {
    let expected = format!("{action_id}:{point}");
    if std::env::var("YARDLET_TEST_RESOURCE_ACTION_FAULT")
        .ok()
        .as_deref()
        != Some(expected.as_str())
    {
        return Ok(());
    }
    if point.starts_with("after_") {
        if point == "after_spawn_before_recovery" {
            std::thread::sleep(Duration::from_millis(50));
        }
        std::process::exit(86);
    }
    if !TEST_RESOURCE_FAULT_FIRED.swap(true, Ordering::SeqCst) {
        bail!("injected {point} failure");
    }
    Ok(())
}

#[cfg(debug_assertions)]
fn test_resource_spawn_gap_fault(action_id: &str, pid: u32) -> Result<()> {
    let point = "after_spawn_before_recovery";
    let expected = format!("{action_id}:{point}");
    if std::env::var("YARDLET_TEST_RESOURCE_ACTION_FAULT")
        .ok()
        .as_deref()
        == Some(expected.as_str())
    {
        if let Ok(path) = std::env::var("YARDLET_TEST_RESOURCE_ACTION_TRACE") {
            std::fs::write(path, format!("{pid}\n"))?;
        }
    }
    test_resource_fault(action_id, point)
}

#[cfg(not(debug_assertions))]
fn test_resource_spawn_gap_fault(_action_id: &str, _pid: u32) -> Result<()> {
    Ok(())
}

#[cfg(not(debug_assertions))]
fn test_resource_fault(_action_id: &str, _point: &str) -> Result<()> {
    Ok(())
}

fn safe_relative_path(path: &Path) -> bool {
    !path.as_os_str().is_empty()
        && !path.is_absolute()
        && path.components().all(|component| {
            !matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn ingest_run_proposals(
    ws: &Workspace,
    session_id: &str,
    intent_id: &str,
    task_id: &str,
    attempt_id: &str,
    worker_id: &str,
    worker_root: &Path,
    result: &RunResult,
) -> Result<()> {
    let errors = result.resource_provenance_errors(attempt_id);
    if !errors.is_empty() {
        bail!(
            "invalid resource proposal provenance: {}",
            errors.join("; ")
        );
    }
    let canonical_root = std::fs::canonicalize(worker_root)
        .with_context(|| format!("canonicalizing worker root {}", worker_root.display()))?;
    for proposal in &result.artifacts {
        if proposal.task_id != task_id || proposal.producer.worker_id != worker_id {
            bail!(
                "artifact proposal producer linkage conflict: {}",
                proposal.proposal_id
            );
        }
        let relative = Path::new(&proposal.path);
        if !safe_relative_path(relative) {
            bail!("artifact path is not workspace-relative: {}", proposal.path);
        }
        let path = worker_root.join(relative);
        let canonical_path = std::fs::canonicalize(&path)
            .with_context(|| format!("opening proposed artifact {}", path.display()))?;
        if canonical_path.strip_prefix(&canonical_root).is_err() || !canonical_path.is_file() {
            bail!(
                "artifact path escapes worker root or is not a file: {}",
                proposal.path
            );
        }
        let bytes = std::fs::read(&canonical_path)
            .with_context(|| format!("reading proposed artifact {}", canonical_path.display()))?;
        let actual_digest = digest_bytes(&bytes);
        if actual_digest != proposal.digest {
            bail!(
                "artifact digest mismatch for {}: expected {}, got {}",
                proposal.proposal_id,
                proposal.digest,
                actual_digest
            );
        }
        // Everything in `result.artifacts` crossed the worker contract, so
        // authorship is a property of this ingest path, not a claim the
        // proposal gets to make (or omit, as pre-field workers do).
        let mut proposal = proposal.clone();
        proposal.worker_authored = Some(true);
        ws.publish_artifact(
            session_id,
            intent_id,
            &proposal,
            &canonical_path.display().to_string(),
        )?;
    }
    for proposal in &result.resources {
        if proposal.task_id != task_id || proposal.producer.worker_id != worker_id {
            bail!(
                "resource proposal producer linkage conflict: {}",
                proposal.proposal_id
            );
        }
        ws.publish_runtime_resource(session_id, intent_id, proposal)?;
    }
    ws.load_or_rebuild_resource_index()?;
    Ok(())
}

fn artifact_entry(ws: &Workspace, artifact: Artifact) -> ResourceEntry {
    let preferred = if artifact.source_path.is_empty() {
        &artifact.path
    } else {
        &artifact.source_path
    };
    let path = Path::new(preferred);
    let resolved = if path.is_absolute() {
        path.to_path_buf()
    } else {
        ws.root.join(path)
    };
    let fallback = ws.root.join(&artifact.path);
    let resolved = if resolved.is_file() || !fallback.is_file() {
        resolved
    } else {
        fallback
    };
    let available = std::fs::read(&resolved)
        .ok()
        .is_some_and(|bytes| digest_bytes(&bytes) == artifact.digest);
    let status = if available {
        ResourceStatus::Available
    } else {
        ResourceStatus::Unavailable
    };
    let open_target = if available {
        ResourceOpenTarget::File {
            path: resolved.display().to_string(),
            media_type: artifact.media_type.clone(),
        }
    } else {
        ResourceOpenTarget::Unavailable {
            reason: format!(
                "artifact is missing or digest-mismatched: {}",
                artifact.path
            ),
        }
    };
    ResourceEntry::Artifact {
        artifact,
        status,
        open_target,
    }
}

fn resource_open_target(resource: &RuntimeResource) -> ResourceOpenTarget {
    match &resource.target {
        RuntimeResourceTarget::Terminal {
            terminal_id,
            attach_hint,
            ..
        } => ResourceOpenTarget::TerminalSession {
            terminal_id: terminal_id.clone(),
            attach_hint: attach_hint.clone(),
        },
        RuntimeResourceTarget::Process { pid, .. } => {
            ResourceOpenTarget::ProcessMonitor { pid: *pid }
        }
        RuntimeResourceTarget::Service { url, .. } | RuntimeResourceTarget::Browser { url, .. } => {
            ResourceOpenTarget::Url { url: url.clone() }
        }
    }
}

fn runtime_entry(ws: &Workspace, resource: RuntimeResource) -> Result<ResourceEntry> {
    let last_observation = ws
        .load_resource_observations(&resource.resource_id)?
        .into_iter()
        .last();
    Ok(ResourceEntry::RuntimeResource {
        open_target: resource_open_target(&resource),
        resource,
        // A persisted observation is last-observed evidence, not a current
        // claim in a fresh CLI/core process. `reconcile` returns its new probe
        // result directly and appends a new canonical observation.
        status: ResourceStatus::Unknown,
        last_observation,
    })
}

#[derive(Debug, Clone)]
struct Probe {
    status: ResourceStatus,
    pid: Option<u32>,
    start_identity: String,
    detail: String,
}

fn process_identity(pid: u32) -> Option<String> {
    if pid == 0 {
        return None;
    }
    let output = Command::new("ps")
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let normalized = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    (!normalized.is_empty()).then_some(normalized)
}

fn effective_process(ws: &Workspace, resource: &RuntimeResource) -> Result<Option<(u32, String)>> {
    if let Some(observation) = ws
        .load_resource_observations(&resource.resource_id)?
        .into_iter()
        .last()
    {
        if observation.status != ResourceStatus::Orphaned && !observation.start_identity.is_empty()
        {
            if let Some(pid) = observation.pid {
                return Ok(Some((pid, observation.start_identity)));
            }
        }
        if observation.status == ResourceStatus::Unrecoverable {
            return Ok(None);
        }
    }
    Ok(match &resource.target {
        RuntimeResourceTarget::Terminal {
            pid,
            start_identity,
            ..
        }
        | RuntimeResourceTarget::Process {
            pid,
            start_identity,
            ..
        } => Some((*pid, start_identity.clone())),
        RuntimeResourceTarget::Service {
            pid: Some(pid),
            start_identity,
            ..
        }
        | RuntimeResourceTarget::Browser {
            pid: Some(pid),
            start_identity,
            ..
        } => Some((*pid, start_identity.clone())),
        _ => None,
    })
}

fn probe_process(pid: u32, expected_identity: &str) -> Probe {
    match process_identity(pid) {
        None => Probe {
            status: ResourceStatus::Dead,
            pid: Some(pid),
            start_identity: expected_identity.to_string(),
            detail: "process is not present".to_string(),
        },
        Some(actual) if actual != expected_identity => Probe {
            status: ResourceStatus::Orphaned,
            pid: Some(pid),
            start_identity: actual,
            detail: "pid exists but process start identity does not match".to_string(),
        },
        Some(actual) => Probe {
            status: ResourceStatus::Live,
            pid: Some(pid),
            start_identity: actual,
            detail: "process identity probe matched".to_string(),
        },
    }
}

fn url_socket(url: &str) -> Option<SocketAddr> {
    let (scheme, rest) = url.split_once("://")?;
    let authority = rest.split('/').next()?;
    let default_port = if scheme.eq_ignore_ascii_case("https") {
        443
    } else {
        80
    };
    let (host, port) = authority
        .rsplit_once(':')
        .and_then(|(host, port)| port.parse::<u16>().ok().map(|port| (host, port)))
        .unwrap_or((authority, default_port));
    (host, port).to_socket_addrs().ok()?.next()
}

enum HttpProbe {
    Response { status: u16, body: String },
    Unavailable(String),
    Unrecoverable(String),
}

fn probe_http(url: &str) -> HttpProbe {
    let Some((scheme, rest)) = url.split_once("://") else {
        return HttpProbe::Unrecoverable("URL has no scheme".to_string());
    };
    if !scheme.eq_ignore_ascii_case("http") {
        return HttpProbe::Unrecoverable(format!("unsupported semantic probe scheme {scheme}"));
    }
    let (authority, path) = rest
        .split_once('/')
        .map(|(authority, path)| (authority, format!("/{path}")))
        .unwrap_or((rest, "/".to_string()));
    if authority.is_empty() {
        return HttpProbe::Unrecoverable("URL has no authority".to_string());
    }
    let Some(address) = url_socket(url) else {
        return HttpProbe::Unrecoverable("URL cannot be resolved".to_string());
    };
    let mut stream = match TcpStream::connect_timeout(&address, Duration::from_millis(300)) {
        Ok(stream) => stream,
        Err(error) => {
            return HttpProbe::Unavailable(format!(
                "HTTP probe could not connect to {address}: {error}"
            ))
        }
    };
    let timeout = Some(Duration::from_millis(500));
    let _ = stream.set_read_timeout(timeout);
    let _ = stream.set_write_timeout(timeout);
    if let Err(error) = write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\nAccept: application/json\r\n\r\n"
    ) {
        return HttpProbe::Unavailable(format!("HTTP probe write failed: {error}"));
    }
    let mut bytes = Vec::new();
    if let Err(error) = stream.take(64 * 1024).read_to_end(&mut bytes) {
        return HttpProbe::Unavailable(format!("HTTP probe read failed: {error}"));
    }
    let response = String::from_utf8_lossy(&bytes);
    let Some(head_end) = response.find("\r\n\r\n") else {
        return HttpProbe::Unrecoverable("HTTP probe returned a malformed response".to_string());
    };
    let status = response
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|status| status.parse::<u16>().ok());
    let Some(status) = status else {
        return HttpProbe::Unrecoverable("HTTP probe returned no status code".to_string());
    };
    HttpProbe::Response {
        status,
        body: response[head_end + 4..].to_string(),
    }
}

fn browser_session_attested(body: &str, session_id: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|value| {
            value
                .get("session_id")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string)
        })
        .as_deref()
        == Some(session_id)
}

fn probe_service_semantics(
    url: &str,
    health_url: &str,
    observed_pid: Option<u32>,
    start_identity: String,
) -> Probe {
    if health_url.trim().is_empty() {
        let Some(address) = url_socket(url) else {
            return Probe {
                status: ResourceStatus::Unrecoverable,
                pid: observed_pid,
                start_identity,
                detail: "service URL cannot be parsed for a local probe".to_string(),
            };
        };
        let reachable = TcpStream::connect_timeout(&address, Duration::from_millis(200)).is_ok();
        return Probe {
            status: if reachable {
                ResourceStatus::Unknown
            } else {
                ResourceStatus::Unavailable
            },
            pid: observed_pid,
            start_identity,
            detail: if reachable {
                format!(
                    "service port {address} is reachable but no semantic health_url was declared"
                )
            } else {
                format!("service socket probe could not reach {address}")
            },
        };
    }
    let (status, detail) = match probe_http(health_url) {
        HttpProbe::Response { status, .. } if (200..300).contains(&status) => (
            ResourceStatus::Live,
            format!("declared health URL returned HTTP {status}"),
        ),
        HttpProbe::Response { status, .. } => (
            ResourceStatus::Unavailable,
            format!("declared health URL returned HTTP {status}"),
        ),
        HttpProbe::Unavailable(detail) => (ResourceStatus::Unavailable, detail),
        HttpProbe::Unrecoverable(detail) => (ResourceStatus::Unrecoverable, detail),
    };
    Probe {
        status,
        pid: observed_pid,
        start_identity,
        detail,
    }
}

fn probe_resource(ws: &Workspace, resource: &RuntimeResource) -> Result<Probe> {
    match &resource.target {
        RuntimeResourceTarget::Terminal { .. } | RuntimeResourceTarget::Process { .. } => {
            let (pid, identity) = effective_process(ws, resource)?
                .ok_or_else(|| anyhow!("process resource lacks identity"))?;
            Ok(probe_process(pid, &identity))
        }
        RuntimeResourceTarget::Service {
            url,
            health_url,
            pid,
            ..
        } => {
            if pid.is_some() {
                let (pid, identity) = effective_process(ws, resource)?
                    .ok_or_else(|| anyhow!("service process lacks identity"))?;
                let process = probe_process(pid, &identity);
                if process.status != ResourceStatus::Live {
                    return Ok(process);
                }
            }
            let process = effective_process(ws, resource)?;
            let (observed_pid, start_identity) = process
                .map(|(pid, identity)| (Some(pid), identity))
                .unwrap_or_default();
            Ok(probe_service_semantics(
                url,
                health_url,
                observed_pid,
                start_identity,
            ))
        }
        RuntimeResourceTarget::Browser {
            session_id,
            session_probe_url,
            pid,
            ..
        } => {
            let process = if pid.is_some() {
                let (pid, identity) = effective_process(ws, resource)?
                    .ok_or_else(|| anyhow!("browser process lacks identity"))?;
                let mut process = probe_process(pid, &identity);
                if process.status == ResourceStatus::Dead {
                    process.status = ResourceStatus::Expired;
                    process.detail = "browser session process expired".to_string();
                    return Ok(process);
                }
                if process.status != ResourceStatus::Live {
                    return Ok(process);
                }
                Some(process)
            } else {
                None
            };
            let observed_pid = process.as_ref().and_then(|process| process.pid);
            let start_identity = process
                .as_ref()
                .map(|process| process.start_identity.clone())
                .unwrap_or_default();
            if session_id.trim().is_empty() {
                return Ok(Probe {
                    status: ResourceStatus::Unrecoverable,
                    pid: observed_pid,
                    start_identity,
                    detail: "browser target has no session identity to probe".to_string(),
                });
            }
            if session_probe_url.trim().is_empty() {
                return Ok(Probe {
                    status: if process.is_some() {
                        ResourceStatus::Unknown
                    } else {
                        ResourceStatus::Expired
                    },
                    pid: observed_pid,
                    start_identity,
                    detail: "browser session has no semantic session probe".to_string(),
                });
            }
            let (status, detail) = match probe_http(session_probe_url) {
                HttpProbe::Response { status, body }
                    if (200..300).contains(&status)
                        && browser_session_attested(&body, session_id) =>
                {
                    (
                        ResourceStatus::Live,
                        "browser session probe attested the declared session".to_string(),
                    )
                }
                HttpProbe::Response { status, .. } => (
                    ResourceStatus::Expired,
                    format!(
                        "browser session probe HTTP {status} did not attest the declared session"
                    ),
                ),
                HttpProbe::Unavailable(detail) => (ResourceStatus::Unknown, detail),
                HttpProbe::Unrecoverable(detail) => (ResourceStatus::Unrecoverable, detail),
            };
            Ok(Probe {
                status,
                pid: observed_pid,
                start_identity,
                detail,
            })
        }
    }
}

fn owned_for_destructive_action(ownership: ResourceOwnership) -> bool {
    matches!(
        ownership,
        ResourceOwnership::Yardlet | ResourceOwnership::Worker
    )
}

fn terminate_exact_process(probe: &Probe) -> Result<()> {
    if probe.status != ResourceStatus::Live {
        bail!("process is not live with a matching identity");
    }
    let pid = probe.pid.ok_or_else(|| anyhow!("process pid is missing"))?;
    // SAFETY: the current probe matched both pid and start identity. The caller
    // separately verified canonical ownership before reaching this function.
    let result = unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
    if result != 0 {
        return Err(std::io::Error::last_os_error()).context("stopping owned resource process");
    }
    for _ in 0..40 {
        if process_identity(pid).is_none() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    bail!("owned process did not stop after SIGTERM")
}

fn restart_command(resource: &RuntimeResource) -> &[String] {
    match &resource.target {
        RuntimeResourceTarget::Process { command, .. } => command,
        RuntimeResourceTarget::Service {
            restart_command, ..
        } => restart_command,
        _ => &[],
    }
}

fn persist_probe(
    ws: &Workspace,
    resource: &RuntimeResource,
    probe: &Probe,
    requested_event: &str,
    action_id: &str,
) -> Result<ResourceObservation> {
    ws.record_resource_observation(
        resource,
        probe.status,
        true,
        probe.pid,
        &probe.start_identity,
        &probe.detail,
        requested_event,
        action_id,
    )
}

fn save_recovery_phase(
    ws: &Workspace,
    recovery: &mut ResourceActionRecoveryReceipt,
    phase: ResourceActionRecoveryPhase,
    pid: Option<u32>,
    start_identity: String,
) -> Result<()> {
    recovery.phase = phase;
    recovery.effect_pid = pid;
    recovery.effect_start_identity = start_identity;
    ws.save_resource_action_recovery(recovery)
}

fn probe_restarted_resource(
    resource: &RuntimeResource,
    pid: u32,
    expected_identity: &str,
) -> Probe {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let mut process = probe_process(pid, expected_identity);
        if process.status != ResourceStatus::Live {
            process.status = match process.status {
                ResourceStatus::Dead => ResourceStatus::Unavailable,
                ResourceStatus::Orphaned => ResourceStatus::Unrecoverable,
                status => status,
            };
            process.detail = "restarted process is not live with its recorded identity".to_string();
            return process;
        }
        let probe = match &resource.target {
            RuntimeResourceTarget::Process { .. } => {
                process.detail =
                    "restart command spawned a process with a verified identity".to_string();
                process
            }
            RuntimeResourceTarget::Service {
                url, health_url, ..
            } => probe_service_semantics(url, health_url, Some(pid), process.start_identity),
            _ => Probe {
                status: ResourceStatus::Unrecoverable,
                pid: Some(pid),
                start_identity: process.start_identity,
                detail: "resource kind has no restart probe contract".to_string(),
            },
        };
        let endpoint_responded = probe
            .detail
            .starts_with("declared health URL returned HTTP");
        if probe.status != ResourceStatus::Unavailable
            || endpoint_responded
            || Instant::now() >= deadline
        {
            return probe;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn destructive_process_probe(resource: &RuntimeResource, observed: &Probe) -> Probe {
    match (&resource.target, observed.pid) {
        (RuntimeResourceTarget::Service { pid: Some(_), .. }, Some(pid)) => {
            probe_process(pid, &observed.start_identity)
        }
        _ => observed.clone(),
    }
}

#[allow(clippy::too_many_arguments)]
fn lifecycle_result(
    ws: &Workspace,
    resource: &RuntimeResource,
    operation: ResourceOperationKind,
    expected_status: ResourceStatus,
    requested_event: &str,
    action_id: &str,
    recovery: &mut ResourceActionRecoveryReceipt,
    recovery_loaded: bool,
) -> Result<(ResourceActionStatus, ResourceActionResult, String)> {
    if operation == ResourceOperationKind::Restart
        && recovery.phase == ResourceActionRecoveryPhase::Spawned
    {
        test_resource_fault(action_id, "probe")?;
        let pid = recovery
            .effect_pid
            .ok_or_else(|| anyhow!("spawn recovery is missing its pid"))?;
        if recovery.effect_start_identity.is_empty() {
            let identity = process_identity(pid)
                .ok_or_else(|| anyhow!("spawned process disappeared before identity recovery"))?;
            save_recovery_phase(
                ws,
                recovery,
                ResourceActionRecoveryPhase::Spawned,
                Some(pid),
                identity,
            )?;
        }
        let restarted = probe_restarted_resource(resource, pid, &recovery.effect_start_identity);
        let observation = persist_probe(ws, resource, &restarted, requested_event, action_id)?;
        let status = if restarted.status == ResourceStatus::Live {
            ResourceActionStatus::Completed
        } else {
            ResourceActionStatus::Rejected
        };
        let error = if status == ResourceActionStatus::Completed {
            String::new()
        } else {
            format!(
                "restarted resource failed its current liveness gate: {}",
                restarted.detail
            )
        };
        return Ok((
            status,
            ResourceActionResult {
                observation: Some(observation),
                ..Default::default()
            },
            error,
        ));
    }

    if matches!(
        operation,
        ResourceOperationKind::Stop | ResourceOperationKind::Cleanup
    ) && recovery.phase == ResourceActionRecoveryPhase::Terminated
    {
        let stopped = Probe {
            status: ResourceStatus::Dead,
            pid: recovery.effect_pid,
            start_identity: recovery.effect_start_identity.clone(),
            detail: "recovered durable termination effect without signalling again".to_string(),
        };
        let observation = persist_probe(ws, resource, &stopped, requested_event, action_id)?;
        return Ok((
            ResourceActionStatus::Completed,
            ResourceActionResult {
                observation: Some(observation),
                ..Default::default()
            },
            String::new(),
        ));
    }

    if operation == ResourceOperationKind::Restart
        && recovery_loaded
        && recovery.phase == ResourceActionRecoveryPhase::Terminated
    {
        let probe = Probe {
            status: ResourceStatus::Unrecoverable,
            pid: None,
            start_identity: String::new(),
            detail: "restart may have spawned a child before recovery identity was persisted"
                .to_string(),
        };
        let observation = persist_probe(ws, resource, &probe, requested_event, action_id)?;
        return Ok((
            ResourceActionStatus::Rejected,
            ResourceActionResult {
                observation: Some(observation),
                ..Default::default()
            },
            "terminated restart recovery is ambiguous; refusing to spawn without a durably recorded child identity"
                .to_string(),
        ));
    }

    test_resource_fault(action_id, "probe")?;
    let probe = probe_resource(ws, resource)?;
    if recovery_loaded
        && recovery.phase == ResourceActionRecoveryPhase::Prepared
        && matches!(
            operation,
            ResourceOperationKind::Stop
                | ResourceOperationKind::Restart
                | ResourceOperationKind::Cleanup
        )
        && owned_for_destructive_action(resource.ownership)
    {
        let mutation_probe = destructive_process_probe(resource, &probe);
        if matches!(
            operation,
            ResourceOperationKind::Stop | ResourceOperationKind::Cleanup
        ) && mutation_probe.status == ResourceStatus::Dead
        {
            save_recovery_phase(
                ws,
                recovery,
                ResourceActionRecoveryPhase::Terminated,
                mutation_probe.pid,
                mutation_probe.start_identity.clone(),
            )?;
            let stopped = Probe {
                detail: "recovered a prepared action by observing the exact process already dead"
                    .to_string(),
                ..mutation_probe
            };
            let observation = persist_probe(ws, resource, &stopped, requested_event, action_id)?;
            return Ok((
                ResourceActionStatus::Completed,
                ResourceActionResult {
                    observation: Some(observation),
                    ..Default::default()
                },
                String::new(),
            ));
        }
        let observation = persist_probe(ws, resource, &probe, requested_event, action_id)?;
        return Ok((
            ResourceActionStatus::Rejected,
            ResourceActionResult {
                observation: Some(observation),
                ..Default::default()
            },
            "prepared action recovery is ambiguous; refusing to repeat a destructive side effect"
                .to_string(),
        ));
    }
    if recovery.phase == ResourceActionRecoveryPhase::Prepared && probe.status != expected_status {
        let observation = persist_probe(ws, resource, &probe, requested_event, action_id)?;
        return Ok((
            ResourceActionStatus::Rejected,
            ResourceActionResult {
                observation: Some(observation),
                ..Default::default()
            },
            format!(
                "expected status {:?}, current probe found {:?}",
                expected_status, probe.status
            ),
        ));
    }

    if operation == ResourceOperationKind::Reconcile {
        let observation = persist_probe(ws, resource, &probe, requested_event, action_id)?;
        return Ok((
            ResourceActionStatus::Completed,
            ResourceActionResult {
                observation: Some(observation),
                ..Default::default()
            },
            String::new(),
        ));
    }

    if operation == ResourceOperationKind::Detach {
        let detached = Probe {
            status: ResourceStatus::Detached,
            detail: "detached without changing the target process".to_string(),
            ..probe
        };
        let observation = persist_probe(ws, resource, &detached, requested_event, action_id)?;
        return Ok((
            ResourceActionStatus::Completed,
            ResourceActionResult {
                observation: Some(observation),
                ..Default::default()
            },
            String::new(),
        ));
    }

    if !owned_for_destructive_action(resource.ownership) {
        let observation = persist_probe(ws, resource, &probe, requested_event, action_id)?;
        return Ok((
            ResourceActionStatus::Rejected,
            ResourceActionResult {
                observation: Some(observation),
                ..Default::default()
            },
            format!(
                "ownership {:?} forbids destructive resource operations",
                resource.ownership
            ),
        ));
    }
    if probe.status == ResourceStatus::Orphaned {
        let observation = persist_probe(ws, resource, &probe, requested_event, action_id)?;
        return Ok((
            ResourceActionStatus::Rejected,
            ResourceActionResult {
                observation: Some(observation),
                ..Default::default()
            },
            "process identity mismatch; refusing to signal the pid".to_string(),
        ));
    }
    let mutation_probe = destructive_process_probe(resource, &probe);

    match operation {
        ResourceOperationKind::Stop | ResourceOperationKind::Cleanup => {
            if mutation_probe.status == ResourceStatus::Live {
                test_resource_fault(action_id, "terminate")?;
                terminate_exact_process(&mutation_probe)?;
            } else if mutation_probe.status != ResourceStatus::Dead {
                let observation = persist_probe(ws, resource, &probe, requested_event, action_id)?;
                return Ok((
                    ResourceActionStatus::Rejected,
                    ResourceActionResult {
                        observation: Some(observation),
                        ..Default::default()
                    },
                    format!(
                        "cannot {:?} resource in {:?} state",
                        operation, probe.status
                    ),
                ));
            }
            save_recovery_phase(
                ws,
                recovery,
                ResourceActionRecoveryPhase::Terminated,
                mutation_probe.pid,
                mutation_probe.start_identity.clone(),
            )?;
            test_resource_fault(action_id, "after_terminate")?;
            let stopped = Probe {
                status: ResourceStatus::Dead,
                detail: if operation == ResourceOperationKind::Cleanup {
                    "owned resource cleanup confirmed process dead".to_string()
                } else {
                    "owned resource stop confirmed process dead".to_string()
                },
                ..mutation_probe
            };
            let observation = persist_probe(ws, resource, &stopped, requested_event, action_id)?;
            Ok((
                ResourceActionStatus::Completed,
                ResourceActionResult {
                    observation: Some(observation),
                    ..Default::default()
                },
                String::new(),
            ))
        }
        ResourceOperationKind::Restart => {
            let command = restart_command(resource);
            if command.is_empty() {
                let observation = persist_probe(ws, resource, &probe, requested_event, action_id)?;
                return Ok((
                    ResourceActionStatus::Rejected,
                    ResourceActionResult {
                        observation: Some(observation),
                        ..Default::default()
                    },
                    "resource has no typed restart command".to_string(),
                ));
            }
            if recovery.phase == ResourceActionRecoveryPhase::Prepared {
                if mutation_probe.status == ResourceStatus::Live {
                    test_resource_fault(action_id, "terminate")?;
                    terminate_exact_process(&mutation_probe)?;
                } else if mutation_probe.status != ResourceStatus::Dead {
                    let observation =
                        persist_probe(ws, resource, &probe, requested_event, action_id)?;
                    return Ok((
                        ResourceActionStatus::Rejected,
                        ResourceActionResult {
                            observation: Some(observation),
                            ..Default::default()
                        },
                        format!("cannot restart resource in {:?} state", probe.status),
                    ));
                }
                save_recovery_phase(
                    ws,
                    recovery,
                    ResourceActionRecoveryPhase::Terminated,
                    mutation_probe.pid,
                    mutation_probe.start_identity,
                )?;
                test_resource_fault(action_id, "after_terminate")?;
            }

            test_resource_fault(action_id, "spawn")?;
            #[cfg(unix)]
            let mut child = {
                let mut child = Command::new("nohup");
                child.arg(&command[0]);
                child
            };
            #[cfg(not(unix))]
            let mut child = Command::new(&command[0]);
            child
                .args(&command[1..])
                .current_dir(&ws.root)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            #[cfg(unix)]
            {
                use std::os::unix::process::CommandExt;
                child.process_group(0);
            }
            let child = child.spawn().context("starting owned resource")?;
            let pid = child.id();
            drop(child);
            test_resource_spawn_gap_fault(action_id, pid)?;
            save_recovery_phase(
                ws,
                recovery,
                ResourceActionRecoveryPhase::Spawned,
                Some(pid),
                String::new(),
            )?;
            let mut identity = None;
            for _ in 0..20 {
                identity = process_identity(pid);
                if identity.is_some() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            let identity =
                identity.ok_or_else(|| anyhow!("restarted process could not be probed"))?;
            save_recovery_phase(
                ws,
                recovery,
                ResourceActionRecoveryPhase::Spawned,
                Some(pid),
                identity.clone(),
            )?;
            test_resource_fault(action_id, "after_spawn")?;
            let restarted = probe_restarted_resource(resource, pid, &identity);
            let observation = persist_probe(ws, resource, &restarted, requested_event, action_id)?;
            let status = if restarted.status == ResourceStatus::Live {
                ResourceActionStatus::Completed
            } else {
                ResourceActionStatus::Rejected
            };
            let error = if status == ResourceActionStatus::Completed {
                String::new()
            } else {
                format!(
                    "restarted resource failed its current liveness gate: {}",
                    restarted.detail
                )
            };
            Ok((
                status,
                ResourceActionResult {
                    observation: Some(observation),
                    ..Default::default()
                },
                error,
            ))
        }
        _ => unreachable!("non-lifecycle operation reached lifecycle dispatcher"),
    }
}

fn discover_entries(ws: &Workspace, intent_id: &str, task_id: &str) -> Result<Vec<ResourceEntry>> {
    let index = ws.load_or_rebuild_resource_index()?;
    let mut entries = Vec::new();
    let task_index = index
        .tasks
        .iter()
        .find(|entry| entry.intent_id == intent_id && entry.task_id == task_id);
    if task_index.is_none_or(|entry| entry.truncated) {
        for artifact in ws
            .load_artifacts()?
            .into_iter()
            .filter(|artifact| artifact.intent_id == intent_id && artifact.task_id == task_id)
        {
            entries.push(artifact_entry(ws, artifact));
        }
        for resource in ws
            .load_runtime_resources()?
            .into_iter()
            .filter(|resource| resource.intent_id == intent_id && resource.task_id == task_id)
        {
            entries.push(runtime_entry(ws, resource)?);
        }
    } else if let Some(task_index) = task_index {
        for artifact_id in &task_index.artifacts {
            if let Some(artifact) = ws.load_artifact(artifact_id)? {
                entries.push(artifact_entry(ws, artifact));
            }
        }
        for resource_id in &task_index.resources {
            if let Some(resource) = ws.load_runtime_resource(resource_id)? {
                entries.push(runtime_entry(ws, resource)?);
            }
        }
    }
    Ok(entries)
}

fn inspect_entry(ws: &Workspace, target_id: &str) -> Result<ResourceEntry> {
    if let Some(artifact) = ws.load_artifact(target_id)? {
        return Ok(artifact_entry(ws, artifact));
    }
    if let Some(resource) = ws.load_runtime_resource(target_id)? {
        return runtime_entry(ws, resource);
    }
    bail!("resource target not found: {target_id}")
}

fn entry_task_context(entry: &ResourceEntry) -> (&str, &str, &str) {
    match entry {
        ResourceEntry::Artifact { artifact, .. } => {
            (&artifact.session_id, &artifact.intent_id, &artifact.task_id)
        }
        ResourceEntry::RuntimeResource { resource, .. } => {
            (&resource.session_id, &resource.intent_id, &resource.task_id)
        }
    }
}

fn open_target(entry: &ResourceEntry) -> ResourceOpenTarget {
    match entry {
        ResourceEntry::Artifact { open_target, .. }
        | ResourceEntry::RuntimeResource { open_target, .. } => open_target.clone(),
    }
}

fn operation_capability(operation: ResourceOperationKind) -> Option<ResourceCapability> {
    match operation {
        ResourceOperationKind::Discover | ResourceOperationKind::Inspect => None,
        ResourceOperationKind::Open => Some(ResourceCapability::Open),
        ResourceOperationKind::Attach => Some(ResourceCapability::Attach),
        ResourceOperationKind::Stop => Some(ResourceCapability::Stop),
        ResourceOperationKind::Restart => Some(ResourceCapability::Restart),
        ResourceOperationKind::Detach => Some(ResourceCapability::Detach),
        ResourceOperationKind::Cleanup => Some(ResourceCapability::Cleanup),
        ResourceOperationKind::Reconcile => Some(ResourceCapability::Reconcile),
    }
}

fn runtime_supports(resource: &RuntimeResource, operation: ResourceOperationKind) -> bool {
    operation_capability(operation)
        .is_none_or(|capability| resource.capabilities.contains(&capability))
}

fn action_event_id(action_id: &str, suffix: &str) -> String {
    format!(
        "evt_resource_action_{}_{}",
        digest_bytes(action_id.as_bytes()).trim_start_matches("fnv1a64:"),
        suffix
    )
}

#[allow(clippy::too_many_arguments)]
fn record_action_event(
    ws: &Workspace,
    action_id: &str,
    suffix: &str,
    event_type: crate::schemas::ChannelEventType,
    operation: ResourceOperationKind,
    session_id: &str,
    intent_id: &str,
    task_id: &str,
    target_id: &str,
    causation_id: Option<String>,
    error: &str,
) -> Result<String> {
    let event = ws.record_task_event(
        intent_id,
        crate::schemas::ChannelEvent {
            schema_version: 1,
            event_id: action_event_id(action_id, suffix),
            session_id: session_id.to_string(),
            seq: 0,
            event_type,
            recorded_at: String::new(),
            actor: crate::schemas::EventActor {
                kind: crate::schemas::EventActorKind::Surface,
                id: "cli".to_string(),
            },
            action_id: Some(action_id.to_string()),
            causation_id,
            correlation_id: format!("cor_resource_{task_id}"),
            task_id: task_id.to_string(),
            attempt_id: None,
            payload: serde_json::json!({
                "operation": operation,
                "target_id": target_id,
                "error": error
            }),
            raw_ref: None,
        },
    )?;
    Ok(event.event_id)
}

#[allow(clippy::too_many_arguments)]
fn ensure_receipt_events(
    ws: &Workspace,
    receipt: &ResourceActionReceipt,
    session_id: &str,
    intent_id: &str,
    task_id: &str,
) -> Result<()> {
    let requested_event = record_action_event(
        ws,
        &receipt.action_id,
        "requested",
        crate::schemas::ChannelEventType::ActionRequested,
        receipt.operation,
        session_id,
        intent_id,
        task_id,
        &receipt.target_id,
        None,
        "",
    )?;
    let (suffix, event_type) = if receipt.status == ResourceActionStatus::Completed {
        (
            "completed",
            crate::schemas::ChannelEventType::ActionCompleted,
        )
    } else {
        ("rejected", crate::schemas::ChannelEventType::ActionRejected)
    };
    record_action_event(
        ws,
        &receipt.action_id,
        suffix,
        event_type,
        receipt.operation,
        session_id,
        intent_id,
        task_id,
        &receipt.target_id,
        Some(requested_event),
        &receipt.error,
    )?;
    Ok(())
}

pub fn dispatch(
    ws: &Workspace,
    request: ResourceOperationRequest,
) -> Result<ResourceActionReceipt> {
    validate_action_id(&request.action_id)?;
    let digest = request_digest(&request)?;

    let (entries, context_entry) = match request.operation {
        ResourceOperationKind::Discover => {
            if request.intent_id.trim().is_empty() || request.task_id.trim().is_empty() {
                bail!("discover requires intent_id and task_id");
            }
            let entries = discover_entries(ws, &request.intent_id, &request.task_id)?;
            let context = entries.first().cloned();
            (entries, context)
        }
        _ => {
            if request.target_id.trim().is_empty() {
                bail!(
                    "{} requires target_id",
                    format!("{:?}", request.operation).to_lowercase()
                );
            }
            let entry = inspect_entry(ws, &request.target_id)?;
            (vec![entry.clone()], Some(entry))
        }
    };
    let context_entry = context_entry.ok_or_else(|| anyhow!("task has no published resources"))?;
    let (session_id, intent_id, actual_task_id) = entry_task_context(&context_entry);
    let session_id = session_id.to_string();
    let intent_id = intent_id.to_string();
    let actual_task_id = actual_task_id.to_string();
    if !request.intent_id.is_empty() && request.intent_id != intent_id {
        bail!("resource intent linkage conflict");
    }
    if !request.task_id.is_empty() && request.task_id != actual_task_id {
        bail!("resource task linkage conflict");
    }
    if let Some(existing) = ws.load_resource_action(&request.action_id)? {
        if existing.request_digest != digest {
            bail!(
                "idempotency_conflict: action {} changed request",
                request.action_id
            );
        }
        ensure_receipt_events(ws, &existing, &session_id, &intent_id, &actual_task_id)?;
        return Ok(existing);
    }
    let requested_event = record_action_event(
        ws,
        &request.action_id,
        "requested",
        crate::schemas::ChannelEventType::ActionRequested,
        request.operation,
        &session_id,
        &intent_id,
        &actual_task_id,
        &request.target_id,
        None,
        "",
    )?;
    test_resource_fault(&request.action_id, "after_requested")?;

    let prepared = ResourceActionRecoveryReceipt {
        schema_version: 1,
        action_id: request.action_id.clone(),
        request_digest: digest.clone(),
        operation: request.operation,
        intent_id: intent_id.clone(),
        task_id: actual_task_id.clone(),
        target_id: request.target_id.clone(),
        expected_status: request.expected_status,
        requested_event_id: requested_event.clone(),
        phase: ResourceActionRecoveryPhase::Prepared,
        effect_pid: None,
        effect_start_identity: String::new(),
    };
    let (mut recovery, recovery_loaded) =
        if let Some(existing) = ws.load_resource_action_recovery(&request.action_id)? {
            let same_action = existing.action_id == prepared.action_id
                && existing.request_digest == prepared.request_digest
                && existing.operation == prepared.operation
                && existing.intent_id == prepared.intent_id
                && existing.task_id == prepared.task_id
                && existing.target_id == prepared.target_id
                && existing.expected_status == prepared.expected_status
                && existing.requested_event_id == prepared.requested_event_id;
            if !same_action {
                bail!(
                    "idempotency_conflict: action {} changed recovery request",
                    request.action_id
                );
            }
            (existing, true)
        } else {
            ws.save_resource_action_recovery(&prepared)?;
            (prepared, false)
        };
    test_resource_fault(&request.action_id, "after_prepared")?;

    let (status, result, error) = match request.operation {
        ResourceOperationKind::Discover | ResourceOperationKind::Inspect => (
            ResourceActionStatus::Completed,
            ResourceActionResult {
                entries: entries.clone(),
                ..Default::default()
            },
            String::new(),
        ),
        ResourceOperationKind::Open => match &context_entry {
            ResourceEntry::RuntimeResource { resource, .. }
                if !runtime_supports(resource, ResourceOperationKind::Open) =>
            {
                (
                    ResourceActionStatus::Rejected,
                    ResourceActionResult::default(),
                    "open is unsupported for this runtime resource".to_string(),
                )
            }
            _ => (
                ResourceActionStatus::Completed,
                ResourceActionResult {
                    entries: entries.clone(),
                    open_target: Some(open_target(&context_entry)),
                    observation: None,
                },
                String::new(),
            ),
        },
        ResourceOperationKind::Attach => {
            let target = open_target(&context_entry);
            let supported = matches!(
                &context_entry,
                ResourceEntry::RuntimeResource { resource, .. }
                    if runtime_supports(resource, ResourceOperationKind::Attach)
            );
            if supported
                && matches!(
                    target,
                    ResourceOpenTarget::TerminalSession { .. }
                        | ResourceOpenTarget::ProcessMonitor { .. }
                )
            {
                (
                    ResourceActionStatus::Completed,
                    ResourceActionResult {
                        entries: entries.clone(),
                        open_target: Some(target),
                        observation: None,
                    },
                    String::new(),
                )
            } else {
                (
                    ResourceActionStatus::Rejected,
                    ResourceActionResult::default(),
                    "attach is unsupported for this target".to_string(),
                )
            }
        }
        operation @ (ResourceOperationKind::Stop
        | ResourceOperationKind::Restart
        | ResourceOperationKind::Detach
        | ResourceOperationKind::Cleanup
        | ResourceOperationKind::Reconcile) => match &context_entry {
            ResourceEntry::Artifact { .. } => (
                ResourceActionStatus::Rejected,
                ResourceActionResult::default(),
                "lifecycle operation is unsupported for artifacts".to_string(),
            ),
            ResourceEntry::RuntimeResource { resource, .. } => {
                if !runtime_supports(resource, operation) {
                    (
                        ResourceActionStatus::Rejected,
                        ResourceActionResult::default(),
                        format!(
                            "{} is unsupported for this runtime resource",
                            format!("{operation:?}").to_lowercase()
                        ),
                    )
                } else {
                    let lifecycle = lifecycle_result(
                        ws,
                        resource,
                        operation,
                        request.expected_status,
                        &requested_event,
                        &request.action_id,
                        &mut recovery,
                        recovery_loaded,
                    );
                    match lifecycle {
                        Ok((status, mut result, error)) => {
                            result.entries = entries.clone();
                            (status, result, error)
                        }
                        Err(error) => (
                            ResourceActionStatus::Rejected,
                            ResourceActionResult {
                                entries: entries.clone(),
                                ..Default::default()
                            },
                            format!("{error:#}"),
                        ),
                    }
                }
            }
        },
    };
    let terminal_suffix = if status == ResourceActionStatus::Completed {
        "completed"
    } else {
        "rejected"
    };
    let mut receipt = ResourceActionReceipt {
        schema_version: 1,
        action_id: request.action_id.clone(),
        operation: request.operation,
        intent_id: intent_id.clone(),
        task_id: actual_task_id.clone(),
        target_id: request.target_id.clone(),
        request_digest: digest,
        status,
        result,
        result_event_ids: vec![
            requested_event.clone(),
            action_event_id(&request.action_id, terminal_suffix),
        ],
        error,
    };

    if let Err(persistence_error) = test_resource_fault(&request.action_id, "receipt")
        .and_then(|()| ws.save_resource_action(&receipt))
    {
        receipt.status = ResourceActionStatus::Rejected;
        receipt.error = format!("receipt persistence failure: {persistence_error:#}");
        receipt.result_event_ids[1] = action_event_id(&request.action_id, "rejected");
        ws.save_resource_action(&receipt)?;
    }

    let (terminal_suffix, terminal_type) = if receipt.status == ResourceActionStatus::Completed {
        (
            "completed",
            crate::schemas::ChannelEventType::ActionCompleted,
        )
    } else {
        ("rejected", crate::schemas::ChannelEventType::ActionRejected)
    };
    record_action_event(
        ws,
        &request.action_id,
        terminal_suffix,
        terminal_type,
        request.operation,
        &session_id,
        &intent_id,
        &actual_task_id,
        &request.target_id,
        Some(requested_event),
        &receipt.error,
    )?;
    test_resource_fault(&request.action_id, "after_terminal_event")?;
    Ok(receipt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;

    #[cfg(unix)]
    #[test]
    fn restarted_service_waits_for_a_slow_but_healthy_local_endpoint() {
        let mut child = Command::new("/bin/sleep")
            .arg("10")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn restart target");
        let pid = child.id();
        let identity = process_identity(pid).expect("restart target identity");

        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind delayed health server");
        let address = listener.local_addr().expect("delayed health address");
        listener
            .set_nonblocking(true)
            .expect("set delayed health server nonblocking");
        let finished = Arc::new(AtomicBool::new(false));
        let server_finished = Arc::clone(&finished);
        let server = thread::spawn(move || {
            thread::sleep(Duration::from_millis(1_200));
            while !server_finished.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let mut request = [0_u8; 1_024];
                        let _ = stream.read(&mut request);
                        let _ = stream.write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                        );
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("accept delayed health request: {error}"),
                }
            }
        });

        let health_url = format!("http://{address}/health");
        let resource = RuntimeResource {
            schema_version: 1,
            resource_id: "res-delayed-health".to_string(),
            proposal_id: "proposal-delayed-health".to_string(),
            session_id: "session-delayed-health".to_string(),
            intent_id: "intent-delayed-health".to_string(),
            task_id: "YARD-DELAYED-HEALTH".to_string(),
            attempt_id: "attempt-delayed-health".to_string(),
            producer: crate::schemas::ResourceProducer {
                worker_id: "fixture".to_string(),
            },
            causation_id: "attempt-delayed-health".to_string(),
            ownership: ResourceOwnership::Yardlet,
            capabilities: vec![ResourceCapability::Restart],
            target: RuntimeResourceTarget::Service {
                url: health_url.clone(),
                health_url,
                pid: Some(pid),
                start_identity: identity.clone(),
                restart_command: vec!["/bin/sleep".to_string(), "10".to_string()],
            },
            created_event_id: "evt-delayed-health".to_string(),
            published_seq: 1,
            recorded_at: "2026-07-15T00:00:00Z".to_string(),
        };

        let probe = probe_restarted_resource(&resource, pid, &identity);
        finished.store(true, Ordering::SeqCst);
        server.join().expect("join delayed health server");
        let _ = child.kill();
        let _ = child.wait();

        assert_eq!(probe.status, ResourceStatus::Live, "{}", probe.detail);
    }
}
