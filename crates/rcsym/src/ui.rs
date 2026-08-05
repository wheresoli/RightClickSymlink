//! Native dialogs, and the fallback for when there is no GUI to show them in.
//!
//! Everything here goes through `rfd`, which maps onto `IFileDialog` on
//! Windows, `NSOpenPanel`/`NSSavePanel` on macOS, and the XDG desktop portal
//! (falling back to GTK) on Linux. No toolkit is bundled and the dialogs match
//! whatever the user's desktop actually looks like.
//!
//! The destination picker is deliberately a **Save** dialog rather than a
//! folder picker. A save dialog is "choose a folder, and type a name" in one
//! native window, which is exactly the two things a link needs, and it lets the
//! OS handle the name-collision prompt in the way the user already expects.

use std::path::{Path, PathBuf};

use rfd::{FileDialog, MessageButtons, MessageDialog, MessageDialogResult, MessageLevel};
use symlink_core::Plan;

/// Where output goes when there is nothing to print to.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Output {
    /// Console subsystem: stdout/stderr are real.
    Console,
    /// GUI subsystem: there is no console, so text has to become a dialog.
    Gui,
}

const TITLE: &str = "Right Click Symlink";

pub fn error(out: Output, msg: &str) {
    match out {
        Output::Console => eprintln!("error: {msg}"),
        Output::Gui => {
            MessageDialog::new()
                .set_level(MessageLevel::Error)
                .set_title(TITLE)
                .set_description(msg)
                .set_buttons(MessageButtons::Ok)
                .show();
        }
    }
}

pub fn info(out: Output, msg: &str) {
    match out {
        Output::Console => println!("{msg}"),
        Output::Gui => {
            MessageDialog::new()
                .set_level(MessageLevel::Info)
                .set_title(TITLE)
                .set_description(msg)
                .set_buttons(MessageButtons::Ok)
                .show();
        }
    }
}

/// Ask where the new link should go.
///
/// `default_dir` seeds the starting folder, `default_name` prefills the
/// filename. Returns `None` if the user cancelled.
pub fn ask_link_path(default_dir: &Path, default_name: &str) -> Option<PathBuf> {
    FileDialog::new()
        .set_title("Create link as...")
        .set_directory(default_dir)
        .set_file_name(default_name)
        .set_can_create_directories(true)
        .save_file()
}

/// Ask what the link should point at.
pub fn ask_source_folder(start: &Path) -> Option<PathBuf> {
    FileDialog::new()
        .set_title("Link to which folder?")
        .set_directory(start)
        .pick_folder()
}

pub fn ask_source_file(start: &Path) -> Option<PathBuf> {
    FileDialog::new()
        .set_title("Link to which file?")
        .set_directory(start)
        .pick_file()
}

/// Show the plan and any warnings, and wait for a yes.
///
/// Warnings are rendered in full rather than summarised. Every one of them
/// describes a way the resulting link will behave surprisingly later, and the
/// moment before creating it is the only time the user is paying attention.
pub fn confirm(out: Output, plan: &Plan) -> bool {
    if out == Output::Console {
        // A console run with confirmation still enabled has no way to prompt
        // safely from a context-menu launch, so treat it as approved and let
        // stdout carry the record.
        println!("{}", describe(plan));
        return true;
    }

    let result = MessageDialog::new()
        .set_level(if plan.warnings.is_empty() {
            MessageLevel::Info
        } else {
            MessageLevel::Warning
        })
        .set_title(TITLE)
        .set_description(describe(plan))
        .set_buttons(MessageButtons::YesNo)
        .show();

    result == MessageDialogResult::Yes
}

pub fn describe(plan: &Plan) -> String {
    let mut s = plan.summary();
    if !plan.warnings.is_empty() {
        s.push('\n');
        for w in &plan.warnings {
            s.push_str("\n\u{26a0} ");
            s.push_str(w.message());
        }
    }
    s
}
