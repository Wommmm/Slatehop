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

#[derive(Clone, Serialize, Deserialize)]
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
    Config::get_option("rental-host") == "Y"
        || exists_or_inaccessible(&marker_path())
        || exists_or_inaccessible(&policy_path())
        || exists_or_inaccessible(&authority_marker(serving_uid()))
        || exists_or_inaccessible(&authority_policy(serving_uid()))
}
fn valid_window(from: u64, until: u64) -> bool {
    from < until && until <= MAX_TIMESTAMP_MS
}
fn binding(storage: &str, salt: &str) -> ResultType<String> {
    if salt.is_empty() {
        bail!("Rental credential salt unavailable");
    }
    let mut h1 = config::decode_permanent_password_h1_from_storage(storage)
        .ok_or_else(|| anyhow!("Rental credential storage unavailable"))?;
    // This is a local binding, never a new password algorithm or wire proof.
    let mut hash = Sha256::new();
    hash.update(b"rustdesk-rental-binding-v1\0");
    hash.update((salt.len() as u64).to_be_bytes());
    hash.update(salt.as_bytes());
    hash.update(h1);
    sodiumoxide::utils::memzero(&mut h1);
    Ok(hex::encode(hash.finalize()))
}
fn now_ms() -> ResultType<u64> {
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
fn check_bytes(bytes: &[u8], storage: &str, salt: &str, now: u64) -> ResultType<Grant> {
    let policy: Policy =
        serde_json::from_slice(bytes).map_err(|_| anyhow!("Rental policy invalid"))?;
    if policy.version != 1
        || !valid_window(policy.valid_from_ms, policy.valid_until_ms)
        || !sodiumoxide::utils::memcmp(
            policy.credential_binding.as_bytes(),
            binding(storage, salt)?.as_bytes(),
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
    let now = now_ms().map_err(|_| AuthError::Validity)?;
    // User-writable staging/config files are never the authorization source.
    let bytes =
        read_owned(&authority_policy(serving_uid()), 0, 0o022).map_err(|_| AuthError::Validity)?;
    check_bytes(&bytes, &storage, &salt, now)
        .map(Some)
        .map_err(|_| AuthError::Validity)
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
    owned_parent(path, owner)?;
    let target = fs::symlink_metadata(path)?;
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
    Ok(bytes)
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

/// The root CLI selects the serving UID from kernel IPC credentials; the
/// daemon cannot nominate an arbitrary destination or extend the submitted time.
pub fn begin_administrator_delivery(uid: u32) -> ResultType<()> {
    if serving_uid() != 0 {
        bail!("Administrator privileges required");
    }
    fs::create_dir_all(authority_directory())?;
    owned_parent(&authority_policy(uid), 0)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(authority_directory(), fs::Permissions::from_mode(0o755))?;
    }
    write_owned(
        &authority_marker(uid),
        b"rustdesk-rental-host-v1\n",
        0,
        0o644,
    )
}
pub fn commit_administrator_delivery(
    uid: u32,
    policy: Policy,
    window: (u64, u64),
) -> ResultType<()> {
    if serving_uid() != 0
        || policy.version != 1
        || !valid_window(policy.valid_from_ms, policy.valid_until_ms)
        || (policy.valid_from_ms, policy.valid_until_ms) != window
        || policy.credential_binding.len() != 64
        || !policy
            .credential_binding
            .bytes()
            .all(|b| b.is_ascii_hexdigit())
    {
        bail!("Invalid administrator rental snapshot");
    }
    let bytes = serde_json::to_vec(&policy)?;
    write_owned(&authority_policy(uid), &bytes, 0, 0o644)?;
    if read_owned(&authority_policy(uid), 0, 0o022)? != bytes {
        bail!("Administrator rental snapshot persistence failed");
    }
    Ok(())
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

/// Executed in the serving daemon's config context, through the authenticated
/// local administrator IPC. No plaintext is added to a file, argv or log.
pub fn provision(request: ProvisionRequest) -> ResultType<Policy> {
    let _lock = POLICY_LOCK
        .lock()
        .map_err(|_| anyhow!("Rental policy unavailable"))?;
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
    let persisted = read_private(&Config::file())?;
    let value: hbb_common::toml::Value = hbb_common::toml::from_str(
        std::str::from_utf8(&persisted).map_err(|_| anyhow!("Credential persistence invalid"))?,
    )
    .map_err(|_| anyhow!("Credential persistence invalid"))?;
    let stored = value
        .get("password")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let stored_salt = value
        .get("salt")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    if binding(stored, stored_salt)? != expected
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
