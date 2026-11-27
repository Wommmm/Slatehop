mod vault;

use hbb_common::{config::Config, libc, password_security as password, sodiumoxide};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    net::{Ipv4Addr, SocketAddrV4},
    path::{Path, PathBuf},
    process::Command,
    sync::{Mutex, MutexGuard},
};

pub(crate) const PREFIX: &str = "slatehop-personal-access:";
const UNAVAILABLE: &str = "unavailable";
const MANAGED: &str = "managed";
const NO_PASSWORD: &str = "no_password";
const INVALID_INPUT: &str = "invalid_input";
static PASSWORD_OPERATIONS: Mutex<()> = Mutex::new(());

type AccessResult<T> = Result<T, &'static str>;

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Status,
    Setup {
        #[serde(rename = "managementPassword")]
        management: String,
    },
    Show {
        #[serde(rename = "managementPassword")]
        management: String,
    },
    Set {
        #[serde(rename = "managementPassword")]
        management: String,
        #[serde(rename = "remotePassword")]
        remote: String,
    },
}

impl std::fmt::Debug for Request {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PersonalAccessRequest([REDACTED])")
    }
}

impl Drop for Request {
    fn drop(&mut self) {
        match self {
            Self::Setup { management } | Self::Show { management } => erase(management),
            Self::Set { management, remote } => {
                erase(management);
                erase(remote);
            }
            Self::Status => {}
        }
    }
}

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Mode {
    Unconfigured,
    Personal,
    Managed,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Reply {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    mode: Option<Mode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    address: Option<String>,
    #[serde(rename = "remotePassword", skip_serializing_if = "Option::is_none")]
    remote_password: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl std::fmt::Debug for Reply {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PersonalAccessReply([REDACTED])")
    }
}

impl Drop for Reply {
    fn drop(&mut self) {
        if let Some(password) = &mut self.remote_password {
            erase(password);
        }
    }
}

impl Reply {
    pub(crate) fn failed(error: &'static str) -> Self {
        let error = match error {
            MANAGED | "invalid_password" | INVALID_INPUT | NO_PASSWORD | "already_configured" => {
                error
            }
            _ => UNAVAILABLE,
        };
        Self {
            ok: false,
            mode: None,
            address: None,
            remote_password: None,
            error: Some(error.into()),
        }
    }

    fn status(mode: Mode, address: Option<String>, remote_password: Option<String>) -> Self {
        Self {
            ok: true,
            mode: Some(mode),
            address,
            remote_password,
            error: None,
        }
    }

    pub(crate) fn json(&self) -> String {
        serde_json::to_string(self)
            .unwrap_or_else(|_| r#"{"ok":false,"error":"unavailable"}"#.into())
    }
}

fn erase(value: &mut str) {
    // All zero bytes are valid UTF-8.
    unsafe { sodiumoxide::utils::memzero(value.as_bytes_mut()) };
}

pub(crate) async fn dispatch(mut key: String) -> String {
    let request = key
        .strip_prefix(PREFIX)
        .filter(|input| input.len() <= 8_192)
        .and_then(|input| serde_json::from_str::<Request>(input).ok());
    erase(&mut key);
    let Some(request) = request else {
        return Reply::failed(INVALID_INPUT).json();
    };
    // Also hide local controls for a managed host whose server is unavailable.
    match managed() {
        Ok(true) if matches!(&request, Request::Status) => {
            return Reply::status(Mode::Managed, None, None).json();
        }
        Ok(true) => return Reply::failed(MANAGED).json(),
        Err(error) => return Reply::failed(error).json(),
        Ok(false) => {}
    }
    crate::ipc::personal_access(request).await.json()
}

fn vault_path() -> PathBuf {
    Config::file().with_extension("slatehop-personal-vault")
}

fn present(path: &Path) -> AccessResult<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(UNAVAILABLE),
    }
}

