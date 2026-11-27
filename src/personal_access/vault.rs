use hbb_common::{
    libc,
    sodiumoxide::{
        self,
        crypto::{pwhash::argon2id13, secretbox},
        utils::memzero,
    },
};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::{
        fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        io::AsRawFd,
    },
    path::{Path, PathBuf},
};

type VaultResult<T> = Result<T, &'static str>;

const INVALID_INPUT: &str = "invalid_input";
const INVALID_PASSWORD: &str = "invalid_password";
const ALREADY_CONFIGURED: &str = "already_configured";
const NOT_CONFIGURED: &str = "not_configured";
const NOT_SET: &str = "no_password";
const UNAVAILABLE: &str = "unavailable";
const UNCONFIRMED: &str = "unconfirmed";

const HEADER: &[u8] = b"SlateHopVault\x01";
const MAX_PASSWORD_BYTES: usize = 1024;
const EMPTY: u8 = 0;
const PENDING: u8 = 1;
const PASSWORD: u8 = 2;
const PREFIX_BYTES: usize = HEADER.len() + argon2id13::SALTBYTES + secretbox::NONCEBYTES;
const MIN_RECORD_BYTES: usize = PREFIX_BYTES + secretbox::MACBYTES + 1;
const MAX_RECORD_BYTES: usize = MIN_RECORD_BYTES + MAX_PASSWORD_BYTES;
const SAFE_OPEN: i32 = libc::O_NOFOLLOW | libc::O_NONBLOCK;

pub(super) fn configured(path: &Path) -> VaultResult<bool> {
    Ok(LockedVault::existing(path)?.is_some())
}

pub(super) fn setup(path: &Path, management: &str) -> VaultResult<()> {
    validate_password(management)?;
    let parent = parent_path(path)?;
    io_result(
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent),
    )?;
    let vault = LockedVault::lock(path)?;
    if vault.read()?.is_some() {
        return Err(ALREADY_CONFIGURED);
    }

    init_crypto()?;
    let salt = argon2id13::gen_salt();
    let key = derive_key(management, &salt)?;
    vault.write(&seal(&salt, &key, EMPTY, ""))
}

pub(super) fn reveal(path: &Path, management: &str) -> VaultResult<String> {
    let (_vault, record) = LockedVault::existing(path)?.ok_or(NOT_CONFIGURED)?;
    let (_, message) = record.unlock(management)?;
    match message.entry()? {
        Entry::Empty => Err(NOT_SET),
        Entry::Pending => Err(UNCONFIRMED),
        Entry::Password(password) => Ok(password.to_owned()),
    }
}

pub(super) fn set<F: FnOnce(&str) -> VaultResult<()>>(
    path: &Path,
    management: &str,
    remote: &str,
    apply: F,
) -> VaultResult<()> {
    validate_password(remote)?;
    let (vault, record) = LockedVault::existing(path)?.ok_or(NOT_CONFIGURED)?;
    let (key, previous) = record.unlock(management)?;
    previous.entry()?;
    drop(previous);

    let confirmed = seal(&record.salt, &key, PASSWORD, remote);
    let pending = seal(&record.salt, &key, PENDING, "");
    drop(key);
    // Commit the pending record before giving the host a chance to change.
    // A failed or interrupted callback leaves reads blocked until a new set.
    vault.write(&pending)?;
    apply(remote)?;
    vault.write(&confirmed).map_err(|_| UNCONFIRMED)
}

fn validate_password(value: &str) -> VaultResult<()> {
    if value.is_empty() || value.len() > MAX_PASSWORD_BYTES {
        return Err(INVALID_INPUT);
    }
    Ok(())
}

fn init_crypto() -> VaultResult<()> {
    sodiumoxide::init().map_err(|_| UNAVAILABLE)
}

fn derive_key(management: &str, salt: &argon2id13::Salt) -> VaultResult<secretbox::Key> {
    let mut key = secretbox::Key([0; secretbox::KEYBYTES]);
    argon2id13::derive_key(
        &mut key.0,
        management.as_bytes(),
        salt,
        argon2id13::OPSLIMIT_INTERACTIVE,
        argon2id13::MEMLIMIT_INTERACTIVE,
    )
    .map_err(|_| UNAVAILABLE)?;
    Ok(key)
}

