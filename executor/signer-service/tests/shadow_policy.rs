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
            "c27cd9068bf3c54364ed4782cdd1ae0cf3ed7f98fb38ec769764bd7512a8e52d",
        )
    );
    assert_eq!(report.simulated_quantity_atoms, "38271565");
    assert_eq!(report.compute_units_consumed, "220000");
    assert_eq!(report.account_deltas.len(), 2);
    Ok(())
}

#[test]
fn shadow_policy_rejects_inconsistent_simulation() -> Result<(), Box<dyn Error>> {
    let mut action = vector::<BuiltAction>("shadow-action-v1.json")?;
    action.compute_units_consumed = "300001".to_owned();

    let error = approve_shadow(
        &vector::<ExecutionIntent>("shadow-intent-v1.json")?,
        &action,
        &vector::<ExecutorPolicy>("shadow-policy-v1.json")?,
        1_785_024_000_000,
    )
    .expect_err("simulation consumption above the built limit must be rejected");

    assert_eq!(
        error.to_string(),
        "simulation result is inconsistent with the built action"
    );

    action.compute_units_consumed = "220000".to_owned();
    action.simulated_fee_atoms = "500001".to_owned();
    let error = approve_shadow(
        &vector::<ExecutionIntent>("shadow-intent-v1.json")?,
        &action,
        &vector::<ExecutorPolicy>("shadow-policy-v1.json")?,
        1_785_024_000_000,
    )
    .expect_err("simulation fees above policy must be rejected");
    assert_eq!(error.to_string(), "action exceeds intent or executor caps");
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
