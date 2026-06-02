//! Terminal UI (Ratatui).
//!
//! The TUI is the normal interface, but it is never the canonical state store:
//! it reads and writes through Yard's state layer. This first cut renders a
//! read-only Home dashboard from `.agents/` state.

mod home;

use anyhow::Result;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind};

use crate::snapshot::Snapshot;
use crate::state::Workspace;

pub fn run(ws: &Workspace) -> Result<()> {
    let mut terminal = ratatui::init();
    let result = main_loop(&mut terminal, ws);
    ratatui::restore();
    result
}

fn main_loop(terminal: &mut ratatui::DefaultTerminal, ws: &Workspace) -> Result<()> {
    loop {
        let snapshot = Snapshot::load(ws)?;
        terminal.draw(|frame| home::render(frame, &snapshot))?;

        if let Event::Key(key) = event::read()? {
            if key.kind == KeyEventKind::Press {
                match key.code {
                    KeyCode::Char('q') | KeyCode::Esc => break,
                    _ => {}
                }
            }
        }
    }
    Ok(())
}
