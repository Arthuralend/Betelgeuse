use crate::{records::{now_ms, Kind, SignedRecord, MAX_RECORD}, storage::Store};
use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine};
use libp2p::PeerId;
use qrcode::{render::svg, EcLevel, QrCode};
use serde::{Deserialize, Serialize};

const PREFIX: &str = "betelgeuse://v1/";
const MAX_INVITE: usize = 12_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Invitation {
    pub account: SignedRecord,
    pub routes: SignedRecord,
}

impl Invitation {
    pub fn verify(&self) -> Result<PeerId> {
        let now = now_ms()?;
        let peer = self.account.verify(now)?;
        ensure!(self.account.kind() == Kind::Account && self.routes.kind() == Kind::Routes &&
            self.routes.verify(now)? == peer, "invitation records do not match");
        Ok(peer)
    }

    pub fn encode(&self) -> Result<String> {
        self.verify()?;
        ensure!(self.account.encode()?.len() <= MAX_RECORD && self.routes.encode()?.len() <= MAX_RECORD,
            "invalid invite size");
        let invite = format!("{PREFIX}{}", B64.encode(serde_json::to_vec(self)?));
        ensure!(invite.len() <= MAX_INVITE, "invite too large");
        Ok(invite)
    }

    pub fn decode(link: &str) -> Result<Self> {
        ensure!(link.len() <= MAX_INVITE, "invite too large");
        let value: Self = serde_json::from_slice(&B64.decode(link.trim().strip_prefix(PREFIX).context("invalid invitation link")?)?)?;
        value.verify()?;
        Ok(value)
    }

    pub fn qr_svg(&self) -> Result<String> {
        let qr = QrCode::with_error_correction_level(self.encode()?.as_bytes(), EcLevel::L)
            .context("invite exceeds QR capacity; reduce number of addresses")?;
        Ok(qr.render::<svg::Color>().min_dimensions(500, 500).build())
    }

    pub fn import(&self, store: &mut Store, own: &PeerId) -> Result<crate::storage::Contact> {
        ensure!(self.verify()? != *own, "cannot add own identity");
        store.put_contact(&self.account, &self.routes)
    }
}
