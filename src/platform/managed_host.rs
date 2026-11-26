use hbb_common::{bail, ResultType};
use std::{fs, os::unix::fs::MetadataExt, path::Path, process::Command};

pub(crate) const APP_BUNDLE: &str = "/Library/SlateHopHost/RustDesk.app";
const BIN_DIR: &str = "/Library/SlateHopHost/RustDesk.app/Contents/MacOS/";
const MAIN: &str = "/Library/SlateHopHost/RustDesk.app/Contents/MacOS/RustDesk";
const SERVICE: &str = "/Library/SlateHopHost/RustDesk.app/Contents/MacOS/service";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Role {
    Main,
    Service,
}

impl Role {
    fn executable(self) -> &'static str {
        match self {
            Self::Main => MAIN,
            Self::Service => SERVICE,
        }
    }

    fn launchd_label(self) -> &'static str {
        match self {
            Self::Main => "com.slatehop.managed-host.server",
            Self::Service => "com.slatehop.managed-host.service",
        }
    }

    pub(crate) fn plist_path(self) -> String {
        let directory = match self {
            Self::Main => "/Library/LaunchAgents",
            Self::Service => "/Library/LaunchDaemons",
        };
        format!("{directory}/{}.plist", self.launchd_label())
    }
}

pub(crate) fn role_for_path(path: &Path) -> Option<Role> {
    match path.to_str()? {
        MAIN => Some(Role::Main),
        SERVICE => Some(Role::Service),
        _ => None,
    }
}

pub(crate) fn current_role() -> ResultType<Option<Role>> {
    let executable = std::env::current_exe()?;
    if let Some(role) = role_for_path(&executable) {
        return Ok(Some(role));
    }
    // Guard legacy entry points even when the executable was opened through an alias.
    Ok(role_for_path(&executable.canonicalize()?))
}

pub(crate) fn require_legacy_lifecycle() -> ResultType<()> {
    if current_role()?.is_some() {
        bail!("Use the SlateHop host installer to manage this installation");
    }
    Ok(())
}

pub(crate) fn verify_current_executable(expected: Role) -> ResultType<()> {
    let executable = std::env::current_exe()?;
    if role_for_path(&executable) != Some(expected) || unsafe { hbb_common::libc::geteuid() } != 0 {
        bail!("Managed host operation requires the fixed executable and administrator privileges");
    }
    let entries: Vec<_> = executable.ancestors().collect();
    for entry in entries.into_iter().rev() {
        verify_protected_entry(entry, entry == executable.as_path())?;
    }
    Ok(())
}

pub(crate) fn verify_protected_directory(path: &Path) -> ResultType<()> {
    verify_protected_entry(path, false)
}

fn verify_protected_entry(path: &Path, executable: bool) -> ResultType<()> {
    let metadata = fs::symlink_metadata(path)?;
    let mode = metadata.mode();
    let correct_type = if executable {
        metadata.is_file() && mode & 0o100 != 0 && mode & 0o6000 == 0
    } else {
        metadata.is_dir()
    };
    if !correct_type || metadata.uid() != 0 || mode & 0o022 != 0 {
        bail!("Managed host path is not protected: {}", path.display());
    }
    // The installer also uses Darwin ls -e to require an ACL-free entry.
    // These paths are fixed and contain no characters that can split the listing.
    let output = Command::new("/bin/ls")
        .args(["-lde"])
        .arg(path)
        .env_clear()
        .env("LC_ALL", "C")
        .output()?;
    if !output.status.success() || !output.stderr.is_empty() || !listing_has_no_acl(&output.stdout)
    {
        bail!("Managed host path ACL check failed: {}", path.display());
    }
    Ok(())
}

fn listing_has_no_acl(listing: &[u8]) -> bool {
    let Some(line) = listing.strip_suffix(b"\n") else {
        return false;
    };
    line.get(10)
        .is_some_and(|marker| matches!(marker, b' ' | b'@'))
        && !line.contains(&b'\r')
        && !line.contains(&b'\n')
}

