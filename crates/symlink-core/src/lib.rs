//! Creating real filesystem links, uniformly, on Windows / macOS / Linux.
//!
//! The whole crate is built around one idea: **plan, then execute**.
//!
//! ```no_run
//! use symlink_core::{plan, execute, LinkRequest, PathStyle};
//!
//! let req = LinkRequest::into_dir("/data/photos", "/home/me/Desktop")
//!     .with_style(PathStyle::Relative);
//!
//! let p = plan(&req)?;                     // validates, touches nothing
//! for w in &p.warnings {
//!     eprintln!("warning: {}", w.message());
//! }
//! execute(&p)?;                            // the only mutating call
//! # Ok::<(), symlink_core::Error>(())
//! ```
//!
//! [`plan`] does every check that does not require writing, and returns a
//! [`Plan`] describing exactly what will land on disk -- including the literal
//! string that goes inside the link. That is what a confirmation dialog should
//! render. [`execute`] then has essentially no decisions left to make.
//!
//! # What this crate will not do
//!
//! It will not overwrite anything. There is no force flag, at any layer. If
//! something already occupies the link path you get [`Error::LinkPathExists`]
//! and the filesystem is untouched. Replacing an existing file or folder with a
//! link is a genuinely destructive operation and does not belong behind the
//! same button as creating one.
//!
//! # Platform asymmetries worth knowing
//!
//! * **Windows symlinks are typed.** File-vs-directory is fixed at creation.
//!   [`TargetType::Auto`] infers it from the target, and fails on Windows if
//!   the target does not exist, because there is nothing to infer from.
//! * **Windows symlinks need privilege.** Elevation, or Developer Mode plus
//!   `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`. When neither is available
//!   and the target is a directory, [`LinkKind::Junction`] is the escape hatch;
//!   [`plan`] flags this as [`Warning::JunctionSubstituteAvailable`].
//! * **Unix symlinks are free and untyped.** No privilege, no flag, and
//!   dangling links are perfectly legal.

#![deny(unsafe_op_in_unsafe_fn)]

mod error;
mod pathutil;
mod plan;
mod platform;
mod request;

