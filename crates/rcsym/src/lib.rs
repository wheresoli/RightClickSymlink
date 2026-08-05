//! The shared body of both binaries.
//!
//! `rcsym` (console) and `rcsymw` (GUI subsystem) differ only in how they were
//! linked and what they pass as [`ui::Output`].

pub mod cli;
pub mod ui;

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use symlink_core::{execute, plan, LinkRequest, TargetType};

use crate::cli::{Cli, Cmd, LinkOpts, Pick};
use crate::ui::Output;

pub const EXIT_OK: u8 = 0;
pub const EXIT_ERROR: u8 = 1;
pub const EXIT_CANCELLED: u8 = 2;

pub fn run(args: Cli, out: Output) -> ExitCode {
    match args.cmd {
        Cmd::Probe => {
            ui::info(out, &symlink_core::capabilities_json());
            ExitCode::from(EXIT_OK)
        }
        Cmd::To { targets, opts } => cmd_to(&targets, &opts, out),
        Cmd::From { dir, pick, opts } => cmd_from(&dir, pick, &opts, out),
        Cmd::Link {
            target,
            into,
            name,
            dry_run,
            opts,
        } => cmd_link(&target, &into, name.as_deref(), dry_run, &opts, out),
    }
}

/// "Symlink To..." -- the user right-clicked the real thing.
fn cmd_to(targets: &[PathBuf], opts: &LinkOpts, out: Output) -> ExitCode {
    let mut failures = Vec::new();

    for target in targets {
        // Start the picker beside the target: the overwhelmingly common case is
        // linking something into a nearby folder, not across the disk.
        let start = target.parent().unwrap_or(Path::new(".")).to_path_buf();
        let default_name = target
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "link".to_string());

        let Some(link_path) = ui::ask_link_path(&start, &default_name) else {
            return ExitCode::from(EXIT_CANCELLED);
        };

        match make(target, &link_path, opts, out, false) {
            Ok(true) => {}
            Ok(false) => return ExitCode::from(EXIT_CANCELLED),
            Err(e) => failures.push(format!("{}: {e}", target.display())),
        }
    }

    finish(failures, out)
}

/// "Symlink From..." -- the user right-clicked empty space inside a folder.
///
/// `dir` becomes the link's *parent*. It is never itself replaced or modified,
/// which is why this direction cannot destroy the folder you invoked it from.
fn cmd_from(dir: &Path, pick: Pick, opts: &LinkOpts, out: Output) -> ExitCode {
    let source = match pick {
        Pick::Folder => ui::ask_source_folder(dir),
        Pick::File => ui::ask_source_file(dir),
    };
    let Some(source) = source else {
        return ExitCode::from(EXIT_CANCELLED);
    };

    let default_name = source
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "link".to_string());

    let Some(link_path) = ui::ask_link_path(dir, &default_name) else {
        return ExitCode::from(EXIT_CANCELLED);
    };

    match make(&source, &link_path, opts, out, false) {
        Ok(true) => ExitCode::from(EXIT_OK),
        Ok(false) => ExitCode::from(EXIT_CANCELLED),
        Err(e) => {
            ui::error(out, &e);
            ExitCode::from(EXIT_ERROR)
        }
    }
}

/// Headless path, for native front ends that ran their own dialog.
fn cmd_link(
    target: &Path,
    into: &Path,
    name: Option<&str>,
    dry_run: bool,
    opts: &LinkOpts,
    out: Output,
) -> ExitCode {
    let name = name.map(|s| s.to_string()).unwrap_or_else(|| {
        target
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "link".to_string())
    });
    let link_path = into.join(name);

    match make(target, &link_path, opts, out, dry_run) {
        Ok(_) => ExitCode::from(EXIT_OK),
        Err(e) => {
            ui::error(out, &e);
            ExitCode::from(EXIT_ERROR)
        }
    }
}

/// Plan, confirm, execute. Returns `Ok(false)` when the user said no.
fn make(
    target: &Path,
    link_path: &Path,
    opts: &LinkOpts,
    out: Output,
    dry_run: bool,
) -> Result<bool, String> {
    let req = LinkRequest {
        target: target.to_path_buf(),
        link_path: link_path.to_path_buf(),
        kind: opts.kind.into(),
        style: opts.style(),
        target_type: TargetType::Auto,
    };

    let p = plan(&req).map_err(|e| e.to_string())?;

    if dry_run {
        ui::info(
            out,
            &format!("(dry run, nothing written)\n\n{}", ui::describe(&p)),
        );
        return Ok(true);
    }

    if !opts.no_confirm && !ui::confirm(out, &p) {
        return Ok(false);
    }

    execute(&p).map_err(|e| e.to_string())?;
    Ok(true)
}

fn finish(failures: Vec<String>, out: Output) -> ExitCode {
    if failures.is_empty() {
        ExitCode::from(EXIT_OK)
    } else {
        ui::error(out, &failures.join("\n"));
        ExitCode::from(EXIT_ERROR)
    }
}