pub(crate) fn launchd_plist(template: &str, role: Role) -> ResultType<String> {
    const LEGACY_WORKING_DIR: &str = "<string>/Applications/RustDesk.app/Contents/MacOS/</string>";
    let (old_label, old_executable) = match role {
        Role::Main => (
            "com.carriez.RustDesk_server",
            "<string>/Applications/RustDesk.app/Contents/MacOS/RustDesk</string>",
        ),
        Role::Service => (
            "com.carriez.RustDesk_service",
            "<string>/Applications/RustDesk.app/Contents/MacOS/service</string>",
        ),
    };
    let old_label = format!("<key>Label</key>\n        <string>{old_label}</string>");
    if template.matches("<key>Label</key>").count() != 1
        || !template.contains(&old_label)
        || template.matches(old_executable).count() != 1
        || template.matches(LEGACY_WORKING_DIR).count() != 1
    {
        bail!("Managed launchd template has an unexpected label, executable or working directory");
    }
    Ok(template
        .replace(
            &old_label,
            &format!(
                "<key>Label</key>\n        <string>{}</string>",
                role.launchd_label()
            ),
        )
        .replace(
            old_executable,
            &format!("<string>{}</string>", role.executable()),
        )
        .replace(LEGACY_WORKING_DIR, &format!("<string>{BIN_DIR}</string>")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requires_a_single_listing_line_without_an_acl() {
        let entry = b"drwxr-xr-x  root wheel /Library\n";
        assert!(listing_has_no_acl(entry));
        assert!(!listing_has_no_acl(
            b"drwxr-xr-x+ root wheel /Library\n 0: group:everyone deny delete\n"
        ));
        assert!(!listing_has_no_acl(b"drwxr-xr-x+ root wheel /Library\n"));
        assert!(!listing_has_no_acl(b""));
        assert!(!listing_has_no_acl(b"drwxr-xr-x  root wheel /Library"));
    }

    #[test]
    fn recognizes_only_the_two_managed_executable_paths() {
        assert_eq!(
            role_for_path(Path::new(
                "/Library/SlateHopHost/RustDesk.app/Contents/MacOS/RustDesk"
            )),
            Some(Role::Main)
        );
        assert_eq!(
            role_for_path(Path::new(
                "/Library/SlateHopHost/RustDesk.app/Contents/MacOS/service"
            )),
            Some(Role::Service)
        );
        for path in [
            "/Applications/RustDesk.app/Contents/MacOS/RustDesk",
            "/Applications/RustDesk.app/Contents/MacOS/service",
            "/Library/SlateHopHostBackup/RustDesk.app/Contents/MacOS/service",
            "/private/Library/SlateHopHost/RustDesk.app/Contents/MacOS/service",
            "/Library/SlateHopHost/RustDesk.app/Contents/MacOS/service.old",
            "/Library/SlateHopHost/RustDesk.app/Contents/MacOS//service",
            "/Library/SlateHopHost/RustDesk.app/Contents/MacOS/rustdesk",
        ] {
            assert_eq!(role_for_path(Path::new(path)), None, "{path}");
        }
    }

    #[test]
    fn expands_only_managed_launchd_label_program_and_working_directory() {
        let daemon = include_str!("privileges_scripts/daemon.plist");
        let agent = include_str!("privileges_scripts/agent.plist");
        for (role, template, old_label, label, plist_path) in [
            (
                Role::Service,
                daemon,
                "com.carriez.RustDesk_service",
                "com.slatehop.managed-host.service",
                "/Library/LaunchDaemons/com.slatehop.managed-host.service.plist",
            ),
            (
                Role::Main,
                agent,
                "com.carriez.RustDesk_server",
                "com.slatehop.managed-host.server",
                "/Library/LaunchAgents/com.slatehop.managed-host.server.plist",
            ),
        ] {
            let plist = launchd_plist(template, role).unwrap();
            assert_eq!(role.plist_path(), plist_path);
            assert!(plist.contains(&format!("<string>{label}</string>")));
            assert!(plist.contains(&format!("<string>{}</string>", role.executable())));
            assert!(plist
                .contains("<string>/Library/SlateHopHost/RustDesk.app/Contents/MacOS/</string>"));
            assert!(!plist.contains("/Applications/"));
            assert_eq!(
                plist
                    .replace(
                        "/Library/SlateHopHost/RustDesk.app/",
                        "/Applications/RustDesk.app/"
                    )
                    .replace(label, old_label),
                template
            );
        }
        assert!(launchd_plist(
            &daemon.replace("com.carriez.RustDesk_service", "com.example.service"),
            Role::Service,
        )
        .is_err());
        assert!(launchd_plist(daemon, Role::Main).is_err());
        assert!(launchd_plist(&format!("{agent}{agent}"), Role::Main).is_err());
    }
}
