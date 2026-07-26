use std::error::Error;
use std::fs;
use std::path::PathBuf;

use funding_collector_signer::{
    BuiltAction, ExecutionIntent, ExecutorPolicy, approve_shadow, execution_intent_hash,
};

fn vector<T: serde::de::DeserializeOwned>(name: &str) -> Result<T, Box<dyn Error>> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/vectors")
        .join(name);
    Ok(serde_json::from_str(&fs::read_to_string(path)?)?)
}

#[test]
fn shadow_policy_approves_bounded_simulation() -> Result<(), Box<dyn Error>> {
    let report = approve_shadow(
        &vector::<ExecutionIntent>("shadow-intent-v1.json")?,
        &vector::<BuiltAction>("shadow-action-v1.json")?,
        &vector::<ExecutorPolicy>("shadow-policy-v1.json")?,
        1_785_024_000_000,
    )?;

    assert_eq!(
        (
            report.mode.as_str(),
            report.status.as_str(),
            report.authoritative_reference.as_str(),
        ),
        (
            "shadow",
            "PLANNED",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
    );
    Ok(())
}

#[test]
fn shadow_policy_rejects_unallowlisted_program() -> Result<(), Box<dyn Error>> {
    let mut action = vector::<BuiltAction>("shadow-action-v1.json")?;
    action.program_ids = vec!["arbitrary-program".to_owned()];

    let error = approve_shadow(
        &vector::<ExecutionIntent>("shadow-intent-v1.json")?,
        &action,
        &vector::<ExecutorPolicy>("shadow-policy-v1.json")?,
        1_785_024_000_000,
    )
    .expect_err("an arbitrary program must be rejected");

    assert_eq!(error.to_string(), "program is not allowlisted");
    Ok(())
}

#[test]
fn shadow_policy_rejects_rehashed_malformed_intent() -> Result<(), Box<dyn Error>> {
    let mut intent = vector::<ExecutionIntent>("shadow-intent-v1.json")?;
    intent.variant = "invented_variant".to_owned();
    let mut action = vector::<BuiltAction>("shadow-action-v1.json")?;
    action.intent_hash = execution_intent_hash(&serde_json::to_value(&intent)?)?;

    let error = approve_shadow(
        &intent,
        &action,
        &vector::<ExecutorPolicy>("shadow-policy-v1.json")?,
        1_785_024_000_000,
    )
    .expect_err("a malformed but correctly hashed intent must be rejected");

    assert_eq!(error.to_string(), "invalid executor field: variant");
    Ok(())
}
