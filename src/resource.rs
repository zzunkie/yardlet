//! Surface-neutral runtime resource and artifact operations.
//!
//! Workers author proposals. This module validates content and live targets;
//! `state.rs` remains the only canonical `.agents/` writer.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Component, Path};
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};

use crate::schemas::{
    Artifact, ResourceActionReceipt, ResourceActionResult, ResourceActionStatus,
    ResourceCapability, ResourceEntry, ResourceObservation, ResourceOpenTarget,
    ResourceOperationKind, ResourceOperationRequest, ResourceOwnership, ResourceStatus, RunResult,
    RuntimeResource, RuntimeResourceTarget,
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
        ws.publish_artifact(
            session_id,
            intent_id,
            proposal,
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
        .rev()
        .find(|observation| {
            observation.status == ResourceStatus::Live
                && observation.pid.is_some()
                && !observation.start_identity.is_empty()
        })
    {
        return Ok(Some((
            observation.pid.expect("filtered observation pid"),
            observation.start_identity,
        )));
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
            if health_url.trim().is_empty() {
                let Some(address) = url_socket(url) else {
                    return Ok(Probe {
                        status: ResourceStatus::Unrecoverable,
                        pid: observed_pid,
                        start_identity,
                        detail: "service URL cannot be parsed for a local probe".to_string(),
                    });
                };
                let reachable =
                    TcpStream::connect_timeout(&address, Duration::from_millis(200)).is_ok();
                return Ok(Probe {
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
                });
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
            Ok(Probe {
                status,
                pid: observed_pid,
                start_identity,
                detail,
            })
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

fn lifecycle_result(
    ws: &Workspace,
    resource: &RuntimeResource,
    operation: ResourceOperationKind,
    expected_status: ResourceStatus,
    requested_event: &str,
    action_id: &str,
) -> Result<(ResourceActionStatus, ResourceActionResult, String)> {
    let probe = probe_resource(ws, resource)?;
    if probe.status != expected_status {
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

    match operation {
        ResourceOperationKind::Stop | ResourceOperationKind::Cleanup => {
            if probe.status == ResourceStatus::Live {
                terminate_exact_process(&probe)?;
            } else if probe.status != ResourceStatus::Dead {
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
            let stopped = Probe {
                status: ResourceStatus::Dead,
                detail: if operation == ResourceOperationKind::Cleanup {
                    "owned resource cleanup confirmed process dead".to_string()
                } else {
                    "owned resource stop confirmed process dead".to_string()
                },
                ..probe
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
            if probe.status == ResourceStatus::Live {
                terminate_exact_process(&probe)?;
            } else if probe.status != ResourceStatus::Dead {
                let observation = persist_probe(ws, resource, &probe, requested_event, action_id)?;
                return Ok((
                    ResourceActionStatus::Rejected,
                    ResourceActionResult {
                        observation: Some(observation),
                        ..Default::default()
                    },
                    format!("cannot restart resource in {:?} state", probe.status),
                ));
            }
            let mut child = Command::new(&command[0]);
            child
                .args(&command[1..])
                .current_dir(&ws.root)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            let child = child.spawn().context("starting owned resource")?;
            let pid = child.id();
            drop(child);
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
            let restarted = Probe {
                status: ResourceStatus::Live,
                pid: Some(pid),
                start_identity: identity,
                detail: "restart command spawned a process with a verified identity".to_string(),
            };
            let observation = persist_probe(ws, resource, &restarted, requested_event, action_id)?;
            Ok((
                ResourceActionStatus::Completed,
                ResourceActionResult {
                    observation: Some(observation),
                    ..Default::default()
                },
                String::new(),
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
            event_id: format!(
                "evt_resource_action_{}_{}",
                digest_bytes(action_id.as_bytes()).trim_start_matches("fnv1a64:"),
                suffix
            ),
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

pub fn dispatch(
    ws: &Workspace,
    request: ResourceOperationRequest,
) -> Result<ResourceActionReceipt> {
    validate_action_id(&request.action_id)?;
    let digest = request_digest(&request)?;
    if let Some(existing) = ws.load_resource_action(&request.action_id)? {
        if existing.request_digest == digest {
            return Ok(existing);
        }
        bail!(
            "idempotency_conflict: action {} changed request",
            request.action_id
        );
    }

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

    let (status, result, error) = match request.operation {
        ResourceOperationKind::Discover | ResourceOperationKind::Inspect => (
            ResourceActionStatus::Completed,
            ResourceActionResult {
                entries,
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
                    entries,
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
                        entries,
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
                    let (status, mut result, error) = lifecycle_result(
                        ws,
                        resource,
                        operation,
                        request.expected_status,
                        &requested_event,
                        &request.action_id,
                    )?;
                    result.entries = entries;
                    (status, result, error)
                }
            }
        },
    };
    let terminal_type = if status == ResourceActionStatus::Completed {
        crate::schemas::ChannelEventType::ActionCompleted
    } else {
        crate::schemas::ChannelEventType::ActionRejected
    };
    let terminal_event = record_action_event(
        ws,
        &request.action_id,
        if status == ResourceActionStatus::Completed {
            "completed"
        } else {
            "rejected"
        },
        terminal_type,
        request.operation,
        &session_id,
        &intent_id,
        &actual_task_id,
        &request.target_id,
        Some(requested_event.clone()),
        &error,
    )?;
    let receipt = ResourceActionReceipt {
        schema_version: 1,
        action_id: request.action_id,
        operation: request.operation,
        intent_id,
        task_id: actual_task_id,
        target_id: request.target_id,
        request_digest: digest,
        status,
        result,
        result_event_ids: vec![requested_event, terminal_event],
        error,
    };
    ws.save_resource_action(&receipt)?;
    Ok(receipt)
}
