//! Command-line surface.
//!
//! The TUI is the normal interface; these commands exist for automation,
//! scripting, debugging, and the UI implementation itself.

use anyhow::Result;
use clap::{Args, Parser, Subcommand};

use crate::guard;
use crate::inspect;
use crate::run::{self, RunOptions};
use crate::snapshot::Snapshot;
use crate::state::{self, Workspace};
use crate::{init, packet};

#[derive(Parser)]
#[command(
    name = "yard",
    version,
    about = "Yard: a local AI workbench. Zero AI API keys; Codex/Claude Code as hidden workers."
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Subcommand)]
pub enum Command {
    /// Scaffold canonical .agents/ state into this workspace.
    Init(InitArgs),
    /// Turn a natural-language request into an intent contract + queue.
    New(NewArgs),
    /// Report workspace, intent, queue, and worker state.
    Status(StatusArgs),
    /// List the work queue.
    Queue,
    /// Worker readiness and zero-key billing safety.
    Worker(WorkerArgs),
    /// Gather cheap deterministic local evidence.
    Inspect(InspectArgs),
    /// Compile a worker-specific task packet.
    Packet(PacketArgs),
    /// Prepare (and optionally execute) the next bounded task.
    Run(RunArgs),
    /// Print the latest run's handoff.
    Handoff,
}

#[derive(Args)]
pub struct NewArgs {
    /// The work request, in a few natural-language sentences.
    request: Vec<String>,
    /// Force a specific planning worker (codex | claude-code).
    #[arg(long)]
    worker: Option<String>,
}

#[derive(Args)]
pub struct InitArgs {
    /// Overwrite existing policy templates.
    #[arg(long)]
    force: bool,
}

#[derive(Args)]
pub struct StatusArgs {
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct WorkerArgs {
    #[command(subcommand)]
    cmd: WorkerCmd,
}

#[derive(Subcommand)]
enum WorkerCmd {
    /// Probe each configured worker.
    Status,
}

#[derive(Args)]
pub struct InspectArgs {
    #[command(subcommand)]
    cmd: InspectCmd,
}

#[derive(Subcommand)]
enum InspectCmd {
    /// Summarize the repo for worker pre-inspection.
    Repo {
        #[arg(long)]
        json: bool,
    },
}

#[derive(Args)]
pub struct PacketArgs {
    /// Task id (e.g. YARD-002).
    #[arg(long)]
    task: String,
    /// Worker id (codex | claude-code).
    #[arg(long, default_value = "codex")]
    worker: String,
    /// Print only; do not persist (packets are not persisted by this command anyway).
    #[arg(long)]
    dry_run: bool,
}

#[derive(Args)]
pub struct RunArgs {
    /// Select and prepare the next eligible task.
    #[arg(long)]
    next: bool,
    /// Actually invoke the worker (consumes subscription usage). Default: prepare only.
    #[arg(long)]
    execute: bool,
    /// Override the worker for this run.
    #[arg(long)]
    worker: Option<String>,
    /// Non-interactive output (no extra prompts).
    #[arg(long)]
    headless: bool,
}

pub fn dispatch(cli: Cli) -> Result<()> {
    let cwd = inspect::cwd();
    match cli.command {
        None => launch_tui(&cwd),
        Some(Command::Init(a)) => cmd_init(&cwd, a),
        Some(Command::New(a)) => cmd_new(&cwd, a),
        Some(Command::Status(a)) => cmd_status(&cwd, a),
        Some(Command::Queue) => cmd_queue(&cwd),
        Some(Command::Worker(a)) => cmd_worker(&cwd, a),
        Some(Command::Inspect(a)) => cmd_inspect(&cwd, a),
        Some(Command::Packet(a)) => cmd_packet(&cwd, a),
        Some(Command::Run(a)) => cmd_run(&cwd, a),
        Some(Command::Handoff) => cmd_handoff(&cwd),
    }
}

fn launch_tui(cwd: &std::path::Path) -> Result<()> {
    match Workspace::discover(cwd) {
        Some(ws) => crate::ui::run(&ws),
        None => {
            println!(
                "No Yard workspace here. Run `yard init` to create .agents/ state, then `yard`."
            );
            Ok(())
        }
    }
}

fn cmd_init(cwd: &std::path::Path, args: InitArgs) -> Result<()> {
    let written = init::init(cwd, args.force)?;
    println!("Initialized Yard workspace at {}/.agents", cwd.display());
    for f in &written {
        println!("  + {f}");
    }
    println!("\nNext: `yard` opens the workbench, `yard worker status` checks workers.");
    Ok(())
}

fn cmd_new(cwd: &std::path::Path, args: NewArgs) -> Result<()> {
    let ws = state::require_initialized(cwd)?;
    let request = args.request.join(" ");
    if request.trim().is_empty() {
        anyhow::bail!("provide a request, e.g. `yard new \"add admin order search\"`");
    }
    println!("Planning: {request}\n");
    let report = crate::planner::run_planning(&ws, &request, args.worker.as_deref())?;
    println!(
        "planning worker: {}  ·  run: {}",
        report.worker_id, report.run_id
    );
    for line in &report.lines {
        println!("{line}");
    }
    println!("\nIntent: {}", report.intent_summary);
    println!("Created {} task(s) in the queue.", report.task_count);
    if !report.questions.is_empty() {
        println!("\nQuestions (non-blocking, assumptions were made):");
        for q in &report.questions {
            println!("  - {q}");
        }
    }
    println!("\nNext: `yard queue` to review, `yard run --next --execute` to run.");
    Ok(())
}

fn cmd_queue(cwd: &std::path::Path) -> Result<()> {
    let ws = state::require_initialized(cwd)?;
    let queue = ws.load_queue()?;
    if queue.tasks.is_empty() {
        println!("Queue is empty. Run `yard new \"...\"` to create work.");
        return Ok(());
    }
    for t in &queue.tasks {
        println!(
            "{} {:<12} {:<48} {:>6}  {}",
            t.state.glyph(),
            t.id,
            truncate(&t.title, 48),
            t.risk,
            t.preferred_worker
        );
    }
    Ok(())
}

fn cmd_handoff(cwd: &std::path::Path) -> Result<()> {
    let ws = state::require_initialized(cwd)?;
    let latest = latest_run_dir(&ws.runs_dir());
    match latest {
        Some(dir) => {
            let h = dir.join("handoff.md");
            if h.is_file() {
                print!("{}", std::fs::read_to_string(&h)?);
            } else {
                println!("Latest run {} has no handoff yet.", dir.display());
            }
            Ok(())
        }
        None => {
            println!("No runs yet. Run `yard run --next --execute` first.");
            Ok(())
        }
    }
}

fn latest_run_dir(runs_dir: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut newest: Option<(std::time::SystemTime, std::path::PathBuf)> = None;
    for entry in std::fs::read_dir(runs_dir).ok()?.flatten() {
        if !entry.path().is_dir() {
            continue;
        }
        let mtime = entry
            .metadata()
            .and_then(|m| m.modified())
            .unwrap_or(std::time::UNIX_EPOCH);
        match &newest {
            Some((t, _)) if *t >= mtime => {}
            _ => newest = Some((mtime, entry.path())),
        }
    }
    newest.map(|(_, p)| p)
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('\u{2026}');
        out
    }
}

