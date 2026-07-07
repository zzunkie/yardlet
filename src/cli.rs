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
use crate::state::{UserTaskInput, Workspace};
use crate::{init, packet};

#[derive(Parser)]
#[command(
    name = "yardlet",
    version,
    about = "Yardlet: a local AI workbench driving your already-installed Codex/Claude Code as hidden workers."
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
    /// Add a user-authored task to the current queue without rebuilding it.
    Add(AddArgs),
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
    /// Set a task aside by decision (Deferred: not pending, not done).
    Defer(DeferArgs),
    /// Bring a Deferred task back to Queued.
    Revive(ReviveArgs),
    /// Set the default worker permission: sandboxed | full.
    Access(AccessArgs),
    /// Print the latest run's handoff.
    Handoff,
    /// Print the intent's final report (aggregate of every task's result).
    Report,
    /// Summarize run telemetry into a trust report (first-pass vs retried Done).
    Trust,
    /// List the project-memory index discovered under .agents/memory/.
    Memory,
    /// Review routing telemetry and apply suggested worker preferences.
    Routing(RoutingArgs),
    /// Show worker-rubric drift from the template and merge improvements in.
    Rubric(RubricArgs),
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
pub struct RubricArgs {
    #[command(subcommand)]
    cmd: RubricCmd,
}

#[derive(Subcommand)]
enum RubricCmd {
    /// Show how this workspace's worker rubric drifts from the current template.
    Drift,
    /// Merge template rubric improvements into workers.yaml (non-destructive).
    Sync {
        /// Also replace customized best_for/not_for/cost_weight text with the
        /// template's wording (default only fills empty text fields).
        #[arg(long)]
        adopt_text: bool,
    },
}

#[derive(Args)]
pub struct ApproveArgs {
    /// The task id to approve (single use).
    task: String,
}

#[derive(Args)]
pub struct DeferArgs {
    /// The task id to set aside.
    task: String,
    /// Also defer queued tasks stranded behind this one, transitively.
    #[arg(long)]
    cascade: bool,
    /// Why you are deferring it (recorded on the task).
    reason: Vec<String>,
}

#[derive(Args)]
pub struct ReviveArgs {
    /// The Deferred task id to return to Queued.
    task: String,
    /// Revive every Deferred task recorded in the same cascade-defer group.
    #[arg(long)]
    group: bool,
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
    /// Capability the goal task hard-requires (e.g. image_generation): routes to
    /// a worker that declares it, since the express path skips the planner.
    /// Repeatable.
    #[arg(long = "requires")]
    requires: Vec<String>,
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
pub struct AddArgs {
    /// Task title/request to append to the current queue.
    request: Vec<String>,
    /// Dependency task id. Repeat for multiple dependencies.
    #[arg(long = "depends-on")]
    depends_on: Vec<String>,
    /// Task kind recorded in the queue.
    #[arg(long, default_value = "implementation")]
    kind: String,
    /// Risk label recorded in the queue.
    #[arg(long, default_value = "low")]
    risk: String,
    /// Preferred worker id, if any.
    #[arg(long)]
    worker: Option<String>,
    /// Allowed-scope entry. Repeat to add multiple scope hints.
    #[arg(long = "scope")]
    scope: Vec<String>,
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
        Some(Command::Add(a)) => cmd_add(&cwd, a),
        Some(Command::Goal(a)) => cmd_goal(&cwd, a),
        Some(Command::Status(a)) => cmd_status(&cwd, a),
        Some(Command::Queue) => cmd_queue(&cwd),
        Some(Command::Worker(a)) => cmd_worker(&cwd, a),
        Some(Command::Inspect(a)) => cmd_inspect(&cwd, a),
        Some(Command::Packet(a)) => cmd_packet(&cwd, a),
        Some(Command::Run(a)) => cmd_run(&cwd, a),
        Some(Command::Answer(a)) => cmd_answer(&cwd, a),
        Some(Command::Approve(a)) => cmd_approve(&cwd, a),
        Some(Command::Defer(a)) => cmd_defer(&cwd, a),
        Some(Command::Revive(a)) => cmd_revive(&cwd, a),
        Some(Command::Access(a)) => cmd_access(&cwd, a),
        Some(Command::Handoff) => cmd_handoff(&cwd),
        Some(Command::Report) => cmd_report(&cwd),
        Some(Command::Trust) => cmd_trust(&cwd),
        Some(Command::Memory) => cmd_memory(&cwd),
        Some(Command::Routing(a)) => cmd_routing(&cwd, a),
        Some(Command::Rubric(a)) => cmd_rubric(&cwd, a),
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
            let mined = crate::trust::mine(&crate::telemetry::read_runs(&ws));
            println!("\nMined observations ({}):", mined.len());
            if mined.is_empty() {
                println!("  (none — telemetry shows no recurring problem pattern yet)");
            }
            for o in &mined {
                println!("  \u{2022} {}", o.detail);
                println!("    \u{2192} {}", o.suggestion);
            }