fn managed() -> AccessResult<bool> {
    if crate::rental::is_host()
        || present(Path::new("/Library/SlateHopOperator/owner-state"))?
        || present(Path::new("/Library/SlateHopHost"))?
    {
        return Ok(true);
    }
    crate::rental::any_macos_rental_authority().map_err(|_| UNAVAILABLE)
}

pub(crate) fn password_operations() -> AccessResult<MutexGuard<'static, ()>> {
    PASSWORD_OPERATIONS.lock().map_err(|_| UNAVAILABLE)
}

// Call while holding password_operations, so setup cannot overtake an old setter.
pub(crate) fn require_legacy_password_write(protected_config_sync: bool) -> AccessResult<()> {
    if managed()? {
        return if protected_config_sync { Ok(()) } else { Err(MANAGED) };
    }
    if vault::configured(&vault_path())? {
        return Err("invalid_password");
    }
    Ok(())
}

fn require_personal_host(peer_uid: u32) -> AccessResult<()> {
    if managed()? {
        return Err(MANAGED);
    }
    if !crate::common::is_server_running() || !crate::ipc::is_personal_console_user(peer_uid) {
        return Err(UNAVAILABLE);
    }
    Ok(())
}

fn password_access_available() -> bool {
    password::permanent_enabled() && password::approve_mode() != password::ApproveMode::Click
}

fn verified_password(remote: &str) -> AccessResult<bool> {
    crate::rental::confirms_local_password(remote).map_err(|_| UNAVAILABLE)
}

pub(crate) fn handle(request: Request, peer_uid: u32) -> Reply {
    match perform(&request, peer_uid) {
        Ok(reply) => reply,
        Err(error) => Reply::failed(error),
    }
}

fn perform(request: &Request, peer_uid: u32) -> AccessResult<Reply> {
    if managed()? && matches!(request, Request::Status) {
        return Ok(Reply::status(Mode::Managed, None, None));
    }
    require_personal_host(peer_uid)?;
    let address = direct_port().and_then(|port| direct_address(port).map(|address| (port, address)));
    let _guard = password_operations()?;
    if managed()? && matches!(request, Request::Status) {
        return Ok(Reply::status(Mode::Managed, None, None));
    }
    require_personal_host(peer_uid)?;
    let path = vault_path();
    let mut secret = None;
    let mode = match request {
        Request::Status => {
            if vault::configured(&path)? {
                Mode::Personal
            } else {
                Mode::Unconfigured
            }
        }
        Request::Setup { management } => {
            vault::setup(&path, management)?;
            Mode::Personal
        }
        Request::Show { management } => {
            let mut remote = vault::reveal(&path, management)?;
            if let Err(error) = confirm_for_display(peer_uid, &remote) {
                erase(&mut remote);
                return Err(error);
            }
            secret = Some(remote);
            Mode::Personal
        }
        Request::Set { management, remote } => {
            require_password_write()?;
            vault::set(&path, management, remote, |candidate| {
                require_personal_host(peer_uid)?;
                require_password_write()?;
                let accepted = crate::trusted_devices::config::set_host_password(candidate)
                    .map_err(|_| UNAVAILABLE)?;
                if !accepted || !verified_password(candidate)? {
                    return Err(UNAVAILABLE);
                }
                Ok(())
            })?;
            confirm_for_display(peer_uid, remote)?;
            secret = Some(remote.clone());
            Mode::Personal
        }
    };
    let address = address
        .filter(|(port, _)| direct_port() == Some(*port))
        .map(|(_, address)| address);
    Ok(Reply::status(mode, address, secret))
}

fn require_password_write() -> AccessResult<()> {
    if !password_access_available() || Config::is_disable_change_permanent_password() {
        return Err(UNAVAILABLE);
    }
    Ok(())
}

fn confirm_for_display(peer_uid: u32, remote: &str) -> AccessResult<()> {
    require_personal_host(peer_uid)?;
    if !password_access_available() || !verified_password(remote)? {
        return Err(NO_PASSWORD);
    }
    Ok(())
}