fn seal(salt: &argon2id13::Salt, key: &secretbox::Key, state: u8, password: &str) -> Vec<u8> {
    let mut message = Cleartext(Vec::with_capacity(1 + password.len()));
    message.0.push(state);
    message.0.extend_from_slice(password.as_bytes());
    let nonce = secretbox::gen_nonce();
    let sealed = secretbox::seal(&message.0, &nonce, key);
    let mut bytes = Vec::with_capacity(PREFIX_BYTES + sealed.len());
    bytes.extend_from_slice(HEADER);
    bytes.extend_from_slice(&salt.0);
    bytes.extend_from_slice(&nonce.0);
    bytes.extend_from_slice(&sealed);
    bytes
}

struct Record {
    salt: argon2id13::Salt,
    nonce: secretbox::Nonce,
    sealed: Vec<u8>,
}

impl Record {
    fn decode(bytes: Vec<u8>) -> VaultResult<Self> {
        if !(MIN_RECORD_BYTES..=MAX_RECORD_BYTES).contains(&bytes.len())
            || !bytes.starts_with(HEADER)
        {
            return Err(UNAVAILABLE);
        }
        let salt_end = HEADER.len() + argon2id13::SALTBYTES;
        Ok(Self {
            salt: argon2id13::Salt::from_slice(&bytes[HEADER.len()..salt_end]).ok_or(UNAVAILABLE)?,
            nonce: secretbox::Nonce::from_slice(&bytes[salt_end..PREFIX_BYTES]).ok_or(UNAVAILABLE)?,
            sealed: bytes[PREFIX_BYTES..].to_vec(),
        })
    }

    fn unlock(&self, management: &str) -> VaultResult<(secretbox::Key, Cleartext)> {
        validate_password(management)?;
        init_crypto()?;
        let key = derive_key(management, &self.salt)?;
        let plaintext =
            secretbox::open(&self.sealed, &self.nonce, &key).map_err(|_| INVALID_PASSWORD)?;
        Ok((key, Cleartext(plaintext)))
    }
}

struct Cleartext(Vec<u8>);

impl Drop for Cleartext {
    fn drop(&mut self) {
        memzero(&mut self.0);
    }
}

enum Entry<'a> {
    Empty,
    Pending,
    Password(&'a str),
}

impl Cleartext {
    fn entry(&self) -> VaultResult<Entry<'_>> {
        match self.0.as_slice() {
            [EMPTY] => Ok(Entry::Empty),
            [PENDING] => Ok(Entry::Pending),
            [PASSWORD, bytes @ ..] if !bytes.is_empty() && bytes.len() <= MAX_PASSWORD_BYTES => {
                let password = std::str::from_utf8(bytes).map_err(|_| UNAVAILABLE)?;
                Ok(Entry::Password(password))
            }
            _ => Err(UNAVAILABLE),
        }
    }
}

fn io_result<T>(result: io::Result<T>) -> VaultResult<T> {
    result.map_err(|_| UNAVAILABLE)
}

fn parent_path(path: &Path) -> VaultResult<&Path> {
    if !path.is_absolute() || path.file_name().is_none() {
        return Err(UNAVAILABLE);
    }
    path.parent().ok_or(UNAVAILABLE)
}

fn lock_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(".lock");
    PathBuf::from(name)
}

struct LockedVault<'a> {
    path: &'a Path,
    parent: File,
    _lock: File,
}

impl<'a> LockedVault<'a> {
    fn existing(path: &'a Path) -> VaultResult<Option<(Self, Record)>> {
        parent_path(path)?;
        match fs::symlink_metadata(path) {
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(UNAVAILABLE),
        }
        let vault = Self::lock(path)?;
        Ok(vault.read()?.map(|record| (vault, record)))
    }

    fn lock(path: &'a Path) -> VaultResult<Self> {
        let parent = io_result(
            OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | SAFE_OPEN)
                .open(parent_path(path)?),
        )?;
        let meta = io_result(parent.metadata())?;
        let owner = unsafe { libc::geteuid() };
        if !meta.is_dir() || meta.uid() != owner || meta.mode() & 0o022 != 0 || !safe_acl(&parent) {
            return Err(UNAVAILABLE);
        }

