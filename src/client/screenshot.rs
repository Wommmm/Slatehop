#[cfg(not(any(target_os = "android", target_os = "ios")))]
use crate::clipboard::{update_clipboard, ClipboardSide};
use base::message_proto::*;
use hbb_common::ResultType;
use std::{collections::HashMap, io::Write, sync::Mutex};

#[cfg(not(feature = "flutter"))]
lazy_static::lazy_static! {
    static ref SCREENSHOT: Mutex<Screenshot> = Default::default();
}

lazy_static::lazy_static! {
    static ref REQUESTS: Mutex<ScreenshotRequests> = Default::default();
}

pub enum ScreenshotAction {
    SaveAs(String),
    CopyToClipboard,
    Discard,
}

impl Default for ScreenshotAction {
    fn default() -> Self {
        Self::Discard
    }
}

impl From<&str> for ScreenshotAction {
    fn from(value: &str) -> Self {
        match value.chars().next() {
            Some('0') => {
                if let Some((pos, _)) = value.char_indices().nth(2) {
                    let substring = &value[pos..];
                    Self::SaveAs(substring.to_string())
                } else {
                    Self::default()
                }
            }
            Some('1') => Self::CopyToClipboard,
            Some('2') => Self::default(),
            _ => Self::default(),
        }
    }
}

impl Into<String> for ScreenshotAction {
    fn into(self) -> String {
        match self {
            Self::SaveAs(p) => format!("0:{p}"),
            Self::CopyToClipboard => "1".to_owned(),
            Self::Discard => "2".to_owned(),
        }
    }
}

#[derive(Default)]
pub struct Screenshot {
    data: Option<bytes::Bytes>,
}

impl Screenshot {
    fn set_screenshot(&mut self, data: bytes::Bytes) {
        self.data.replace(data);
    }

    fn handle_screenshot(&mut self, action: String) -> String {
        let Some(data) = self.data.as_ref().cloned() else {
            return "No cached screenshot".to_owned();
        };
        match Self::handle_screenshot_(data, action) {
            Ok(()) => {
                self.data = None;
                "".to_owned()
            }
            Err(e) => e.to_string(),
        }
    }

    fn handle_screenshot_(data: bytes::Bytes, action: String) -> ResultType<()> {
        match ScreenshotAction::from(&action as &str) {
            ScreenshotAction::SaveAs(p) => {
                save_image(&p, &data)?;
            }
            ScreenshotAction::CopyToClipboard => {
                #[cfg(not(any(target_os = "android", target_os = "ios")))]
                {
                    let clips = vec![Clipboard {
                        compress: false,
                        content: data,
                        format: ClipboardFormat::ImagePng.into(),
                        ..Default::default()
                    }];
                    update_clipboard(clips, ClipboardSide::Client);
                }
            }
            ScreenshotAction::Discard => {}
        }
        Ok(())
    }
}

