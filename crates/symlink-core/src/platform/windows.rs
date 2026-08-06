//! Windows.
//!
//! The awkward platform. Three things make it so:
//!
//! * Symlink creation needs `SeCreateSymbolicLinkPrivilege`, i.e. an elevated
//!   process -- unless Developer Mode is on and we pass
//!   `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE` (Windows 10 1703+).
//! * Symlinks are *typed*. File-vs-directory is baked into the reparse point at
//!   creation and cannot be changed afterwards. `symlink(2)` has no such flag.
//! * When a symlink is impossible, a junction usually still works and needs no
//!   privilege whatsoever -- so the fallback is worth the extra code.
//!
//! The Win32 declarations below are hand-written rather than pulled from
//! `windows-sys`. Six functions from kernel32 and three from advapi32 do not
//! justify the dependency, and hand-rolling means no feature-flag guesswork and
//! no breakage when the crate reshuffles its `HANDLE` type between releases.

use std::ffi::{c_void, OsStr};
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::sync::OnceLock;

use crate::error::{Error, Result};
use crate::platform::Capabilities;

// ---------------------------------------------------------------------------
// Raw Win32
// ---------------------------------------------------------------------------

type Handle = *mut c_void;
type Hkey = *mut c_void;

const INVALID_HANDLE_VALUE: Handle = -1isize as Handle;

const GENERIC_WRITE: u32 = 0x4000_0000;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;

const FSCTL_SET_REPARSE_POINT: u32 = 0x0009_00A4;
const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;

const SYMBOLIC_LINK_FLAG_DIRECTORY: u32 = 0x1;
const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE: u32 = 0x2;

const ERROR_INVALID_PARAMETER: u32 = 87;
const ERROR_PRIVILEGE_NOT_HELD: u32 = 1314;
const ERROR_NOT_SAME_DEVICE: u32 = 17;
const ERROR_ALREADY_EXISTS: u32 = 183;

const HKEY_LOCAL_MACHINE: Hkey = 0x8000_0002u32 as usize as Hkey;
const RRF_RT_REG_DWORD: u32 = 0x0000_0018;
const TOKEN_QUERY: u32 = 0x0008;
const TOKEN_ELEVATION_CLASS: i32 = 20;

#[link(name = "kernel32")]
extern "system" {
    fn CreateSymbolicLinkW(symlink: *const u16, target: *const u16, flags: u32) -> u8;
    fn CreateHardLinkW(new_file: *const u16, existing: *const u16, sa: *mut c_void) -> i32;
    fn CreateFileW(
        name: *const u16,
        access: u32,
        share: u32,
        sa: *mut c_void,
        disposition: u32,
        flags: u32,
        template: Handle,
    ) -> Handle;
    fn DeviceIoControl(
        handle: Handle,
        code: u32,
        in_buf: *const c_void,
        in_size: u32,
        out_buf: *mut c_void,
        out_size: u32,
        returned: *mut u32,
        overlapped: *mut c_void,
    ) -> i32;
    fn CloseHandle(handle: Handle) -> i32;
    fn GetLastError() -> u32;
    fn GetVolumePathNameW(path: *const u16, buf: *mut u16, len: u32) -> i32;
    fn GetCurrentProcess() -> Handle;
}

#[link(name = "advapi32")]
extern "system" {
    fn RegGetValueW(
        key: Hkey,
        subkey: *const u16,
        value: *const u16,
        flags: u32,
        kind: *mut u32,
        data: *mut c_void,
        size: *mut u32,
    ) -> i32;
    fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
    fn GetTokenInformation(
        token: Handle,
        class: i32,
        info: *mut c_void,
        len: u32,
        ret_len: *mut u32,
    ) -> i32;
}

// ---------------------------------------------------------------------------
// String / path helpers
// ---------------------------------------------------------------------------

fn wide(s: &OsStr) -> Vec<u16> {
    s.encode_wide().chain(std::iter::once(0)).collect()
}

