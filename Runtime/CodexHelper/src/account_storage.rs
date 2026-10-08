//! Filesystem transactions for TranslateX's private Codex account namespace.
//!
//! This module never reads, copies, or deletes credentials. The caller supplies
//! its fixed, owned canonical root and performs the Keychain action requested by
//! `recovery_action` before acknowledging cleanup. `active.json` is the sole
//! durable login commit point: a lost IPC reply cannot roll that commit back.
//! Every account operation, including status and translation, must hold this
//! lease and resolve a pending action before using an active identity.
//!
//! A worker must retain a duplicate of the lease's open file description until
//! it exits. Do not explicitly LOCK_UN: that would unlock all duplicates. This
//! protects filesystem recovery from a live worker, but cannot prove that an
//! already submitted macOS Keychain IPC has stopped after a hard kill.

use serde::{Deserialize, Serialize};
use std::ffi::CString;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use uuid::Uuid;

const SCHEMA: u32 = 1;
const RECORD_LIMIT: u64 = 4096;
const ACTIVE: &str = "active.json";
const PENDING: &str = "pending.json";
const LOCK: &str = "account.lock";

#[derive(Debug)]
pub enum StorageError {
    Busy,
    AlreadySignedIn,
    AlreadyCommitted,
    PendingOperation,
    InvalidOperation,
    InvalidState,
    UnsafeStorage,
    Io(io::Error),
}

impl StorageError {
    /// Safe for the protocol; never return an underlying filesystem error text.
    pub fn status(&self) -> &'static str {
        match self {
            Self::Busy => "identity_busy",
            Self::AlreadySignedIn => "already_signed_in",
            Self::AlreadyCommitted => "already_committed",
            Self::PendingOperation => "recovery_required",
            Self::InvalidOperation => "invalid_operation",
            Self::InvalidState | Self::UnsafeStorage => "invalid_account_storage",
            Self::Io(_) => "storage_unavailable",
        }
    }
}

impl From<io::Error> for StorageError {
    fn from(value: io::Error) -> Self { Self::Io(value) }
}

