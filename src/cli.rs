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
    about = "Yard: a local AI workbench driving your already-installed Codex/Claude Code as hidden workers."
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
    /// Express lane: skip planning, run one goal (to a --verify condition).
    Goal(GoalArgs),
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
    /// Grant single-use approval to a gated task.
    Approve(ApproveArgs),
    /// Set the default worker permission: sandboxed | full.
    Access(AccessArgs),
    /// Print the latest run's handoff.
    Handoff,
    /// Print the intent's final report (aggregate of every task's result).
    Report,
    /// Review routing telemetry and apply suggested worker preferences.
    Routing(RoutingArgs),
    /// Recover state from an interrupted session (orphaned runs, unread plans).
    Recover,
    /// Classify the repo and equip skills from the library (docs/skills.md).
    Skill(SkillArgs),
    /// Review the harness learning loop: learned rules + learned skills (H4).
    Harness(HarnessArgs),
}

#[derive(Args)]
pub struct HarnessArgs {
    #[command(subcommand)]
    cmd: HarnessCmd,
}

#[derive(Subcommand)]
enum HarnessCmd {
    /// Show auto-learned rules and skills (with their eval scores).
    Review,
}

#[derive(Args)]
pub struct SkillArgs {
    #[command(subcommand)]
    cmd: SkillCmd,
}

#[derive(Subcommand)]
enum SkillCmd {
    /// Show equipped skills, detected presets, and library availability.
    List,
    /// Print skills the detected presets want but that aren't equipped.
    Suggest,
    /// Equip skills (or a whole preset) from the library.
    Equip { names: Vec<String> },
    /// Remove equipped skills.
    Unequip { names: Vec<String> },
    /// Draft a candidate skill for a topic (a worker authors it; installs nothing).
    Research { topic: Vec<String> },
    /// Author and install a new skill by name (optionally from a topic).
    Create {
        /// Skill name (kebab-case recommended).
        name: String,
        /// Extra context/topic to brief the worker with.
        #[arg(long)]
        from: Option<String>,
    },
    /// Install a skill previously drafted by `research`, by its run id.
    Apply { run: String },
    /// Show each equipped skill's eval score (from telemetry).
    Review,
}

#[derive(Args)]
pub struct RoutingArgs {
    #[command(subcommand)]
    cmd: RoutingCmd,
}

#[derive(Subcommand)]
enum RoutingCmd {
    /// Show per-kind worker success stats and suggested preferences.
    Review,
    /// Pin a worker for a task kind (human-approved policy change).
    Apply {
        #[arg(long)]
        kind: String,
        #[arg(long)]
        worker: String,
    },
}

#[derive(Args)]
pub struct ApproveArgs {
    /// The task id to approve (single use).
    task: String,
}

#[derive(Args)]
pub struct AccessArgs {
    /// sandboxed (local only, network blocked) or full (no sandbox).
    level: String,
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
pub struct GoalArgs {
    /// What to achieve, in a sentence or two.
    goal: Vec<String>,
    /// A condition a separate reviewer task checks against the workspace
    /// (e.g. "all tests pass and the UI has no clipped text").
    #[arg(long)]
    verify: Option<String>,
    /// Force a worker for the goal task (codex | claude-code | <id>).
    #[arg(long)]
    worker: Option<String>,
    /// Plan only; do not start the drain.
    #[arg(long)]
    plan_only: bool,
    /// Drop the worker sandbox (network, installs, etc.).
    #[arg(long)]
    bypass: bool,
}

#[derive(Args)]
pub struct NewArgs {
    /// The work request, in a few natural-language sentences.
    request: Vec<String>,
    /// Force a specific planning worker (codex | claude-code).
    #[arg(long)]
    worker: Option<String>,
    /// Attach a local image (repeatable). Also auto-detected from the request.
    #[arg(long = "image")]
    images: Vec<String>,
    /// After planning, drain the queue autonomously (plan + run in one go).
    #[arg(long)]
    run: bool,
    /// With --run: drop the sandbox (workers still self-gate dangerous actions).
    #[arg(long)]
    bypass: bool,
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
    /// Run a specific task by id (retries blocked/failed tasks too).
    #[arg(long)]
    task: Option<String>,
    /// Actually invoke the worker (consumes subscription usage). Default: prepare only.
    #[arg(long)]
    execute: bool,
    /// Override the worker for this run.
    #[arg(long)]
    worker: Option<String>,
    /// Drop the worker sandbox (network, installs, etc.). Use with care.
    #[arg(long)]
    full_access: bool,
    /// Drain the whole queue autonomously, stopping only at human gates.
    #[arg(long)]
    auto: bool,
    /// With --auto: drop the sandbox (workers still self-gate dangerous actions).
    #[arg(long)]
    bypass: bool,
    /// With --auto: run up to N independent tasks at once, each in its own git
    /// worktree (overrides the workspace max_parallel setting).
    #[arg(long)]
    parallel: Option<usize>,
    /// Run even though the planner scored ambiguity "high".
    #[arg(long)]
    accept_ambiguity: bool,
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
        Some(Command::Goal(a)) => cmd_goal(&cwd, a),
        Some(Command::Status(a)) => cmd_status(&cwd, a),
        Some(Command::Queue) => cmd_queue(&cwd),
        Some(Command::Worker(a)) => cmd_worker(&cwd, a),
        Some(Command::Inspect(a)) => cmd_inspect(&cwd, a),
        Some(Command::Packet(a)) => cmd_packet(&cwd, a),
        Some(Command::Run(a)) => cmd_run(&cwd, a),
        Some(Command::Answer(a)) => cmd_answer(&cwd, a),
        Some(Command::Approve(a)) => cmd_approve(&cwd, a),
        Some(Command::Access(a)) => cmd_access(&cwd, a),
        Some(Command::Handoff) => cmd_handoff(&cwd),
        Some(Command::Report) => cmd_report(&cwd),
        Some(Command::Routing(a)) => cmd_routing(&cwd, a),
        Some(Command::Recover) => cmd_recover(&cwd),
        Some(Command::Skill(a)) => cmd_skill(&cwd, a),
        Some(Command::Harness(a)) => cmd_harness(&cwd, a),
    }
}

