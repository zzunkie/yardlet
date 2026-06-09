//! Yard: a local AI workbench.
//!
//! Plan, queue, route, validate, and hand off long-running work inside a local
//! workspace using subscription-backed Codex and Claude Code CLIs as hidden
//! workers. Yard core never requires, requests, stores, or calls AI provider
//! API keys.

mod approvals;
mod cli;
mod compact;
mod evaluator;
mod guard;
mod init;
mod inspect;
mod packet;
mod planner;
mod report;
mod review;
mod routing;
mod run;
mod schemas;
mod snapshot;
mod state;
mod telemetry;
mod templates;
mod ui;
mod workers;
mod yaml;

use clap::Parser;

fn main() {
    let cli = cli::Cli::parse();
    if let Err(err) = cli::dispatch(cli) {
        eprintln!("yard: {err:#}");
        std::process::exit(1);
    }
}
