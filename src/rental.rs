//! Credential-bound rental policy. The RustDesk challenge/password protocol is
//! unchanged; this module only decides whether a verified credential may grant a
//! new connection. Existing active sessions are never timed out by this policy.
use hbb_common::{
    anyhow::{anyhow, bail},
    config::{self, Config, Config2},
    sodiumoxide, ResultType,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

pub const OUTSIDE_VALIDITY: &str = "RD_RENTAL_OUT_OF_VALIDITY";
pub const DEADLINE_FIELD: &str = "rental_valid_until_ms";
// Matches the supported UI date range; no client-side time comparison is made.
pub const MAX_TIMESTAMP_MS: u64 = 253_402_300_799_999;
const MAX_INPUT: u64 = 16 * 1024;
#[cfg(any(target_os = "linux", target_os = "macos"))]
const AUTHORITY_MARKER: &[u8] = b"rustdesk-rental-host-v1\n";
#[cfg(any(target_os = "linux", target_os = "macos"))]
const FENCED_TRANSACTION: &[u8] = b"fenced\n";
static POLICY_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProvisionRequest {
    password: String,
    valid_from_ms: u64,
    valid_until_ms: u64,
}
impl std::fmt::Debug for ProvisionRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RentalProvisionRequest([REDACTED])")
    }
}
impl Drop for ProvisionRequest {
    fn drop(&mut self) {
        // Replacing all bytes with zero preserves UTF-8. No reference escapes.
        unsafe { sodiumoxide::utils::memzero(self.password.as_bytes_mut()) };
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    version: u32,
    credential_binding: String,
    valid_from_ms: u64,
    valid_until_ms: u64,
}
impl std::fmt::Debug for Policy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RentalPolicySnapshot([REDACTED])")
    }
}
impl ProvisionRequest {
    pub fn window(&self) -> (u64, u64) {
        (self.valid_from_ms, self.valid_until_ms)
    }

    #[cfg(any(target_os = "macos", test))]
    pub(crate) fn generated(policy: Option<&Policy>, now: u64, expiry: u64) -> ResultType<Self> {
        let from = policy.map_or(now, |policy| policy.valid_from_ms);
        validate_new_expiry(from, now, expiry)?;
        sodiumoxide::init().map_err(|_| anyhow!("Secure random generator unavailable"))?;
        let mut bytes = [0; 24];
        sodiumoxide::randombytes::randombytes_into(&mut bytes);
        let password =
            sodiumoxide::base64::encode(&bytes, sodiumoxide::base64::Variant::UrlSafeNoPadding);
        sodiumoxide::utils::memzero(&mut bytes);
        Ok(Self {
            password,
            valid_from_ms: from,
            valid_until_ms: expiry,
        })
    }

    #[cfg(target_os = "macos")]
    pub(crate) fn into_password(mut self) -> String {
        std::mem::take(&mut self.password)
    }
}

impl Policy {
    #[cfg(target_os = "macos")]
    pub(crate) fn window(&self) -> (u64, u64) {
        (self.valid_from_ms, self.valid_until_ms)
    }

    fn valid(&self) -> bool {
        self.version == 1
            && valid_window(self.valid_from_ms, self.valid_until_ms)
            && self.credential_binding.len() == 64
            && self
                .credential_binding
                .bytes()
                .all(|b| b.is_ascii_hexdigit())
    }

    #[cfg(any(target_os = "macos", test))]
    pub(crate) fn set_expiry(&mut self, now: u64, expiry: u64) -> ResultType<AdminStatus> {
        if !self.valid() {
            bail!("Rental policy invalid");
        }
        validate_new_expiry(self.valid_from_ms, now, expiry)?;
        self.valid_until_ms = expiry;
        AdminStatus::from_policy(Some(self), now)
    }
}

