use super::*;

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn rental_admin_recovers_missing_credentials_and_rejects_corrupt_storage() {
    use std::os::unix::fs::{symlink, PermissionsExt};

    sodiumoxide::init().unwrap();
    let dir = fixture();
    let path = dir.join("credential.toml");
    let salt = "synthetic-salt";
    let storage = encrypted_storage("synthetic-password", salt);
    let policy = Policy {
        version: 1,
        credential_binding: binding(&storage, salt).unwrap(),
        valid_from_ms: 100,
        valid_until_ms: 200,
    };
    let needs_recovery = |memory, salt| admin_credential_recovery(&policy, memory, salt, &path);
    assert!(needs_recovery(&storage, salt).unwrap());
    let valid = format!("password = \"{storage}\"\nsalt = \"{salt}\"\n");
    write_private(&path, valid.as_bytes()).unwrap();
    assert!(!needs_recovery(&storage, salt).unwrap());
    assert!(needs_recovery("", salt).unwrap());
    assert!(needs_recovery(&storage, "").unwrap());
    assert!(needs_recovery("unsupported", "").is_err());

    for missing in ["id = 'fixture'", "password = ''\nsalt = ''"] {
        write_private(&path, missing.as_bytes()).unwrap();
        assert!(needs_recovery(&storage, salt).unwrap());
    }
    write_private(&path, format!("password = \"{storage}\"").as_bytes()).unwrap();
    assert!(needs_recovery(&storage, salt).unwrap());
    for corrupt in [
        "password = [",
        "password = 17",
        "salt = false",
        "password = 'unsupported'",
    ] {
        write_private(&path, corrupt.as_bytes()).unwrap();
        assert!(needs_recovery("", "").is_err());
    }

    write_private(&path, valid.as_bytes()).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(needs_recovery("", "").is_err());
    fs::remove_file(&path).unwrap();
    symlink(dir.join("missing-target"), &path).unwrap();
    assert!(needs_recovery("", "").is_err());
    fs::remove_dir_all(dir).unwrap();
    assert!(needs_recovery("", "").is_err());
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn rental_fenced_transaction_rejects_late_work_and_drains_running_write() {
    use std::{sync::mpsc, thread, time::Duration};

    let dir = fixture();
    let pending = dir.join("pending");
    let uid = serving_uid();
    let old = "0123456789abcdef0123456789abcdef";
    let next = "abcdef0123456789abcdef0123456789";
    write_owned(&pending, old.as_bytes(), uid, 0o644).unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let (waiting_tx, waiting_rx) = mpsc::channel();
    let (drained_tx, drained_rx) = mpsc::channel();
    thread::scope(|scope| {
        let pending = pending.as_path();
        scope.spawn(move || {
            with_provision_transaction(pending, uid, old, || {
                started_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(2)).unwrap();
                Ok(())
            })
            .unwrap();
        });
        started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        fence_transaction(pending, uid).unwrap();
        scope.spawn(move || {
            waiting_tx.send(()).unwrap();
            provision_barrier().unwrap();
            drained_tx.send(()).unwrap();
        });
        waiting_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let before_release = drained_rx.recv_timeout(Duration::from_millis(50));
        release_tx.send(()).unwrap();
        assert_eq!(before_release, Err(mpsc::RecvTimeoutError::Timeout));
        drained_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let try_stale = || {
            with_provision_transaction(pending, uid, old, || -> ResultType<()> {
                panic!("fenced request reached persistence")
            })
        };
        assert!(try_stale().is_err());
        write_owned(pending, next.as_bytes(), uid, 0o644).unwrap();
        assert!(try_stale().is_err());
        assert_eq!(
            with_provision_transaction(pending, uid, next, || Ok(42)).unwrap(),
            42
        );
    });
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn rental_recovery_requires_trusted_authority_and_preserves_known_window() {
    use std::os::unix::fs::{symlink, PermissionsExt};

    let dir = fixture();
    let marker = dir.join("enabled");
    let snapshot = dir.join("policy");
    let pending = dir.join("pending");
    let uid = serving_uid();
    let inspect = || read_authority(&marker, &snapshot, &pending, uid);
    assert_eq!(inspect().unwrap(), (None, false));
    write_owned(&marker, AUTHORITY_MARKER, uid, 0o644).unwrap();
    let (policy, interrupted) = inspect().unwrap();
    let recovery = AdminStatus::verified(policy.as_ref(), 150, interrupted).unwrap();
    assert_eq!(recovery.state, "recovery_required");
    assert_eq!(
        (recovery.valid_from_ms, recovery.valid_until_ms),
        (None, None)
    );

    let policy = Policy {
        version: 1,
        credential_binding: "ab".repeat(32),
        valid_from_ms: 100,
        valid_until_ms: 200,
    };
    write_owned(&snapshot, &serde_json::to_vec(&policy).unwrap(), uid, 0o644).unwrap();
    let (snapshot_policy, interrupted) = inspect().unwrap();
    assert!(!interrupted);
    let mismatch = credential_binding_mismatch(
        &snapshot_policy.unwrap(),
        &"cd".repeat(32),
        &"ab".repeat(32),
    );
    let recovery = AdminStatus::verified(Some(&policy), 150, mismatch).unwrap();
    assert_eq!(recovery.state, "recovery_required");
    assert_eq!(
        (recovery.valid_from_ms, recovery.valid_until_ms),
        (Some(100), Some(200))
    );
    assert!(!credential_binding_mismatch(
        &policy,
        &"ab".repeat(32),
        &"ab".repeat(32)
    ));
    assert!(credential_binding_mismatch(
        &policy,
        &"ab".repeat(32),
        &"cd".repeat(32)
    ));

    write_owned(&pending, FENCED_TRANSACTION, uid, 0o644).unwrap();
    assert_eq!(inspect().unwrap(), (Some(policy), true));

    fs::set_permissions(&snapshot, fs::Permissions::from_mode(0o666)).unwrap();
    assert!(inspect().is_err());
    fs::remove_file(&snapshot).unwrap();
    symlink(&marker, &snapshot).unwrap();
    assert!(inspect().is_err());
    fs::remove_file(&snapshot).unwrap();
    write_owned(&pending, b"bad", uid, 0o644).unwrap();
    assert!(inspect().is_err());
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn rental_admin_uses_host_time_and_expiry_preserves_binding() {
    let mut policy = Policy {
        version: 1,
        credential_binding: "ab".repeat(32),
        valid_from_ms: 100,
        valid_until_ms: 200,
    };
    let unconfigured = AdminReply {
        status: AdminStatus::from_policy(None, 99).unwrap(),
        password: None,
    };
    assert_eq!(
        serde_json::to_value(&unconfigured).unwrap(),
        serde_json::json!({
            "state": "unconfigured",
            "now_ms": 99,
            "valid_from_ms": null,
            "valid_until_ms": null,
        })
    );
    assert_eq!(
        AdminStatus::from_policy(Some(&policy), 99).unwrap().state,
        "pending"
    );
    assert_eq!(
        AdminStatus::from_policy(Some(&policy), 100).unwrap().state,
        "active"
    );
    assert_eq!(
        AdminStatus::from_policy(Some(&policy), 200).unwrap().state,
        "expired"
    );
    let original = serde_json::to_vec(&policy).unwrap();
    assert!(policy.set_expiry(199, 199).is_err());
    assert!(policy.set_expiry(99, 100).is_err());
    assert!(policy.set_expiry(200, MAX_TIMESTAMP_MS + 1).is_err());
    assert_eq!(serde_json::to_vec(&policy).unwrap(), original);

    let status = policy.set_expiry(200, 300).unwrap();
    assert_eq!(status.state, "active");
    assert_eq!(status.valid_from_ms, Some(100));
    assert_eq!(status.valid_until_ms, Some(300));
    assert_eq!(policy.credential_binding, "ab".repeat(32));
    assert!(serde_json::to_value(status)
        .unwrap()
        .get("password")
        .is_none());
}

#[test]
fn rental_admin_command_rejects_wrong_caller_and_invalid_arguments() {
    let parse = |uid, args: &[&str]| {
        AdminCommand::parse(
            Some(uid),
            &args.iter().map(|arg| arg.to_string()).collect::<Vec<_>>(),
        )
    };
    assert!(parse(501, &["--rental-admin-status"]).is_err());
    assert!(parse(0, &["--rental-admin-status", "1"]).is_err());
    assert!(parse(0, &["--rental-admin-set-expiry", "+123"]).is_err());
    assert!(parse(0, &["--rental-admin-new-password", "0"]).is_err());
    assert!(parse(0, &["--rental-admin-new-password", "253402300800000"]).is_err());
    assert!(matches!(
        parse(0, &["--rental-admin-set-expiry", "123"]),
        Ok(AdminCommand::SetExpiry(123))
    ));
    assert!(matches!(
        parse(0, &["--rental-admin-new-password", "123"]),
        Ok(AdminCommand::NewPassword(123))
    ));
}

#[test]
fn rental_generated_password_uses_the_existing_window_start_on_reset() {
    sodiumoxide::init().unwrap();
    let first = ProvisionRequest::generated(None, 100, 200).unwrap();
    assert_eq!(first.window(), (100, 200));
    let policy = Policy {
        version: 1,
        credential_binding: "ab".repeat(32),
        valid_from_ms: 100,
        valid_until_ms: 200,
    };
    let reset = ProvisionRequest::generated(Some(&policy), 150, 200).unwrap();
    assert_eq!(reset.window(), (100, 200));
    assert_eq!(reset.password.len(), 32);
    assert!(first.password != reset.password);
    assert!(!format!("{reset:?}").contains(&reset.password));
    assert!(ProvisionRequest::generated(Some(&policy), 200, 200).is_err());
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn rental_authority_lock_rejects_overlapping_writers_and_unsafe_paths() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let dir = fixture();
    let path = dir.join("administrator.lock");
    let writer = AuthorityWrite::lock_file(&path).unwrap();
    assert!(AuthorityWrite::lock_file(&path).is_err());
    drop(writer);
    assert!(AuthorityWrite::lock_file(&path).is_ok());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(AuthorityWrite::lock_file(&path).is_err());
    fs::remove_file(&path).unwrap();
    let victim = dir.join("unrelated");
    fs::write(&victim, b"unchanged").unwrap();
    symlink(&victim, &path).unwrap();
    assert!(AuthorityWrite::lock_file(&path).is_err());
    assert_eq!(fs::read(victim).unwrap(), b"unchanged");
    fs::remove_dir_all(dir).unwrap();
}

fn fixture() -> PathBuf {
    let path = std::env::temp_dir().join(format!("rd-rental-test-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&path).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    path
}
fn encrypted_storage(password: &str, salt: &str) -> String {
    let h1 = config::compute_permanent_password_h1(password, salt);
    // Construct the SAME existing permanent-password record format, using its
    // existing local encryption primitive; not a substitute authentication path.
    let plaintext = format!(
        "00{}",
        sodiumoxide::base64::encode(h1, sodiumoxide::base64::Variant::Original)
    );
    let encrypted =
        hbb_common::password_security::symmetric_crypt(plaintext.as_bytes(), true).unwrap();
    format!(
        "01{}",
        sodiumoxide::base64::encode(encrypted, sodiumoxide::base64::Variant::Original)
    )
}

#[test]
fn rental_policy_boundaries_binding_corruption_reload_and_password_priority() {
    let _ = sodiumoxide::init();
    let dir = fixture();
    let path = dir.join("rental.json");
    let salt = "rental-test-salt";
    let storage = encrypted_storage("synthetic-rental-password", salt);
    let policy = Policy {
        version: 1,
        credential_binding: binding(&storage, salt).unwrap(),
        valid_from_ms: 100,
        valid_until_ms: 200,
    };
    write_private(&path, &serde_json::to_vec(&policy).unwrap()).unwrap();
    for now in [100, 150, 199] {
        assert_eq!(
            authorize_at(&path, &storage, salt, true, Ok(now))
                .unwrap()
                .valid_until_ms,
            200
        );
    }
    for now in [0, 99, 200, u64::MAX] {
        assert_eq!(
            authorize_at(&path, &storage, salt, true, Ok(now)),
            Err(AuthError::Validity)
        );
        assert_eq!(
            authorize_at(&path, &storage, salt, false, Ok(now)),
            Err(AuthError::Password)
        );
    }
    assert_eq!(
        authorize_at(&path, &storage, salt, false, Err(anyhow!("clock"))),
        Err(AuthError::Password)
    );
    assert_eq!(
        authorize_at(&path, &storage, salt, true, Err(anyhow!("clock"))),
        Err(AuthError::Validity)
    );
    // Correct legacy proof still receives a policy error, not a false wrong-
    // password result. Provisioning upgrades it to the existing encrypted H1.
    assert_eq!(
        authorize_at(&path, "legacy-storage", salt, true, Ok(150)),
        Err(AuthError::Validity)
    );
    let changed = encrypted_storage("synthetic-replacement", salt);
    assert!(check_at(&path, &changed, salt, 150).is_err());
    assert!(check_at(&path, &storage, "changed-salt", 150).is_err());
    // Actual file reload after replacement, no cached authorization snapshot.
    let renewed = Policy {
        version: 1,
        credential_binding: binding(&changed, salt).unwrap(),
        valid_from_ms: 300,
        valid_until_ms: 700,
    };
    write_private(&path, &serde_json::to_vec(&renewed).unwrap()).unwrap();
    assert!(check_at(&path, &storage, salt, 350).is_err());
    assert_eq!(
        check_at(&path, &changed, salt, 350).unwrap().valid_until_ms,
        700
    );
    for malformed in [
        b"{}".as_slice(),
        b"not-json",
        b"{\"version\":1,\"version\":2}",
        b"[]",
    ] {
        write_private(&path, malformed).unwrap();
        assert_eq!(
            authorize_at(&path, &storage, salt, false, Ok(150)),
            Err(AuthError::Password)
        );
        assert_eq!(
            authorize_at(&path, &storage, salt, true, Ok(150)),
            Err(AuthError::Validity)
        );
    }
    for invalid in [
        Policy {
            version: 2,
            credential_binding: binding(&storage, salt).unwrap(),
            valid_from_ms: 100,
            valid_until_ms: 200,
        },
        Policy {
            version: 1,
            credential_binding: binding(&storage, salt).unwrap(),
            valid_from_ms: 200,
            valid_until_ms: 100,
        },
        Policy {
            version: 1,
            credential_binding: binding(&storage, salt).unwrap(),
            valid_from_ms: 0,
            valid_until_ms: MAX_TIMESTAMP_MS + 1,
        },
        Policy {
            version: 1,
            credential_binding: String::new(),
            valid_from_ms: 100,
            valid_until_ms: 200,
        },
    ] {
        write_private(&path, &serde_json::to_vec(&invalid).unwrap()).unwrap();
        assert_eq!(
            authorize_at(&path, &storage, salt, false, Ok(150)),
            Err(AuthError::Password)
        );
        assert_eq!(
            authorize_at(&path, &storage, salt, true, Ok(150)),
            Err(AuthError::Validity)
        );
    }
    fs::remove_file(&path).unwrap();
    assert_eq!(
        authorize_at(&path, &storage, salt, false, Ok(150)),
        Err(AuthError::Password)
    );
    assert_eq!(
        authorize_at(&path, &storage, salt, true, Ok(150)),
        Err(AuthError::Validity)
    );
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn rental_policy_rejects_unsafe_file_targets_and_keeps_old_bytes() {
    let dir = fixture();
    let path = dir.join("policy");
    write_private(&path, b"old").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(read_owned(&path, serving_uid().wrapping_add(1), 0o022).is_err());
        let link = dir.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(read_private(&link).is_err());
        assert!(write_private(&link, b"new").is_err());
        assert_eq!(fs::read(&path).unwrap(), b"old");
        fs::remove_file(link).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_private(&path).is_err());
    }
    let directory = dir.join("directory");
    fs::create_dir(&directory).unwrap();
    assert!(write_private(&directory, b"bad").is_err());
    assert!(read_private(&directory).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"old");
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn rental_stdin_and_display_metadata_are_strict_and_redacted() {
    assert!(administrator_peer(Some(0)));
    assert!(!administrator_peer(None));
    assert!(!administrator_peer(Some(501)));
    let valid = br#"{"password":"synthetic-secret","valid_from_ms":100,"valid_until_ms":200}"#;
    let request = read_request(&valid[..]).unwrap();
    assert!(!format!("{:?}", request).contains("synthetic-secret"));
    for input in [
        r#"{"password":"x","valid_from_ms":200,"valid_until_ms":200}"#,
        r#"{"password":"","valid_from_ms":0,"valid_until_ms":10}"#,
        r#"{"password":"x","valid_from_ms":-1,"valid_until_ms":10}"#,
        r#"{"password":"x","valid_from_ms":0,"valid_until_ms":10,"extra":true}"#,
        r#"{"password":"do-not-echo", "valid_until_ms":"bad"}"#,
    ] {
        let error = read_request(input.as_bytes()).unwrap_err().to_string();
        assert!(!error.contains("do-not-echo"));
    }
    assert!(read_request(vec![b'x'; MAX_INPUT as usize + 1].as_slice()).is_err());
    for value in ["1", "200", "253402300799999"] {
        assert_eq!(
            peer_deadline(&format!(r#"{{"rental_valid_until_ms":"{value}"}}"#)),
            Some(value.into())
        );
    }
    for input in [
        "",
        "{}",
        r#"{"rental_valid_until_ms":200}"#,
        r#"{"rental_valid_until_ms":"0"}"#,
        r#"{"rental_valid_until_ms":"-1"}"#,
        r#"{"rental_valid_until_ms":"253402300800000"}"#,
        r#"{"rental_valid_until_ms":"1e9"}"#,
    ] {
        assert_eq!(peer_deadline(input), None);
    }
}

#[cfg(target_os = "linux")]
#[test]
fn rental_actual_provisioning_persists_existing_secure_storage_and_fail_closed_marker() {
    // Like native direct lifecycle tests, refuse a normal user profile.
    assert_eq!(
        std::env::var("RD_DIRECT_DISPOSABLE_CONFIG").as_deref(),
        Ok("1")
    );
    assert!(Config::path("").starts_with(std::env::var("HOME").unwrap()));
    let _ = sodiumoxide::init();
    assert_disposable_authority();
    if std::env::var("RD_RENTAL_RELOAD_CHILD").as_deref() == Ok("1") {
        // A fresh OS process initializes Config from the actual encrypted file.
        let (storage, salt) = Config::get_local_permanent_password_storage_and_salt();
        assert!(is_host());
        assert_eq!(
            read_owned(&authority_policy(serving_uid()), 0, 0o022).is_ok(),
            true
        );
        assert_eq!(
            check_at(&policy_path(), &storage, &salt, 300)
                .unwrap()
                .valid_until_ms,
            900
        );
        return;
    }
    let _ = Config::get_salt();
    fs::create_dir_all(Config::file().parent().unwrap()).unwrap();
    let req = read_request(
        br#"{"password":"synthetic-delivery-password","valid_from_ms":100,"valid_until_ms":500}"#
            .as_slice(),
    )
    .unwrap();
    begin_administrator_delivery(serving_uid()).unwrap();
    let prepared = provision(req).unwrap();
    commit_administrator_delivery(serving_uid(), prepared, (100, 500)).unwrap();
    assert!(is_host());
    let (storage, salt) = Config::get_local_permanent_password_storage_and_salt();
    assert!(storage.starts_with("01"));
    assert_eq!(
        check_at(&policy_path(), &storage, &salt, 250)
            .unwrap()
            .valid_until_ms,
        500
    );
    assert_eq!(authorize(|_| false), Err(AuthError::Password));
    // This lease is in the past by the real server clock, despite any client date.
    assert_eq!(authorize(|_| true), Err(AuthError::Validity));
    let policy_bytes = fs::read(policy_path()).unwrap();
    assert!(!String::from_utf8_lossy(&policy_bytes).contains("synthetic-delivery-password"));
    // Config mode edits cannot disable an installed host or a missing policy.
    Config::set_option("rental-host".into(), "N".into());
    fs::remove_file(policy_path()).unwrap();
    assert!(is_host());
    assert!(check_at(&policy_path(), &storage, &salt, 250).is_err());
    // Extending a lease with the SAME desktop password preserves the proof a
    // saved connection already holds; an OS-login password is never substituted.
    let same_password = read_request(
        br#"{"password":"synthetic-delivery-password","valid_from_ms":200,"valid_until_ms":800}"#.as_slice()
    ).unwrap();
    let same_policy = provision(same_password).unwrap();
    commit_administrator_delivery(serving_uid(), same_policy, (200, 800)).unwrap();
    let (same_storage, same_salt) = Config::get_local_permanent_password_storage_and_salt();
    assert_eq!(same_salt, salt);
    assert_eq!(config::decode_permanent_password_h1_from_storage(&same_storage),
               config::decode_permanent_password_h1_from_storage(&storage));
    assert_eq!(check_bytes(&read_owned(&authority_policy(serving_uid()), 0, 0o022).unwrap(),
        &storage, &salt, 600).unwrap().valid_until_ms, 800);

    // Renewal is independently reloaded and credential-bound.
    let req = read_request(
        br#"{"password":"synthetic-renewed-password","valid_from_ms":200,"valid_until_ms":900}"#
            .as_slice(),
    )
    .unwrap();
    let prepared = provision(req).unwrap();
    commit_administrator_delivery(serving_uid(), prepared, (200, 900)).unwrap();
    let (new_storage, new_salt) = Config::get_local_permanent_password_storage_and_salt();
    assert!(check_at(&policy_path(), &storage, &salt, 300).is_err());
    assert_eq!(
        check_at(&policy_path(), &new_storage, &new_salt, 300)
            .unwrap()
            .valid_until_ms,
        900
    );
    let child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "rental::tests::rental_actual_provisioning_persists_existing_secure_storage_and_fail_closed_marker",
            "--test-threads=1"])
        .env("RD_RENTAL_RELOAD_CHILD", "1").status().unwrap();
    assert!(child.success());
    let forged = Policy {
        version: 1,
        credential_binding: binding(&new_storage, &new_salt).unwrap(),
        valid_from_ms: 0,
        valid_until_ms: MAX_TIMESTAMP_MS,
    };
    write_private(&policy_path(), &serde_json::to_vec(&forged).unwrap()).unwrap();
    assert_eq!(
        authorize(|_| true),
        Err(AuthError::Validity),
        "user staging cannot extend root's expired lease"
    );
    // A current root-authorized lease can grant; persisted user dates cannot.
    commit_administrator_delivery(serving_uid(), forged, (0, MAX_TIMESTAMP_MS)).unwrap();
    assert_eq!(
        authorize(|_| true).unwrap().unwrap().valid_until_ms,
        MAX_TIMESTAMP_MS
    );
    assert_eq!(authorize(|_| false), Err(AuthError::Password));
    fs::remove_file(authority_policy(serving_uid())).unwrap();
    assert!(is_host());
    assert_eq!(authorize(|_| true), Err(AuthError::Validity));
    fs::remove_file(authority_marker(serving_uid())).unwrap();
    fs::remove_file(policy_path()).unwrap();
    fs::remove_file(marker_path()).unwrap();
    Config::set_option("rental-host".into(), "".into());
}