        let lock = io_result(
            OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .mode(0o600)
                .custom_flags(SAFE_OPEN)
                .open(lock_path(path)),
        )?;
        require_private_file(&lock)?;
        loop {
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } == 0 {
                break;
            }
            if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                return Err(UNAVAILABLE);
            }
        }
        Ok(Self {
            path,
            parent,
            _lock: lock,
        })
    }

    fn read(&self) -> VaultResult<Option<Record>> {
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(SAFE_OPEN)
            .open(self.path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(UNAVAILABLE),
        };
        require_private_file(&file)?;
        let mut bytes = Vec::new();
        io_result(file.take(MAX_RECORD_BYTES as u64 + 1).read_to_end(&mut bytes))?;
        Record::decode(bytes).map(Some)
    }

    fn write(&self, bytes: &[u8]) -> VaultResult<()> {
        let temp =
            parent_path(self.path)?.join(format!(".slatehop-vault-{}.tmp", uuid::Uuid::new_v4()));
        let mut file = io_result(
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp),
        )?;
        let result = (|| {
            io_result(file.set_permissions(fs::Permissions::from_mode(0o600)))?;
            require_private_file(&file)?;
            io_result(file.write_all(bytes))?;
            io_result(file.sync_all())?;
            io_result(fs::rename(&temp, self.path))?;
            io_result(self.parent.sync_all())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp);
        }
        result
    }
}

