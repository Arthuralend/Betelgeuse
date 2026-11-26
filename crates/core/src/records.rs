use anyhow::{bail, ensure, Context, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine};
use libp2p::{identity, kad, multiaddr::Protocol, Multiaddr, PeerId};
use libp2p_core::{PeerRecord, SignedEnvelope};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_RECORD: usize = 8192;
pub const PROFILE_TTL_MS: u64 = 86_400_000;
pub const ROUTE_TTL_MS: u64 = 1_800_000;
const DOMAIN: &[u8] = b"betelgeuse:record:1\0";

pub fn now_ms() -> Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis().try_into()?)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind { Account, Routes }

impl Kind {
    pub fn name(self) -> &'static str {
        match self { Self::Account => "account", Self::Routes => "routes" }
    }

    pub fn ttl(self) -> u64 {
        match self { Self::Account => PROFILE_TTL_MS, Self::Routes => ROUTE_TTL_MS }
    }

    pub fn key(self, peer: &PeerId) -> kad::RecordKey {
        kad::RecordKey::new(&format!("/betelgeuse/{}/1/{}", self.name(), peer))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Payload {
    Account { name: Option<String> },
    Routes { peer_record: String },
}

impl Payload {
    pub fn kind(&self) -> Kind {
        match self { Self::Account { .. } => Kind::Account, Self::Routes { .. } => Kind::Routes }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Body {
    pub version: u8,
    pub peer: String,
    pub public_key: String,
    pub sequence: u64,
    pub issued_ms: u64,
    pub expires_ms: u64,
    pub payload: Payload,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SignedRecord {
    pub body: Body,
    pub signature: String,
}

fn signing_bytes(body: &Body) -> Result<Vec<u8>> {
    let mut bytes = DOMAIN.to_vec();
    bytes.extend(serde_json::to_vec(body)?);
    Ok(bytes)
}

impl SignedRecord {
    pub fn sign(key: &identity::Keypair, sequence: u64, payload: Payload) -> Result<Self> {
        let issued_ms = now_ms()?;
        let body = Body {
            version: 1,
            peer: key.public().to_peer_id().to_string(),
            public_key: B64.encode(key.public().encode_protobuf()),
            sequence,
            issued_ms,
            expires_ms: issued_ms.checked_add(payload.kind().ttl()).context("time overflow")?,
            payload,
        };
        let signature = B64.encode(key.sign(&signing_bytes(&body)?)?);
        let record = Self { body, signature };
        record.verify(issued_ms)?;
        Ok(record)
    }

    pub fn kind(&self) -> Kind { self.body.payload.kind() }

    pub fn verify(&self, now: u64) -> Result<PeerId> {
        let body = &self.body;
        ensure!(body.version == 1 && body.sequence > 0 && body.sequence <= i64::MAX as u64, "invalid record version");
        ensure!(body.issued_ms <= now.saturating_add(60_000), "record issued in the future");
        ensure!(body.expires_ms > now && body.expires_ms > body.issued_ms &&
            body.expires_ms - body.issued_ms <= self.kind().ttl(), "expired or invalid lifetime");
        ensure!(body.public_key.len() <= 128 && self.signature.len() <= 128, "invalid key/signature length");
        let public = identity::PublicKey::try_decode_protobuf(&B64.decode(&body.public_key)?)?;
        ensure!(public.key_type() == identity::KeyType::Ed25519, "unexpected key type");
        let peer: PeerId = body.peer.parse()?;
        ensure!(peer == public.to_peer_id() && body.peer == peer.to_string(), "identity mismatch");
        ensure!(public.verify(&signing_bytes(body)?, &B64.decode(&self.signature)?), "invalid record signature");
        match &body.payload {
            Payload::Account { name } => {
                if let Some(name) = name {
                    ensure!(!name.trim().is_empty() && name.len() <= 120 &&
                        !name.chars().any(char::is_control), "invalid display name");
                }
            }
            Payload::Routes { .. } => { self.addresses()?; }
        }
        Ok(peer)
    }

    pub fn addresses(&self) -> Result<Vec<Multiaddr>> {
        let Payload::Routes { peer_record } = &self.body.payload else { bail!("not a routing record") };
        let envelope = SignedEnvelope::from_protobuf_encoding(&B64.decode(peer_record)?)?;
        let record = PeerRecord::from_signed_envelope_interop(envelope)?;
        ensure!(record.peer_id().to_string() == self.body.peer, "routing record identity mismatch");
        validate_addresses(record.addresses())?;
        Ok(record.addresses().to_vec())
    }

    pub fn routes(key: &identity::Keypair, sequence: u64, addresses: Vec<Multiaddr>) -> Result<Self> {
        validate_addresses(&addresses)?;
        let signed = PeerRecord::new_interop(key, addresses)?.into_signed_envelope().into_protobuf_encoding();
        Self::sign(key, sequence, Payload::Routes { peer_record: B64.encode(signed) })
    }

    pub fn encode(&self) -> Result<Vec<u8>> {
        let bytes = serde_json::to_vec(self)?;
        ensure!(bytes.len() <= MAX_RECORD, "record too large");
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        ensure!(bytes.len() <= MAX_RECORD, "record too large");
        let record: Self = serde_json::from_slice(bytes)?;
        record.verify(now_ms()?)?;
        Ok(record)
    }

    pub fn from_kad(record: &kad::Record) -> Result<Self> {
        let data = Self::decode(&record.value)?;
        let peer = data.verify(now_ms()?)?;
        ensure!(record.key == data.kind().key(&peer), "DHT key binding mismatch");
        Ok(data)
    }
}

fn validate_addresses(addresses: &[Multiaddr]) -> Result<()> {
    ensure!(!addresses.is_empty() && addresses.len() <= 8, "one to eight addresses required");
    for address in addresses {
        ensure!(address.to_vec().len() <= 256, "address too large");
        // Accept direct TCP/QUIC and explicit Circuit Relay v2 routes. The
        // destination peer identifier is supplied separately when dialing.
        let parts: Vec<_> = address.iter().collect();
        let valid_host = match parts.first() {
            Some(Protocol::Ip4(ip)) => !ip.is_unspecified() && !ip.is_multicast() && !ip.is_broadcast(),
            Some(Protocol::Ip6(ip)) => !ip.is_unspecified() && !ip.is_multicast(),
            Some(Protocol::Dns(host) | Protocol::Dns4(host) | Protocol::Dns6(host)) => !host.is_empty(),
            _ => false,
        };
        let valid_transport = match parts.as_slice() {
            [_, Protocol::Tcp(port)] => *port != 0,
            [_, Protocol::Udp(port), Protocol::QuicV1] => *port != 0,
            [_, Protocol::Tcp(port), Protocol::P2p(_), Protocol::P2pCircuit] => *port != 0,
            [_, Protocol::Udp(port), Protocol::QuicV1, Protocol::P2p(_), Protocol::P2pCircuit] => *port != 0,
            _ => false,
        };
        ensure!(valid_host && valid_transport, "unsupported or unroutable address");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_wrong_identity_signature_expiration_and_key() -> Result<()> {
        let key = identity::Keypair::generate_ed25519();
        let record = SignedRecord::sign(&key, 1, Payload::Account { name: Some("Alice".into()) })?;
        let peer = key.public().to_peer_id();
        assert_eq!(record.verify(now_ms()?)?, peer);
        let mut altered = record.clone();
        altered.body.payload = Payload::Account { name: Some("Mallory".into()) };
        assert!(altered.verify(now_ms()?).is_err());
        altered = record.clone();
        altered.body.peer = identity::Keypair::generate_ed25519().public().to_peer_id().to_string();
        assert!(altered.verify(now_ms()?).is_err());
        assert!(record.verify(record.body.expires_ms).is_err());
        assert!(SignedRecord::from_kad(&kad::Record::new(Kind::Routes.key(&peer), record.encode()?)).is_err());
        Ok(())
    }

    #[test]
    fn standard_peer_record_round_trip() -> Result<()> {
        let key = identity::Keypair::generate_ed25519();
        let address: Multiaddr = "/ip4/127.0.0.1/tcp/45000".parse()?;
        let record = SignedRecord::routes(&key, 1, vec![address.clone()])?;
        assert_eq!(SignedRecord::decode(&record.encode()?)?.addresses()?, vec![address]);
        Ok(())
    }
}
