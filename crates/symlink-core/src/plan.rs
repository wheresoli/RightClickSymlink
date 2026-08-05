use std::path::PathBuf;

use crate::error::{Error, Result};
use crate::pathutil::{lexical_abs, relative_from};
use crate::platform;
use crate::request::{LinkKind, LinkRequest, PathStyle, TargetType};

/// Something the user should know before confirming, but which does not block
/// the operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Warning {
    /// The target does not exist. The link will be created and will dangle.
    DanglingTarget,
    /// User asked for a relative link but the paths share no root, so we fell
    /// back to absolute.
    RelativeImpossible,
    /// User asked for a symlink, this system cannot make one unprivileged, but
    /// a junction would work.
    JunctionSubstituteAvailable,
    /// A junction's target is resolved once, at creation. Moving the target
    /// later leaves the junction pointing at nothing, with no way to tell from
    /// the link itself.
    JunctionIsAbsoluteOnly,
    /// Hardlinks share an inode: editing either path edits the same bytes, and
    /// there is no "original".
    HardlinkHasNoOriginal,
    /// The link is being created inside the directory it points at.
    LinkInsideTarget,
}

impl Warning {
    pub fn message(&self) -> &'static str {
        match self {
            Warning::DanglingTarget => {
                "The target does not exist yet. The link will be created but will not resolve \
                 until something appears at that path."
            }
            Warning::RelativeImpossible => {
                "A relative link is not possible across different drives. Using an absolute \
                 path instead."
            }
            Warning::JunctionSubstituteAvailable => {
                "This account cannot create symlinks without elevation, but a junction will \
                 work and behaves the same for most purposes."
            }
            Warning::JunctionIsAbsoluteOnly => {
                "Junctions store an absolute path. If you move the target later, the junction \
                 will break silently."
            }
            Warning::HardlinkHasNoOriginal => {
                "A hard link is a second name for the same file, not a pointer. Edits through \
                 either name change the same data, and the file survives until both names are \
                 deleted."
            }
            Warning::LinkInsideTarget => {
                "The link is being created inside the folder it points at. Tools that walk the \
                 tree may recurse forever unless they detect the cycle."
            }
        }
    }
}

/// A validated, ready-to-execute operation.
///
/// Producing a `Plan` performs every check that can be done without touching
/// the filesystem in a mutating way, so the UI can show the user exactly what
/// is about to happen -- and so `execute` has almost no branching left in it.
#[derive(Debug, Clone)]
pub struct Plan {
    /// Absolute, lexically-normalised location of the real thing.
    pub target_abs: PathBuf,
    /// Absolute location the link will be created at.
    pub link_path: PathBuf,
    /// What actually gets written into the link -- absolute or relative
    /// depending on `style`. This is the string a user sees in `ls -l`.
    pub stored_target: PathBuf,
    pub kind: LinkKind,
    /// Resolved file-vs-directory. Matters only on Windows, where it is baked
    /// into the link permanently.
    pub is_dir: bool,
    pub warnings: Vec<Warning>,
}

impl Plan {
    /// One-line summary suitable for a confirmation dialog.
    pub fn summary(&self) -> String {
        format!(
            "Create {} \"{}\"\n  in  {}\n  ->  {}",
            self.kind,
            self.link_path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy(),
            self.link_path.parent().unwrap_or(&self.link_path).display(),
            self.stored_target.display(),
        )
    }
}

