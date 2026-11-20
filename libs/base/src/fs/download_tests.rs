use super::*;

struct DownloadDir(PathBuf);

impl DownloadDir {
    fn new() -> Self {
        static NEXT_DIRECTORY: AtomicI32 = AtomicI32::new(1);
        let sequence = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "rustdesk_download_{}_{nonce}_{sequence}",
            std::process::id()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn job(&self) -> TransferJob {
        self.job_with_files(vec![FileEntry {
            size: 8,
            ..Default::default()
        }])
    }

    fn job_with_files(&self, files: Vec<FileEntry>) -> TransferJob {
        self.job_with_direction(files, true)
    }

    fn job_with_direction(&self, files: Vec<FileEntry>, is_remote: bool) -> TransferJob {
        TransferJob::new_write(
            1,
            JobType::Generic,
            "/remote/file.txt".into(),
            DataSource::FilePath(self.0.join("file.txt")),
            0,
            false,
            is_remote,
            true,
        )
        .with_files(files)
        .unwrap()
    }
}

impl Drop for DownloadDir {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}

fn block() -> FileTransferBlock {
    FileTransferBlock {
        id: 1,
        file_num: 0,
        data: b"received".to_vec().into(),
        ..Default::default()
    }
}

fn approval(file_num: i32, offset: u32) -> FileTransferSendConfirmRequest {
    FileTransferSendConfirmRequest {
        id: 1,
        file_num,
        union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(offset)),
        ..Default::default()
    }
}

#[test]
fn download_listing_rejects_unsafe_names_and_keeps_drive_rows() {
    for name in ["../outside", "/outside", ".", "..", "", "dir/file"] {
        let entry = FileEntry {
            name: name.into(),
            ..Default::default()
        };
        assert!(
            download::validate_listing(&[entry], false).is_err(),
            "{}",
            name
        );
    }
    let entries = [
        FileEntry {
            name: "report.txt".into(),
            ..Default::default()
        },
        FileEntry {
            name: "report:notes".into(),
            ..Default::default()
        },
        FileEntry {
            name: "C:".into(),
            entry_type: FileType::DirDrive.into(),
            ..Default::default()
        },
    ];
    download::validate_listing(&entries, true).unwrap();
}

#[tokio::test]
async fn download_requires_confirmation_to_overwrite() {
    let dir = DownloadDir::new();
    let target = dir.0.join("file.txt");
    std::fs::write(&target, b"original").unwrap();
    let mut job = dir.job();
    assert!(job.write(block()).await.is_err());
    assert_eq!(std::fs::read(&target).unwrap(), b"original");
    assert!(!dir.0.join("file.txt.download").exists());

    job.confirm(&approval(0, 0)).await;
    job.write(block()).await.unwrap();
    assert!(job.set_files(vec![FileEntry::default()]).is_err());
    job.finish_download().unwrap();
    assert_eq!(std::fs::read(&target).unwrap(), b"received");
}

#[tokio::test]
async fn download_requires_separate_confirmation_for_each_existing_file() {
    let dir = DownloadDir::new();
    let mut job = dir.job_with_files(vec![
        FileEntry {
            name: "first.txt".into(),
            size: 8,
            ..Default::default()
        },
        FileEntry {
            name: "second.txt".into(),
            size: 8,
            ..Default::default()
        },
    ]);
    job.write(block()).await.unwrap();
    let second = dir.0.join("file.txt/second.txt");
    std::fs::write(&second, b"original").unwrap();
    assert!(job
        .write(FileTransferBlock {
            file_num: 1,
            ..block()
        })
        .await
        .is_err());
    assert_eq!(std::fs::read(&second).unwrap(), b"original");
    assert_eq!(
        std::fs::read(dir.0.join("file.txt/first.txt")).unwrap(),
        b"received"
    );
    job.confirm(&approval(1, 0)).await;
    job.write(FileTransferBlock {
        file_num: 1,
        ..block()
    })
    .await
    .unwrap();
    job.finish_download().unwrap();
    assert_eq!(std::fs::read(&second).unwrap(), b"received");
}