fn cmd_status(cwd: &std::path::Path, args: StatusArgs) -> Result<()> {
    let ws = state::require_initialized(cwd)?;
    let snap = Snapshot::load(&ws)?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&snap.to_json())?);
        return Ok(());
    }
    println!("Yard workspace: {}", snap.config.workspace_id);
    println!("Intent: {}", snap.intent_summary());
    println!(
        "Queue: {} queued, {} running, {} blocked, {} done, {} total",
        snap.count(crate::schemas::TaskState::Queued),
        snap.count(crate::schemas::TaskState::Running),
        snap.count(crate::schemas::TaskState::Blocked),
        snap.count(crate::schemas::TaskState::Done),
        snap.queue.tasks.len(),
    );
    println!(
        "Workers ready: {}/{}",
        snap.workers_ready(),
        snap.workers.len()
    );
    Ok(())
}

fn cmd_worker(cwd: &std::path::Path, args: WorkerArgs) -> Result<()> {
    match args.cmd {
        WorkerCmd::Status => {
            let ws = state::require_initialized(cwd)?;
            let billing = ws.load_billing()?;
            let workers = ws.load_workers()?;
            println!("Zero-key policy: {}", billing.mode);
            println!(
                "Billing env policy: {}\n",
                billing.worker_invocation.ai_billing_env_policy
            );
            for p in &workers.workers {
                let s = guard::probe(p, &billing);
                println!("{} [{}]", s.id, s.readiness.label());
                if let Some(v) = &s.version {
                    println!("  version: {v}");
                }
                println!("  command: {}", s.command);
                if let Some(path) = &s.binary_path {
                    println!("  path: {}", path.display());
                }
                if !s.billing_env_present.is_empty() {
                    // names only, never values
                    println!(
                        "  billing env present: {}",
                        s.billing_env_present.join(", ")
                    );
                }
                println!("  {}", s.detail);
                println!();
            }
            Ok(())
        }
    }
}

fn cmd_inspect(cwd: &std::path::Path, args: InspectArgs) -> Result<()> {
    match args.cmd {
        InspectCmd::Repo { json } => {
            let root = Workspace::discover(cwd)
                .map(|w| w.root)
                .unwrap_or_else(|| cwd.to_path_buf());
            let summary = inspect::summarize(&root);
            if json {
                println!("{}", serde_json::to_string_pretty(&summary)?);
            } else {
                print!("{}", inspect::to_markdown(&summary));
            }
            Ok(())
        }
    }
}

fn cmd_packet(cwd: &std::path::Path, args: PacketArgs) -> Result<()> {
    let ws = state::require_initialized(cwd)?;
    let queue = ws.load_queue()?;
    let intent = ws.load_intent()?;
    let task = queue
        .tasks
        .iter()
        .find(|t| t.id == args.task)
        .ok_or_else(|| anyhow::anyhow!("task '{}' not found in the queue", args.task))?;
    let summary = inspect::summarize(&ws.root);
    let text = packet::compile(&packet::PacketInputs {
        worker_id: &args.worker,
        task,
        intent: intent.as_ref(),
        repo: &summary,
        run_dir_rel: ".agents/runs/<run-id>",
    });
    if args.dry_run {
        eprintln!("(dry-run: packet not persisted)\n");
    }
    print!("{text}");
    Ok(())
}

fn cmd_run(cwd: &std::path::Path, args: RunArgs) -> Result<()> {
    let ws = state::require_initialized(cwd)?;
    let _ = (args.next, args.headless); // --next is the only mode today
    let report = run::run_next(
        &ws,
        &RunOptions {
            execute: args.execute,
            worker_override: args.worker,
        },
    )?;
    for line in &report.lines {
        println!("{line}");
    }
    println!(
        "\nrun {} {}",
        report.run_id,
        if report.executed {
            "executed"
        } else {
            "prepared"
        }
    );
    let _ = (
        report.task_id,
        report.worker_id,
        report.run_dir,
        report.prepared,
    );
    Ok(())
}