#[cfg(any(target_os = "macos", test))]
fn validate_new_expiry(from: u64, now: u64, expiry: u64) -> ResultType<()> {
    if expiry <= now || !valid_window(from, expiry) {
        bail!("Expiration must be after the host time and the rental start");
    }
    Ok(())
}

#[cfg(any(target_os = "macos", test))]
pub(crate) enum AdminCommand {
    Status,
    SetExpiry(u64),
    NewPassword(u64),
}

#[cfg(any(target_os = "macos", test))]
impl AdminCommand {
    pub(crate) fn parse(uid: Option<u32>, args: &[String]) -> ResultType<Self> {
        if !administrator_peer(uid) {
            bail!("Rental host administration requires administrator privileges");
        }
        match args {
            [name] if name == "--rental-admin-status" => Ok(Self::Status),
            [name, value]
                if name == "--rental-admin-set-expiry" || name == "--rental-admin-new-password" =>
            {
                let expiry = value
                    .parse::<u64>()
                    .ok()
                    .filter(|expiry| {
                        *expiry > 0
                            && *expiry <= MAX_TIMESTAMP_MS
                            && value.bytes().all(|b| b.is_ascii_digit())
                    })
                    .ok_or_else(|| anyhow!("Invalid expiration in UTC milliseconds"))?;
                if name == "--rental-admin-set-expiry" {
                    Ok(Self::SetExpiry(expiry))
                } else {
                    Ok(Self::NewPassword(expiry))
                }
            }
            _ => bail!("Invalid rental host administration arguments"),
        }
    }
}

#[cfg(any(target_os = "macos", test))]
#[derive(Serialize)]
pub(crate) struct AdminStatus {
    state: &'static str,
    now_ms: u64,
    valid_from_ms: Option<u64>,
    valid_until_ms: Option<u64>,
}

#[cfg(any(target_os = "macos", test))]
impl AdminStatus {
    pub(crate) fn verified(
        policy: Option<&Policy>,
        now_ms: u64,
        recovery_required: bool,
    ) -> ResultType<Self> {
        let mut status = Self::from_policy(policy, now_ms)?;
        if recovery_required {
            status.state = "recovery_required";
        }
        Ok(status)
    }

    pub(crate) fn from_policy(policy: Option<&Policy>, now_ms: u64) -> ResultType<Self> {
        if now_ms > MAX_TIMESTAMP_MS {
            bail!("Host clock outside the supported range");
        }
        let state = match policy {
            None => "unconfigured",
            Some(p) if !p.valid() => bail!("Rental policy invalid"),
            Some(p) if now_ms < p.valid_from_ms => "pending",
            Some(p) if now_ms >= p.valid_until_ms => "expired",
            Some(_) => "active",
        };
        Ok(Self {
            state,
            now_ms,
            valid_from_ms: policy.map(|p| p.valid_from_ms),
            valid_until_ms: policy.map(|p| p.valid_until_ms),
        })
    }
}

#[cfg(any(target_os = "macos", test))]
#[derive(Serialize)]
pub(crate) struct AdminReply {
    #[serde(flatten)]
    pub(crate) status: AdminStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) password: Option<String>,
}