#[tokio::test]
async fn download_preserves_received_files_when_publication_fails() {
    for next_is_digest in [false, true] {
        let dir = DownloadDir::new();
        let files = ["first.txt", "second.txt"]
            .iter()
            .map(|&name| FileEntry {
                name: name.into(),
                size: 8,
                ..Default::default()
            })
            .collect();
        let mut job = dir.job_with_files(files);
        job.write(block()).await.unwrap();
        let target = dir.0.join("file.txt/first.txt");
        std::fs::write(&target, b"existing").unwrap();
        if next_is_digest {
            assert!(job
                .download_digest(
                    true,
                    &FileTransferDigest {
                        id: 1,
                        file_num: 1,
                        ..Default::default()
                    },
                )
                .is_err());
        } else {
            assert!(job
                .write(FileTransferBlock {
                    file_num: 1,
                    ..block()
                })
                .await
                .is_err());
        }
        job.remove_download_file();
        assert_eq!(std::fs::read(target).unwrap(), b"existing");
        assert_eq!(
            std::fs::read(dir.0.join("file.txt/first.txt.download")).unwrap(),
            b"received"
        );
        assert!(dir.0.join("file.txt/first.txt.digest").exists());
    }
}

#[tokio::test]
async fn download_recovers_interrupted_transfer() {
    for (is_remote, resuming, changed) in [
        (false, false, false),
        (false, true, true),
        (false, true, false),
        (true, false, false),
        (true, true, true),
        (true, true, false),
    ] {
        let dir = DownloadDir::new();
        let mut digest = FileTransferDigest {
            id: 1,
            file_size: block().data.len() as _,
            last_modified: 1,
            ..Default::default()
        };
        let mut interrupted = dir.job_with_direction(
            vec![FileEntry {
                size: 8,
                ..Default::default()
            }],
            is_remote,
        );
        interrupted.set_digest(digest.file_size, digest.last_modified);
        let partial = FileTransferBlock {
            data: b"rec".to_vec().into(),
            ..block()
        };
        interrupted.write(partial).await.unwrap();
        drop(interrupted);

        let mut job = dir.job_with_direction(
            vec![FileEntry {
                size: 8,
                ..Default::default()
            }],
            is_remote,
        );
        job.is_resume = resuming;
        digest.last_modified += u64::from(changed);
        job.set_digest(digest.file_size, digest.last_modified);
        let confirmation = match job.download_digest(true, &digest).unwrap() {
            DigestCheckResult::NeedConfirm(confirmation) => confirmation,
            _ => panic!("interrupted download must require confirmation"),
        };
        let offset = if resuming && !changed {
            b"rec".len()
        } else {
            0
        };
        assert_eq!(confirmation.is_identical, offset > 0);
        assert_eq!(confirmation.transferred_size, offset as u64);
        assert!(job.write(block()).await.is_err());
        assert_eq!(
            std::fs::read(dir.0.join("file.txt.download")).unwrap(),
            b"rec"
        );
        job.confirm(&approval(0, offset as _)).await;
        job.write(FileTransferBlock {
            data: block().data.slice(offset..),
            ..block()
        })
        .await
        .unwrap();
        job.finish_download().unwrap();
        assert_eq!(std::fs::read(dir.0.join("file.txt")).unwrap(), b"received");
    }
}

#[tokio::test]
async fn download_does_not_publish_or_remove_unreceived_staging_files() {
    let dir = DownloadDir::new();
    let target = dir.0.join("file.txt");
    let staging = dir.0.join("file.txt.download");
    std::fs::write(&target, b"original").unwrap();
    std::fs::write(&staging, b"another transfer").unwrap();
    let job = dir.job();
    job.modify_time();
    job.remove_download_file();
    assert_eq!(std::fs::read(&target).unwrap(), b"original");
    assert_eq!(std::fs::read(&staging).unwrap(), b"another transfer");

    let metadata_only = DownloadDir::new();
    let metadata = metadata_only.0.join("file.txt.digest");
    std::fs::write(&metadata, b"unrelated file").unwrap();
    assert!(metadata_only.job().write(block()).await.is_err());
    assert_eq!(std::fs::read(metadata).unwrap(), b"unrelated file");
}

#[test]
#[cfg(windows)]
fn download_rejects_windows_streams_and_ambiguous_components() {
    let dir = DownloadDir::new();
    for name in ["nested/file:stream", "nested/.. /outside", "nested/file."] {
        assert!(
            download::validated_target(&dir.0.join("docs"), name).is_err(),
            "{}",
            name
        );
    }
}

