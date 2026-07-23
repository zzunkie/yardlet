#[cfg(unix)]
mod unix {
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct Fixture {
        base: PathBuf,
        workspace: PathBuf,
        external: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let base = std::env::temp_dir().join(format!(
                "yardlet-init-symlink-process-{}-{nonce}",
                std::process::id()
            ));
            let workspace = base.join("workspace");
            let external = base.join("external");
            fs::create_dir_all(workspace.join(".agents")).unwrap();
            fs::create_dir_all(&external).unwrap();
            Self {
                base,
                workspace,
                external,
            }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.base);
        }
    }

    #[test]
    fn init_force_skips_symlink_scaffold_destinations_and_warns() {
        let fixture = Fixture::new();
        let links = [
            ("yardlet.yaml", "yardlet.yaml"),
            ("billing-policy.yaml", "billing-policy.yaml"),
            ("skills/planning-gate/SKILL.md", "planning-gate-SKILL.md"),
            ("hooks/README.md", "hooks-README.md"),
            ("memory/README.md", "memory-README.md"),
        ];

        for (relative, external_name) in links {
            let destination = fixture.workspace.join(".agents").join(relative);
            fs::create_dir_all(destination.parent().unwrap()).unwrap();
            let target = fixture.external.join(external_name);
            fs::write(&target, format!("shared sentinel for {relative}\n")).unwrap();
            symlink(target, destination).unwrap();
        }

        let output = Command::new(env!("CARGO_BIN_EXE_yardlet"))
            .args(["init", "--force"])
            .current_dir(&fixture.workspace)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "yardlet init --force failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );

        for (relative, external_name) in links {
            let destination = fixture.workspace.join(".agents").join(relative);
            assert!(
                fs::symlink_metadata(&destination)
                    .unwrap()
                    .file_type()
                    .is_symlink(),
                "{} must remain a symlink",
                destination.display()
            );
            assert_eq!(
                fs::read_to_string(fixture.external.join(external_name)).unwrap(),
                format!("shared sentinel for {relative}\n"),
                "--force must not overwrite the target of {}",
                destination.display()
            );
        }

        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            stderr
                .matches("warning: skipped scaffold destination symlink")
                .count(),
            links.len(),
            "every skipped scaffold symlink must use the warning channel\nstderr:\n{stderr}"
        );
    }
}
