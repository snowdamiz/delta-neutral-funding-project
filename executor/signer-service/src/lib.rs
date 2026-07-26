use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConformanceError {
    #[error("invalid conformance field: {0}")]
    InvalidField(&'static str),
    #[error("fixed-point result is outside the signed 64-bit range")]
    Overflow,
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FixedOutputs {
    pub nav_lamports: String,
    pub funding_usd_micros: String,
    pub spot_equivalent_lamports: String,
    pub delta_lamports: String,
    pub delta_bps: String,
    pub realized_funding_usd_micros: String,
}

fn text<'a>(input: &'a Value, key: &'static str) -> Result<&'a str, ConformanceError> {
    input[key]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or(ConformanceError::InvalidField(key))
}

fn integer(input: &Value, key: &'static str) -> Result<i64, ConformanceError> {
    let raw = text(input, key)?;
    let value = raw
        .parse::<i64>()
        .map_err(|_| ConformanceError::InvalidField(key))?;
    if value.to_string() != raw {
        return Err(ConformanceError::InvalidField(key));
    }
    Ok(value)
}

fn positive_divisor(value: i128) -> Result<i128, ConformanceError> {
    if value > 0 {
        Ok(value)
    } else {
        Err(ConformanceError::InvalidField("divisor"))
    }
}

fn atom(value: i128) -> Result<i64, ConformanceError> {
    i64::try_from(value).map_err(|_| ConformanceError::Overflow)
}

fn half_even(numerator: i128, denominator: i128) -> Result<i128, ConformanceError> {
    let divisor = positive_divisor(denominator)?;
    let mut quotient = numerator / divisor;
    let remainder = (numerator % divisor).abs();
    if remainder * 2 > divisor || (remainder * 2 == divisor && quotient.abs() % 2 == 1) {
        quotient += numerator.signum();
    }
    Ok(quotient)
}

pub fn evaluate_fixed_vector(input: &Value) -> Result<FixedOutputs, ConformanceError> {
    let nav = i128::from(integer(input, "totalPoolLamports")?) * 1_000_000_000
        / positive_divisor(i128::from(integer(input, "supplyAtoms")?))?;
    let funding = i128::from(integer(input, "notionalUsdMicros")?)
        * i128::from(integer(input, "expectedFundingRatePpm")?)
        / 1_000_000;
    let spot_equivalent = i128::from(integer(input, "spotQuantityAtoms")?)
        * i128::from(integer(input, "marketRateLamports")?)
        / 1_000_000_000;
    let delta = spot_equivalent - i128::from(integer(input, "perpShortLamports")?);
    let delta_bps = if spot_equivalent == 0 {
        0
    } else {
        (delta.abs() * 10_000 + spot_equivalent - 1) / spot_equivalent
    };
    let realized_notional = half_even(
        i128::from(integer(input, "realizedShortQuantityLamports")?)
            * i128::from(integer(input, "solPriceUsdMicros")?),
        1_000_000_000,
    )?;
    let realized_funding =
        realized_notional * i128::from(integer(input, "realizedShortRatePpm")?) / 1_000_000;

    Ok(FixedOutputs {
        nav_lamports: atom(nav)?.to_string(),
        funding_usd_micros: atom(funding)?.to_string(),
        spot_equivalent_lamports: atom(spot_equivalent)?.to_string(),
        delta_lamports: atom(delta)?.to_string(),
        delta_bps: atom(delta_bps)?.to_string(),
        realized_funding_usd_micros: atom(realized_funding)?.to_string(),
    })
}

fn unsigned_text<'a>(input: &'a Value, key: &'static str) -> Result<&'a str, ConformanceError> {
    let raw = text(input, key)?;
    let value = raw
        .parse::<u64>()
        .map_err(|_| ConformanceError::InvalidField(key))?;
    if value.to_string() != raw {
        return Err(ConformanceError::InvalidField(key));
    }
    Ok(raw)
}

pub fn canonical_execution_intent(input: &Value) -> Result<String, ConformanceError> {
    let reduce_only = input["reduceOnly"]
        .as_bool()
        .ok_or(ConformanceError::InvalidField("reduceOnly"))?;
    let intent = json!({
        "configHash": text(input, "configHash")?,
        "expiresAtMs": unsigned_text(input, "expiresAtMs")?,
        "instrument": text(input, "instrument")?,
        "intentId": text(input, "intentId")?,
        "leg": text(input, "leg")?,
        "limitPriceAtoms": unsigned_text(input, "limitPriceAtoms")?,
        "maxQuantityAtoms": unsigned_text(input, "maxQuantityAtoms")?,
        "maxSlippageBps": unsigned_text(input, "maxSlippageBps")?,
        "operation": text(input, "operation")?,
        "policyProfile": text(input, "policyProfile")?,
        "reduceOnly": reduce_only,
        "schemaVersion": 1,
        "side": text(input, "side")?,
        "snapshotIds": [text(input, "snapshotId")?],
        "stateVersion": unsigned_text(input, "stateVersion")?,
        "strategyRunId": text(input, "strategyRunId")?,
        "variant": text(input, "variant")?,
    });
    Ok(serde_json::to_string(&intent)?)
}

pub fn execution_intent_hash(input: &Value) -> Result<String, ConformanceError> {
    Ok(format!(
        "{:x}",
        Sha256::digest(canonical_execution_intent(input)?.as_bytes())
    ))
}