#[tokio::test]
#[cfg_attr(windows, ignore = "requires symlink privilege")]
async fn download_refuses_symlink_destination_directory() {
    let dir = DownloadDir::new();
    let outside = dir.0.join("outside");
    let link = dir.0.join("file.txt");
    std::fs::create_dir_all(&outside).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&outside, &link).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_dir(&outside, &link).unwrap();
    let mut job = dir.job_with_files(vec![FileEntry {
        name: "child.txt".into(),
        ..Default::default()
    }]);
    assert!(job.write(block()).await.is_err());
    job.modify_time();
    assert!(!outside.join("child.txt").exists());
    assert!(!outside.join("child.txt.download").exists());
}

#[tokio::test]
#[cfg_attr(windows, ignore = "requires symlink privilege")]
async fn download_refuses_linked_target_and_staging_files() {
    for suffix in ["", ".download", ".digest"] {
        let dir = DownloadDir::new();
        let outside = dir.0.join("outside.txt");
        let link = dir.0.join(format!("file.txt{suffix}"));
        std::fs::write(&outside, b"original").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(&outside, &link).unwrap();
        let mut job = dir.job();
        assert!(job.write(block()).await.is_err());
        job.modify_time();
        job.remove_download_file();
        assert_eq!(std::fs::read(&outside).unwrap(), b"original");
        assert!(std::fs::symlink_metadata(link)
            .unwrap()
            .file_type()
            .is_symlink());
    }
}

#[tokio::test]
async fn incomplete_file_is_never_published_in_either_direction() {
    for is_remote in [false, true] {
        for next_file in [false, true] {
            let dir = DownloadDir::new();
            let target = dir.0.join("file.txt/first.txt");
            std::fs::create_dir_all(target.parent().unwrap()).unwrap();
            std::fs::write(&target, b"original").unwrap();
            let mut job = TransferJob::new_write(
                1,
                JobType::Generic,
                "/remote".into(),
                DataSource::FilePath(dir.0.join("file.txt")),
                0,
                false,
                is_remote,
                true,
            )
            .with_files(vec![
                FileEntry {
                    name: "first.txt".into(),
                    size: 8,
                    ..Default::default()
                },
                FileEntry {
                    name: "second.txt".into(),
                    size: 8,
                    ..Default::default()
                },
            ])
            .unwrap();
            job.download_digest(
                false,
                &FileTransferDigest {
                    id: 1,
                    file_size: 8,
                    ..Default::default()
                },
            )
            .unwrap();
            job.confirm(&approval(0, 0)).await;
            job.write(FileTransferBlock {
                data: b"rec".to_vec().into(),
                ..block()
            })
            .await
            .unwrap();
            let result = if next_file {
                job.download_digest(
                    false,
                    &FileTransferDigest {
                        id: 1,
                        file_num: 1,
                        file_size: 8,
                        ..Default::default()
                    },
                )
                .map(|_| ())
            } else {
                job.finish_download()
            };
            assert!(
                result.is_err(),
                "partial file was accepted: remote={}, next={}",
                is_remote,
                next_file
            );
            job.remove_download_file();
            assert_eq!(std::fs::read(&target).unwrap(), b"original");
            assert!(!target.with_extension("txt.download").exists());
            assert!(!target.with_extension("txt.digest").exists());
        }
    }
}

#[tokio::test]
async fn upload_requires_confirmation_and_cancellation_preserves_destination() {
    let dir = DownloadDir::new();
    let target = dir.0.join("file.txt");
    std::fs::write(&target, b"original").unwrap();
    let mut job = TransferJob::new_write(
        1,
        JobType::Generic,
        "/remote".into(),
        DataSource::FilePath(target.clone()),
        0,
        false,
        false,
        true,
    )
    .with_files(vec![FileEntry {
        size: 8,
        ..Default::default()
    }])
    .unwrap();
    assert!(
        job.write(block()).await.is_err(),
        "unconfirmed upload opened staging"
    );
    job.confirm(&approval(0, 0)).await;
    job.write(block()).await.unwrap();
    job.remove_download_file();
    assert_eq!(std::fs::read(&target).unwrap(), b"original");
    assert!(!dir.0.join("file.txt.download").exists());
    assert!(!dir.0.join("file.txt.digest").exists());
}