/// Wide-encode a path we are about to *create*, adding the `\\?\` extended
/// prefix when it is long enough to trip the legacy `MAX_PATH` limit.
///
/// Only ever applied to the link path, never to the stored target -- a `\\?\`
/// prefix baked into a link's target is visible in every UI that reads it and
/// changes path-resolution semantics for anything that follows the link.
fn wide_link_path(p: &Path) -> Vec<u16> {
    const LEGACY_LIMIT: usize = 240;
    let s = p.as_os_str();
    if s.len() > LEGACY_LIMIT
        && p.is_absolute()
        && !p.to_string_lossy().starts_with(r"\\?\")
        && !p.to_string_lossy().starts_with(r"\\")
    {
        let mut v: Vec<u16> = r"\\?\".encode_utf16().collect();
        v.extend(s.encode_wide());
        v.push(0);
        v
    } else {
        wide(s)
    }
}

fn last_error() -> Error {
    match unsafe { GetLastError() } {
        ERROR_PRIVILEGE_NOT_HELD => Error::PrivilegeRequired,
        code => Error::Io(std::io::Error::from_raw_os_error(code as i32)),
    }
}

// ---------------------------------------------------------------------------
// Capabilities
// ---------------------------------------------------------------------------

pub fn capabilities() -> Capabilities {
    static CACHE: OnceLock<Capabilities> = OnceLock::new();
    *CACHE.get_or_init(|| Capabilities {
        symlink_unprivileged: probe_symlink(),
        junction: true,
        hardlink: true,
        developer_mode: developer_mode(),
        elevated: is_elevated(),
    })
}

/// Actually try to create a symlink in the temp directory and see what happens.
///
/// Inference from Developer Mode plus elevation gets this wrong often enough
/// -- group policy, container images, mapped drives -- that an empirical answer
/// is worth one file operation, cached for the process lifetime.
fn probe_symlink() -> bool {
    let dir = std::env::temp_dir();
    let link = dir.join(format!(".rcsym-probe-{}", std::process::id()));

    // Clear a leftover from an earlier run that died mid-probe and had this
    // same PID. remove_dir first: a *directory* symlink is removed with
    // RemoveDirectoryW, and remove_file (DeleteFileW) will not touch one.
    let _ = std::fs::remove_dir(&link);
    let _ = std::fs::remove_file(&link);

    // Point at a path that deliberately does NOT exist.
    //
    // The privilege is enforced when the link is *created*, not when it
    // resolves, so a dangling target measures exactly the same thing.
    //
    // Pointing at the temp directory itself -- which is the obvious choice,
    // since it is guaranteed to exist -- makes the probe self-referential.
    // The link is removed microseconds later, but if the process is killed in
    // between, that leaves a directory that contains itself sitting in %TEMP%,
    // and any tree walker without cycle detection will descend it forever.
    // Disk cleaners, backup agents and search indexers all walk %TEMP%.
    //
    // A dangling link leaks as an inert dead pointer instead.
    let target = dir.join(".rcsym-probe-target-that-does-not-exist");

    let l = wide_link_path(&link);
    let t = wide(target.as_os_str());
    let flags = SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;

    let ok = unsafe { CreateSymbolicLinkW(l.as_ptr(), t.as_ptr(), flags) } != 0;
    if ok {
        // remove_dir unlinks the link itself and never follows it.
        let _ = std::fs::remove_dir(&link);
    }
    ok
}

fn developer_mode() -> Option<bool> {
    let subkey = wide(OsStr::new(
        r"SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock",
    ));
    let value = wide(OsStr::new("AllowDevelopmentWithoutDevLicense"));
    let mut data: u32 = 0;
    let mut size: u32 = std::mem::size_of::<u32>() as u32;

    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            subkey.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_DWORD,
            std::ptr::null_mut(),
            &mut data as *mut u32 as *mut c_void,
            &mut size,
        )
    };
    if status == 0 {
        Some(data != 0)
    } else {
        None
    }
}

fn is_elevated() -> Option<bool> {
    let mut token: Handle = std::ptr::null_mut();
    let opened = unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) };
    if opened == 0 {
        return None;
    }

    // TOKEN_ELEVATION is a single DWORD.
    let mut elevation: u32 = 0;
    let mut ret_len: u32 = 0;
    let ok = unsafe {
        GetTokenInformation(
            token,
            TOKEN_ELEVATION_CLASS,
            &mut elevation as *mut u32 as *mut c_void,
            std::mem::size_of::<u32>() as u32,
            &mut ret_len,
        )
    };
    unsafe { CloseHandle(token) };

    if ok != 0 {
        Some(elevation != 0)
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Volume comparison
// ---------------------------------------------------------------------------

/// Compare the volume mount points of two paths.
///
/// `GetVolumePathNameW` rather than a drive-letter compare, so that mounted
/// volume folders (`C:\mnt\data` being a separate disk) are handled correctly.
pub fn check_same_volume(a: &Path, b: &Path) -> Result<()> {
    match (volume_root(a), volume_root(b)) {
        (Some(va), Some(vb)) if va.eq_ignore_ascii_case(&vb) => Ok(()),
        (Some(_), Some(_)) => Err(Error::CrossVolume {
            from: a.to_path_buf(),
            to: b.to_path_buf(),
        }),
        // If Windows will not tell us, let the actual call decide rather than
        // refusing something that might have worked.
        _ => Ok(()),
    }
}

fn volume_root(p: &Path) -> Option<String> {
    let input = wide(p.as_os_str());
    let mut buf = vec![0u16; 260];
    let ok = unsafe { GetVolumePathNameW(input.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) };
    if ok == 0 {
        return None;
    }
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(String::from_utf16_lossy(&buf[..end]))
}

// ---------------------------------------------------------------------------
// Link creation
// ---------------------------------------------------------------------------

pub fn create_symlink(link: &Path, stored_target: &Path, is_dir: bool) -> Result<()> {
    let l = wide_link_path(link);
    let t = wide(stored_target.as_os_str());
    let dir_flag = if is_dir {
        SYMBOLIC_LINK_FLAG_DIRECTORY
    } else {
        0
    };

    let ok = unsafe {
        CreateSymbolicLinkW(
            l.as_ptr(),
            t.as_ptr(),
            dir_flag | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE,
        )
    };
    if ok != 0 {
        return Ok(());
    }

    // Windows builds older than 10.0.14972 reject the unprivileged flag itself
    // rather than ignoring it. Retry without it -- on those builds an elevated
    // process can still succeed.
    if unsafe { GetLastError() } == ERROR_INVALID_PARAMETER {
        let retry = unsafe { CreateSymbolicLinkW(l.as_ptr(), t.as_ptr(), dir_flag) };
        if retry != 0 {
            return Ok(());
        }
    }

    Err(last_error())
}

/// Create a directory junction.
///
/// Junctions have no dedicated Win32 call. You create an empty directory, open
/// a handle to it with `FILE_FLAG_OPEN_REPARSE_POINT`, and write a
/// `REPARSE_DATA_BUFFER` into it with `FSCTL_SET_REPARSE_POINT`.
pub fn create_junction(link: &Path, stored_target: &Path) -> Result<()> {
    if !stored_target.is_absolute() {
        return Err(Error::Unsupported {
            kind: crate::request::LinkKind::Junction,
            why: "a junction's target must be an absolute path",
        });
    }

    std::fs::create_dir(link).map_err(|e| {
        if e.raw_os_error() == Some(ERROR_ALREADY_EXISTS as i32) {
            Error::LinkPathExists(link.to_path_buf())
        } else {
            Error::Io(e)
        }
    })?;

    // If the reparse write fails we must not leave a bare empty directory
    // behind where the user expected a link.
    match write_mount_point(link, stored_target) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = std::fs::remove_dir(link);
            Err(e)
        }
    }
}

