use std::fmt;
use std::path::{Path, PathBuf};

/// What kind of link to create.
///
/// Only `Symlink` exists on every platform. The other two are Windows escape
/// hatches for the case where the user cannot create a symlink because they
/// are not elevated and Developer Mode is off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkKind {
    /// A real symbolic link. `symlink(2)` on Unix, `CreateSymbolicLinkW` on
    /// Windows.
    Symlink,
    /// Windows directory junction (`IO_REPARSE_TAG_MOUNT_POINT`).
    ///
    /// Directories only, absolute target only, local volumes only -- but it
    /// requires no privilege at all, which is why it exists here.
    Junction,
    /// A second directory entry for the same inode. Files only, same volume
    /// only. Not really a link in the user-facing sense, but occasionally what
    /// someone actually wants.
    Hardlink,
}

impl fmt::Display for LinkKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            LinkKind::Symlink => "symlink",
            LinkKind::Junction => "junction",
            LinkKind::Hardlink => "hard link",
        })
    }
}

impl LinkKind {
    pub fn parse(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "symlink" | "sym" | "soft" => Some(LinkKind::Symlink),
            "junction" | "jn" => Some(LinkKind::Junction),
            "hardlink" | "hard" => Some(LinkKind::Hardlink),
            _ => None,
        }
    }
}

/// Whether the path baked into the link is absolute or relative to the link's
/// own directory.
///
/// Relative links survive the whole tree being moved or renamed; absolute
/// links survive the link alone being moved. Neither is universally right,
/// which is why this is a user-facing choice.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathStyle {
    Absolute,
    Relative,
}

/// Windows bakes file-vs-directory into the link at creation time and there is
/// no way to change it afterwards. Unix does not care. `Auto` means "look at
/// the target and figure it out", which only fails when the target does not
/// exist yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetType {
    File,
    Dir,
    Auto,
}

/// A fully-specified request, before validation.
///
/// `link_path` is the complete path of the link to create, not a directory --
/// this matches what a native Save dialog hands back and removes an entire
/// class of "did the name mean a sibling or a child?" ambiguity.
#[derive(Debug, Clone)]
pub struct LinkRequest {
    /// The real thing being pointed at.
    pub target: PathBuf,
    /// Where the new link goes, including its filename.
    pub link_path: PathBuf,
    pub kind: LinkKind,
    pub style: PathStyle,
    pub target_type: TargetType,
}

impl LinkRequest {
    /// The common case: link named after the target, dropped into `dir`.
    pub fn into_dir(target: impl AsRef<Path>, dir: impl AsRef<Path>) -> Self {
        let target = target.as_ref().to_path_buf();
        let name = target
            .file_name()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("link"));
        LinkRequest {
            link_path: dir.as_ref().join(name),
            target,
            kind: LinkKind::Symlink,
            style: PathStyle::Absolute,
            target_type: TargetType::Auto,
        }
    }

    pub fn with_kind(mut self, kind: LinkKind) -> Self {
        self.kind = kind;
        self
    }

    pub fn with_style(mut self, style: PathStyle) -> Self {
        self.style = style;
        self
    }

    pub fn with_target_type(mut self, t: TargetType) -> Self {
        self.target_type = t;
        self
    }
}
