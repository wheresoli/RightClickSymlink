use std::path::{Component, Path, PathBuf};

/// Normalise a path lexically: make it absolute against the CWD, drop `.`, and
/// resolve `..` textually.
///
/// Deliberately *not* `canonicalize()`. Canonicalising resolves symlinks, which
/// is exactly wrong here -- if the user right-clicked a path that already goes
/// through a symlink, that is the path they meant, and rewriting it to the real
/// location would silently point the new link somewhere they never named.
/// It also avoids `\\?\` verbatim prefixes on Windows, which leak into the UI
/// and into the link target itself.
pub fn lexical_abs(p: &Path) -> PathBuf {
    let joined = if p.is_absolute() {
        p.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(p)
    };

    let mut out = PathBuf::new();
    for c in joined.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                // Only pop real names; never chew through the root or a `C:` prefix.
                let can_pop = matches!(out.components().next_back(), Some(Component::Normal(_)));
                if can_pop {
                    out.pop();
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Express `to` relative to the directory `from_dir`.
///
/// Returns `None` when the two share no common root -- different Windows
/// drives, or a UNC share versus a local path. In that case there is no
/// relative form and the caller must fall back to absolute.
pub fn relative_from(from_dir: &Path, to: &Path) -> Option<PathBuf> {
    let from: Vec<Component> = from_dir.components().collect();
    let dest: Vec<Component> = to.components().collect();

    // The prefix (`C:`) and root must match before a relative path means anything.
    let roots_match = from
        .first()
        .zip(dest.first())
        .map(|(a, b)| a == b)
        .unwrap_or(false);
    if !roots_match {
        return None;
    }

    let common = from
        .iter()
        .zip(dest.iter())
        .take_while(|(a, b)| a == b)
        .count();

    let mut out = PathBuf::new();
    for _ in common..from.len() {
        out.push("..");
    }
    for c in &dest[common..] {
        out.push(c.as_os_str());
    }
    if out.as_os_str().is_empty() {
        out.push(".");
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn relative_within_same_drive() {
        let r = relative_from(Path::new(r"C:\a\b\c"), Path::new(r"C:\a\x\y")).unwrap();
        assert_eq!(r, PathBuf::from(r"..\..\x\y"));
    }

    #[cfg(windows)]
    #[test]
    fn relative_across_drives_is_impossible() {
        assert!(relative_from(Path::new(r"C:\a"), Path::new(r"D:\b")).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn relative_within_same_root() {
        let r = relative_from(Path::new("/a/b/c"), Path::new("/a/x/y")).unwrap();
        assert_eq!(r, PathBuf::from("../../x/y"));
    }

    #[test]
    fn relative_into_child() {
        #[cfg(windows)]
        let (base, dest, want) = (r"C:\a", r"C:\a\b\c", r"b\c");
        #[cfg(unix)]
        let (base, dest, want) = ("/a", "/a/b/c", "b/c");
        let r = relative_from(Path::new(base), Path::new(dest)).unwrap();
        assert_eq!(r, PathBuf::from(want));
    }

    #[test]
    fn relative_to_self_is_dot() {
        #[cfg(windows)]
        let p = r"C:\a\b";
        #[cfg(unix)]
        let p = "/a/b";
        let r = relative_from(Path::new(p), Path::new(p)).unwrap();
        assert_eq!(r, PathBuf::from("."));
    }

    #[test]
    fn lexical_abs_eats_dot_segments() {
        #[cfg(windows)]
        let (input, want) = (r"C:\a\.\b\..\c", r"C:\a\c");
        #[cfg(unix)]
        let (input, want) = ("/a/./b/../c", "/a/c");
        assert_eq!(lexical_abs(Path::new(input)), PathBuf::from(want));
    }

    #[test]
    fn lexical_abs_never_climbs_past_root() {
        #[cfg(windows)]
        let (input, want) = (r"C:\..\..\a", r"C:\a");
        #[cfg(unix)]
        let (input, want) = ("/../../a", "/a");
        assert_eq!(lexical_abs(Path::new(input)), PathBuf::from(want));
    }
}
