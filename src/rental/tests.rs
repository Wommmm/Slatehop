use super::*;

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