// Stage the complete PNG beside the destination before replacing it. A failed
// write must not truncate a previous screenshot selected in the Save As panel.
fn save_image(path: &str, data: &[u8]) -> ResultType<()> {
    let destination = std::path::Path::new(path);
    let parent = destination
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."));
    let temporary = parent.join(format!(".rustdesk-screenshot-{}.tmp", uuid::Uuid::new_v4()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    let result = (|| -> ResultType<()> {
        file.write_all(data)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, destination)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

struct ScreenshotRequest {
    token: String,
    image: Screenshot,
    received: bool,
}

#[derive(Default)]
struct ScreenshotRequests {
    sessions: HashMap<String, ScreenshotRequest>,
}

impl ScreenshotRequests {
    fn begin(&mut self, session: &str) -> String {
        if self.sessions.contains_key(session) {
            return "Screenshot already in progress".to_owned();
        }
        let token = format!("screenshot:{}", uuid::Uuid::new_v4());
        self.sessions.insert(
            session.to_owned(),
            ScreenshotRequest {
                token: token.clone(),
                image: Screenshot::default(),
                received: false,
            },
        );
        token
    }

    fn pending(&self, session: &str) -> Option<String> {
        self.sessions
            .get(session)
            .filter(|r| !r.received)
            .map(|r| r.token.clone())
    }

    fn receive(&mut self, token: &str, data: bytes::Bytes, success: bool) -> Option<String> {
        let owner = self
            .sessions
            .iter()
            .find(|(_, r)| r.token == token && !r.received)
            .map(|(s, _)| s.clone())?;
        if success {
            let request = self.sessions.get_mut(&owner)?;
            request.received = true;
            request.image.set_screenshot(data);
        } else {
            self.sessions.remove(&owner);
        }
        Some(owner)
    }

    fn close(&mut self, session: &str) {
        self.sessions.remove(session);
    }

    fn handle(&mut self, session: &str, action: &str) -> String {
        if action == "begin" {
            return self.begin(session);
        }
        let Some((token, command)) = action.split_once('|') else {
            return "Invalid screenshot request".to_owned();
        };
        let Some(request) = self.sessions.get_mut(session).filter(|r| r.token == token) else {
            return "Screenshot request is no longer active".to_owned();
        };
        if command == "2" {
            self.sessions.remove(session);
            return String::new();
        }
        if !command.starts_with("0:") || command.len() <= 2 {
            return "Invalid screenshot action".to_owned();
        }
        let result = request.image.handle_screenshot(command.to_owned());
        if result.is_empty() {
            self.sessions.remove(session);
        }
        result
    }
}

pub fn pending_request(session: &str) -> Option<String> {
    REQUESTS.lock().unwrap().pending(session)
}

pub fn receive_screenshot(token: &str, data: bytes::Bytes, success: bool) -> Option<String> {
    REQUESTS.lock().unwrap().receive(token, data, success)
}

pub fn handle_session_screenshot(session: &str, action: &str) -> String {
    REQUESTS.lock().unwrap().handle(session, action)
}

pub fn close_screenshot_session(session: &str) {
    REQUESTS.lock().unwrap().close(session);
}

#[cfg(not(feature = "flutter"))]
pub fn set_screenshot(data: bytes::Bytes) {
    SCREENSHOT.lock().unwrap().set_screenshot(data);
}

#[cfg(not(feature = "flutter"))]
pub fn handle_screenshot(action: String) -> String {
    SCREENSHOT.lock().unwrap().handle_screenshot(action)
}

#[cfg(test)]
mod tests {
    use super::Screenshot;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn preserves_cached_screenshot_when_save_fails() {
        let data = bytes::Bytes::from_static(b"screenshot data");
        let mut screenshot = Screenshot {
            data: Some(data.clone()),
        };
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let missing_parent = std::env::temp_dir()
            .join(format!("rustdesk-screenshot-missing-parent-{unique}"))
            .join("screenshot.png");
        let valid_path = std::env::temp_dir().join(format!("rustdesk-screenshot-{unique}.png"));

        let error = screenshot.handle_screenshot(format!("0:{}", missing_parent.display()));

        assert!(!error.is_empty());
        assert_eq!(screenshot.data.as_deref(), Some(data.as_ref()));
        assert_eq!(
            screenshot.handle_screenshot(format!("0:{}", valid_path.display())),
            ""
        );
        assert!(screenshot.data.is_none());
        assert_eq!(std::fs::read(&valid_path).unwrap(), data.as_ref());
        std::fs::remove_file(valid_path).unwrap();
    }
    fn image(value: &'static [u8]) -> bytes::Bytes {
        bytes::Bytes::from_static(value)
    }

    fn directory() -> std::path::PathBuf {
        let p =
            std::env::temp_dir().join(format!("rustdesk-screenshot-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&p).unwrap();
        p
    }

    #[test]
    fn screenshot_sessions_save_and_cancel_independently() {
        let mut requests = super::ScreenshotRequests::default();
        let a = requests.begin("A");
        let b = requests.begin("B");
        assert_eq!(
            requests.receive(&a, image(b"image A"), true),
            Some("A".into())
        );
        assert_eq!(
            requests.receive(&b, image(b"image B"), true),
            Some("B".into())
        );
        assert!(!requests.handle("A", &format!("{b}|2")).is_empty());
        assert_eq!(requests.handle("A", &format!("{a}|2")), "");
        let dir = directory();
        let out = dir.join("B.png");
        assert_eq!(
            requests.handle("B", &format!("{b}|0:{}", out.display())),
            ""
        );
        assert_eq!(std::fs::read(&out).unwrap(), b"image B");
        assert!(requests.sessions.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn screenshot_save_a_does_not_consume_b() {
        let mut requests = super::ScreenshotRequests::default();
        let a = requests.begin("A");
        let b = requests.begin("B");
        requests.receive(&a, image(b"A"), true);
        requests.receive(&b, image(b"B"), true);
        let dir = directory();
        for (owner, token, expected) in [("A", a, b"A"), ("B", b, b"B")] {
            let out = dir.join(format!("{owner}.png"));
            assert_eq!(
                requests.handle(owner, &format!("{token}|0:{}", out.display())),
                ""
            );
            assert_eq!(std::fs::read(out).unwrap(), expected);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn screenshot_close_timeout_and_stale_actions_cannot_consume_new_request() {
        let mut requests = super::ScreenshotRequests::default();
        let old = requests.begin("A");
        requests.close("A");
        let current = requests.begin("A");
        assert_ne!(old, current);
        assert!(requests.receive(&old, image(b"old"), true).is_none());
        assert!(!requests.handle("A", &format!("{old}|2")).is_empty());
        assert_eq!(requests.pending("A"), Some(current.clone()));
        assert_eq!(requests.handle("A", &format!("{current}|2")), "");
        let next = requests.begin("A");
        assert!(requests.receive(&current, image(b"late"), true).is_none());
        assert_eq!(requests.pending("A"), Some(next));
    }

    #[test]
    fn screenshot_repeated_capture_and_duplicate_response_preserve_snapshot() {
        let mut requests = super::ScreenshotRequests::default();
        let token = requests.begin("A");
        assert!(!requests.begin("A").starts_with("screenshot:"));
        requests.receive(&token, image(b"original"), true);
        assert!(requests.pending("A").is_none());
        assert!(!requests.begin("A").starts_with("screenshot:"));
        assert!(requests
            .receive(&token, image(b"duplicate"), true)
            .is_none());
        assert_eq!(
            requests.sessions["A"].image.data.as_deref(),
            Some(&b"original"[..])
        );
    }

    #[test]
    fn screenshot_failed_save_retries_original_and_preserves_existing_destination() {
        let mut requests = super::ScreenshotRequests::default();
        let token = requests.begin("A");
        requests.receive(&token, image(b"new image"), true);
        let dir = directory();
        let missing = dir.join("missing/image.png");
        assert!(!requests
            .handle("A", &format!("{token}|0:{}", missing.display()))
            .is_empty());
        let existing = dir.join("existing.png");
        std::fs::write(&existing, b"old image").unwrap();
        // A failed rename (directory destination) leaves both the snapshot and
        // unrelated existing output intact and removes its staging file.
        assert!(!requests
            .handle("A", &format!("{token}|0:{}", dir.display()))
            .is_empty());
        assert_eq!(std::fs::read(&existing).unwrap(), b"old image");
        assert_eq!(
            requests.handle("A", &format!("{token}|0:{}", existing.display())),
            ""
        );
        assert_eq!(std::fs::read(&existing).unwrap(), b"new image");
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn screenshot_failure_and_malformed_actions_do_not_affect_other_requests() {
        let mut requests = super::ScreenshotRequests::default();
        let a = requests.begin("A");
        let b = requests.begin("B");
        assert!(!requests.handle("A", "2").is_empty());
        assert!(!requests.handle("A", &format!("{a}|garbage")).is_empty());
        assert_eq!(requests.receive(&a, image(b""), false), Some("A".into()));
        assert_eq!(requests.pending("B"), Some(b));
        assert!(requests.begin("A").starts_with("screenshot:"));
    }
}