#[cfg(any(target_os = "macos", test))]
impl Drop for AdminReply {
    fn drop(&mut self) {
        if let Some(password) = &mut self.password {
            unsafe { sodiumoxide::utils::memzero(password.as_bytes_mut()) };
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Grant {
    pub valid_until_ms: u64,
}

fn policy_path() -> PathBuf {
    Config::file().with_extension("rental.json")
}
fn marker_path() -> PathBuf {
    Config::file().with_extension("rental-host")
}
#[cfg(target_os = "macos")]
fn authority_directory() -> PathBuf {
    PathBuf::from("/Library/Application Support/RustDeskRental")
}
#[cfg(not(target_os = "macos"))]
fn authority_directory() -> PathBuf {
    PathBuf::from("/var/lib/rustdesk-rental")
}
fn authority_policy(uid: u32) -> PathBuf {
    authority_directory().join(format!("{uid}.json"))
}
fn authority_marker(uid: u32) -> PathBuf {
    authority_directory().join(format!("{uid}.enabled"))
}
#[cfg(any(target_os = "linux", target_os = "macos"))]
fn authority_pending(uid: u32) -> PathBuf {
    authority_directory().join(format!("{uid}.pending"))
}
fn serving_uid() -> u32 {
    #[cfg(unix)]
    {
        return unsafe { hbb_common::libc::geteuid() };
    }
    #[cfg(not(unix))]
    {
        0
    }
}

fn exists_or_inaccessible(path: &Path) -> bool {
    !matches!(fs::symlink_metadata(path), Err(e) if e.kind() == std::io::ErrorKind::NotFound)
}
/// The persistent marker survives config sync/option edits and a missing or
/// malformed policy. Only an administrator removing it offline can disable it.
pub fn is_host() -> bool {
    let managed = Config::get_option("rental-host") == "Y"
        || exists_or_inaccessible(&marker_path())
        || exists_or_inaccessible(&policy_path())
        || exists_or_inaccessible(&authority_marker(serving_uid()))
        || exists_or_inaccessible(&authority_policy(serving_uid()));
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    let managed = managed || exists_or_inaccessible(&authority_pending(serving_uid()));
    managed
}
fn valid_window(from: u64, until: u64) -> bool {
    from < until && until <= MAX_TIMESTAMP_MS
}
fn binding(storage: &str, salt: &str) -> ResultType<String> {
    available_binding(storage, salt)?.ok_or_else(|| anyhow!("Rental credential missing"))
}

fn available_binding(storage: &str, salt: &str) -> ResultType<Option<String>> {
    if storage.is_empty() {
        return Ok(None);
    }
    let mut h1 = config::decode_permanent_password_h1_from_storage(storage)
        .ok_or_else(|| anyhow!("Rental credential storage invalid"))?;
    if salt.is_empty() {
        sodiumoxide::utils::memzero(&mut h1);
        return Ok(None);
    }
    // This is a local binding, never a new password algorithm or wire proof.
    let mut hash = Sha256::new();
    hash.update(b"rustdesk-rental-binding-v1\0");
    hash.update((salt.len() as u64).to_be_bytes());
    hash.update(salt.as_bytes());
    hash.update(h1);
    sodiumoxide::utils::memzero(&mut h1);
    Ok(Some(hex::encode(hash.finalize())))
}
pub(crate) fn now_ms() -> ResultType<u64> {
    let value = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| anyhow!("Server clock unavailable"))?
        .as_millis();
    u64::try_from(value).map_err(|_| anyhow!("Server clock unavailable"))
}

#[cfg(test)]
fn check_at(path: &Path, storage: &str, salt: &str, now: u64) -> ResultType<Grant> {
    check_bytes(&read_private(path)?, storage, salt, now)
}
#[cfg(test)]
fn check_bytes(bytes: &[u8], storage: &str, salt: &str, now: u64) -> ResultType<Grant> {
    check_binding(bytes, &binding(storage, salt)?, now)
}

fn check_binding(bytes: &[u8], credential_binding: &str, now: u64) -> ResultType<Grant> {
    let policy: Policy =
        serde_json::from_slice(bytes).map_err(|_| anyhow!("Rental policy invalid"))?;
    if !policy.valid()
        || !sodiumoxide::utils::memcmp(
            policy.credential_binding.as_bytes(),
            credential_binding.as_bytes(),
        )
        || now > MAX_TIMESTAMP_MS
        || now < policy.valid_from_ms
        || now >= policy.valid_until_ms
    {
        bail!("Rental policy denies authorization");
    }
    Ok(Grant {
        valid_until_ms: policy.valid_until_ms,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthError {
    Password,
    Validity,
}

/// Every grant route supplies the SAME current permanent credential verifier,
/// including click/recent/trusted/switch/auxiliary connections. Neither a client
/// ID nor a cached approval is sufficient in rental mode.
pub fn authorize(verify: impl FnOnce(&str) -> bool) -> Result<Option<Grant>, AuthError> {
    if !is_host() {
        return Ok(None);
    }
    let (storage, salt) = Config::get_local_permanent_password_storage_and_salt();
    let matches = config::local_permanent_password_storage_is_usable_for_auth(&storage, &salt)
        && verify(&storage);
    if !matches {
        return Err(AuthError::Password);
    }
    // A poisoned/unavailable policy lock must not outrank a wrong password.
    let _lock = POLICY_LOCK.lock().map_err(|_| AuthError::Validity)?;
    let (current, current_salt) = Config::get_local_permanent_password_storage_and_salt();
    if current != storage || current_salt != salt {
        return Err(AuthError::Password);
    }
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    if exists_or_inaccessible(&authority_pending(serving_uid())) {
        return Err(AuthError::Validity);
    }
    let now = now_ms().map_err(|_| AuthError::Validity)?;
    // User-writable staging/config files are never the authorization source.
    let bytes =
        read_owned(&authority_policy(serving_uid()), 0, 0o022).map_err(|_| AuthError::Validity)?;
    let credential_binding = binding(&storage, &salt).map_err(|_| AuthError::Validity)?;
    let grant = check_binding(&bytes, &credential_binding, now).map_err(|_| AuthError::Validity)?;
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    if persisted_binding().map_err(|_| AuthError::Validity)? != credential_binding {
        return Err(AuthError::Validity);
    }
    Ok(Some(grant))
}
#[cfg(test)]
fn authorize_at(
    path: &Path,
    storage: &str,
    salt: &str,
    password_matches: bool,
    now: ResultType<u64>,
) -> Result<Grant, AuthError> {
    // No policy parse, expiry disclosure or local-clock error takes priority
    // over an incorrect password, even if provisioning is missing/corrupted.
    if !password_matches {
        return Err(AuthError::Password);
    }
    let now = now.map_err(|_| AuthError::Validity)?;
    check_at(path, storage, salt, now).map_err(|_| AuthError::Validity)
}

fn owned_parent(path: &Path, owner: u32) -> ResultType<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("Rental path invalid"))?;
    let meta = fs::symlink_metadata(parent)?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        bail!("Rental directory invalid");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.uid() != owner || meta.mode() & 0o022 != 0 {
            bail!("Rental directory permissions invalid");
        }
    }
    Ok(())
}
fn read_private(path: &Path) -> ResultType<Vec<u8>> {
    read_owned(path, serving_uid(), 0o077)
}
fn read_owned(path: &Path, owner: u32, forbidden_mode: u32) -> ResultType<Vec<u8>> {
    read_owned_if_present(path, owner, forbidden_mode)?
        .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::NotFound).into())
}