fn require_private_file(file: &File) -> VaultResult<()> {
    let meta = io_result(file.metadata())?;
    let owner = unsafe { libc::geteuid() };
    if !meta.is_file()
        || meta.uid() != owner
        || meta.nlink() != 1
        || meta.mode() & 0o7777 != 0o600
        || !safe_acl(file)
    {
        return Err(UNAVAILABLE);
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn safe_acl(_file: &File) -> bool {
    true
}

#[cfg(target_os = "macos")]
fn safe_acl(file: &File) -> bool {
    use libc::{c_int, c_void};
    extern "C" {
        fn acl_get_fd_np(fd: c_int, acl_type: c_int) -> *mut c_void;
        fn acl_get_entry(acl: *mut c_void, entry_id: c_int, entry: *mut *mut c_void) -> c_int;
        fn acl_get_tag_type(entry: *mut c_void, tag: *mut c_int) -> c_int;
        fn acl_free(acl: *mut c_void) -> c_int;
    }
    const ACL_TYPE_EXTENDED: c_int = 0x100;
    const ACL_EXTENDED_DENY: c_int = 2;
    const ACL_FIRST_ENTRY: c_int = 0;
    const ACL_NEXT_ENTRY: c_int = -1;

    // Darwin ACL grants can allow access independently of the POSIX mode.
    let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), ACL_TYPE_EXTENDED) };
    if acl.is_null() {
        return matches!(
            io::Error::last_os_error().raw_os_error(),
            Some(libc::ENOENT) | Some(libc::ENOATTR)
        );
    }
    let mut index = ACL_FIRST_ENTRY;
    let permitted = loop {
        let mut entry = std::ptr::null_mut();
        if unsafe { acl_get_entry(acl, index, &mut entry) } != 0 {
            break io::Error::last_os_error().raw_os_error() == Some(libc::EINVAL);
        }
        let mut tag = 0;
        if entry.is_null()
            || unsafe { acl_get_tag_type(entry, &mut tag) } != 0
            || tag != ACL_EXTENDED_DENY
        {
            break false;
        }
        index = ACL_NEXT_ENTRY;
    };
    unsafe { acl_free(acl) };
    permitted
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    const MANAGEMENT: &str = "fixture-management";
    const PASSWORD: &str = "fixture-remote";

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let directory =
                std::env::temp_dir().join(format!("slatehop-vault-{}", uuid::Uuid::new_v4()));
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .unwrap();
            Self(directory)
        }

        fn path(&self) -> PathBuf {
            self.0.join("vault")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn requires_management_password_and_only_publishes_confirmed_password() {
        let fixture = Fixture::new();
        let path = fixture.path();
        assert_eq!(configured(&path), Ok(false));
        assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 0);
        setup(&path, MANAGEMENT).unwrap();
        assert_eq!(configured(&path), Ok(true));
        assert_eq!(reveal(&path, MANAGEMENT), Err(NOT_SET));
        assert_eq!(setup(&path, MANAGEMENT), Err(ALREADY_CONFIGURED));

        let called = Cell::new(false);
        assert_eq!(
            set(&path, "wrong-password", PASSWORD, |_| {
                called.set(true);
                Ok(())
            }),
            Err(INVALID_PASSWORD)
        );
        assert!(!called.get());
        assert_eq!(reveal(&path, "wrong-password"), Err(INVALID_PASSWORD));
        set(&path, MANAGEMENT, PASSWORD, |password| {
            assert_eq!(password, PASSWORD);
            Ok(())
        })
        .unwrap();
        assert_eq!(reveal(&path, MANAGEMENT).as_deref(), Ok(PASSWORD));
        let bytes = fs::read(&path).unwrap();
        assert!(!bytes
            .windows(PASSWORD.len())
            .any(|window| window == PASSWORD.as_bytes()));
        assert!(!bytes
            .windows(MANAGEMENT.len())
            .any(|window| window == MANAGEMENT.as_bytes()));
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
    }

    #[test]
    fn interrupted_write_stays_hidden_until_a_confirmed_retry() {
        let fixture = Fixture::new();
        let path = fixture.path();
        setup(&path, MANAGEMENT).unwrap();
        set(&path, MANAGEMENT, PASSWORD, |_| Ok(())).unwrap();

        let host = RefCell::new(PASSWORD.to_owned());
        let failed = set(&path, MANAGEMENT, "fixture-next", |password| {
            host.replace(password.to_owned());
            Err("fixture_host_error")
        });
        assert_eq!(failed, Err("fixture_host_error"));
        assert_eq!(reveal(&path, MANAGEMENT), Err(UNCONFIRMED));

        let interrupted = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = set(&path, MANAGEMENT, "fixture-interrupted", |password| {
                host.replace(password.to_owned());
                panic!("simulated interruption");
            });
        }));
        assert!(interrupted.is_err());
        assert_eq!(reveal(&path, MANAGEMENT), Err(UNCONFIRMED));
        set(&path, MANAGEMENT, "fixture-confirmed", |password| {
            host.replace(password.to_owned());
            Ok(())
        })
        .unwrap();
        assert_eq!(reveal(&path, MANAGEMENT).unwrap(), host.into_inner());
    }

    #[test]
    fn damaged_and_non_private_records_are_never_overwritten() {
        let fixture = Fixture::new();
        let path = fixture.path();
        setup(&path, MANAGEMENT).unwrap();

        let mut damaged = fs::read(&path).unwrap();
        *damaged.last_mut().unwrap() ^= 0x80;
        fs::write(&path, &damaged).unwrap();
        assert_eq!(reveal(&path, MANAGEMENT), Err(INVALID_PASSWORD));
        assert_eq!(
            set(&path, MANAGEMENT, PASSWORD, |_| panic!("vault must fail first")),
            Err(INVALID_PASSWORD)
        );
        assert_eq!(fs::read(&path).unwrap(), damaged);

        fs::write(&path, b"invalid file").unwrap();
        assert_eq!(configured(&path), Err(UNAVAILABLE));
        assert_eq!(setup(&path, MANAGEMENT), Err(UNAVAILABLE));
        assert_eq!(fs::read(&path).unwrap().as_slice(), &b"invalid file"[..]);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            set(&path, MANAGEMENT, PASSWORD, |_| panic!("vault must fail first")),
            Err(UNAVAILABLE)
        );
    }

    #[test]
    fn stable_lock_blocks_a_separate_open_file_description() {
        let fixture = Fixture::new();
        let path = fixture.path();
        let _vault = LockedVault::lock(&path).unwrap();
        let other = File::open(lock_path(&path)).unwrap();
        let result = unsafe { libc::flock(other.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        assert_eq!(result, -1);
        let errno = io::Error::last_os_error().raw_os_error();
        assert_eq!(errno, Some(libc::EWOULDBLOCK));
    }
}