fn write_mount_point(link: &Path, target: &Path) -> Result<()> {
    // The NT-namespace form is what the reparse point stores; the print name is
    // the friendly path Explorer shows in the properties dialog.
    let substitute: Vec<u16> = OsStr::new(&format!(r"\??\{}", target.display()))
        .encode_wide()
        .collect();
    let print: Vec<u16> = target.as_os_str().encode_wide().collect();

    let path_bytes = (substitute.len() + 1 + print.len() + 1) * 2;
    let reparse_data_len = 8 + path_bytes; // the four USHORTs plus PathBuffer
    let total = 8 + reparse_data_len; // plus tag, length, reserved

    // Backed by u64 so the buffer is 8-byte aligned for the kernel.
    let mut words = vec![0u64; total.div_ceil(8)];
    let buf: &mut [u8] =
        unsafe { std::slice::from_raw_parts_mut(words.as_mut_ptr() as *mut u8, words.len() * 8) };

    buf[0..4].copy_from_slice(&IO_REPARSE_TAG_MOUNT_POINT.to_le_bytes());
    buf[4..6].copy_from_slice(&(reparse_data_len as u16).to_le_bytes());
    buf[6..8].copy_from_slice(&0u16.to_le_bytes()); // Reserved
    buf[8..10].copy_from_slice(&0u16.to_le_bytes()); // SubstituteNameOffset
    buf[10..12].copy_from_slice(&((substitute.len() * 2) as u16).to_le_bytes());
    buf[12..14].copy_from_slice(&(((substitute.len() + 1) * 2) as u16).to_le_bytes());
    buf[14..16].copy_from_slice(&((print.len() * 2) as u16).to_le_bytes());

    let mut off = 16;
    for w in &substitute {
        buf[off..off + 2].copy_from_slice(&w.to_le_bytes());
        off += 2;
    }
    off += 2; // NUL after the substitute name
    for w in &print {
        buf[off..off + 2].copy_from_slice(&w.to_le_bytes());
        off += 2;
    }
    // Trailing NUL is already zero.

    let l = wide_link_path(link);
    let handle = unsafe {
        CreateFileW(
            l.as_ptr(),
            GENERIC_WRITE,
            0,
            std::ptr::null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
            std::ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(last_error());
    }

    let mut returned: u32 = 0;
    let ok = unsafe {
        DeviceIoControl(
            handle,
            FSCTL_SET_REPARSE_POINT,
            buf.as_ptr() as *const c_void,
            total as u32,
            std::ptr::null_mut(),
            0,
            &mut returned,
            std::ptr::null_mut(),
        )
    };
    let err = if ok == 0 { Some(last_error()) } else { None };
    unsafe { CloseHandle(handle) };

    match err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

pub fn create_hardlink(link: &Path, target: &Path) -> Result<()> {
    let l = wide_link_path(link);
    let t = wide(target.as_os_str());
    let ok = unsafe { CreateHardLinkW(l.as_ptr(), t.as_ptr(), std::ptr::null_mut()) };
    if ok != 0 {
        return Ok(());
    }
    if unsafe { GetLastError() } == ERROR_NOT_SAME_DEVICE {
        return Err(Error::CrossVolume {
            from: target.to_path_buf(),
            to: link.to_path_buf(),
        });
    }
    Err(last_error())
}
