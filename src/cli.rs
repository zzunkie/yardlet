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
use crate::state::Workspace;
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
    /// Answer a task that is waiting on you, and resume it.
    Answer(AnswerArgs),
    /// Print the latest run's handoff.
    Handoff,
}

#[derive(Args)]
pub struct AnswerArgs {
    /// Your answer to the worker's question.
    reply: Vec<String>,
    /// The task to answer (defaults to the one waiting on you).
    #[arg(long)]
    task: Option<String>,
    /// Drop the worker sandbox when resuming (e.g. to grant the access asked for).
    #[arg(long)]
    full_access: bool,
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
    /// Drop the worker sandbox (network, installs, etc.). Use with care.
    #[arg(long)]
    full_access: bool,
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
        Some(Command::Answer(a)) => cmd_answer(&cwd, a),
        Some(Command::Handoff) => cmd_handoff(&cwd),
    }
}

fn launch_tui(cwd: &std::path::Path) -> Result<()> {
    // Like the worker CLIs, `yard` just works: it initializes on demand.
    let (ws, just_created) = init::ensure_initialized(cwd)?;
    crate::ui::run(&ws, just_created)
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
    let (ws, created) = init::ensure_initialized(cwd)?;
    if created {
        println!("Initialized Yard workspace (.agents/).");
    }
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
    let ws = init::ensure_initialized(cwd)?.0;
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

fn cmd_answer(cwd: &std::path::Path, args: AnswerArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let reply = args.reply.join(" ");
    if reply.trim().is_empty() {
        anyhow::bail!("provide an answer, e.g. `yard answer \"use postgres\"`");
    }
    let queue = ws.load_queue()?;
    let task_id = match args.task {
        Some(t) => t,
        None => queue
            .tasks
            .iter()
            .find(|t| t.state == crate::schemas::TaskState::NeedsUser)
            .map(|t| t.id.clone())
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "no task is waiting for an answer (NeedsUser). Use --task <id> to name one."
                )
            })?,
    };
    println!("Answering {task_id}: {reply}\n");
    let report = run::run_next(
        &ws,
        &RunOptions {
            execute: true,
            worker_override: None,
            target: Some(task_id),
            answer: Some(reply),
            full_access: args.full_access,
        },
    )?;
    for line in &report.lines {
        println!("{line}");
    }
    println!("\nrun {} resumed", report.run_id);
    Ok(())
}

fn cmd_handoff(cwd: &std::path::Path) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
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
    let ws = init::ensure_initialized(cwd)?.0;
    let snap = Snapshot::load(&ws)?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&snap.to_json())?);
        return Ok(());
    }
    use crate::schemas::TaskState;
    println!("Yard workspace: {}", snap.config.workspace_id);
    println!("Intent: {}", snap.intent_summary());
    println!(
        "Queue: {} queued, {} running, {} needs-you, {} blocked, {} failed, {} done, {} total",
        snap.count(TaskState::Queued),
        snap.count(TaskState::Running),
        snap.count(TaskState::NeedsUser),
        snap.count(TaskState::Blocked),
        snap.count(TaskState::Failed),
        snap.count(TaskState::Done),
        snap.queue.tasks.len(),
    );
    println!(
        "Workers ready: {}/{}   (planner: {})",
        snap.workers_ready(),
        snap.workers.len(),
        snap.planner,
    );
    if let Some((id, q)) = &snap.pending {
        println!("\n\u{2691} {id} is waiting on you:");
        println!(
            "  {}",
            if q.is_empty() {
                "(see `yard handoff`)"
            } else {
                q
            }
        );
        println!("  answer with:  yard answer \"<your reply>\"");
    }
    Ok(())
}

fn cmd_worker(cwd: &std::path::Path, args: WorkerArgs) -> Result<()> {
    match args.cmd {
        WorkerCmd::Status => {
            let ws = init::ensure_initialized(cwd)?.0;
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
    let ws = init::ensure_initialized(cwd)?.0;
    let queue = ws.load_queue()?;
    let intent = ws.load_intent()?;
    let task = queue
        .tasks
        .iter()
        .find(|t| t.id == args.task)
        .ok_or_else(|| anyhow::anyhow!("task '{}' not found in the queue", args.task))?;
    let summary = inspect::summarize(&ws.root);
    let config = ws.load_config()?;
    let sample = intent
        .as_ref()
        .map(|i| i.raw_request.clone())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| task.title.clone());
    let language = packet::resolve_language(&config.language, &sample);
    let text = packet::compile(&packet::PacketInputs {
        worker_id: &args.worker,
        task,
        intent: intent.as_ref(),
        repo: &summary,
        run_dir_rel: ".agents/runs/<run-id>",
        prior_question: None,
        user_answer: None,
        language: &language,
    });
    if args.dry_run {
        eprintln!("(dry-run: packet not persisted)\n");
    }
    print!("{text}");
    Ok(())
}

fn cmd_run(cwd: &std::path::Path, args: RunArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let _ = (args.next, args.headless); // --next is the only mode today
    let report = run::run_next(
        &ws,
        &RunOptions {
            execute: args.execute,
            worker_override: args.worker,
            target: None,
            answer: None,
            full_access: args.full_access,
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
