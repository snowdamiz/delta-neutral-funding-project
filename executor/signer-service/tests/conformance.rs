use std::error::Error;
use std::fs;
use std::path::PathBuf;

use funding_collector_signer::{
    FixedOutputs, canonical_execution_intent, evaluate_fixed_vector, execution_intent_hash,
};
use serde_json::Value;

fn vector(name: &str) -> Result<Value, Box<dyn Error>> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/vectors")
        .join(name);
    Ok(serde_json::from_str(&fs::read_to_string(path)?)?)
}

fn string(input: &Value, key: &str) -> Result<String, Box<dyn Error>> {
    input[key]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| format!("{key} is not a string").into())
}

#[test]
fn fixed_point_reference_matches_shared_vectors() -> Result<(), Box<dyn Error>> {
    for name in [
        "fixed-point-baseline-v1.json",
        "fixed-point-boundary-v1.json",
    ] {
        let input = vector(name)?;
        assert_eq!(
            evaluate_fixed_vector(&input)?,
            FixedOutputs {
                nav_lamports: string(&input, "expectedNavLamports")?,
                funding_usd_micros: string(&input, "expectedFundingUsdMicros")?,
                spot_equivalent_lamports: string(&input, "expectedSpotEquivalentLamports",)?,
                delta_lamports: string(&input, "expectedDeltaLamports")?,
                delta_bps: string(&input, "expectedDeltaBps")?,
                realized_funding_usd_micros: string(&input, "expectedRealizedFundingUsdMicros",)?,
            }
        );
    }
    Ok(())
}

#[test]
fn execution_intent_reference_matches_shared_vector() -> Result<(), Box<dyn Error>> {
    let input = vector("execution-intent-v1.json")?;
    assert_eq!(
        (
            canonical_execution_intent(&input)?,
            execution_intent_hash(&input)?
        ),
        (
            string(&input, "expectedCanonical")?,
            string(&input, "expectedHash")?
        )
    );
    Ok(())
}
