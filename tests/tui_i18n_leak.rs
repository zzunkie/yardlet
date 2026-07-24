use std::path::Path;

fn production_source(path: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(path);
    let source = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("could not read {}: {error}", path.display()));
    source
        .split("#[cfg(test)]\nmod tests")
        .next()
        .unwrap_or(&source)
        .to_string()
}

#[test]
fn tui_generated_chrome_does_not_bypass_the_i18n_boundary() {
    let cases = [
        (
            "src/ui/view.rs",
            [
                r#"format!("task {}"#,
                r#"format!("worker {}"#,
                r#""(default)""#,
                r#""No workspace state loaded.""#,
                r#""(no reports yet)""#,
            ]
            .as_slice(),
        ),
        (
            "src/ui/mod.rs",
            [
                r#"format!("current "#,
                r#"format!("follow-up {}"#,
                r#"follow-up: {}"#,
                r#"format!("question: "#,
                r#"format!("user: "#,
            ]
            .as_slice(),
        ),
        (
            "src/run.rs",
            [r#""done:"#, r#""stopped:"#, r#"format!("running {task_id}"#].as_slice(),
        ),
    ];

    let mut leaks = Vec::new();
    for (path, forbidden) in cases {
        let source = production_source(path);
        for needle in forbidden {
            if source.contains(needle) {
                leaks.push(format!("{path}: {needle}"));
            }
        }
    }

    assert!(
        leaks.is_empty(),
        "TUI-owned strings bypassed src/ui/i18n.rs:\n{}",
        leaks.join("\n")
    );
}