            println!(
                "\nLearned skills below score floor over enough runs are auto-pruned \
                 (auto_prune). Learned rules are kept until removed (git-reversible). \
                 Mined observations only SUGGEST — apply a rule/skill/scope change yourself. \
                 Full skill table: `yardlet skill review`."
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
                None => println!("\n(no skill_library configured; set it in .agents/yardlet.yaml)"),
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
                    println!("equip with: yardlet skill equip {}", s.join(" "));
                }
            }
            None => println!("no skill_library configured."),
        },
        SkillCmd::Equip { names } => {
            let Some(library) = &lib else {
                anyhow::bail!("no skill_library configured (set it in .agents/yardlet.yaml).");
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
                anyhow::bail!("usage: yardlet skill research \"<topic>\"");
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
                    println!(
                        "    yardlet routing apply --kind {} --worker {}",
                        s.kind, s.to
                    );
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

fn cmd_rubric(cwd: &std::path::Path, args: RubricArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let workspace = ws.load_workers()?;
    let template = crate::rubric::template_workers()?;
    let drift = crate::rubric::diff(&workspace, &template);
    match args.cmd {
        RubricCmd::Drift => {
            print_drift(&drift);
            Ok(())
        }
        RubricCmd::Sync { adopt_text } => {
            let (merged, changes) = crate::rubric::merge(&workspace, &template, adopt_text);
            if changes.is_empty() {
                println!("workers.yaml rubric already matches the template; nothing to sync.");
                hint_adopt_text(&drift, adopt_text);
                return Ok(());
            }
            // Rewriting from the struct normalizes formatting and drops inline
            // comments; the commented reference is the template / `rubric drift`.
            println!(
                "note: this rewrites .agents/workers.yaml from the merged rubric and drops inline \
                 comments (the commented reference lives in the template)."
            );
            crate::state::save_yaml(&ws.workers_path(), &merged)?;
            println!(
                "Synced {} rubric change(s) into .agents/workers.yaml:",
                changes.len()
            );
            for c in &changes {
                println!("  \u{2022} {:<12} {}", c.worker, c.detail);
            }
            hint_adopt_text(&drift, adopt_text);
            Ok(())
        }
    }
}

fn print_drift(d: &crate::rubric::RubricDrift) {
    if d.schema_version_template != d.schema_version_workspace {
        println!(
            "schema_version: workspace {} vs template {} (structural; sync does not change it).",
            d.schema_version_workspace, d.schema_version_template
        );
    }
    if !d.has_drift() {
        println!("No rubric drift: workers.yaml matches the current template.");
        if !d.extra_workers.is_empty() {
            println!(
                "  (local-only worker(s), untouched: {})",
                d.extra_workers.join(", ")
            );
        }
        return;
    }
    println!("Rubric drift vs the current template:\n");
    for w in &d.workers {
        if w.capabilities_added.is_empty()
            && w.role_strengths_added.is_empty()
            && w.text_changes.is_empty()
        {
            continue;
        }
        println!("  {}:", w.id);
        for c in &w.capabilities_added {
            println!("    + capability {c}  (hard routing gap: template declares it, you do not)");
        }
        for r in &w.role_strengths_added {
            println!("    + role_strength {r}");
        }
        for t in &w.text_changes {
            if t.workspace_empty() {
                println!(
                    "    ~ {} is empty; template has a value (sync fills it)",
                    t.field
                );
            } else {
                println!(
                    "    ~ {} differs (local wording kept unless --adopt-text):",
                    t.field
                );
                println!("        template:  {}", clip(&t.template));
                println!("        workspace: {}", clip(&t.workspace));
            }
        }
        if !w.capabilities_local.is_empty() {
            println!(
                "    . local-only capability kept: {}",
                w.capabilities_local.join(", ")
            );
        }
    }
    for id in &d.missing_workers {
        println!("  + worker {id}  (template ships it; sync adds it)");
    }
    if !d.extra_workers.is_empty() {
        println!(
            "\n  local-only worker(s), untouched: {}",
            d.extra_workers.join(", ")
        );
    }
    println!("\nApply:");
    println!(
        "  yardlet rubric sync               # capabilities + missing workers + fill empty text"
    );
    println!("  yardlet rubric sync --adopt-text  # also replace customized best_for/not_for/cost_weight");
}

fn hint_adopt_text(d: &crate::rubric::RubricDrift, adopt_text: bool) {
    if adopt_text {
        return;
    }
    let kept = d.kept_text_fields();
    if kept > 0 {
        println!(
            "\n{kept} customized text field(s) kept. Re-run with --adopt-text to replace them with \
             the template wording."
        );
    }
}

/// Collapse whitespace and clip to a readable preview width for the drift report.
fn clip(s: &str) -> String {
    let collapsed = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let max = 100;
    if collapsed.chars().count() <= max {
        collapsed
    } else {
        let head: String = collapsed.chars().take(max).collect();
        format!("{head}...")
    }
}

fn launch_tui(cwd: &std::path::Path) -> Result<()> {
    // Like the worker CLIs, `yardlet` just works: it initializes on demand.
    let (ws, just_created) = init::ensure_initialized(cwd)?;
    crate::ui::run(&ws, just_created)
}

fn cmd_init(cwd: &std::path::Path, args: InitArgs) -> Result<()> {
    let written = init::init(cwd, args.force)?;
    println!("Initialized Yardlet workspace at {}/.agents", cwd.display());
    for f in &written {
        println!("  + {f}");
    }
    println!("\nNext: `yardlet` opens the workbench, `yardlet worker status` checks workers.");
    Ok(())
}

fn cmd_goal(cwd: &std::path::Path, args: GoalArgs) -> Result<()> {
    let (ws, created) = init::ensure_initialized(cwd)?;
    if created {
        println!("Initialized Yardlet workspace (.agents/).");
    }
    let goal = args.goal.join(" ");
    let n = crate::planner::plan_goal(
        &ws,
        &goal,
        args.verify.as_deref(),
        args.worker.as_deref(),
        &args.requires,
    )?;
    println!("Goal queued ({n} task{}).", if n == 1 { "" } else { "s" });
    if args.plan_only {
        println!("Next: `yardlet run --auto` to execute.");
        return Ok(());
    }
    println!("\nRunning \u{2014} stops only if it needs you:\n");
    run::run_auto(&ws, args.bypass, None, None, false, |s| println!("{s}"))?;
    Ok(())
}

fn cmd_new(cwd: &std::path::Path, args: NewArgs) -> Result<()> {
    let (ws, created) = init::ensure_initialized(cwd)?;
    if created {
        println!("Initialized Yardlet workspace (.agents/).");
    }
    let request = args.request.join(" ");
    if request.trim().is_empty() {
        anyhow::bail!("provide a request, e.g. `yardlet new \"add admin order search\"`");
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
    println!("\nNext: `yardlet queue` to review, `yardlet run --next --execute` to run.");
    Ok(())
}

fn cmd_add(cwd: &std::path::Path, args: AddArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let request = args.request.join(" ");
    if request.trim().is_empty() {
        anyhow::bail!("provide a task, e.g. `yardlet add \"add admin order search\"`");
    }
    let task = ws.append_user_task(UserTaskInput {
        title: request.trim().to_string(),
        risk: args.risk,
        kind: args.kind,
        preferred_worker: args.worker.unwrap_or_default(),
        depends_on: args.depends_on,
        allowed_scope: args.scope,
    })?;
    println!(
        "Added {} to the queue: {}{}",
        task.id,
        task.title,
        if task.depends_on.is_empty() {
            String::new()
        } else {
            format!(" (depends on {})", task.depends_on.join(", "))
        }
    );
    Ok(())
}

fn cmd_queue(cwd: &std::path::Path) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let mut queue = ws.load_queue()?;
    if queue.tasks.is_empty() {
        println!("Queue is empty. Run `yardlet new \"...\"` to create work.");
        return Ok(());
    }
    // Sort for display (active work on top, done at the bottom) and mark the
    // task that runs next, so live work is not buried under completed history.
    queue.sort_for_display();
    let next = run::select_next(
        &queue,
        &RunOptions {
            execute: false,
            worker_override: None,
            target: None,
            answer: None,
            full_access: false,
            accept_ambiguity: false,
            chain: None,
        },
    )
    .ok()
    .flatten();
    for (i, t) in queue.tasks.iter().enumerate() {
        let marker = if Some(i) == next { "\u{25b8}" } else { " " };
        println!(
            "{marker}{} {:<12} {:<48} {:>6}  {}",
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
    let queue = ws.load_queue()?;
    let task_id = match &args.task {
        Some(t) => t.clone(),
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

    // No reply yet: show the worker's pending message so the user can read it
    // and decide, instead of erroring. Replying then continues the conversation.
    if reply.trim().is_empty() {
        match run::latest_question_for(&ws, &task_id) {
            Some(q) => {
                println!("{task_id} is waiting on you:\n");
                println!("{q}\n");
                println!(
                    "Reply with `yardlet answer \"...\" --task {task_id}` \
                     (ask a follow-up question, or give your decision)."
                );
            }
            None => println!("{task_id} has no recorded message. See `yardlet handoff`."),
        }
        return Ok(());
    }

    println!("You: {reply}\n");
    let report = run::run_next(
        &ws,
        &RunOptions {
            execute: true,
            worker_override: None,
            target: Some(task_id.clone()),
            answer: Some(reply),
            full_access: args.full_access,
            accept_ambiguity: false,
            chain: None,
        },
    )?;
    for line in &report.lines {
        println!("{line}");
    }
    // Surface the worker's reply so the conversation is visible in the terminal.
    if report.result_state == Some(crate::schemas::TaskState::NeedsUser) {
        if let Some(q) = run::latest_question_for(&ws, &task_id) {
            println!("\n{task_id} replied:\n");
            println!("{q}");
            println!("\nStill needs you. Reply with `yardlet answer \"...\" --task {task_id}`.");
        }
    } else if !report.run_id.is_empty() {
        println!("\nrun {} resumed", report.run_id);
    }
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
        "Approved {} (single use). Run it with `yardlet run --task {} --execute`.",
        args.task, args.task
    );
    Ok(())
}

fn cmd_defer(cwd: &std::path::Path, args: DeferArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let mut queue = ws.load_queue()?;
    let reason = args.reason.join(" ");
    let id = args.task.clone();
    let outcome = queue
        .defer_task(&id, args.cascade, &reason)
        .map_err(anyhow::Error::msg)?;
    ws.save_queue(&queue)?;
    if args.cascade && outcome.deferred.len() > 1 {
        println!(
            "Deferred {} tasks as group {}: {}",
            outcome.deferred.len(),
            outcome.group_id,
            outcome.deferred.join(", ")
        );
        println!("Revive the whole group:  yardlet revive {id} --group");
        println!("Revive only {id}:       yardlet revive {id}");
    } else {
        println!(
            "Deferred {id}: set aside, not pending and not done. Revive it with `yardlet revive {id}`."
        );
    }
    if !args.cascade && !outcome.stranded.is_empty() {
        println!(
            "WARNING: {} queued task(s) now cannot run because they depend on {id}: {}.",
            outcome.stranded.len(),
            outcome.stranded.join(", ")
        );
        println!("  Defer the stranded chain:  yardlet defer {id} --cascade");
        println!("  Revive {id}:              yardlet revive {id}");
    }
    Ok(())
}

fn cmd_revive(cwd: &std::path::Path, args: ReviveArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let mut queue = ws.load_queue()?;
    let outcome = queue
        .revive_task(&args.task, args.group)
        .map_err(anyhow::Error::msg)?;
    ws.save_queue(&queue)?;

    if outcome.revived.len() == 1 {
        println!(
            "Revived {}: queued again. Run it with `yardlet run --task {} --execute`.",
            outcome.revived[0], outcome.revived[0]
        );
    } else {
        println!(
            "Revived {} tasks: {}",
            outcome.revived.len(),
            outcome.revived.join(", ")
        );
        println!("Run the queue with `yardlet run --auto --execute`.");
    }

    if !outcome.blocked_dependencies.is_empty() {
        println!("WARNING: revived task(s) still have dependency blockers:");
        for dep in outcome.blocked_dependencies {
            println!(
                "  {} depends on {} ({:?})",
                dep.task_id, dep.dependency_id, dep.dependency_state
            );
        }
        println!("  Resolve or revive those dependencies before the task can run.");
    }
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
    crate::state::save_config_preserving_format(&ws.config_path(), &config)?;
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

fn cmd_trust(cwd: &std::path::Path) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    print!("{}", crate::trust::report(&ws)?);
    Ok(())
}

fn cmd_memory(cwd: &std::path::Path) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let config = ws.load_config()?;
    let h = crate::packet::discover_harness(&ws.root, config.harness_discovery);
    if h.memory.is_empty() {
        println!("No project memory yet. Add markdown docs under .agents/memory/.");
        return Ok(());
    }
    // A doc is possibly stale when a `look_at` landmark changed in git AFTER the
    // doc, OR has an uncommitted edit. One `git status` up front (instead of one
    // per landmark) gives the uncommitted set; commit times still need per-path
    // `git log`. An untracked doc has no commit time, but an uncommitted landmark
    // still flags it (so a git-ignored memory dir is not falsely "fresh").
    let uncommitted = git_uncommitted_paths(&ws.root);
    // `git status --porcelain` reports paths from the repo root, but a landmark is
    // workspace-root-relative — in a subdirectory workspace they differ, so build
    // the repo-root-relative form (prefix + landmark) before matching the set.
    let prefix = git_show_prefix(&ws.root);
    let staleness: Vec<bool> = h
        .memory
        .iter()
        .map(|m| {
            if m.look_at.is_empty() {
                return false;
            }
            let doc_ct = git_commit_time(&ws.root, &m.path);
            m.look_at.iter().any(|p| {
                let rel = p.trim_start_matches("./");
                uncommitted.contains(format!("{prefix}{rel}").as_str())
                    || matches!(
                        (doc_ct, git_commit_time(&ws.root, rel)),
                        (Some(d), Some(t)) if t > d
                    )
            })
        })
        .collect();
    let stale_count = staleness.iter().filter(|s| **s).count();
    let suffix = if stale_count > 0 {
        format!(", {stale_count} possibly stale")
    } else {
        String::new()
    };
    println!(
        "Project memory ({}{suffix}) — injected as an index into every packet, bodies read on demand:",
        h.memory.len(),
    );
    for (m, stale) in h.memory.iter().zip(&staleness) {
        let mark = if *stale {
            " \u{26a0} possibly stale (a look_at landmark changed since)"
        } else {
            ""
        };
        if m.summary.is_empty() {
            println!("  \u{2022} {}{mark}", m.title);
        } else {
            println!("  \u{2022} {} \u{2014} {}{mark}", m.title, m.summary);
        }
        println!("    {}", m.path);
    }
    Ok(())
}

/// The set of paths with uncommitted working-tree changes under `root` (one
/// `git status` for the whole workspace; `-z` keeps special-char paths intact).
fn git_uncommitted_paths(root: &std::path::Path) -> std::collections::HashSet<String> {
    let Some(out) = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["status", "--porcelain", "-z", "--untracked-files=all"])
        .output()
        .ok()
        .filter(|o| o.status.success())
    else {
        return std::collections::HashSet::new();
    };
    let raw = String::from_utf8_lossy(&out.stdout);
    let mut chunks = raw.split('\0');
    let mut set = std::collections::HashSet::new();
    while let Some(entry) = chunks.next() {
        if entry.len() < 4 {
            continue;
        }
        let xy = &entry[..2];
        set.insert(entry[3..].to_string());
        if xy.starts_with('R') || xy.starts_with('C') {
            chunks.next();
        }
    }
    set
}

/// The path of `root` within its git repo, with a trailing slash (empty when
/// `root` is the repo top-level). `git status --porcelain` reports paths from the
/// repo root, so a subdirectory workspace prepends this to a workspace-relative
/// landmark before matching against the uncommitted set.
fn git_show_prefix(root: &std::path::Path) -> String {
    std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["rev-parse", "--show-prefix"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

/// Unix time of the last commit touching `pathspec` under `root`, or None when
/// the path is untracked or `root` is not a git repo.
fn git_commit_time(root: &std::path::Path, pathspec: &str) -> Option<i64> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["log", "-1", "--format=%ct", "--", pathspec])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    std::str::from_utf8(&out.stdout)
        .ok()?
        .trim()
        .parse::<i64>()
        .ok()
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
            println!("No runs yet. Run `yardlet run --next --execute` first.");
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

/// A task is surfaced as "needs approval" only while it can still act on that
/// approval: it is live (not terminal — see [`TaskState::is_terminal`]) and its
/// gate is unmet. A Done/Deferred/otherwise-settled task never awaits approval,
/// even though its single-use grant was consumed or never issued.
fn task_awaits_approval(
    state: crate::schemas::TaskState,
    approval_required: bool,
    granted: bool,
) -> bool {
    !state.is_terminal() && approval_required && !granted
}

fn cmd_status(cwd: &std::path::Path, args: StatusArgs) -> Result<()> {
    let ws = init::ensure_initialized(cwd)?.0;
    let snap = Snapshot::load(&ws)?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&snap.to_json())?);
        return Ok(());
    }
    use crate::schemas::TaskState;
    println!("Yardlet workspace: {}", snap.config.workspace_id);
    println!("Intent: {}", snap.intent_summary());
    println!(
        "Queue: {} queued, {} running, {} needs-you, {} blocked, {} failed, {} deferred, {} done, {} total",
        snap.count(TaskState::Queued),
        snap.count(TaskState::Running),
        snap.count(TaskState::NeedsUser),
        snap.count(TaskState::Blocked),
        snap.count(TaskState::Failed),
        snap.count(TaskState::Deferred),
        snap.count(TaskState::Done),
        snap.queue.tasks.len(),
    );
    println!(
        "Workers invocable: {}/{}   (planner: {})",
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
                "(see `yardlet handoff`)"
            } else {
                q
            }
        );
        println!("  answer with:  yardlet answer \"<your reply>\"");
    }
    // A task blocked on a capability no enabled worker declares is not "stuck"
    // you can retry — it is parked on a human decision or a new worker. Split it
    // out so a decided/deferred ceiling does not read as a broken task (and so an
    // intent with only such tasks left does not look falsely complete).
    // Reuse the capability vocab the snapshot already parsed from workers.yaml.
    let vocab = &snap.capabilities;
    let cap_gated = |t: &crate::schemas::Task| {
        t.state == TaskState::Blocked
            && !crate::routing::unsatisfiable_capabilities(&t.required_capabilities, vocab)
                .is_empty()
    };
    let awaiting: Vec<&str> = snap
        .queue
        .tasks
        .iter()
        .filter(|t| cap_gated(t))
        .map(|t| t.id.as_str())
        .collect();
    // Stuck = Failed/Partial only (retryable). Blocked is its own thing.
    let stuck: Vec<&str> = snap
        .queue
        .tasks
        .iter()
        .filter(|t| matches!(t.state, TaskState::Failed | TaskState::Partial))
        .map(|t| t.id.as_str())
        .collect();
    // A non-capability Blocked task (e.g. a worker self-reported `blocked`) is a
    // real block, not a failed/partial run and not retryable by re-running.
    let blocked: Vec<&str> = snap
        .queue
        .tasks
        .iter()
        .filter(|t| t.state == TaskState::Blocked && !cap_gated(t))
        .map(|t| t.id.as_str())
        .collect();
    if !awaiting.is_empty() {
        println!(
            "\nawaiting you (no worker can do these yet): {}",
            awaiting.join(", ")
        );
        println!("  parked on a decision or a capability no worker declares —");
        println!("  provide what they need or add a capable worker; see `yardlet handoff`.");
    }
    if !blocked.is_empty() {
        println!("\nblocked: {}", blocked.join(", "));
        println!("  see why and how to unblock:  yardlet handoff");
    }
    if !stuck.is_empty() {
        println!("\nstuck (failed/partial): {}", stuck.join(", "));
        println!("  see why:   yardlet handoff");
        println!(
            "  retry:     yardlet run --task <id> --execute   (add --full-access if it needs network/installs)"
        );
    }
    let deferred: Vec<&str> = snap
        .queue
        .tasks
        .iter()
        .filter(|t| t.state == TaskState::Deferred)
        .map(|t| t.id.as_str())
        .collect();
    if !deferred.is_empty() {
        println!("\ndeferred (set aside by you): {}", deferred.join(", "));
        println!("  revive one:    yardlet revive <id>");
        println!("  revive group:  yardlet revive <id> --group");
    }
    let needs_approval: Vec<&str> = snap
        .queue
        .tasks
        .iter()
        .filter(|t| {
            task_awaits_approval(
                t.state,
                t.approval_required(),
                crate::approvals::is_granted(&ws, &t.id),
            )
        })
        .map(|t| t.id.as_str())
        .collect();
    if !needs_approval.is_empty() {
        println!("\nneeds approval: {}", needs_approval.join(", "));
        println!("  approve:   yardlet approve <id>   then  yardlet run --task <id> --execute");
    }
    let suggestions = crate::review::pending_count(&ws);
    if suggestions > 0 {
        println!("\nrouting: {suggestions} suggestion(s) \u{2014} run `yardlet routing review`");
    }
    let memory = crate::packet::discover_harness(&ws.root, snap.config.harness_discovery)
        .memory
        .len();
    if memory > 0 {
        println!("\nProject memory: {memory} doc(s) \u{2014} `yardlet memory`");
    }
    let runs = crate::telemetry::read_runs(&ws).len();
    if runs > 0 {
        println!("Run telemetry: {runs} run(s) \u{2014} `yardlet trust`");
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
                println!("  command: {}", s.command);
                // Staged checklist: each readiness gate, with auth reported as
                // unverifiable offline (Yardlet never makes a billed call).
                for stage in s.stages(&billing) {
                    println!(
                        "  [{:>5}] {:<11} {}",
                        stage.mark.marker(),
                        stage.label,
                        stage.note
                    );
                }
                println!("  => {}", s.invocation_verdict(&billing));
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
    let approved = task.approval_required() && crate::approvals::is_granted(&ws, &task.id);
    let text = packet::compile(&packet::PacketInputs {
        worker_id: &args.worker,
        task,
        intent: intent.as_ref(),
        repo: &summary,
        run_dir_rel: ".agents/runs/<run-id>",
        conversation: &[],
        continuation: continuation.as_deref(),
        chained_from: None,
        language: &language,
        images: &images,
        role_notes: &role_notes,
        harness: &harness,
        approved,
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
    // A backstop-parked task returns an empty run id (no run was prepared); the
    // lines above already explain it, so don't print a blank "run  prepared".
    if !report.run_id.is_empty() {
        println!(
            "\nrun {} {}",
            report.run_id,
            if report.executed {
                "executed"
            } else {
                "prepared"
            }
        );
    }
    let _ = (
        report.task_id,
        report.worker_id,
        report.run_dir,
        report.prepared,
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn needs_approval_excludes_terminal_tasks() {
        use crate::schemas::TaskState;

        // A live, gated, ungranted task is the only thing that awaits approval.
        assert!(task_awaits_approval(TaskState::Queued, true, false));
        // Granting it clears the prompt.
        assert!(!task_awaits_approval(TaskState::Queued, true, true));
        // A task with no gate never awaits approval.
        assert!(!task_awaits_approval(TaskState::Queued, false, false));
        // Terminal states never await approval, even gated-and-ungranted:
        // Done (grant consumed) and Deferred (set aside) must not be listed.
        for terminal in [
            TaskState::Done,
            TaskState::Deferred,
            TaskState::Blocked,
            TaskState::Failed,
            TaskState::NeedsUser,
            TaskState::Partial,
        ] {
            assert!(
                !task_awaits_approval(terminal, true, false),
                "{terminal:?} should not await approval"
            );
        }
    }

    const CONFIG_WITH_COMMENTS: &str = r#"schema_version: 1
product: yardlet
workspace_id: cli-test
created_at: "2026-07-03T00:00:00Z"
state_dir: .agents
default_interface: tui
canonical_queue: work-queue.yaml
current_intent: ""
language: auto
default_access: sandboxed # keep access comment
max_parallel: 1
auto_ime: true
ambiguity_gate: true
harness_discovery: true
skill_library: ""
auto_equip: true
auto_skill: true
auto_rule: false
auto_prune: true
hooks: true
auto_commit: false
"#;

    #[test]
    fn access_command_preserves_config_comments_and_order() {
        let root = std::env::temp_dir().join(format!("yard-cli-access-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        std::fs::create_dir_all(ws.agents_dir()).unwrap();
        std::fs::write(ws.config_path(), CONFIG_WITH_COMMENTS).unwrap();

        cmd_access(
            &root,
            AccessArgs {
                level: "full".to_string(),
            },
        )
        .unwrap();

        let updated = std::fs::read_to_string(ws.config_path()).unwrap();
        assert!(updated.contains("default_access: full # keep access comment"));
        assert!(updated.contains("language: auto"));
        assert!(updated.contains("auto_commit: false"));
        let _ = std::fs::remove_dir_all(&root);
    }
}
