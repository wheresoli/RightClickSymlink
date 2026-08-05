//! GUI front end. This is what the Windows context menu invokes.
//!
//! The `windows_subsystem = "windows"` attribute is what stops a console window
//! flashing on screen every time someone clicks the menu entry. It is applied
//! only in release builds so that `dbg!` and panic messages remain visible
//! while developing.
//!
//! On macOS and Linux this compiles to an ordinary binary; the attribute is a
//! no-op there.

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use clap::Parser;
use rcsym::{cli::Cli, run, ui::Output};
use std::process::ExitCode;

fn main() -> ExitCode {
    // Argument parsing can fail, and with no console there is nowhere for clap
    // to print the error -- so catch it and put it in a dialog instead.
    match Cli::try_parse() {
        Ok(args) => run(args, Output::Gui),
        Err(e) => {
            rcsym::ui::error(Output::Gui, &e.to_string());
            ExitCode::from(rcsym::EXIT_ERROR)
        }
    }
}