fn cmd_harness(cwd: &std::path::Path, args: HarnessArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    match args.cmd {
        HarnessCmd::Review => {
            let rules = crate::skills::learned_rules(&ws);
            println!("Learned rules ({}):", rules.len());
            if rules.is_empty() {
                println!("  (none yet — a run proposes them via harness_suggestions)");
            }
            for r in &rules {
                println!("  \u{2022} {r}  (.agents/rules/{r}.md)");
            }

            let scores = crate::skills::scores(&ws);
            let learned: Vec<_> = scores
                .iter()
                .filter(|s| crate::skills::is_learned(&ws, &s.name))
                .collect();
            println!("\nLearned skills ({}):", learned.len());
            if learned.is_empty() {
                println!("  (none yet)");
            }
            for s in &learned {
                let signal = if s.verdict_total > 0 {
                    format!("verdict {}/{}", s.verdict_pass, s.verdict_total)
                } else if s.runs > 0 {
                    format!("done {}/{}", s.done, s.runs)
                } else {
                    "no runs yet".to_string()
                };
                println!(
                    "  \u{2022} {:<26} score {:>4.2}  {}",
                    s.name,
                    s.value(),
                    signal
                );
            }
            println!(
                "\nLearned skills below score floor over enough runs are auto-pruned \
                 (auto_prune). Learned rules are kept until removed (git-reversible). \
                 Full skill table: `yard skill review`."
            );
        }
    }
    Ok(())
}

fn cmd_recover(cwd: &std::path::Path) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let mut msgs = Vec::new();
    if let Some(m) = crate::planner::recover_unconsumed_plan(&ws) {
        msgs.push(m);
    }
    msgs.extend(crate::run::recover_orphans(&ws));
    if msgs.is_empty() {
        println!("nothing to recover \u{2014} state is consistent.");
    } else {
        for m in &msgs {
            println!("{m}");
        }
    }
    Ok(())
}

