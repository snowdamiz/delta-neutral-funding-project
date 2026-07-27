use std::error::Error;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn shadow_cli_emits_planned_report() -> Result<(), Box<dyn Error>> {
    let vectors = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/vectors");
    let output = Command::new(env!("CARGO_BIN_EXE_funding-collector-signer"))
        .args([
            "shadow",
            "--intent",
            vectors.join("shadow-intent-v1.json").to_str().unwrap(),
            "--action",
            vectors.join("shadow-action-v1.json").to_str().unwrap(),
            "--policy",
            vectors.join("shadow-policy-v2.json").to_str().unwrap(),
            "--now-ms",
            "1785024000000",
        ])
        .output()?;

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "PLANNED");
    Ok(())
}
