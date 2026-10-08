//! Fixed macOS process boundary. No caller-selected account root or environment
//! credentials. Tests exercise constructed directories only.
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

const PRIVATE_COMPONENTS: &[&str] = &["Library", "Application Support", "com.theoyuuu.LumaxTranslate", "CodexAccount"];

pub fn allowed_environment() -> bool {
    allowed_variables(std::env::vars_os(), unsafe { libc::getuid() })
}

fn allowed_variables(values: impl Iterator<Item = (OsString, OsString)>, uid: u32) -> bool {
    values.into_iter().all(|(key, value)| match key.to_str() {
        Some("PATH") => value == OsStr::new("/usr/bin:/bin"),
        Some("LANG") => value == OsStr::new("en_US.UTF-8"),
        Some("TMPDIR") => value.as_bytes().len() <= 4096 && Path::new(&value).is_absolute(),
        // CoreFoundation may insert its numeric encoding before main even
        // when the native caller cleared the launch environment.
        Some("__CF_USER_TEXT_ENCODING") => {
            let Some(value) = value.to_str().filter(|value| value.len() <= 32) else { return false };
            let fields: Option<Vec<u32>> = value.split(':').map(|field| {
                field.strip_prefix("0x")
                    .filter(|digits| !digits.is_empty() && digits.len() <= 8 && digits.bytes().all(|byte| byte.is_ascii_hexdigit()))
                    .and_then(|digits| u32::from_str_radix(digits, 16).ok())
            }).collect();
            matches!(fields.as_deref(), Some([encoded_uid, _, _]) if *encoded_uid == uid)
        }
        _ => false,
    })
}

/// Uses the OS account database rather than HOME, CODEX_HOME, or IPC. This is
/// called only after the one-operation input and environment were validated.
pub fn account_root() -> io::Result<PathBuf> {
    if unsafe { libc::getuid() } != unsafe { libc::geteuid() } { return Err(invalid()); }
    let mut buffer = vec![0u8; 64 * 1024];
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut found = std::ptr::null_mut();
    let code = unsafe { libc::getpwuid_r(libc::getuid(), entry.as_mut_ptr(), buffer.as_mut_ptr().cast(), buffer.len(), &mut found) };
    if code != 0 || found.is_null() { return Err(invalid()); }
    let entry = unsafe { entry.assume_init() };
    if entry.pw_dir.is_null() { return Err(invalid()); }
    let bytes = unsafe { CStr::from_ptr(entry.pw_dir) }.to_bytes();
    if bytes.is_empty() || bytes.len() > 4096 { return Err(invalid()); }
    let home = PathBuf::from(OsString::from_vec(bytes.to_vec())).canonicalize()?;
    create_private_root(&home)
}

fn invalid() -> io::Error { io::Error::other("invalid_account_storage") }

fn create_private_root(home: &Path) -> io::Result<PathBuf> {
    if !home.is_absolute() || home.canonicalize()? != home { return Err(invalid()); }
    let path = CString::new(home.as_os_str().as_bytes()).map_err(|_| invalid())?;
    let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
    if fd < 0 { return Err(io::Error::last_os_error()); }
    let mut directory = unsafe { File::from_raw_fd(fd) };
    check_directory(&directory, false)?;
    let mut result = home.to_path_buf();
    for (index, component) in PRIVATE_COMPONENTS.iter().enumerate() {
        let name = CString::new(*component).map_err(|_| invalid())?;
        if unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists { return Err(error); }
        }
        let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
        if fd < 0 { return Err(io::Error::last_os_error()); }
        let child = unsafe { File::from_raw_fd(fd) };
        check_directory(&child, index >= 2)?;
        directory.sync_all()?;
        directory = child;
        result.push(component);
    }
    directory.sync_all()?;
    if result.canonicalize()? != result { return Err(invalid()); }
    let path_metadata = std::fs::symlink_metadata(&result)?;
    let open_metadata = directory.metadata()?;
    if path_metadata.dev() != open_metadata.dev() || path_metadata.ino() != open_metadata.ino() { return Err(invalid()); }
    Ok(result)
}

fn check_directory(file: &File, private: bool) -> io::Result<()> {
    let metadata = file.metadata()?;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o022 != 0 || (private && metadata.mode() & 0o7777 != 0o700)
    { return Err(invalid()); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};
    use uuid::Uuid;

    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!("translatex-host-test-{}", Uuid::new_v4()));
            std::fs::DirBuilder::new().mode(0o700).create(&path).unwrap(); Self(path)
        }
    }
    impl Drop for Scratch { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }

    #[test]
    fn private_root_is_fixed_and_repeatable() {
        let scratch = Scratch::new();
        let root = create_private_root(&scratch.0).unwrap();
        assert_eq!(root, scratch.0.join("Library/Application Support/com.theoyuuu.LumaxTranslate/CodexAccount"));
        assert_eq!(create_private_root(&scratch.0).unwrap(), root);
        assert_eq!(std::fs::metadata(root).unwrap().mode() & 0o7777, 0o700);
    }
    #[test]
    fn redirected_and_permissive_roots_are_rejected_without_repair() {
        let scratch = Scratch::new();
        let target = Scratch::new();
        symlink(&target.0, scratch.0.join("Library")).unwrap();
        assert!(create_private_root(&scratch.0).is_err());
        assert!(std::fs::read_dir(&target.0).unwrap().next().is_none());
        std::fs::remove_file(scratch.0.join("Library")).unwrap();
        let root = create_private_root(&scratch.0).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(create_private_root(&scratch.0).is_err());
        assert_eq!(std::fs::metadata(root).unwrap().mode() & 0o7777, 0o755);
    }
    #[test]
    fn ambient_credentials_endpoints_and_unsafe_encoding_are_rejected() {
        let allowed = [("PATH", "/usr/bin:/bin"), ("LANG", "en_US.UTF-8"), ("TMPDIR", "/tmp")];
        let make = |values: Vec<(&str, &str)>| values.into_iter().map(|(key, value)| (OsString::from(key), OsString::from(value))).collect::<Vec<_>>().into_iter();
        assert!(allowed_variables(make(allowed.to_vec()), 501));
        for name in ["HOME", "CODEX_HOME", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "HTTPS_PROXY", "SSL_CERT_FILE", "RUST_LOG", "DYLD_INSERT_LIBRARIES"] {
            let mut values = allowed.to_vec(); values.push((name, "constructed"));
            assert!(!allowed_variables(make(values), 501));
        }
        assert!(allowed_variables(make(vec![("__CF_USER_TEXT_ENCODING", "0x1f5:0x0:0x0")]), 501));
        assert!(!allowed_variables(make(vec![("__CF_USER_TEXT_ENCODING", "0x1f6:0x0:0x0")]), 501));
        assert!(!allowed_variables(make(vec![("__CF_USER_TEXT_ENCODING", "0x1f5:0x0:0x0:0x0")]), 501));
    }
}
