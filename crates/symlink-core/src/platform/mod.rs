//! Thin, uniform wrappers over the OS link syscalls.
//!
//! Two rules hold across every implementation in here:
//!
//! 1. **Nothing overwrites.** Every function fails if the link path is already
//!    occupied. There is no force flag. The OS primitives behave this way
//!    already (`symlink(2)` returns `EEXIST`, `CreateSymbolicLinkW` fails) and
//!    we do not paper over it. The destructive convenience of `ln -sf` is a
//!    property of the `ln` binary, not of the syscall, and it is not
//!    reproduced here.
//!
//! 2. **Nothing shells out.** No `ln`, no `mklink`. `ln -s target dir` silently
//!    creates `dir/target` when the second argument is a directory, and
//!    `ln -sf` dereferences an existing symlink and writes inside its target
//!    unless you also pass `-n`. `mklink` is a `cmd.exe` builtin and is not
//!    even an executable. Calling the syscalls directly removes all of it.

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::*;

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use self::unix::*;

/// What this machine can actually do right now.
///
/// On Unix this is a constant. On Windows it depends on elevation and the
/// Developer Mode setting, and is therefore probed at runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capabilities {
    /// Can this process create a symlink without being elevated?
    pub symlink_unprivileged: bool,
    /// Are directory junctions available? (Windows only.)
    pub junction: bool,
    /// Are hard links available?
    pub hardlink: bool,
    /// Windows: is Developer Mode on? `None` where the question is meaningless
    /// or not yet probed.
    pub developer_mode: Option<bool>,
    /// Windows: is this process elevated? `None` where not applicable.
    pub elevated: Option<bool>,
}

/// Render capabilities as JSON without pulling in a serialiser.
///
/// Used by `rcsym probe`, which exists so the install scripts and a support
/// request can both answer "why won't it make a symlink on this box?".
pub fn capabilities_json() -> String {
    let c = capabilities();
    fn opt(b: Option<bool>) -> String {
        match b {
            Some(v) => v.to_string(),
            None => "null".to_string(),
        }
    }
    format!(
        "{{\n  \"platform\": \"{}\",\n  \"symlink_unprivileged\": {},\n  \
         \"junction\": {},\n  \"hardlink\": {},\n  \"developer_mode\": {},\n  \
         \"elevated\": {}\n}}",
        std::env::consts::OS,
        c.symlink_unprivileged,
        c.junction,
        c.hardlink,
        opt(c.developer_mode),
        opt(c.elevated),
    )
}

/// Guard for hard links and junctions, neither of which can cross volumes.
///
/// A no-op on Unix, where the kernel enforces `EXDEV` for us and there is no
/// cheap portable way to compare mount points ahead of time.
#[cfg(unix)]
pub fn check_same_volume(_a: &std::path::Path, _b: &std::path::Path) -> crate::error::Result<()> {
    Ok(())
}
