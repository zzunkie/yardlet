//! Yardlet: a local AI workbench.
//!
//! Plan, queue, route, validate, and hand off long-running work inside a local
//! workspace using subscription-backed Codex and Claude Code CLIs as hidden
//! workers. Yardlet core never requires, requests, stores, or calls AI provider
//! API keys.

mod approvals;
mod cli;
mod compact;
mod eval_fixtures;
mod evaluator;
mod git_finish;
mod guard;
mod hooks;
mod init;
mod inspect;
mod memory;
mod packet;
mod parallel;
mod planner;
mod report;
mod review;
mod routing;
mod rubric;
mod run;
mod schemas;
mod skill_author;
mod skills;
mod snapshot;
mod state;
mod telemetry;
mod templates;
mod trust;
mod ui;
mod watch;
mod workers;
mod yaml;

use clap::Parser;

fn main() {
    let cli = cli::Cli::parse();
    if let Err(err) = cli::dispatch(cli) {
        eprintln!("yardlet: {err:#}");
        std::process::exit(1);
    }
}
