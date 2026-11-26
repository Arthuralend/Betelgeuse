//! Pair requests only carry signed public profiles. Both users must consent.
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairRequest { pub id: String, pub link: String }
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairReply { pub id: String, pub link: Option<String> }
