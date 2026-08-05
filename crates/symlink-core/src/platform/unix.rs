//! macOS and Linux. Both are POSIX here, and both are trivial compared to
//! Windows: `symlink(2)` needs no privilege, takes no file-vs-directory flag,
//! and happily creates dangling links.

use std::path::Path;

use crate::error::{Error, Result};
use crate::platform::Capabilities;
use crate::request::LinkKind;

pub fn capabilities() -> Capabilities {
    Capabilities {
        // Any user can symlink anywhere they can write.
        symlink_unprivileged: true,
        junction: false,
        hardlink: true,
        developer_mode: None,
        elevated: None,
    }
}

/// `symlink(2)`, straight through.
///
/// `is_dir` is accepted and ignored: Unix symlinks are untyped. Keeping the
/// parameter in the signature is what lets the caller stay platform-agnostic,
/// and it documents the asymmetry at the one place it matters.
pub fn create_symlink(link: &Path, stored_target: &Path, _is_dir: bool) -> Result<()> {
    std::os::unix::fs::symlink(stored_target, link).map_err(Error::Io)
}

pub fn create_junction(_link: &Path, _stored_target: &Path) -> Result<()> {
    Err(Error::Unsupported {
        kind: LinkKind::Junction,
        why: "junctions are a Windows-only construct",
    })
}

pub fn create_hardlink(link: &Path, target: &Path) -> Result<()> {
    std::fs::hard_link(target, link).map_err(Error::Io)
}