type Result<T> = std::result::Result<T, StorageError>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub generation: String,
    pub home: PathBuf,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationKind { Login, Logout }

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecoveryAction {
    None,
    /// The caller must confirm this exact identity's Keychain item is absent.
    /// A logout action never authorizes deleting a different active generation.
    Cleanup { operation_id: String, kind: OperationKind, identity: Identity },
    /// Keep this identity. Only `finalize_committed` is appropriate here.
    Committed { operation_id: String, identity: Identity },
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ActiveRecord { schema: u32, generation: String }

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct PendingRecord {
    schema: u32,
    kind: OperationKind,
    operation_id: String,
    generation: String,
}

pub struct AccountStorage {
    root_path: PathBuf,
    root: File,
    identities: File,
    lease: File,
}

impl AccountStorage {
    /// The caller must choose a fixed TranslateX root, never a requested CODEX_HOME.
    /// This validates ownership and permissions but does not select that root.
    pub fn lock(owned_canonical_root: &Path) -> Result<Self> {
        if !owned_canonical_root.is_absolute()
            || owned_canonical_root.canonicalize()? != owned_canonical_root
        {
            return Err(StorageError::UnsafeStorage);
        }
        let path = c_path(owned_canonical_root)?;
        let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY
            | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
        let root = owned_fd(fd)?;
        check_directory(&root)?;
        let lease = open_at(&root, LOCK, libc::O_RDWR | libc::O_CREAT | libc::O_NONBLOCK, 0o600)?;
        check_regular(&lease)?;
        if unsafe { libc::flock(lease.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = io::Error::last_os_error();
            return Err(if error.kind() == io::ErrorKind::WouldBlock {
                StorageError::Busy
            } else { error.into() });
        }
        mkdir_at(&root, "identities")?;
        let identities = open_at(&root, "identities", libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
        check_directory(&identities)?;
        root.sync_all()?;
        let value = Self { root_path: owned_canonical_root.to_path_buf(), root, identities, lease };
        value.check_bindings()?;
        Ok(value)
    }

    /// Duplicates the same open file description, not a second flock.
    /// The returned descriptor is CLOEXEC. The caller must clear that flag only
    /// in the exact child's pre-exec hook and keep the inherited File alive in
    /// the worker. Drop the parent's duplicate after spawn. Never LOCK_UN it.
    pub fn worker_lease(&self) -> Result<File> {
        self.check_bindings()?;
        let fd = unsafe { libc::fcntl(self.lease.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 3) };
        Ok(owned_fd(fd)?)
    }

    /// Adopts the parent's inherited open file description. This never opens a
    /// second lock description or unlocks the inherited lease. The private worker entry
    /// point validates its command against the records before touching auth.
    pub(crate) fn from_worker_lease(owned_canonical_root: &Path, lease: File) -> Result<Self> {
        if !owned_canonical_root.is_absolute()
            || owned_canonical_root.canonicalize()? != owned_canonical_root
        { return Err(StorageError::UnsafeStorage); }
        check_regular(&lease)?;
        // Reaffirm the lock on this SAME open file description. A genuine dup
        // succeeds without releasing it; a separately opened descriptor cannot
        // enter while the parent (or another operation) owns the identity.
        if unsafe { libc::flock(lease.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = io::Error::last_os_error();
            return Err(if error.kind() == io::ErrorKind::WouldBlock { StorageError::Busy } else { error.into() });
        }
        let path = c_path(owned_canonical_root)?;
        let root = owned_fd(unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY
            | libc::O_NOFOLLOW | libc::O_CLOEXEC) })?;
        let identities = open_at(&root, "identities", libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
        let value = Self { root_path: owned_canonical_root.to_path_buf(), root, identities, lease };
        value.check_bindings()?;
        Ok(value)
    }

    /// Call after resolving `recovery_action`, while retaining this storage.
    pub fn active(&self) -> Result<Option<Identity>> {
        self.check_bindings()?;
        self.active_generation()?.map(|generation| self.identity(&generation, false)).transpose()
    }

    /// First version requires explicit logout before another login. This avoids
    /// abandoning an old generation's Keychain item on account replacement.
    pub fn begin_login(&mut self, operation_id: &str) -> Result<Identity> {
        canonical_uuid(operation_id)?;
        self.check_bindings()?;
        self.require_no_pending()?;
        if self.active_generation()?.is_some() { return Err(StorageError::AlreadySignedIn); }
        let generation = Uuid::new_v4().to_string();
        let record = PendingRecord { schema: SCHEMA, kind: OperationKind::Login,
            operation_id: operation_id.to_owned(), generation: generation.clone() };
        // Persist the obligation before a directory or worker can create auth.
        self.write_record(PENDING, &record)?;
        self.identity(&generation, true)
    }

    /// Atomically switches the pointer after the caller has validated the new
    /// account. Success is durable even if IPC delivery subsequently fails.
    /// If this returns an I/O error, reload recovery state: rename may already
    /// have happened before a directory fsync failed.
    pub fn commit_login(&mut self, operation_id: &str, generation: &str) -> Result<Identity> {
        self.check_bindings()?;
        self.match_pending(operation_id, generation, OperationKind::Login)?;
        let identity = self.identity(generation, false)?;
        match self.active_generation()? {
            Some(active) if active == generation => return Ok(identity),
            Some(_) => return Err(StorageError::AlreadySignedIn),
            None => {},
        }
        self.write_record(ACTIVE, &ActiveRecord { schema: SCHEMA, generation: generation.to_owned() })?;
        Ok(identity)
    }

    pub fn finalize_committed(&mut self, operation_id: &str, generation: &str) -> Result<()> {
        self.check_bindings()?;
        self.match_pending(operation_id, generation, OperationKind::Login)?;
        if self.active_generation()?.as_deref() != Some(generation) {
            return Err(StorageError::InvalidState);
        }
        self.identity(generation, false)?;
        self.remove_record(PENDING)
    }

    /// None is already locally signed out. For Some, first persist the intent,
    /// then let the caller attempt official revoke and confirm local deletion.
    pub fn begin_logout(&mut self, operation_id: &str) -> Result<Option<Identity>> {
        canonical_uuid(operation_id)?;
        self.check_bindings()?;
        self.require_no_pending()?;
        let Some(generation) = self.active_generation()? else { return Ok(None) };
        let identity = self.identity(&generation, false)?;
        self.write_record(PENDING, &PendingRecord { schema: SCHEMA, kind: OperationKind::Logout,
            operation_id: operation_id.to_owned(), generation })?;
        Ok(Some(identity))
    }

    pub fn recovery_action(&self) -> Result<RecoveryAction> {
        self.check_bindings()?;
        let Some(pending) = self.pending()? else { return Ok(RecoveryAction::None) };
        let active = self.active_generation()?;
        if pending.kind == OperationKind::Login && active.as_deref() == Some(&pending.generation) {
            return Ok(RecoveryAction::Committed { operation_id: pending.operation_id,
                identity: self.identity(&pending.generation, false)? });
        }
        // A crash can happen after the journal rename and before mkdir, or
        // after cleanup removed a directory. Recreate only its derived empty
        // home so the official store uses the same canonical Keychain key.
        let identity = self.identity(&pending.generation, true)?;
        Ok(RecoveryAction::Cleanup { operation_id: pending.operation_id, kind: pending.kind, identity })
    }

    /// Acknowledge only after the caller confirmed this exact Keychain identity
    /// is absent and any worker using it has exited. This function does not and
    /// cannot verify that precondition itself. It never recursively deletes a
    /// home or deletes an active pointer belonging to another generation.
    pub fn complete_cleanup(&mut self, operation_id: &str, generation: &str) -> Result<()> {
        self.check_bindings()?;
        let pending = self.pending()?.ok_or(StorageError::InvalidOperation)?;
        self.match_pending(operation_id, generation, pending.kind)?;
        // Validate the derived home before changing the active pointer. A
        // missing home is a valid interrupted-cleanup state; a redirected or
        // permissive one is not.
        match self.identity(generation, false) {
            Ok(_) => {},
            Err(StorageError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {},
            Err(error) => return Err(error),
        }
        let active = self.active_generation()?;
        if active.as_deref() == Some(generation) {
            if pending.kind == OperationKind::Login { return Err(StorageError::AlreadyCommitted); }
            self.remove_record(ACTIVE)?;
        }
        self.remove_identity(generation)?;
        self.remove_record(PENDING)
    }

    fn require_no_pending(&self) -> Result<()> {
        if self.pending()?.is_some() { Err(StorageError::PendingOperation) } else { Ok(()) }
    }

    fn active_generation(&self) -> Result<Option<String>> {
        let Some(value) = self.read_record::<ActiveRecord>(ACTIVE)? else { return Ok(None) };
        if value.schema != SCHEMA { return Err(StorageError::InvalidState); }
        canonical_uuid(&value.generation).map_err(|_| StorageError::InvalidState)?;
        Ok(Some(value.generation))
    }

    fn pending(&self) -> Result<Option<PendingRecord>> {
        let Some(value) = self.read_record::<PendingRecord>(PENDING)? else { return Ok(None) };
        if value.schema != SCHEMA { return Err(StorageError::InvalidState); }
        canonical_uuid(&value.operation_id).map_err(|_| StorageError::InvalidState)?;
        canonical_uuid(&value.generation).map_err(|_| StorageError::InvalidState)?;
        Ok(Some(value))
    }

    fn match_pending(&self, operation_id: &str, generation: &str, kind: OperationKind) -> Result<()> {
        canonical_uuid(operation_id)?;
        canonical_uuid(generation)?;
        let pending = self.pending()?.ok_or(StorageError::InvalidOperation)?;
        if pending.operation_id != operation_id || pending.generation != generation || pending.kind != kind {
            return Err(StorageError::InvalidOperation);
        }
        Ok(())
    }

    fn identity(&self, generation: &str, create: bool) -> Result<Identity> {
        canonical_uuid(generation)?;
        if create {
            mkdir_at(&self.identities, generation)?;
            self.identities.sync_all()?;
        }
        let directory = open_at(&self.identities, generation, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
        check_directory(&directory)?;
        let home = self.root_path.join("identities").join(generation);
        if home.canonicalize()? != home { return Err(StorageError::UnsafeStorage); }
        let path_metadata = std::fs::symlink_metadata(&home)?;
        if !same_file(&directory.metadata()?, &path_metadata) { return Err(StorageError::UnsafeStorage); }
        Ok(Identity { generation: generation.to_owned(), home })
    }

    fn remove_identity(&self, generation: &str) -> Result<()> {
        canonical_uuid(generation)?;
        match self.identity(generation, false) {
            Ok(_) => {},
            Err(StorageError::Io(error)) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        }
        let name = CString::new(generation).map_err(|_| StorageError::InvalidOperation)?;
        if unsafe { libc::unlinkat(self.identities.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        self.identities.sync_all()?;
        Ok(())
    }

    fn check_bindings(&self) -> Result<()> {
        check_directory(&self.root)?;
        check_directory(&self.identities)?;
        if self.root_path.canonicalize()? != self.root_path { return Err(StorageError::UnsafeStorage); }
        let root = std::fs::symlink_metadata(&self.root_path)?;
        let identities = std::fs::symlink_metadata(self.root_path.join("identities"))?;
        if !same_file(&root, &self.root.metadata()?) || !same_file(&identities, &self.identities.metadata()?) {
            return Err(StorageError::UnsafeStorage);
        }
        let lock = open_at(&self.root, LOCK, libc::O_RDONLY | libc::O_NONBLOCK, 0)?;
        check_regular(&lock)?;
        if !same_file(&lock.metadata()?, &self.lease.metadata()?) { return Err(StorageError::UnsafeStorage); }
        Ok(())
    }

    fn read_record<T: for<'de> Deserialize<'de>>(&self, name: &str) -> Result<Option<T>> {
        let Some(file) = self.optional_record(name)? else { return Ok(None) };
        let mut bytes = Vec::new();
        file.take(RECORD_LIMIT + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > RECORD_LIMIT { return Err(StorageError::InvalidState); }
        serde_json::from_slice(&bytes).map(Some).map_err(|_| StorageError::InvalidState)
    }

    fn optional_record(&self, name: &str) -> Result<Option<File>> {
        match open_at(&self.root, name, libc::O_RDONLY | libc::O_NONBLOCK, 0) {
            Ok(file) => {
                check_regular(&file)?;
                if file.metadata()?.len() > RECORD_LIMIT { return Err(StorageError::InvalidState); }
                Ok(Some(file))
            },
            Err(StorageError::Io(error)) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn write_record(&self, name: &str, value: &impl Serialize) -> Result<()> {
        // Reject symlinks, hardlinks, and foreign/permissive existing records.
        self.optional_record(name)?;
        let bytes = serde_json::to_vec(value).map_err(|_| StorageError::InvalidState)?;
        if bytes.len() as u64 > RECORD_LIMIT { return Err(StorageError::InvalidState); }
        let temporary = format!(".account-tmp-{}", Uuid::new_v4());
        let mut file = open_at(&self.root, &temporary,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL, 0o600)?;
        let result = (|| {
            check_regular(&file)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            let from = CString::new(temporary.as_str()).map_err(|_| StorageError::InvalidState)?;
            let to = CString::new(name).map_err(|_| StorageError::InvalidState)?;
            if unsafe { libc::renameat(self.root.as_raw_fd(), from.as_ptr(), self.root.as_raw_fd(), to.as_ptr()) } != 0 {
                return Err(io::Error::last_os_error().into());
            }
            self.root.sync_all()?;
            Ok(())
        })();
        if result.is_err() { let _ = unlink_file(&self.root, &temporary); }
        result
    }

    fn remove_record(&self, name: &str) -> Result<()> {
        if self.optional_record(name)?.is_some() { unlink_file(&self.root, name)?; }
        self.root.sync_all()?;
        Ok(())
    }
}

fn canonical_uuid(value: &str) -> Result<()> {
    match Uuid::parse_str(value) {
        Ok(uuid) if !uuid.is_nil() && uuid.to_string() == value => Ok(()),
        _ => Err(StorageError::InvalidOperation),
    }
}

fn c_path(path: &Path) -> Result<CString> {
    CString::new(path.as_os_str().as_bytes()).map_err(|_| StorageError::UnsafeStorage)
}

fn owned_fd(fd: RawFd) -> io::Result<File> {
    if fd < 0 { Err(io::Error::last_os_error()) }
    else { Ok(unsafe { File::from_raw_fd(fd) }) }
}

fn open_at(directory: &File, name: &str, flags: i32, mode: libc::mode_t) -> Result<File> {
    if name.is_empty() || name.contains('/') || name == "." || name == ".." {
        return Err(StorageError::UnsafeStorage);
    }
    let name = CString::new(name).map_err(|_| StorageError::UnsafeStorage)?;
    let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(),
        flags | libc::O_NOFOLLOW | libc::O_CLOEXEC, mode as libc::c_uint) };
    Ok(owned_fd(fd)?)
}

fn mkdir_at(directory: &File, name: &str) -> Result<()> {
    let name = CString::new(name).map_err(|_| StorageError::UnsafeStorage)?;
    if unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::AlreadyExists { return Err(error.into()); }
    }
    Ok(())
}

fn unlink_file(directory: &File, name: &str) -> io::Result<()> {
    let name = CString::new(name).map_err(io::Error::other)?;
    if unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn check_directory(file: &File) -> Result<()> {
    let metadata = file.metadata()?;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o7777 != 0o700
    { return Err(StorageError::UnsafeStorage); }
    Ok(())
}

fn check_regular(file: &File) -> Result<()> {
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o7777 != 0o600 || metadata.nlink() != 1
    { return Err(StorageError::UnsafeStorage); }
    Ok(())
}

fn same_file(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    left.dev() == right.dev() && left.ino() == right.ino()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, OpenOptions, Permissions};
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt, symlink};
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().canonicalize().unwrap()
                .join(format!("translatex-account-storage-test-{}", Uuid::new_v4()));
            fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
            Self(root)
        }
        fn open(&self) -> AccountStorage { AccountStorage::lock(&self.0).unwrap() }
    }
    impl Drop for Fixture {
        fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
    }
    fn operation() -> String { Uuid::new_v4().to_string() }
    fn committed(fixture: &Fixture) -> Identity {
        let mut storage = fixture.open();
        let op = operation();
        let identity = storage.begin_login(&op).unwrap();
        storage.commit_login(&op, &identity.generation).unwrap();
        storage.finalize_committed(&op, &identity.generation).unwrap();
        identity
    }

    #[test]
    fn worker_adoption_requires_same_lease_when_parent_is_alive() {
        let fixture = Fixture::new();
        let parent = fixture.open();
        let unrelated = OpenOptions::new().read(true).write(true).open(fixture.0.join(LOCK)).unwrap();
        assert!(matches!(AccountStorage::from_worker_lease(&fixture.0, unrelated), Err(StorageError::Busy)));
        let worker = AccountStorage::from_worker_lease(&fixture.0, parent.worker_lease().unwrap()).unwrap();
        drop(parent);
        assert!(matches!(AccountStorage::lock(&fixture.0), Err(StorageError::Busy)));
        drop(worker);
        assert!(AccountStorage::lock(&fixture.0).is_ok());
    }

    #[test]
    fn uncommitted_login_recovers_only_its_candidate() {
        let fixture = Fixture::new();
        let op = operation();
        let identity = fixture.open().begin_login(&op).unwrap();
        let mut recovered = fixture.open();
        assert_eq!(recovered.active().unwrap(), None);
        assert_eq!(recovered.recovery_action().unwrap(), RecoveryAction::Cleanup {
            operation_id: op.clone(), kind: OperationKind::Login, identity: identity.clone() });
        recovered.complete_cleanup(&op, &identity.generation).unwrap();
        assert_eq!(recovered.recovery_action().unwrap(), RecoveryAction::None);
        assert!(!identity.home.exists());
    }

    #[test]
    fn journal_before_mkdir_is_recoverable() {
        let fixture = Fixture::new();
        let op = operation();
        let generation = operation();
        let storage = fixture.open();
        storage.write_record(PENDING, &PendingRecord { schema: 1, kind: OperationKind::Login,
            operation_id: op.clone(), generation: generation.clone() }).unwrap();
        drop(storage);
        let mut recovered = fixture.open();
        assert!(matches!(recovered.recovery_action().unwrap(), RecoveryAction::Cleanup { .. }));
        recovered.complete_cleanup(&op, &generation).unwrap();
    }

    #[test]
    fn durable_active_survives_lost_reply_and_rejects_cancel_cleanup() {
        let fixture = Fixture::new();
        let op = operation();
        let mut storage = fixture.open();
        let identity = storage.begin_login(&op).unwrap();
        storage.commit_login(&op, &identity.generation).unwrap();
        drop(storage);
        let mut recovered = fixture.open();
        assert_eq!(recovered.recovery_action().unwrap(), RecoveryAction::Committed {
            operation_id: op.clone(), identity: identity.clone() });
        assert!(matches!(recovered.complete_cleanup(&op, &identity.generation), Err(StorageError::AlreadyCommitted)));
        recovered.finalize_committed(&op, &identity.generation).unwrap();
        assert_eq!(recovered.active().unwrap(), Some(identity));
        assert_eq!(recovered.recovery_action().unwrap(), RecoveryAction::None);
    }

    #[test]
    fn login_requires_explicit_logout_before_replacement() {
        let fixture = Fixture::new();
        let identity = committed(&fixture);
        let mut storage = fixture.open();
        assert!(matches!(storage.begin_login(&operation()), Err(StorageError::AlreadySignedIn)));
        assert_eq!(storage.active().unwrap(), Some(identity));
    }

    #[test]
    fn logout_after_pointer_removal_recovers_idempotently() {
        let fixture = Fixture::new();
        let identity = committed(&fixture);
        let op = operation();
        let mut storage = fixture.open();
        assert_eq!(storage.begin_logout(&op).unwrap(), Some(identity.clone()));
        storage.remove_record(ACTIVE).unwrap();
        storage.remove_identity(&identity.generation).unwrap();
        drop(storage);
        let mut recovered = fixture.open();
        assert_eq!(recovered.recovery_action().unwrap(), RecoveryAction::Cleanup {
            operation_id: op.clone(), kind: OperationKind::Logout, identity: identity.clone() });
        recovered.complete_cleanup(&op, &identity.generation).unwrap();
        assert!(recovered.active().unwrap().is_none());
        assert!(recovered.begin_logout(&operation()).unwrap().is_none());
    }

    #[test]
    fn stale_logout_cannot_remove_a_new_active_generation() {
        let fixture = Fixture::new();
        let old = committed(&fixture);
        let mut storage = fixture.open();
        let op = operation();
        storage.begin_logout(&op).unwrap();
        // Inject a changed durable pointer to test recovery's ownership check;
        // normal methods refuse this replacement while a journal exists.
        let new = storage.identity(&operation(), true).unwrap();
        storage.write_record(ACTIVE, &ActiveRecord { schema: 1, generation: new.generation.clone() }).unwrap();
        storage.complete_cleanup(&op, &old.generation).unwrap();
        assert_eq!(storage.active().unwrap(), Some(new));
        assert!(!old.home.exists());
    }

    #[test]
    fn wrong_operation_or_noncanonical_uuid_cannot_mutate_transaction() {
        let fixture = Fixture::new();
        let mut storage = fixture.open();
        assert!(matches!(storage.begin_login("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"), Err(StorageError::InvalidOperation)));
        let op = operation();
        let identity = storage.begin_login(&op).unwrap();
        assert!(matches!(storage.commit_login(&operation(), &identity.generation), Err(StorageError::InvalidOperation)));
        assert!(matches!(storage.begin_logout(&operation()), Err(StorageError::PendingOperation)));
        assert!(storage.active().unwrap().is_none());
    }

    #[test]
    fn malformed_or_secret_bearing_journal_fails_closed() {
        let fixture = Fixture::new();
        let storage = fixture.open();
        let mut file = open_at(&storage.root, PENDING, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL, 0o600).unwrap();
        file.write_all(br#"{"schema":1,"kind":"login","operation_id":"bad","generation":"bad","token":"fixture-only"}"#).unwrap();
        assert!(matches!(storage.recovery_action(), Err(StorageError::InvalidState)));
    }

    #[test]
    fn unexpected_identity_contents_preserve_cleanup_obligation() {
        let fixture = Fixture::new();
        let mut storage = fixture.open();
        let op = operation();
        let identity = storage.begin_login(&op).unwrap();
        fs::write(identity.home.join("unexpected"), "constructed").unwrap();
        assert!(storage.complete_cleanup(&op, &identity.generation).is_err());
        assert!(matches!(storage.recovery_action().unwrap(), RecoveryAction::Cleanup { .. }));
    }

    #[test]
    fn symlinks_hardlinks_and_permissive_metadata_are_rejected() {
        let fixture = Fixture::new();
        let other = Fixture::new();
        let storage = fixture.open();
        symlink(&other.0, fixture.0.join(ACTIVE)).unwrap();
        assert!(storage.active().is_err());
        fs::remove_file(fixture.0.join(ACTIVE)).unwrap();
        let other_file = other.0.join("record");
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(&other_file).unwrap();
        fs::hard_link(&other_file, fixture.0.join(PENDING)).unwrap();
        assert!(matches!(storage.recovery_action(), Err(StorageError::UnsafeStorage)));
        fs::remove_file(fixture.0.join(PENDING)).unwrap();
        fs::set_permissions(fixture.0.join("identities"), Permissions::from_mode(0o755)).unwrap();
        assert!(matches!(storage.active(), Err(StorageError::UnsafeStorage)));
    }

    #[test]
    fn identity_symlink_cannot_redirect_cleanup() {
        let fixture = Fixture::new();
        let other = Fixture::new();
        let mut storage = fixture.open();
        let op = operation();
        let identity = storage.begin_login(&op).unwrap();
        fs::remove_dir(&identity.home).unwrap();
        symlink(&other.0, &identity.home).unwrap();
        assert!(storage.recovery_action().is_err());
        assert!(storage.complete_cleanup(&op, &identity.generation).is_err());
        assert!(other.0.exists());
    }

    #[test]
    fn partial_atomic_temporary_file_is_never_an_active_pointer() {
        let fixture = Fixture::new();
        let mut storage = fixture.open();
        let op = operation();
        let candidate = storage.begin_login(&op).unwrap();
        let mut file = open_at(&storage.root, &format!(".account-tmp-{}", Uuid::new_v4()),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL, 0o600).unwrap();
        file.write_all(b"{\"schema\":1,").unwrap();
        file.sync_all().unwrap();
        drop(storage);
        let recovered = fixture.open();
        assert!(recovered.active().unwrap().is_none());
        assert_eq!(recovered.recovery_action().unwrap(), RecoveryAction::Cleanup {
            operation_id: op, kind: OperationKind::Login, identity: candidate });
    }

    #[test]
    fn root_and_lock_replacement_are_rejected() {
        let fixture = Fixture::new();
        let storage = fixture.open();
        assert!(matches!(AccountStorage::lock(&fixture.0), Err(StorageError::Busy)));
        fs::rename(fixture.0.join(LOCK), fixture.0.join("old-lock")).unwrap();
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(fixture.0.join(LOCK)).unwrap();
        assert!(matches!(storage.active(), Err(StorageError::UnsafeStorage)));
        let alias = fixture.0.with_extension("alias");
        symlink(&fixture.0, &alias).unwrap();
        assert!(matches!(AccountStorage::lock(&alias), Err(StorageError::UnsafeStorage)));
        fs::remove_file(alias).unwrap();
    }

    #[test]
    fn worker_lease_process() {
        let Ok(value) = std::env::var("TRANSLATEX_STORAGE_TEST_LEASE_FD") else { return };
        let fd: RawFd = value.parse().unwrap();
        let lease = unsafe { File::from_raw_fd(fd) };
        check_regular(&lease).unwrap();
        // One byte from the owning test releases this bounded fixture process.
        // An alarm ensures a failed parent cannot leave it indefinitely alive.
        unsafe { libc::alarm(5); }
        let mut byte = [0_u8; 1];
        std::io::stdin().read_exact(&mut byte).unwrap();
        drop(lease);
    }

    #[test]
    fn inherited_lease_outlives_supervisor_handle_and_releases_on_worker_exit() {
        let fixture = Fixture::new();
        let storage = fixture.open();
        let lease = storage.worker_lease().unwrap();
        let fd = lease.as_raw_fd();
        assert_ne!(unsafe { libc::fcntl(fd, libc::F_GETFD) } & libc::FD_CLOEXEC, 0);
        let mut command = Command::new(std::env::current_exe().unwrap());
        command.args(["--exact", "account_storage::tests::worker_lease_process", "--nocapture"])
            .env_clear().env("TRANSLATEX_STORAGE_TEST_LEASE_FD", fd.to_string())
            .stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null());
        unsafe {
            command.pre_exec(move || {
                let flags = libc::fcntl(fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child = command.spawn().unwrap();
        drop(lease);
        drop(storage);
        let blocked = matches!(AccountStorage::lock(&fixture.0), Err(StorageError::Busy));
        child.stdin.take().unwrap().write_all(b"x").unwrap();
        let exited = child.wait().unwrap().success();
        assert!(blocked, "worker must retain the same open-file-description lock");
        assert!(exited);
        assert!(AccountStorage::lock(&fixture.0).is_ok());
    }
}
