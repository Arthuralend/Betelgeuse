use crate::{identity, records::{now_ms, Kind, SignedRecord}};
use anyhow::{ensure, Result};
use libp2p::PeerId;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{path::Path, time::Duration};

pub struct Store(Connection);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Contact {
    pub peer: String,
    pub name: Option<String>,
    pub routes: SignedRecord,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub text: String,
}

impl Message {
    pub fn validate(&self) -> Result<()> {
        let id = uuid::Uuid::parse_str(&self.id)?;
        ensure!(id.to_string() == self.id, "invalid message identifier");
        ensure!(!self.text.trim().is_empty() && self.text.len() <= 8192, "invalid message length");
        Ok(())
    }
}

impl Store {
    pub fn open(directory: &Path) -> Result<Self> {
        identity::create_directory(directory)?;
        let db = Connection::open(directory.join("state.sqlite3"))?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        ensure!(version <= 1, "unsupported database version");
        if version == 0 {
            db.execute_batch("BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS sequences(kind TEXT PRIMARY KEY, sequence INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS records(peer TEXT NOT NULL, kind TEXT NOT NULL,
                    sequence INTEGER NOT NULL, expires INTEGER NOT NULL, value BLOB NOT NULL,
                    PRIMARY KEY(peer,kind));
                CREATE INDEX IF NOT EXISTS records_expires ON records(expires);
                CREATE TABLE IF NOT EXISTS contacts(peer TEXT PRIMARY KEY, name TEXT, routes BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS messages(peer TEXT NOT NULL, direction INTEGER NOT NULL,
                    id TEXT NOT NULL, text TEXT NOT NULL, delivered INTEGER NOT NULL,
                    created INTEGER NOT NULL, PRIMARY KEY(peer,direction,id));
                CREATE INDEX IF NOT EXISTS messages_pending ON messages(peer,direction,delivered,created);
                PRAGMA user_version=1; COMMIT;")?;
        }
        Ok(Self(db))
    }

    pub fn next_sequence(&mut self, kind: Kind, own: &PeerId) -> Result<u64> {
        let tx = self.0.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let prior: u64 = tx.query_row("SELECT sequence FROM sequences WHERE kind=?1", [kind.name()], |r| r.get(0))
            .optional()?.unwrap_or(0);
        let observed: u64 = tx.query_row("SELECT sequence FROM records WHERE peer=?1 AND kind=?2",
            params![own.to_string(), kind.name()], |r| r.get(0)).optional()?.unwrap_or(0);
        let value = now_ms()?.max(prior.max(observed).checked_add(1).ok_or_else(|| anyhow::anyhow!("sequence overflow"))?);
        ensure!(value <= i64::MAX as u64, "sequence overflow");
        tx.execute("INSERT INTO sequences VALUES(?1,?2) ON CONFLICT(kind) DO UPDATE SET sequence=excluded.sequence",
            params![kind.name(), value])?;
        tx.commit()?;
        Ok(value)
    }

    /// Persist the highest authenticated sequence per owner and record type.
    /// Identical repeats are accepted, conflicts and rollbacks are rejected.
    pub fn accept(&mut self, record: &SignedRecord) -> Result<bool> {
        record.verify(now_ms()?)?;
        let bytes = record.encode()?;
        let tx = self.0.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let old: Option<(u64, Vec<u8>)> = tx.query_row(
            "SELECT sequence,value FROM records WHERE peer=?1 AND kind=?2",
            params![record.body.peer, record.kind().name()], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
        if let Some((sequence, previous)) = old {
            if sequence >= record.body.sequence {
                return Ok(sequence == record.body.sequence && previous == bytes);
            }
        } else {
            let obsolete = now_ms()?.saturating_sub(7 * 86_400_000);
            tx.execute("DELETE FROM records WHERE expires<?1", [obsolete])?;
            let count: u64 = tx.query_row("SELECT COUNT(*) FROM records", [], |r| r.get(0))?;
            ensure!(count < 5000, "record store is full");
        }
        tx.execute("INSERT INTO records VALUES(?1,?2,?3,?4,?5) ON CONFLICT(peer,kind)
            DO UPDATE SET sequence=excluded.sequence,expires=excluded.expires,value=excluded.value",
            params![record.body.peer, record.kind().name(), record.body.sequence, record.body.expires_ms, bytes])?;
        tx.commit()?;
        Ok(true)
    }

    pub fn record_count(&self) -> Result<u64> {
        Ok(self.0.query_row("SELECT COUNT(*) FROM records WHERE expires>?1", [now_ms()?], |r| r.get(0))?)
    }

    pub fn put_contact(&mut self, profile: &SignedRecord, routes: &SignedRecord) -> Result<Contact> {
        ensure!(profile.kind() == Kind::Account && routes.kind() == Kind::Routes &&
            profile.body.peer == routes.body.peer, "contact record mismatch");
        ensure!(self.accept(profile)? && self.accept(routes)?, "stale contact data");
        let crate::records::Payload::Account { name } = &profile.body.payload else { unreachable!() };
        let contact = Contact { peer: profile.body.peer.clone(), name: name.clone(), routes: routes.clone() };
        self.0.execute("INSERT INTO contacts VALUES(?1,?2,?3) ON CONFLICT(peer)
            DO UPDATE SET name=excluded.name,routes=excluded.routes",
            params![contact.peer, contact.name, contact.routes.encode()?])?;
        Ok(contact)
    }

    pub fn contact(&self, peer: &PeerId) -> Result<Option<Contact>> {
        let result: Option<(String, Option<String>, Vec<u8>)> = self.0.query_row(
            "SELECT peer,name,routes FROM contacts WHERE peer=?1", [peer.to_string()],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).optional()?;
        result.map(|(peer, name, bytes)| Ok(Contact { peer, name, routes: serde_json::from_slice(&bytes)? })).transpose()
    }

    pub fn contacts(&self) -> Result<Vec<Contact>> {
        let mut stmt = self.0.prepare("SELECT peer,name,routes FROM contacts ORDER BY peer")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, Vec<u8>>(2)?)))?;
        let mut list = Vec::new();
        for row in rows {
            let (peer, name, bytes) = row?;
            list.push(Contact { peer, name, routes: serde_json::from_slice(&bytes)? });
        }
        Ok(list)
    }

    pub fn update_contact_routes(&self, peer: &PeerId, record: &SignedRecord) -> Result<()> {
        self.0.execute("UPDATE contacts SET routes=?1 WHERE peer=?2", params![record.encode()?, peer.to_string()])?;
        Ok(())
    }

    pub fn queue(&self, peer: &PeerId, text: String) -> Result<Message> {
        ensure!(self.contact(peer)?.is_some(), "add contact before sending");
        let message = Message { id: uuid::Uuid::new_v4().to_string(), text };
        message.validate()?;
        self.0.execute("INSERT INTO messages VALUES(?1,1,?2,?3,0,?4)",
            params![peer.to_string(), message.id, message.text, now_ms()?])?;
        Ok(message)
    }

    pub fn pending(&self, peer: &PeerId) -> Result<Vec<Message>> {
        let mut stmt = self.0.prepare("SELECT id,text FROM messages WHERE peer=?1 AND direction=1 AND delivered=0 ORDER BY created LIMIT 100")?;
        let rows = stmt.query_map([peer.to_string()], |r| Ok(Message { id: r.get(0)?, text: r.get(1)? }))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn delivered(&self, peer: &PeerId, id: &str) -> Result<()> {
        self.0.execute("UPDATE messages SET delivered=1 WHERE peer=?1 AND direction=1 AND id=?2",
            params![peer.to_string(), id])?;
        Ok(())
    }

    /// A duplicate with the same id and text is acknowledged again without
    /// emitting a second receive event; a conflicting duplicate is rejected.
    pub fn receive(&self, peer: &PeerId, message: &Message) -> Result<bool> {
        ensure!(self.contact(peer)?.is_some(), "unknown contact");
        message.validate()?;
        let old: Option<String> = self.0.query_row("SELECT text FROM messages WHERE peer=?1 AND direction=0 AND id=?2",
            params![peer.to_string(), message.id], |r| r.get(0)).optional()?;
        if let Some(text) = old {
            ensure!(text == message.text, "conflicting message");
            return Ok(false);
        }
        self.0.execute("INSERT INTO messages VALUES(?1,0,?2,?3,1,?4)",
            params![peer.to_string(), message.id, message.text, now_ms()?])?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::records::Payload;
    use libp2p::identity::Keypair;

    #[test]
    fn rejects_rollback_after_restart() -> Result<()> {
        let path = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        let key = Keypair::generate_ed25519();
        let first = SignedRecord::sign(&key, 1, Payload::Account { name: None })?;
        let second = SignedRecord::sign(&key, 2, Payload::Account { name: Some("new".into()) })?;
        {
            let mut store = Store::open(&path)?;
            assert!(store.accept(&second)?);
        }
        let mut store = Store::open(&path)?;
        assert!(!store.accept(&first)?);
        assert!(store.accept(&second)?);
        drop(store);
        std::fs::remove_dir_all(path)?;
        Ok(())
    }
}
