use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{ConformanceError, execution_intent_hash};

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionIntent {
    pub schema_version: u32,
    pub intent_id: String,
    pub strategy_run_id: String,
    pub state_version: String,
    pub variant: String,
    pub operation: String,
    pub leg: String,
    pub instrument: String,
    pub side: String,
    pub max_quantity_atoms: String,
    pub limit_price_atoms: String,
    pub max_slippage_bps: String,
    pub reduce_only: bool,
    pub expires_at_ms: String,
    pub policy_profile: String,
    pub snapshot_ids: Vec<String>,
    pub config_hash: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuiltAction {
    pub schema_version: u32,
    pub command_id: String,
    pub intent_hash: String,
    pub program_ids: Vec<String>,
    pub accounts: Vec<String>,
    pub market: String,
    pub mint: String,
    pub destination: String,
    pub quantity_atoms: String,
    pub limit_price_atoms: String,
    pub priority_fee_lamports: String,
    pub compute_unit_limit: String,
    pub simulate_only: bool,
    pub submit: bool,
    pub message_hash: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutorPolicy {
    pub schema_version: u32,
    pub environment: String,
    pub policy_profile: String,
    pub config_hash: String,
    pub max_notional_usd_micros: String,
    pub max_priority_fee_lamports: String,
    pub max_compute_unit_limit: String,
    pub allowed_program_ids: Vec<String>,
    pub allowed_mints: Vec<String>,
    pub allowed_markets: Vec<String>,
    pub allowed_accounts: Vec<String>,
    pub signer_enabled: bool,
    pub submission_enabled: bool,
    pub kill_switch: bool,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecutionReport {
    pub schema_version: u32,
    pub intent_id: String,
    pub command_id: String,
    pub mode: String,
    pub status: String,
    pub observed_at_ms: String,
    pub filled_quantity_atoms: String,
    pub average_price_atoms: String,
    pub fee_atoms: String,
    pub authoritative_reference: String,
}

#[derive(Debug, Error)]
pub enum PolicyError {
    #[error("invalid executor field: {0}")]
    InvalidField(&'static str),
    #[error("shadow executor kill switch is active")]
    KillSwitch,
    #[error("shadow mode cannot reach a signer or submit")]
    ShadowIsolation,
    #[error("execution intent is expired")]
    Expired,
    #[error("execution intent policy binding does not match")]
    PolicyBinding,
    #[error("execution intent hash does not match")]
    IntentHash,
    #[error("program is not allowlisted")]
    Program,
    #[error("account or destination is not allowlisted")]
    Account,
    #[error("market or mint is not allowlisted")]
    Instrument,
    #[error("action exceeds intent or executor caps")]
    Limit,
    #[error(transparent)]
    Conformance(#[from] ConformanceError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

fn unsigned(value: &str, field: &'static str) -> Result<u64, PolicyError> {
    let parsed = value
        .parse::<u64>()
        .map_err(|_| PolicyError::InvalidField(field))?;
    if parsed.to_string() != value {
        return Err(PolicyError::InvalidField(field));
    }
    Ok(parsed)
}

fn identity(value: &str, field: &'static str) -> Result<(), PolicyError> {
    if value.trim().is_empty() {
        return Err(PolicyError::InvalidField(field));
    }
    Ok(())
}

fn sha256(value: &str, field: &'static str) -> Result<(), PolicyError> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(PolicyError::InvalidField(field));
    }
    Ok(())
}

fn validate_intent(intent: &ExecutionIntent) -> Result<(), PolicyError> {
    identity(&intent.intent_id, "intentId")?;
    identity(&intent.strategy_run_id, "strategyRunId")?;
    identity(&intent.instrument, "instrument")?;
    identity(&intent.policy_profile, "policyProfile")?;
    if !matches!(intent.variant.as_str(), "sol_control" | "jitosol_carry") {
        return Err(PolicyError::InvalidField("variant"));
    }
    if !matches!(
        intent.operation.as_str(),
        "OPEN" | "REBALANCE" | "CLOSE" | "EMERGENCY_FLATTEN"
    ) {
        return Err(PolicyError::InvalidField("operation"));
    }
    if !matches!(intent.leg.as_str(), "SPOT" | "PERP") {
        return Err(PolicyError::InvalidField("leg"));
    }
    if !matches!(intent.side.as_str(), "BUY" | "SELL") {
        return Err(PolicyError::InvalidField("side"));
    }
    if unsigned(&intent.max_quantity_atoms, "maxQuantityAtoms")? == 0
        || unsigned(&intent.limit_price_atoms, "limitPriceAtoms")? == 0
        || unsigned(&intent.max_slippage_bps, "maxSlippageBps")? > 10_000
        || unsigned(&intent.expires_at_ms, "expiresAtMs")? == 0
    {
        return Err(PolicyError::InvalidField("intentLimits"));
    }
    unsigned(&intent.state_version, "stateVersion")?;
    if intent.snapshot_ids.is_empty()
        || intent
            .snapshot_ids
            .iter()
            .any(|snapshot| snapshot.trim().is_empty())
    {
        return Err(PolicyError::InvalidField("snapshotIds"));
    }
    sha256(&intent.config_hash, "configHash")
}

fn validate_action(action: &BuiltAction) -> Result<(), PolicyError> {
    identity(&action.command_id, "commandId")?;
    identity(&action.market, "market")?;
    identity(&action.mint, "mint")?;
    identity(&action.destination, "destination")?;
    sha256(&action.intent_hash, "intentHash")?;
    sha256(&action.message_hash, "messageHash")
}

fn validate_policy(policy: &ExecutorPolicy) -> Result<(), PolicyError> {
    identity(&policy.policy_profile, "policyProfile")?;
    sha256(&policy.config_hash, "configHash")?;
    if unsigned(&policy.max_notional_usd_micros, "maxNotionalUsdMicros")? == 0
        || unsigned(&policy.max_compute_unit_limit, "maxComputeUnitLimit")? == 0
        || policy.allowed_program_ids.is_empty()
        || policy.allowed_mints.is_empty()
        || policy.allowed_markets.is_empty()
        || policy.allowed_accounts.is_empty()
    {
        return Err(PolicyError::InvalidField("policyLimits"));
    }
    unsigned(&policy.max_priority_fee_lamports, "maxPriorityFeeLamports")?;
    Ok(())
}

fn all_allowed(values: &[String], allowed: &[String]) -> bool {
    // ponytail: deployment-bounded allowlists stay linear; use HashSet if they grow.
    !values.is_empty() && values.iter().all(|value| allowed.contains(value))
}

pub fn approve_shadow(
    intent: &ExecutionIntent,
    action: &BuiltAction,
    policy: &ExecutorPolicy,
    now_ms: u64,
) -> Result<ExecutionReport, PolicyError> {
    if intent.schema_version != 1 || action.schema_version != 1 || policy.schema_version != 1 {
        return Err(PolicyError::InvalidField("schemaVersion"));
    }
    validate_intent(intent)?;
    validate_action(action)?;
    validate_policy(policy)?;
    if policy.kill_switch {
        return Err(PolicyError::KillSwitch);
    }
    if policy.environment != "shadow"
        || policy.signer_enabled
        || policy.submission_enabled
        || !action.simulate_only
        || action.submit
    {
        return Err(PolicyError::ShadowIsolation);
    }
    if now_ms > unsigned(&intent.expires_at_ms, "expiresAtMs")? {
        return Err(PolicyError::Expired);
    }
    if intent.policy_profile != policy.policy_profile || intent.config_hash != policy.config_hash {
        return Err(PolicyError::PolicyBinding);
    }
    let intent_value = serde_json::to_value(intent)?;
    if execution_intent_hash(&intent_value)? != action.intent_hash {
        return Err(PolicyError::IntentHash);
    }
    if !all_allowed(&action.program_ids, &policy.allowed_program_ids) {
        return Err(PolicyError::Program);
    }
    if !all_allowed(&action.accounts, &policy.allowed_accounts)
        || !policy.allowed_accounts.contains(&action.destination)
    {
        return Err(PolicyError::Account);
    }
    if !policy.allowed_markets.contains(&action.market)
        || !policy.allowed_mints.contains(&action.mint)
        || action.market != intent.instrument
    {
        return Err(PolicyError::Instrument);
    }

    let quantity = unsigned(&action.quantity_atoms, "quantityAtoms")?;
    let price = unsigned(&action.limit_price_atoms, "limitPriceAtoms")?;
    let intent_quantity = unsigned(&intent.max_quantity_atoms, "maxQuantityAtoms")?;
    let intent_price = unsigned(&intent.limit_price_atoms, "limitPriceAtoms")?;
    let price_within_intent = match intent.side.as_str() {
        "BUY" => price <= intent_price,
        "SELL" => price >= intent_price,
        _ => return Err(PolicyError::InvalidField("side")),
    };
    let notional = u128::from(quantity)
        .checked_mul(u128::from(price))
        .ok_or(PolicyError::Limit)?
        .div_ceil(1_000_000_000);
    if quantity == 0
        || quantity > intent_quantity
        || !price_within_intent
        || notional
            > u128::from(unsigned(
                &policy.max_notional_usd_micros,
                "maxNotionalUsdMicros",
            )?)
        || unsigned(&action.priority_fee_lamports, "priorityFeeLamports")?
            > unsigned(&policy.max_priority_fee_lamports, "maxPriorityFeeLamports")?
        || unsigned(&action.compute_unit_limit, "computeUnitLimit")?
            > unsigned(&policy.max_compute_unit_limit, "maxComputeUnitLimit")?
    {
        return Err(PolicyError::Limit);
    }

    Ok(ExecutionReport {
        schema_version: 1,
        intent_id: intent.intent_id.clone(),
        command_id: action.command_id.clone(),
        mode: "shadow".to_owned(),
        status: "PLANNED".to_owned(),
        observed_at_ms: now_ms.to_string(),
        filled_quantity_atoms: "0".to_owned(),
        average_price_atoms: "0".to_owned(),
        fee_atoms: "0".to_owned(),
        authoritative_reference: action.message_hash.clone(),
    })
}
