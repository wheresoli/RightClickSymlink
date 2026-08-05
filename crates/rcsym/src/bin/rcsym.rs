//! Console front end. Use this for scripting, `probe`, and testing.

use clap::Parser;
use rcsym::{cli::Cli, run, ui::Output};
use std::process::ExitCode;

fn main() -> ExitCode {
    run(Cli::parse(), Output::Console)
}
