use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};
use symlink_core::{LinkKind, PathStyle};

/// The contract every shell integration speaks.
///
/// Each platform's context-menu glue is a few lines that build one of these
/// command lines. Nothing platform-specific lives above this layer, which means
/// a bug in the link logic gets fixed once.
#[derive(Parser, Debug)]
#[command(
    name = "rcsym",
    version,
    about = "Create real symlinks from your file manager's right-click menu",
    long_about = None
)]
pub struct Cli {
    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(Subcommand, Debug)]
pub enum Cmd {
    /// You right-clicked the real thing. Asks where to put the link.
    ///
    /// Wired to the *item* context menu (files and folders).
    To {
        /// The item(s) that were right-clicked.
        #[arg(required = true, value_name = "TARGET")]
        targets: Vec<PathBuf>,

        #[command(flatten)]
        opts: LinkOpts,
    },

    /// You right-clicked empty space inside a folder. Asks what to point at.
    ///
    /// Wired to the *background* context menu. The link is created as a new
    /// child of `--dir`; the folder itself is never touched.
    From {
        /// The folder whose background was right-clicked.
        #[arg(long, value_name = "DIR")]
        dir: PathBuf,

        /// Whether the source picker chooses a folder or a file.
        ///
        /// Native folder pickers on Windows and Linux cannot offer both at
        /// once, so the choice is made by which menu entry was clicked.
        #[arg(long, value_enum, default_value_t = Pick::Folder)]
        pick: Pick,

        #[command(flatten)]
        opts: LinkOpts,
    },

    /// Headless. No dialogs, no prompts -- create the link and exit.
    ///
    /// This is what native front ends (the macOS host app, and eventually the
    /// Windows IExplorerCommand handler) call after running their own dialog.
    Link {
        /// The real thing being pointed at.
        #[arg(long, value_name = "PATH")]
        target: PathBuf,

        /// Folder the link is created in.
        #[arg(long, value_name = "DIR")]
        into: PathBuf,

        /// Link filename. Defaults to the target's own name.
        #[arg(long, value_name = "NAME")]
        name: Option<String>,

        /// Validate and print what would happen, without writing anything.
        #[arg(long)]
        dry_run: bool,

        #[command(flatten)]
        opts: LinkOpts,
    },

    /// Print what this machine can do, as JSON.
    ///
    /// Exists so "why won't it make a symlink here?" has a one-command answer.
    Probe,
}

#[derive(clap::Args, Debug, Clone)]
pub struct LinkOpts {
    /// symlink (default), junction (Windows folders), or hardlink (files).
    #[arg(long, value_enum, default_value_t = Kind::Symlink)]
    pub kind: Kind,

    /// Store a path relative to the link's own folder instead of an absolute
    /// one. Relative links survive the whole tree being moved.
    #[arg(long)]
    pub relative: bool,

    /// Skip the confirmation dialog. Errors are still reported.
    #[arg(long)]
    pub no_confirm: bool,
}

#[derive(ValueEnum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Symlink,
    Junction,
    Hardlink,
}

impl From<Kind> for LinkKind {
    fn from(k: Kind) -> Self {
        match k {
            Kind::Symlink => LinkKind::Symlink,
            Kind::Junction => LinkKind::Junction,
            Kind::Hardlink => LinkKind::Hardlink,
        }
    }
}

#[derive(ValueEnum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pick {
    Folder,
    File,
}

impl LinkOpts {
    pub fn style(&self) -> PathStyle {
        if self.relative {
            PathStyle::Relative
        } else {
            PathStyle::Absolute
        }
    }
}