fn cmd_skill(cwd: &std::path::Path, args: SkillArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let cfg = ws.load_config()?;
    let lib = crate::skills::Library::open(&cfg.skill_library);
    match args.cmd {
        SkillCmd::List => {
            let repo = inspect::summarize(&ws.root);
            println!(
                "Detected presets: {}",
                crate::skills::detect_presets(&repo).join(", ")
            );
            let inst = crate::skills::installed(&ws);
            println!("\nEquipped ({}):", inst.len());
            for s in &inst {
                println!("  \u{2713} {s}");
            }
            match &lib {
                Some(library) => {
                    let avail: Vec<String> = library
                        .all_skills()
                        .into_iter()
                        .filter(|s| !inst.contains(s))
                        .collect();
                    println!("\nAvailable in library ({}):", avail.len());
                    for s in &avail {
                        println!("  \u{00b7} {s}");
                    }
                }
                None => println!("\n(no skill_library configured; set it in .agents/yard.yaml)"),
            }
        }
        SkillCmd::Suggest => match &lib {
            Some(library) => {
                let repo = inspect::summarize(&ws.root);
                let s = crate::skills::suggest(&ws, library, &repo);
                if s.is_empty() {
                    println!("nothing to suggest \u{2014} detected presets are fully equipped.");
                } else {
                    println!("suggested for this repo: {}", s.join(", "));
                    println!("equip with: yard skill equip {}", s.join(" "));
                }
            }
            None => println!("no skill_library configured."),
        },
        SkillCmd::Equip { names } => {
            let Some(library) = &lib else {
                anyhow::bail!("no skill_library configured (set it in .agents/yard.yaml).");
            };
            let expanded: Vec<String> = names.iter().flat_map(|n| library.resolve(n)).collect();
            for (name, out) in crate::skills::equip(&ws, library, &expanded) {
                let msg = match out {
                    crate::skills::EquipResult::Added => "equipped".to_string(),
                    crate::skills::EquipResult::AlreadyPresent => "already equipped".to_string(),
                    crate::skills::EquipResult::NotInLibrary => "not in library".to_string(),
                    crate::skills::EquipResult::Failed(e) => format!("failed: {e}"),
                };
                println!("  {name}: {msg}");
            }
        }
        SkillCmd::Unequip { names } => {
            for name in &names {
                match crate::skills::unequip(&ws, name) {
                    Ok(true) => println!("  {name}: removed"),
                    Ok(false) => println!("  {name}: not equipped"),
                    Err(e) => println!("  {name}: {e}"),
                }
            }
        }
        SkillCmd::Research { topic } => {
            let topic = topic.join(" ");
            if topic.trim().is_empty() {
                anyhow::bail!("usage: yard skill research \"<topic>\"");
            }
            let r = crate::skill_author::research(&ws, &topic)?;
            println!("researched skill: {}", r.name);
            for l in &r.lines {
                println!("  {l}");
            }
        }
        SkillCmd::Create { name, from } => {
            let r = crate::skill_author::create(&ws, &name, from.as_deref())?;
            println!("created skill: {}", r.name);
            for l in &r.lines {
                println!("  {l}");
            }
        }
        SkillCmd::Apply { run } => {
            let r = crate::skill_author::apply(&ws, &run)?;
            println!("applied draft from {}: {}", r.run_id, r.name);
            for l in &r.lines {
                println!("  {l}");
            }
        }
        SkillCmd::Review => {
            let scores = crate::skills::scores(&ws);
            if scores.is_empty() {
                println!("no skills equipped.");
            }
            println!("{:<28} {:>6}  {:>5}  signal", "skill", "score", "runs");
            for s in &scores {
                let signal = if s.verdict_total > 0 {
                    format!("verdict {}/{}", s.verdict_pass, s.verdict_total)
                } else if s.runs > 0 {
                    format!("done {}/{}", s.done, s.runs)
                } else {
                    "no runs yet".to_string()
                };
                println!(
                    "{:<28} {:>6.2}  {:>5}  {}",
                    s.name,
                    s.value(),
                    s.runs,
                    signal
                );
            }
        }
    }
    Ok(())
}