fn read_owned_if_present(
    path: &Path,
    owner: u32,
    forbidden_mode: u32,
) -> ResultType<Option<Vec<u8>>> {
    owned_parent(path, owner)?;
    let target = match fs::symlink_metadata(path) {
        Ok(target) => target,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !target.is_file() || target.file_type().is_symlink() {
        bail!("Rental file invalid");
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(hbb_common::libc::O_NOFOLLOW | hbb_common::libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.len() > MAX_INPUT {
        bail!("Rental file invalid");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.uid() != owner || meta.mode() & forbidden_mode != 0 {
            bail!("Rental file permissions invalid");
        }
    }
    let mut bytes = Vec::new();
    file.take(MAX_INPUT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_INPUT {
        bail!("Rental file too large");
    }
    Ok(Some(bytes))
}
fn write_private(path: &Path, bytes: &[u8]) -> ResultType<()> {
    write_owned(path, bytes, serving_uid(), 0o600)
}
fn write_owned(path: &Path, bytes: &[u8], owner: u32, mode: u32) -> ResultType<()> {
    owned_parent(path, owner)?;
    if let Ok(meta) = fs::symlink_metadata(path) {
        if !meta.is_file() || meta.file_type().is_symlink() {
            bail!("Rental target invalid");
        }
    }
    let temporary = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(mode);
    }
    // Only clean up a file this call actually created, never an open failure.
    let mut file = options.open(&temporary)?;
    let result = (|| {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(mode))?;
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)?;
        #[cfg(unix)]
        fs::File::open(path.parent().unwrap())?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// Retained across the complete read/prepare/commit sequence, including the
/// daemon IPC. All root authority writers use the same stable inode.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(crate) struct AuthorityWrite {
    _file: fs::File,
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
impl AuthorityWrite {
    pub(crate) fn acquire() -> ResultType<Self> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        if !administrator_peer(Some(serving_uid())) {
            bail!("Administrator privileges required");
        }
        let directory = authority_directory();
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o755)
            .create(&directory)?;
        let path = directory.join("administrator.lock");
        let lock = Self::lock_file(&path)?;
        // The unprivileged daemon needs to read its authoritative snapshot.
        fs::set_permissions(directory, fs::Permissions::from_mode(0o755))?;
        Ok(lock)
    }

    fn lock_file(path: &Path) -> ResultType<Self> {
        use hbb_common::libc;
        use std::os::unix::{
            fs::{MetadataExt, OpenOptionsExt},
            io::AsRawFd,
        };
        owned_parent(path, serving_uid())?;
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)?;
        let meta = file.metadata()?;
        if !meta.is_file()
            || meta.uid() != serving_uid()
            || meta.mode() & 0o077 != 0
            || meta.nlink() != 1
        {
            bail!("Rental administrator lock permissions invalid");
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            bail!("Rental administrator storage busy or lock unavailable");
        }
        Ok(Self { _file: file })
    }

    fn begin(&self, uid: u32) -> ResultType<()> {
        write_owned(&authority_marker(uid), AUTHORITY_MARKER, 0, 0o644)
    }

    pub(crate) fn fence(&self, uid: u32) -> ResultType<()> {
        fence_transaction(&authority_pending(uid), 0)
    }

    pub(crate) fn start_transaction(&self, uid: u32) -> ResultType<String> {
        // Check existing authority before either legacy or UI delivery
        // overwrites any part of it.
        read_admin_policy(uid)?;
        self.begin(uid)?;
        let id = uuid::Uuid::new_v4().simple().to_string();
        write_owned(&authority_pending(uid), id.as_bytes(), 0, 0o644)?;
        Ok(id)
    }

    pub(crate) fn finish_transaction(&self, uid: u32) -> ResultType<()> {
        fs::remove_file(authority_pending(uid))?;
        fs::File::open(authority_directory())?.sync_all()?;
        Ok(())
    }

    pub(crate) fn commit(&self, uid: u32, policy: &Policy, window: (u64, u64)) -> ResultType<()> {
        if !policy.valid() || (policy.valid_from_ms, policy.valid_until_ms) != window {
            bail!("Invalid administrator rental snapshot");
        }
        let bytes = serde_json::to_vec(policy)?;
        let destination = authority_policy(uid);
        write_owned(&destination, &bytes, 0, 0o644)?;
        if read_owned(&destination, 0, 0o022)? != bytes {
            bail!("Administrator rental snapshot persistence failed");
        }
        Ok(())
    }
}

// Existing Linux test fixtures provision directly, without an IPC daemon.
#[cfg(all(test, target_os = "linux"))]
pub(crate) fn begin_administrator_delivery(uid: u32) -> ResultType<()> {
    AuthorityWrite::acquire()?.begin(uid)
}

#[cfg(all(test, target_os = "linux"))]
pub(crate) fn commit_administrator_delivery(
    uid: u32,
    policy: Policy,
    window: (u64, u64),
) -> ResultType<()> {
    AuthorityWrite::acquire()?.commit(uid, &policy, window)
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn valid_transaction_id(bytes: &[u8]) -> bool {
    bytes.len() == 32 && bytes.iter().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn read_pending(path: &Path, owner: u32) -> ResultType<Option<Vec<u8>>> {
    if !exists_or_inaccessible(path) {
        return Ok(None);
    }
    let bytes = read_owned(path, owner, 0o022)?;
    if bytes != FENCED_TRANSACTION && !valid_transaction_id(&bytes) {
        bail!("Invalid rental transaction record");
    }
    Ok(Some(bytes))
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn fence_transaction(path: &Path, owner: u32) -> ResultType<()> {
    if let Some(bytes) = read_pending(path, owner)? {
        if bytes != FENCED_TRANSACTION {
            write_owned(path, FENCED_TRANSACTION, owner, 0o644)?;
        }
    }
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn read_authority(
    marker: &Path,
    snapshot: &Path,
    pending: &Path,
    owner: u32,
) -> ResultType<(Option<Policy>, bool)> {
    if marker.parent().is_some_and(exists_or_inaccessible) {
        owned_parent(marker, owner)?;
    }
    let interrupted = read_pending(pending, owner)?.is_some();
    let has_snapshot = exists_or_inaccessible(snapshot);
    if !exists_or_inaccessible(marker) && !has_snapshot && !interrupted {
        return Ok((None, false));
    }
    if read_owned(marker, owner, 0o022)? != AUTHORITY_MARKER {
        bail!("Invalid rental authority marker");
    }
    if !has_snapshot {
        return Ok((None, true));
    }
    let bytes = read_owned(snapshot, owner, 0o022)?;
    let policy: Policy =
        serde_json::from_slice(&bytes).map_err(|_| anyhow!("Rental policy invalid"))?;
    if !policy.valid() {
        bail!("Rental policy invalid");
    }
    Ok((Some(policy), interrupted))
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(crate) fn read_admin_policy(uid: u32) -> ResultType<(Option<Policy>, bool)> {
    read_authority(
        &authority_marker(uid),
        &authority_policy(uid),
        &authority_pending(uid),
        0,
    )
}

#[cfg(any(target_os = "macos", test))]
fn credential_binding_mismatch(policy: &Policy, memory: &str, persisted: &str) -> bool {
    !sodiumoxide::utils::memcmp(policy.credential_binding.as_bytes(), memory.as_bytes())
        || policy.credential_binding != persisted
}

#[cfg(target_os = "macos")]
pub(crate) fn print_current_expiry() -> ResultType<()> {
    let (policy, interrupted) = read_admin_policy(serving_uid())?;
    if interrupted {
        bail!("Rental update is incomplete");
    }
    let mut output = std::io::stdout().lock();
    match policy {
        Some(policy) => writeln!(output, "{}", policy.valid_until_ms)?,
        None => writeln!(output, "unconfigured")?,
    }
    Ok(())
}

#[cfg(any(target_os = "macos", all(target_os = "linux", test)))]
fn admin_credential_recovery(
    policy: &Policy,
    storage: &str,
    salt: &str,
    path: &Path,
) -> ResultType<bool> {
    let memory = available_binding(storage, salt)?;
    let persisted = persisted_binding_if_present(path)?;
    Ok(match (memory, persisted) {
        (Some(memory), Some(persisted)) => credential_binding_mismatch(policy, &memory, &persisted),
        _ => true,
    })
}

#[cfg(target_os = "macos")]
pub(crate) fn verify_admin_policy(expected: Option<Policy>) -> ResultType<bool> {
    let _lock = lock_policy()?;
    let (policy, interrupted) = read_admin_policy(serving_uid())?;
    if policy != expected {
        bail!("Rental authority changed");
    }
    if let Some(policy) = policy {
        let (storage, salt) = Config::get_local_permanent_password_storage_and_salt();
        let recovery = admin_credential_recovery(&policy, &storage, &salt, &Config::file())?;
        return Ok(interrupted || recovery);
    }
    Ok(interrupted)
}

pub fn administrator_peer(uid: Option<u32>) -> bool {
    uid == Some(0)
}

pub fn read_request(mut input: impl Read) -> ResultType<ProvisionRequest> {
    let mut bytes = Vec::new();
    if input
        .by_ref()
        .take(MAX_INPUT + 1)
        .read_to_end(&mut bytes)
        .is_err()
    {
        sodiumoxide::utils::memzero(&mut bytes);
        bail!("Unable to read rental provisioning input");
    }
    let result = if bytes.len() as u64 > MAX_INPUT {
        Err(anyhow!("Rental provisioning input too large"))
    } else {
        serde_json::from_slice::<ProvisionRequest>(&bytes)
            .map_err(|_| anyhow!("Invalid rental provisioning input"))
    };
    sodiumoxide::utils::memzero(&mut bytes);
    let request = result?;
    if request.password.is_empty()
        || request.password.len() > 1024
        || !valid_window(request.valid_from_ms, request.valid_until_ms)
    {
        bail!("Invalid rental provisioning fields");
    }
    Ok(request)
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn lock_policy() -> ResultType<std::sync::MutexGuard<'static, ()>> {
    POLICY_LOCK
        .lock()
        .map_err(|_| anyhow!("Rental policy unavailable"))
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(crate) fn provision_barrier() -> ResultType<()> {
    drop(lock_policy()?);
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn with_provision_transaction<T>(
    pending: &Path,
    owner: u32,
    id: &str,
    persist: impl FnOnce() -> ResultType<T>,
) -> ResultType<T> {
    // Keep the token check inside the same lock that holds the write. A task
    // queued before the fence may acquire this lock after the barrier.
    let _lock = lock_policy()?;
    if !valid_transaction_id(id.as_bytes())
        || read_pending(pending, owner)?.as_deref() != Some(id.as_bytes())
    {
        bail!("Rental provisioning transaction is no longer active");
    }
    persist()
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(crate) fn provision_transaction(id: String, request: ProvisionRequest) -> ResultType<Policy> {
    with_provision_transaction(&authority_pending(serving_uid()), 0, &id, || {
        provision_locked(request)
    })
}

#[cfg(all(test, target_os = "linux"))]
pub fn provision(request: ProvisionRequest) -> ResultType<Policy> {
    let _lock = lock_policy()?;
    provision_locked(request)
}

/// Executed in the serving daemon's config context under the policy lock.
#[cfg(any(target_os = "linux", target_os = "macos"))]
fn provision_locked(request: ProvisionRequest) -> ResultType<Policy> {
    if request.password.is_empty()
        || request.password.len() > 1024
        || !valid_window(request.valid_from_ms, request.valid_until_ms)
    {
        bail!("Invalid rental provisioning fields");
    }
    if Config::is_disable_change_permanent_password() {
        bail!("Password changes disabled");
    }
    // Enable fail-closed enforcement BEFORE changing a credential. Partial
    // writes leave the host enforcing, with either an old matching snapshot or
    // a mismatched/missing policy that rejects all new connections.
    write_private(&marker_path(), b"rustdesk-rental-host-v1\n")?;
    Config::set_option("rental-host".into(), "Y".into());
    Config::set_option(
        "verification-method".into(),
        "use-permanent-password".into(),
    );
    Config::set_option("approve-mode".into(), "password".into());
    if !crate::trusted_devices::config::set_password(&request.password)? {
        bail!("Rental credential update failed");
    }
    let (storage, salt) = Config::get_local_permanent_password_storage_and_salt();
    let expected = binding(&storage, &salt)?;
    // The upstream setter logs write errors rather than returning them. Read
    // back the actual existing encrypted config, never ACK a memory-only save.
    if persisted_binding()? != expected
        || !sodiumoxide::utils::memcmp(
            &config::compute_permanent_password_h1(&request.password, &salt),
            &config::decode_permanent_password_h1_from_storage(&storage)
                .ok_or_else(|| anyhow!("Credential storage invalid"))?,
        )
    {
        bail!("Rental credential persistence failed");
    }
    // Also verify mode persistence, independently of the fail-closed marker.
    let options: Config2 = hbb_common::toml::from_str(
        std::str::from_utf8(&read_private(&Config2::file())?)
            .map_err(|_| anyhow!("Rental mode persistence invalid"))?,
    )
    .map_err(|_| anyhow!("Rental mode persistence invalid"))?;
    if options.options.get("rental-host").map(String::as_str) != Some("Y")
        || options
            .options
            .get("verification-method")
            .map(String::as_str)
            != Some("use-permanent-password")
        || options.options.get("approve-mode").map(String::as_str) != Some("password")
    {
        bail!("Rental mode persistence failed");
    }
    let policy = Policy {
        version: 1,
        credential_binding: expected,
        valid_from_ms: request.valid_from_ms,
        valid_until_ms: request.valid_until_ms,
    };
    let encoded = serde_json::to_vec(&policy)?;
    write_private(&policy_path(), &encoded)?;
    if read_private(&policy_path())? != encoded {
        bail!("Rental policy persistence failed");
    }
    Ok(policy)
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn persisted_binding() -> ResultType<String> {
    persisted_binding_if_present(&Config::file())?
        .ok_or_else(|| anyhow!("Persisted rental credential missing"))
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn persisted_binding_if_present(path: &Path) -> ResultType<Option<String>> {
    #[derive(Default, Deserialize)]
    #[serde(default)]
    struct CredentialFields {
        password: String,
        salt: String,
    }

    let Some(bytes) = read_owned_if_present(path, serving_uid(), 0o077)? else {
        return Ok(None);
    };
    let text =
        std::str::from_utf8(&bytes).map_err(|_| anyhow!("Credential persistence invalid"))?;
    let fields: CredentialFields =
        hbb_common::toml::from_str(text).map_err(|_| anyhow!("Credential persistence invalid"))?;
    available_binding(&fields.password, &fields.salt)
}

/// Parse only an authenticated server's optional snapshot. Never compare the
/// client's clock or derive an authorization decision from this display value.
pub fn peer_deadline(additions: &str) -> Option<String> {
    let values: serde_json::Value = serde_json::from_str(additions).ok()?;
    let text = values.get(DEADLINE_FIELD)?.as_str()?;
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let value = text.parse::<u64>().ok()?;
    (value > 0 && value <= MAX_TIMESTAMP_MS).then(|| value.to_string())
}

#[cfg(all(test, target_os = "linux"))]
pub(crate) fn assert_disposable_authority() {
    assert_eq!(
        std::env::var("RD_DIRECT_DISPOSABLE_CONFIG").as_deref(),
        Ok("1")
    );
    assert_eq!(
        std::env::var("RD_RENTAL_EPHEMERAL_AUTHORITY").as_deref(),
        Ok("1")
    );
    assert!(Config::path("").starts_with(std::env::var("HOME").unwrap()));
    assert_eq!(serving_uid(), 0);
    let path = std::ffi::CString::new(authority_directory().to_string_lossy().as_bytes()).unwrap();
    let mut info: hbb_common::libc::statfs = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe { hbb_common::libc::statfs(path.as_ptr(), &mut info) },
        0
    );
    assert_eq!(
        info.f_type as u64,
        hbb_common::libc::TMPFS_MAGIC as u64,
        "administrator tests refuse a real authority directory; mount a fresh container tmpfs"
    );
}

#[cfg(test)]
mod tests;