/// Validate a request and work out precisely what will happen.
///
/// Never mutates the filesystem.
pub fn plan(req: &LinkRequest) -> Result<Plan> {
    let target_abs = lexical_abs(&req.target);
    let link_path = lexical_abs(&req.link_path);
    let mut warnings = Vec::new();

    if link_path.file_name().is_none() {
        return Err(Error::LinkPathHasNoName(link_path));
    }

    // `symlink_metadata` rather than `metadata`: if a broken symlink already
    // sits at the link path we must still refuse, and `exists()` would say no.
    if link_path.symlink_metadata().is_ok() {
        return Err(Error::LinkPathExists(link_path));
    }

    let parent = link_path
        .parent()
        .ok_or_else(|| Error::LinkPathHasNoName(link_path.clone()))?;
    if !parent.is_dir() {
        return Err(Error::LinkParentMissing(parent.to_path_buf()));
    }

    // Resolve file-vs-directory.
    let target_meta = target_abs.symlink_metadata().ok();
    let is_dir = match req.target_type {
        TargetType::File => false,
        TargetType::Dir => true,
        TargetType::Auto => match &target_meta {
            Some(m) => {
                // Follow one level: if the target is itself a symlink, what
                // matters is what it eventually points at.
                if m.file_type().is_symlink() {
                    target_abs.metadata().map(|m| m.is_dir()).unwrap_or(false)
                } else {
                    m.is_dir()
                }
            }
            None => {
                // Windows needs a definite answer here and there is none.
                // Unix does not care, so let it through as a file link.
                if cfg!(windows) {
                    return Err(Error::TargetMissing(target_abs));
                }
                false
            }
        },
    };

    if target_meta.is_none() {
        warnings.push(Warning::DanglingTarget);
    }

    if is_dir && link_path.starts_with(&target_abs) {
        warnings.push(Warning::LinkInsideTarget);
    }

    let caps = platform::capabilities();

    // Per-kind feasibility.
    match req.kind {
        LinkKind::Symlink => {
            if !caps.symlink_unprivileged {
                if is_dir && caps.junction {
                    warnings.push(Warning::JunctionSubstituteAvailable);
                } else {
                    return Err(Error::PrivilegeRequired);
                }
            }
        }
        LinkKind::Junction => {
            if !caps.junction {
                return Err(Error::Unsupported {
                    kind: LinkKind::Junction,
                    why: "junctions exist only on Windows",
                });
            }
            if !is_dir {
                return Err(Error::Unsupported {
                    kind: LinkKind::Junction,
                    why: "junctions can only point at folders",
                });
            }
            if req.style == PathStyle::Relative {
                warnings.push(Warning::JunctionIsAbsoluteOnly);
            }
            platform::check_same_volume(&target_abs, parent)?;
        }
        LinkKind::Hardlink => {
            if is_dir {
                return Err(Error::Unsupported {
                    kind: LinkKind::Hardlink,
                    why: "hard links can only point at files, not folders",
                });
            }
            if target_meta.is_none() {
                return Err(Error::TargetMissing(target_abs));
            }
            warnings.push(Warning::HardlinkHasNoOriginal);
            platform::check_same_volume(&target_abs, parent)?;
        }
    }

    // Work out the string that actually gets stored inside the link.
    let stored_target = if req.kind == LinkKind::Junction {
        // A junction's reparse point has nowhere to put a relative path -- the
        // on-disk format is absolute-only. The request is upgraded silently and
        // `JunctionIsAbsoluteOnly` above tells the user why.
        target_abs.clone()
    } else {
        match req.style {
            PathStyle::Absolute => target_abs.clone(),
            PathStyle::Relative => match relative_from(parent, &target_abs) {
                Some(r) => r,
                None => {
                    warnings.push(Warning::RelativeImpossible);
                    target_abs.clone()
                }
            },
        }
    };

    Ok(Plan {
        target_abs,
        link_path,
        stored_target,
        kind: req.kind,
        is_dir,
        warnings,
    })
}

/// Perform the operation described by a `Plan`.
///
/// Re-checks the link path immediately beforehand. The gap between planning and
/// confirming is however long the user stares at the dialog, and something else
/// may have taken the name in the meantime.
pub fn execute(plan: &Plan) -> Result<()> {
    if plan.link_path.symlink_metadata().is_ok() {
        return Err(Error::LinkPathExists(plan.link_path.clone()));
    }

    match plan.kind {
        LinkKind::Symlink => {
            platform::create_symlink(&plan.link_path, &plan.stored_target, plan.is_dir)
        }
        LinkKind::Junction => platform::create_junction(&plan.link_path, &plan.stored_target),
        LinkKind::Hardlink => platform::create_hardlink(&plan.link_path, &plan.stored_target),
    }
}