pub use error::{Error, Result};
pub use pathutil::{lexical_abs, relative_from};
pub use plan::{execute, plan, Plan, Warning};
pub use platform::{capabilities, capabilities_json, Capabilities};
pub use request::{LinkKind, LinkRequest, PathStyle, TargetType};

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// The property the whole design rests on: creating a link never destroys
    /// what is already there.
    #[test]
    fn refuses_to_overwrite_an_existing_file() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("real.txt");
        let occupied = tmp.path().join("occupied.txt");
        fs::write(&target, b"target").unwrap();
        fs::write(&occupied, b"do not lose me").unwrap();

        let req = LinkRequest {
            target,
            link_path: occupied.clone(),
            kind: LinkKind::Symlink,
            style: PathStyle::Absolute,
            target_type: TargetType::Auto,
        };

        assert!(matches!(plan(&req), Err(Error::LinkPathExists(_))));
        assert_eq!(fs::read(&occupied).unwrap(), b"do not lose me");
    }

    /// A broken symlink still occupies the name. `exists()` returns false for
    /// one, so anything relying on that check would happily clobber it.
    #[test]
    fn refuses_to_overwrite_a_dangling_symlink() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("real.txt");
        fs::write(&target, b"x").unwrap();

        let occupied = tmp.path().join("dangling");
        #[cfg(unix)]
        std::os::unix::fs::symlink(tmp.path().join("nowhere"), &occupied).unwrap();
        #[cfg(windows)]
        {
            if !capabilities().symlink_unprivileged {
                return; // nothing to assert without the privilege
            }
            std::os::windows::fs::symlink_file(tmp.path().join("nowhere"), &occupied).unwrap();
        }

        let req = LinkRequest {
            target,
            link_path: occupied,
            kind: LinkKind::Symlink,
            style: PathStyle::Absolute,
            target_type: TargetType::Auto,
        };
        assert!(matches!(plan(&req), Err(Error::LinkPathExists(_))));
    }

    #[test]
    fn plans_a_relative_link_between_siblings() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        let dst = tmp.path().join("dst");
        fs::create_dir(&src).unwrap();
        fs::create_dir(&dst).unwrap();
        fs::write(src.join("file.txt"), b"x").unwrap();

        let req = LinkRequest::into_dir(src.join("file.txt"), &dst).with_style(PathStyle::Relative);
        let p = plan(&req).unwrap();

        assert_eq!(
            p.stored_target,
            std::path::Path::new("..").join("src").join("file.txt")
        );
        assert!(!p.is_dir);
    }

    #[test]
    fn detects_a_directory_target() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("adir");
        let dst = tmp.path().join("elsewhere");
        fs::create_dir(&src).unwrap();
        fs::create_dir(&dst).unwrap();

        let p = plan(&LinkRequest::into_dir(&src, &dst)).unwrap();
        assert!(p.is_dir, "a folder target must produce a directory link");
        assert!(
            p.warnings.is_empty(),
            "unexpected warnings: {:?}",
            p.warnings
        );
    }

    /// Creating a link *inside* the folder it points at makes a cycle. It is
    /// legal, so it warns rather than failing -- but it must warn.
    #[test]
    fn warns_when_the_link_lands_inside_its_own_target() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("adir");
        fs::create_dir(&src).unwrap();

        let req = LinkRequest {
            link_path: src.join("loop"),
            ..LinkRequest::into_dir(&src, &src)
        };
        let p = plan(&req).unwrap();
        assert!(p.warnings.contains(&Warning::LinkInsideTarget));
    }

    #[test]
    fn hardlink_to_a_directory_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("adir");
        fs::create_dir(&src).unwrap();

        let req = LinkRequest {
            link_path: tmp.path().join("hl"),
            ..LinkRequest::into_dir(&src, tmp.path()).with_kind(LinkKind::Hardlink)
        };
        assert!(matches!(
            plan(&req),
            Err(Error::Unsupported {
                kind: LinkKind::Hardlink,
                ..
            })
        ));
    }

    #[test]
    fn missing_parent_directory_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("real.txt");
        fs::write(&target, b"x").unwrap();

        let req = LinkRequest::into_dir(&target, tmp.path().join("no").join("such"));
        assert!(matches!(plan(&req), Err(Error::LinkParentMissing(_))));
    }

    /// End-to-end on Unix, and on Windows only when the box can actually do it.
    #[test]
    fn creates_and_resolves_a_symlink() {
        let tmp = tempfile::tempdir().unwrap();
        if !capabilities().symlink_unprivileged {
            eprintln!("skipping: this system cannot create symlinks unprivileged");
            return;
        }

        let target = tmp.path().join("real.txt");
        fs::write(&target, b"hello").unwrap();
        let dst = tmp.path().join("sub");
        fs::create_dir(&dst).unwrap();

        let p = plan(&LinkRequest::into_dir(&target, &dst)).unwrap();
        execute(&p).unwrap();

        let link = dst.join("real.txt");
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
        assert_eq!(fs::read(&link).unwrap(), b"hello");

        // Removing the link must leave the target alone.
        fs::remove_file(&link).unwrap();
        assert!(target.exists());
    }

    #[cfg(windows)]
    #[test]
    fn creates_a_junction_without_privilege() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("realdir");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("inside.txt"), b"hi").unwrap();

        let req = LinkRequest {
            link_path: tmp.path().join("jn"),
            target: target.clone(),
            kind: LinkKind::Junction,
            style: PathStyle::Absolute,
            target_type: TargetType::Auto,
        };
        let p = plan(&req).unwrap();
        execute(&p).unwrap();

        let link = tmp.path().join("jn");
        assert_eq!(fs::read(link.join("inside.txt")).unwrap(), b"hi");
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink()); // reparse points report as symlink to std

        fs::remove_dir(&link).unwrap();
        assert!(target.join("inside.txt").exists());
    }

    /// The capability probe is the one thing this crate writes outside the link
    /// it was asked to create, so it must leave nothing in %TEMP%.
    #[cfg(windows)]
    #[test]
    fn the_capability_probe_leaves_nothing_in_temp() {
        // capabilities() is cached per process, so this may be reading the
        // aftermath of an earlier call rather than triggering one. Either way
        // the assertion is the same: no probe artifact survives.
        let _ = capabilities();

        let temp = std::env::temp_dir();
        let leftovers: Vec<_> = fs::read_dir(&temp)
            .expect("temp dir should be readable")
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with(".rcsym-probe"))
            .collect();

        assert!(
            leftovers.is_empty(),
            "probe artifacts left in {}: {leftovers:?}",
            temp.display()
        );
    }

    /// Whatever the probe points at must not be the directory the probe lives
    /// in. A self-referential directory symlink left behind by a killed process
    /// is a cycle that anything walking %TEMP% will spin on.
    #[cfg(windows)]
    #[test]
    fn a_leaked_probe_would_not_be_a_directory_cycle() {
        let temp = std::env::temp_dir();
        let link = temp.join(format!(".rcsym-probe-cycletest-{}", std::process::id()));
        let _ = fs::remove_dir(&link);

        // Same call the probe makes.
        let target = temp.join(".rcsym-probe-target-that-does-not-exist");
        std::os::windows::fs::symlink_dir(&target, &link)
            .expect("creating a dangling directory symlink should succeed");

        // Created, so the privilege was genuinely exercised...
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
        // ...but it resolves nowhere, so it cannot be descended into.
        assert!(!link.exists(), "the probe target must not exist");
        assert_ne!(
            link.read_link().unwrap(),
            temp,
            "the probe must not point at its own directory"
        );

        fs::remove_dir(&link).unwrap();
    }
}