fn cmd_routing(cwd: &std::path::Path, args: RoutingArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    match args.cmd {
        RoutingCmd::Review => {
            let runs = crate::telemetry::read_runs(&ws);
            let workers = ws.load_workers()?;
            let overrides = crate::routing::load_overrides(&ws);
            if runs.is_empty() {
                println!("No run telemetry yet. Routing suggestions appear once runs accrue.");
                return Ok(());
            }
            println!("Per-kind worker success ({} runs):", runs.len());
            let stats = crate::review::aggregate(&runs);
            for ((kind, worker), s) in &stats {
                println!(
                    "  {:<16} {:<12} {}/{} done ({:.0}%)",
                    kind,
                    worker,
                    s.success,
                    s.total,
                    s.rate() * 100.0
                );
            }
            let suggestions = crate::review::suggest(&runs, &workers, &overrides);
            if suggestions.is_empty() {
                println!("\nNo routing changes suggested.");
            } else {
                println!("\nSuggestions (apply are human-approved):");
                for s in &suggestions {
                    println!("  - {}", s.reason);
                    println!("    yard routing apply --kind {} --worker {}", s.kind, s.to);
                }
            }
            Ok(())
        }
        RoutingCmd::Apply { kind, worker } => {
            crate::review::set_kind_override(&ws, &kind, &worker)?;
            println!("Pinned '{kind}' tasks to {worker} (.agents/routing-overrides.yaml).");
            Ok(())
        }
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

fn cmd_goal(cwd: &std::path::Path, args: GoalArgs) -> Result<()> {
    let (ws, created) = init::ensure_initialized(cwd)?;
    if created {
        println!("Initialized Yard workspace (.agents/).");
    }
    let goal = args.goal.join(" ");
    let n = crate::planner::plan_goal(&ws, &goal, args.verify.as_deref(), args.worker.as_deref())?;
    println!("Goal queued ({n} task{}).", if n == 1 { "" } else { "s" });
    if args.plan_only {
        println!("Next: `yard run --auto` to execute.");
        return Ok(());
    }
    println!("\nRunning \u{2014} stops only if it needs you:\n");
    run::run_auto(&ws, args.bypass, None, None, false, |s| println!("{s}"))?;
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
    let report = crate::planner::run_planning(&ws, &request, args.worker.as_deref(), &args.images)?;
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
    if args.run && report.task_count > 0 {
        println!("\nRunning autonomously \u{2014} stops only if it needs you:\n");
        run::run_auto(&ws, args.bypass, None, None, false, |s| println!("{s}"))?;
        return Ok(());
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
            accept_ambiguity: false,
            chain: None,
        },
    )?;
    for line in &report.lines {
        println!("{line}");
    }
    println!("\nrun {} resumed", report.run_id);
    Ok(())
}

fn cmd_approve(cwd: &std::path::Path, args: ApproveArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let queue = ws.load_queue()?;
    if !queue.tasks.iter().any(|t| t.id == args.task) {
        anyhow::bail!("task '{}' not found in the queue", args.task);
    }
    crate::approvals::grant(&ws, &args.task)?;
    println!(
        "Approved {} (single use). Run it with `yard run --task {} --execute`.",
        args.task, args.task
    );
    Ok(())
}

fn cmd_access(cwd: &std::path::Path, args: AccessArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let level = args.level.to_lowercase();
    if level != "sandboxed" && level != "full" {
        anyhow::bail!("level must be 'sandboxed' or 'full'");
    }
    let mut config = ws.load_config()?;
    config.default_access = level.clone();
    crate::state::save_yaml(&ws.config_path(), &config)?;
    println!("Default worker access set to '{level}'.");
    if level == "full" {
        println!(
            "Workers now run without the sandbox (commands and network flow freely). They still \
             self-gate dangerous actions per the packet, and any change to a forbidden path still \
             fails the run."
        );
    }
    Ok(())
}

fn cmd_report(cwd: &std::path::Path) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    print!("{}", crate::report::build_final_report(&ws)?);
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
    println!("Access: {}", snap.config.default_access);
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
    let stuck: Vec<&str> = snap
        .queue
        .tasks
        .iter()
        .filter(|t| {
            matches!(
                t.state,
                TaskState::Blocked | TaskState::Failed | TaskState::Partial
            )
        })
        .map(|t| t.id.as_str())
        .collect();
    if !stuck.is_empty() {
        println!("\nstuck (blocked/failed): {}", stuck.join(", "));
        println!("  see why:   yard handoff");
        println!(
            "  retry:     yard run --task <id> --execute   (add --full-access if it needs network/installs)"
        );
    }
    let needs_approval: Vec<&str> = snap
        .queue
        .tasks
        .iter()
        .filter(|t| t.approval_required() && !crate::approvals::is_granted(&ws, &t.id))
        .map(|t| t.id.as_str())
        .collect();
    if !needs_approval.is_empty() {
        println!("\nneeds approval: {}", needs_approval.join(", "));
        println!("  approve:   yard approve <id>   then  yard run --task <id> --execute");
    }
    let suggestions = crate::review::pending_count(&ws);
    if suggestions > 0 {
        println!("\nrouting: {suggestions} suggestion(s) \u{2014} run `yard routing review`");
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
    let images: Vec<String> = intent
        .as_ref()
        .map(|i| i.images.clone())
        .unwrap_or_default();
    let role_notes = packet::load_role_notes(&ws.root, packet::role_for(&task.kind));
    let continuation = if task.state == crate::schemas::TaskState::Partial {
        crate::run::continuation_context(&ws, &task.id)
    } else {
        None
    };
    let harness = packet::discover_harness(&ws.root, config.harness_discovery);
    let text = packet::compile(&packet::PacketInputs {
        worker_id: &args.worker,
        task,
        intent: intent.as_ref(),
        repo: &summary,
        run_dir_rel: ".agents/runs/<run-id>",
        prior_question: None,
        user_answer: None,
        continuation: continuation.as_deref(),
        chained_from: None,
        language: &language,
        images: &images,
        role_notes: &role_notes,
        harness: &harness,
    });
    if args.dry_run {
        eprintln!("(dry-run: packet not persisted)\n");
    }
    print!("{text}");
    Ok(())
}

fn cmd_run(cwd: &std::path::Path, args: RunArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let _ = (args.next, args.headless); // --next is implied; --task targets one
    if args.auto {
        run::run_auto(
            &ws,
            args.bypass || args.full_access,
            None,
            args.parallel,
            args.accept_ambiguity,
            |s| println!("{s}"),
        )?;
        return Ok(());
    }
    let report = run::run_next(
        &ws,
        &RunOptions {
            execute: args.execute,
            worker_override: args.worker,
            target: args.task,
            answer: None,
            full_access: args.full_access,
            accept_ambiguity: args.accept_ambiguity,
            chain: None,
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
