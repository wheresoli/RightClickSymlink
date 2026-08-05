use std::fmt;
use std::path::PathBuf;

use crate::request::LinkKind;

/// Everything that can go wrong between "user picked two paths" and
/// "a link exists on disk".
///
/// Deliberately concrete: each variant carries enough to render a message a
/// non-technical user can act on, because these surface in a dialog box.
#[derive(Debug)]
pub enum Error {
    /// The thing being pointed at does not exist.
    ///
    /// Not fatal on Unix (dangling symlinks are legal), but on Windows we
    /// cannot infer whether to create a file or directory link, so the caller
    /// must supply the type explicitly.
    TargetMissing(PathBuf),

    /// Something already occupies the path where the link would go.
    ///
    /// The platform APIs refuse to overwrite and so do we. There is no
    /// force-overwrite anywhere in this crate on purpose -- see the module
    /// docs on `platform`.
    LinkPathExists(PathBuf),

    /// The directory that would contain the link does not exist.
    LinkParentMissing(PathBuf),

    /// The link path has no final component (e.g. `C:\` or `/`).
    LinkPathHasNoName(PathBuf),

    /// Requested link kind cannot express this target on this platform.
    Unsupported { kind: LinkKind, why: &'static str },

    /// Windows: symlink creation needs SeCreateSymbolicLinkPrivilege, which
    /// means either an elevated process or Developer Mode turned on.
    PrivilegeRequired,

    /// Hardlinks and junctions cannot span volumes.
    CrossVolume { from: PathBuf, to: PathBuf },

    /// Underlying OS failure we did not classify.
    Io(std::io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::TargetMissing(p) => {
                write!(f, "Nothing exists at {}", p.display())
            }
            Error::LinkPathExists(p) => write!(
                f,
                "{} already exists. Nothing was changed -- pick a different name.",
                p.display()
            ),
            Error::LinkParentMissing(p) => {
                write!(f, "The folder {} does not exist", p.display())
            }
            Error::LinkPathHasNoName(p) => {
                write!(f, "{} is not a valid place to put a link", p.display())
            }
            Error::Unsupported { kind, why } => {
                write!(f, "Cannot create a {kind} here: {why}")
            }
            Error::PrivilegeRequired => write!(
                f,
                "Windows blocks symlink creation for standard users.\n\n\
                 Either turn on Developer Mode (Settings > System > For developers), \
                 or run as administrator. For folders you can also use a junction, \
                 which needs no special permission."
            ),
            Error::CrossVolume { from, to } => write!(
                f,
                "{} and {} are on different drives, and this link type cannot cross drives.",
                from.display(),
                to.display()
            ),
            Error::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, Error>;