fn direct_port() -> Option<u16> {
    if !Config::get_bool_option(base::config::keys::OPTION_DIRECT_SERVER)
        || Config::get_bool_option("stop-service")
    {
        return None;
    }
    // Use the same configured or default port as direct_server.
    let configured = Config::get_option("direct-access-port")
        .parse::<i32>()
        .unwrap_or(0);
    u16::try_from(if configured > 0 {
        configured
    } else {
        hbb_common::config::RENDEZVOUS_PORT + 2
    })
    .ok()
}

fn direct_address(port: u16) -> Option<String> {
    // Verify that the serving process owns the listener before exposing a target.
    let pid = std::process::id();
    let listeners = Command::new("/usr/sbin/lsof")
        .args(["-nP", &format!("-iTCP:{port}"), "-sTCP:LISTEN", "-Fpn"])
        .env_clear()
        .output()
        .ok()?;
    if !listeners.status.success() {
        return None;
    }
    let listeners = std::str::from_utf8(&listeners.stdout).ok()?;

    let interfaces = Command::new("/sbin/ifconfig")
        .arg("-a")
        .env_clear()
        .output()
        .ok()?;
    if !interfaces.status.success() {
        return None;
    }
    let interfaces = std::str::from_utf8(&interfaces.stdout).ok()?;
    verified_address(pid, port, listeners, interfaces)
}

fn verified_address(pid: u32, port: u16, listeners: &str, interfaces: &str) -> Option<String> {
    let owner = pid.to_string();
    let mut owners = listeners.lines().filter_map(|line| line.strip_prefix('p'));
    if owners.next() != Some(owner.as_str()) || owners.next().is_some() {
        return None;
    }
    let wildcard = format!("n*:{port}");
    let mut usable_interface = false;
    for line in interfaces.lines() {
        if !line.starts_with(char::is_whitespace) {
            usable_interface = line
                .split_once('<')
                .and_then(|(_, flags)| flags.split_once('>'))
                .is_some_and(|(flags, _)| {
                    let mut flags = flags.split(',');
                    flags.clone().any(|flag| flag == "UP")
                        && !flags.any(|flag| flag == "LOOPBACK")
                });
        }
        if !usable_interface {
            continue;
        }
        if let Some(address) = line
            .trim_start()
            .strip_prefix("inet ")
            .and_then(|rest| rest.split_whitespace().next())
            .and_then(|ip| ip.parse::<Ipv4Addr>().ok())
        {
            if address.is_loopback() || address.is_unspecified() || address.is_multicast() {
                continue;
            }
            let specific = format!("n{address}:{port}");
            if listeners.lines().any(|line| line == wildcard || line == specific) {
                return Some(SocketAddrV4::new(address, port).to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_requires_the_owning_listener_and_an_up_non_loopback_interface() {
        let interfaces = "lo0: flags=0<UP,LOOPBACK>\n\tinet 127.0.0.1\nen0: flags=0<UP,RUNNING>\n\tinet 192.0.2.15 netmask 0xffffff00\n";
        assert_eq!(
            verified_address(42, 21118, "p42\nn*:21118\n", interfaces).as_deref(),
            Some("192.0.2.15:21118")
        );
        assert_eq!(verified_address(42, 21118, "p7\nn*:21118\n", interfaces), None);
        assert_eq!(
            verified_address(42, 21118, "p42\nn192.0.2.2:21118\n", interfaces),
            None
        );
    }

    #[test]
    fn ipc_payload_debug_never_includes_either_password() {
        let request = Request::Set {
            management: "synthetic-manager".into(),
            remote: "synthetic-remote".into(),
        };
        let reply = Reply::status(Mode::Personal, None, Some("synthetic-remote".into()));
        assert!(!format!("{request:?} {reply:?}").contains("synthetic"));
        assert!(serde_json::from_str::<Request>(
            r#"{"op":"show","managementPassword":"m","remotePassword":"r"}"#
        )
        .is_err());
    }
}