#[tokio::test]
async fn cancelling_one_transfer_keeps_other_transfers_and_completed_files() {
    for is_remote in [false, true] {
        let dir = DownloadDir::new();
        let mut jobs = Vec::new();
        for (id, name) in [(1, "cancelled.txt"), (2, "finished.txt"), (3, "other.txt")] {
            let mut job = TransferJob::new_write(
                id,
                JobType::Generic,
                "/remote".into(),
                DataSource::FilePath(dir.0.join(name)),
                0,
                false,
                is_remote,
                true,
            )
            .with_files(vec![FileEntry {
                size: 8,
                ..Default::default()
            }])
            .unwrap();
            job.write(FileTransferBlock { id, ..block() })
                .await
                .unwrap();
            jobs.push(job);
        }
        remove_job(2, &mut jobs).unwrap().finish_download().unwrap();
        remove_job(1, &mut jobs).unwrap().remove_download_file();
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].id(), 3);
        jobs.pop().unwrap().finish_download().unwrap();
        assert!(!dir.0.join("cancelled.txt").exists());
        assert!(!dir.0.join("cancelled.txt.download").exists());
        assert!(!dir.0.join("cancelled.txt.digest").exists());
        for name in ["finished.txt", "other.txt"] {
            assert_eq!(std::fs::read(dir.0.join(name)).unwrap(), b"received");
        }
    }
}

#[tokio::test]
async fn disconnect_cleans_only_current_partial_file_in_multi_file_transfer() {
    for is_remote in [false, true] {
        let dir = DownloadDir::new();
        let mut job = TransferJob::new_write(
            1,
            JobType::Generic,
            "/remote".into(),
            DataSource::FilePath(dir.0.join("batch")),
            0,
            false,
            is_remote,
            true,
        )
        .with_files(
            ["first.txt", "second.txt"]
                .iter()
                .map(|name| FileEntry {
                    name: (*name).into(),
                    size: 8,
                    ..Default::default()
                })
                .collect(),
        )
        .unwrap();
        job.write(block()).await.unwrap();
        job.write(FileTransferBlock {
            file_num: 1,
            data: b"rec".to_vec().into(),
            ..block()
        })
        .await
        .unwrap();
        job.remove_download_file();
        assert_eq!(
            std::fs::read(dir.0.join("batch/first.txt")).unwrap(),
            b"received"
        );
        assert!(!dir.0.join("batch/second.txt").exists());
        assert!(!dir.0.join("batch/second.txt.download").exists());
        assert!(!dir.0.join("batch/second.txt.digest").exists());
    }
}

#[tokio::test]
async fn read_job_open_error_is_terminal_instead_of_sending_late_done() {
    for fail_during_read in [false, true] {
        let dir = DownloadDir::new();
        let source = dir.0.join("source.txt");
        std::fs::write(&source, b"received").unwrap();
        let mut jobs = vec![TransferJob::new_read(
            11,
            JobType::Generic,
            "/remote".into(),
            DataSource::FilePath(source.clone()),
            0,
            false,
            false,
            false,
        )
        .unwrap()];
        std::fs::remove_file(&source).unwrap();
        if fail_during_read {
            std::fs::create_dir(&source).unwrap();
        }
        let listener = hbb_common::tcp::new_listener("127.0.0.1:0", false)
            .await
            .unwrap();
        let addr = listener.local_addr().unwrap();
        let (peer, accepted) = tokio::join!(
            hbb_common::socket_client::connect_tcp(addr.to_string(), 3000),
            listener.accept()
        );
        let (accepted, far_addr) = accepted.unwrap();
        let mut far = Stream::Tcp(hbb_common::tcp::FramedStream::from(accepted, far_addr));
        let mut peer = peer.unwrap();
        let log = handle_read_jobs(&mut jobs, &mut peer).await.unwrap();
        let log: serde_json::Value = serde_json::from_str(&log).unwrap();
        assert_eq!(log["id"], 11);
        assert_eq!(log["done"], false);
        assert!(!log["error"].as_str().unwrap().is_empty());
        assert!(jobs.is_empty(), "failed read job can still emit Done");
        use hbb_common::protobuf::Message as _;
        let error = hbb_common::timeout(300, far.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let message = Message::parse_from_bytes(&error).unwrap();
        assert!(!message.file_response().error().error.is_empty());
        handle_read_jobs(&mut jobs, &mut peer).await.unwrap();
        assert!(hbb_common::timeout(50, far.next()).await.is_err());
    }
}

#[tokio::test]
async fn zero_length_file_is_published_in_either_direction() {
    for is_remote in [false, true] {
        let dir = DownloadDir::new();
        let mut job = dir.job_with_direction(vec![FileEntry::default()], is_remote);
        job.write(FileTransferBlock {
            data: Vec::new().into(),
            ..block()
        })
        .await
        .unwrap();
        job.finish_download().unwrap();
        assert_eq!(std::fs::metadata(dir.0.join("file.txt")).unwrap().len(), 0);
    }
}
