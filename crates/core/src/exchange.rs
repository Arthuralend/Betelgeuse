//! Bounded application RPCs carried by authenticated libp2p connections.
use anyhow::{ensure, Context, Result};
use libp2p::PeerId;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use uuid::Uuid;

pub const MAX_FILE: u64 = 256 * 1024 * 1024;
pub const CHUNK: usize = 32 * 1024;
const MAX_TRANSFERS: usize = 8;
const OFFER_TTL: Duration = Duration::from_secs(1800);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Signal {
    Invite { video: bool },
    Accept,
    Reject,
    Busy,
    Offer { sdp: String },
    Answer { sdp: String },
    Ice { candidate: String, mid: Option<String>, line: u16 },
    Hangup,
}
impl Signal {
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::Offer { sdp } | Self::Answer { sdp } =>
                ensure!(!sdp.is_empty() && sdp.len() <= 48_000 && !sdp.contains('\0'), "invalid SDP"),
            Self::Ice { candidate, mid, line } =>
                ensure!(!candidate.is_empty() && candidate.len() <= 4096 && *line < 64 &&
                    mid.as_ref().map_or(true, |m| m.len() <= 256), "invalid ICE candidate"),
            _ => {}
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Signal { id: String, signal: Signal },
    FileOffer { id: String, name: String, size: u64, digest: String },
    FilePull { id: String, offset: u64 },
    FileFinish { id: String, digest: String },
    FileCancel { id: String },
}

impl Request {
    pub fn id(&self) -> &str {
        match self {
            Self::Signal { id, .. } | Self::FileOffer { id, .. } | Self::FilePull { id, .. } |
            Self::FileFinish { id, .. } | Self::FileCancel { id, .. } => id,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Reply {
    Ack { id: String, accepted: bool },
    Chunk { id: String, offset: u64, data: Vec<u8> },
}

fn identifier(id: &str) -> Result<()> {
    ensure!(Uuid::parse_str(id)?.to_string() == id, "invalid transfer identifier");
    Ok(())
}

pub fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 180 && name != "." && name != ".." &&
        !name.contains(['/', '\\', ':']) && !name.chars().any(|c| c.is_control())
}

fn digest_valid(digest: &str) -> bool {
    digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn digest_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

type Key = (PeerId, String);

struct Outgoing {
    file: File,
    size: u64,
    digest: String,
    updated: Instant,
}

struct Incoming {
    name: String,
    size: u64,
    digest: String,
    offset: u64,
    hasher: Sha256,
    part: Option<PathBuf>,
    file: Option<File>,
    active: bool,
    in_flight: bool,
    updated: Instant,
}

impl Drop for Incoming {
    fn drop(&mut self) {
        self.file.take();
        if let Some(path) = self.part.take() { let _ = fs::remove_file(path); }
    }
}

pub struct Prepared {
    name: String,
    size: u64,
    digest: String,
    file: File,
}

pub struct Transfers {
    root: PathBuf,
    outgoing: HashMap<Key, Outgoing>,
    incoming: HashMap<Key, Incoming>,
}
impl Transfers {
    pub fn new(root: &Path) -> Result<Self> {
        let root = root.join("transfers");
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)] {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&root)?;
        Ok(Self { root, outgoing: HashMap::new(), incoming: HashMap::new() })
    }

    pub fn prepare(path: PathBuf, name: Option<String>) -> Result<Prepared> {
        let mut file = File::open(&path)?;
        let meta = file.metadata()?;
        ensure!(meta.is_file() && meta.len() <= MAX_FILE, "select a regular file up to 256 MiB");
        let name = name.or_else(|| path.file_name().and_then(|s| s.to_str()).map(str::to_owned))
            .context("missing file name")?;
        ensure!(valid_name(&name), "invalid file name");
        let size = meta.len();
        let mut hash = Sha256::new();
        let mut buffer = [0u8; CHUNK];
        let mut remaining = size;
        while remaining > 0 {
            let count = remaining.min(CHUNK as u64) as usize;
            file.read_exact(&mut buffer[..count])?;
            hash.update(&buffer[..count]);
            remaining -= count as u64;
        }
        file.seek(SeekFrom::Start(0))?;
        Ok(Prepared { name, size, digest: digest_hex(&hash.finalize()), file })
    }

    pub fn offer(&mut self, peer: PeerId, prepared: Prepared) -> Result<(Request, Value)> {
        ensure!(self.outgoing.len() < MAX_TRANSFERS, "too many outgoing transfers");
        let id = Uuid::new_v4().to_string();
        let event = json!({"event":"file_offered","peer":peer.to_string(),"id":id,
            "name":prepared.name,"size":prepared.size});
        let request = Request::FileOffer { id: id.clone(), name: prepared.name,
            size: prepared.size, digest: prepared.digest.clone() };
        self.outgoing.insert((peer, id), Outgoing {
            file: prepared.file, size: prepared.size, digest: prepared.digest, updated: Instant::now()
        });
        Ok((request, event))
    }

    pub fn receive(&mut self, peer: PeerId, request: Request) -> Result<(Reply, Option<Value>)> {
        identifier(request.id())?;
        let id = request.id().to_owned();
        let key = (peer, id.clone());
        let mut event = None;
        let answer = match request {
            Request::Signal { signal, .. } => {
                signal.validate()?;
                event = Some(json!({"event":"call_signal","peer":peer.to_string(),"id":id,"signal":signal}));
                Reply::Ack { id, accepted:true }
            }
            Request::FileOffer { name, size, digest, .. } => {
                ensure!(valid_name(&name) && digest_valid(&digest) && size <= MAX_FILE, "invalid file offer");
                if let Some(old) = self.incoming.get(&key) {
                    ensure!(old.name == name && old.size == size && old.digest == digest, "conflicting offer");
                } else {
                    ensure!(self.incoming.len() < MAX_TRANSFERS, "too many incoming offers");
                    self.incoming.insert(key, Incoming {
                        name: name.clone(), size, digest, offset:0, hasher:Sha256::new(),
                        part:None, file:None, active:false, in_flight:false, updated:Instant::now(),
                    });
                    event = Some(json!({"event":"file_offer","peer":peer.to_string(),"id":id,
                        "name":name,"size":size}));
                }
                Reply::Ack { id, accepted:true }
            }
            Request::FilePull { offset, .. } => {
                let file = self.outgoing.get_mut(&key).context("unknown file offer")?;
                ensure!(offset <= file.size, "invalid file offset");
                file.file.seek(SeekFrom::Start(offset))?;
                let mut data = vec![0u8; (file.size - offset).min(CHUNK as u64) as usize];
                file.file.read_exact(&mut data)?;
                file.updated = Instant::now();
                Reply::Chunk { id, offset, data }
            }
            Request::FileFinish { digest, .. } => {
                let offered = self.outgoing.get(&key).context("unknown file offer")?;
                ensure!(digest == offered.digest, "incorrect file digest");
                self.outgoing.remove(&key);
                event = Some(json!({"event":"file_delivered","peer":peer.to_string(),"id":id,"ok":true}));
                Reply::Ack { id, accepted:true }
            }
            Request::FileCancel { .. } => {
                self.outgoing.remove(&key);
                self.incoming.remove(&key);
                event = Some(json!({"event":"file_cancelled","peer":peer.to_string(),"id":id}));
                Reply::Ack { id, accepted:true }
            }
        };
        Ok((answer,event))
    }

    pub fn accept(&mut self, peer: PeerId, id: String) -> Result<Request> {
        identifier(&id)?;
        let incoming = self.incoming.get_mut(&(peer,id.clone())).context("unknown file offer")?;
        ensure!(incoming.file.is_none(), "file already accepted");
        let path = self.root.join(format!("{}.part", Uuid::new_v4()));
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)] {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        incoming.file = Some(options.open(&path)?);
        incoming.part = Some(path);
        incoming.active = true;
        incoming.in_flight = true;
        incoming.updated = Instant::now();
        Ok(Request::FilePull { id, offset:0 })
    }

    pub fn resume(&mut self, peer: PeerId, id: String) -> Result<Request> {
        let file = self.incoming.get_mut(&(peer,id.clone())).context("unknown incoming file")?;
        ensure!(file.file.is_some() && !file.in_flight, "file is not paused");
        file.active = true;
        file.in_flight = true;
        file.updated = Instant::now();
        Ok(Request::FilePull { id, offset:file.offset })
    }

    pub fn pause(&mut self, peer: PeerId, id: &str) -> Result<()> {
        let file = self.incoming.get_mut(&(peer,id.to_owned())).context("unknown incoming file")?;
        ensure!(file.file.is_some(), "file was not accepted");
        file.active = false;
        Ok(())
    }

    pub fn fail_pull(&mut self, peer: PeerId, id: &str) {
        if let Some(file) = self.incoming.get_mut(&(peer,id.to_owned())) {
            file.in_flight = false;
            file.active = false;
        }
    }

    pub fn cancel(&mut self, peer: PeerId, id: &str) {
        self.incoming.remove(&(peer,id.to_owned()));
        self.outgoing.remove(&(peer,id.to_owned()));
    }

    pub fn chunk(&mut self, peer: PeerId, id: String, offset: u64, data: Vec<u8>) -> Result<(Option<Request>, Value)> {
        let key = (peer,id.clone());
        let file = self.incoming.get_mut(&key).context("unknown incoming transfer")?;
        ensure!(file.in_flight && file.offset == offset && data.len() <= CHUNK &&
            data.len() as u64 <= file.size - file.offset && (!data.is_empty() || file.offset == file.size),
            "unexpected file chunk");
        file.file.as_mut().context("file was not accepted")?.write_all(&data)?;
        file.hasher.update(&data);
        file.offset += data.len() as u64;
        file.in_flight = false;
        file.updated = Instant::now();
        if file.offset == file.size {
            let calculated = digest_hex(&file.hasher.clone().finalize());
            if calculated != file.digest {
                self.incoming.remove(&key);
                anyhow::bail!("file failed SHA-256 verification");
            }
            file.file.as_mut().unwrap().sync_all()?;
            file.file.take();
            let folder = self.root.join(format!("received-{}", Uuid::new_v4()));
            fs::create_dir(&folder)?;
            fs::create_dir(folder.join("payload"))?;
            let path = folder.join("payload").join(&file.name);
            let metadata = json!({"peer":peer.to_string(),"id":id,"name":file.name,"size":file.size,"digest":calculated});
            fs::write(folder.join("metadata.json"),serde_json::to_vec(&metadata)?)?;
            fs::rename(file.part.as_ref().unwrap(), &path)?;
            file.part.take();
            let event = json!({"event":"file_received","peer":peer.to_string(),"id":id,
                "name":file.name,"size":file.size,"digest":calculated,"path":path});
            self.incoming.remove(&key);
            return Ok((Some(Request::FileFinish { id, digest:calculated }),event));
        }
        let progress = json!({"event":"file_progress","peer":peer.to_string(),"id":id,
            "received":file.offset,"size":file.size,"active":file.active});
        let next = if file.active {
            file.in_flight = true;
            Some(Request::FilePull { id, offset:file.offset })
        } else { None };
        Ok((next,progress))
    }

    pub fn received(&self) -> Result<Vec<Value>> {
        let mut records=Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry=entry?;
            if !entry.file_type()?.is_dir() || !entry.file_name().to_string_lossy().starts_with("received-") {continue;}
            let path=entry.path();
            let metadata_path=path.join("metadata.json");
            let Ok(meta)=fs::symlink_metadata(&metadata_path) else {continue;};
            if !meta.is_file() || meta.len()>8192 {continue;}
            let Ok(bytes)=fs::read(metadata_path) else {continue;};
            let Ok(mut item)=serde_json::from_slice::<Value>(&bytes) else {continue;};
            let Some(name)=item["name"].as_str().filter(|s|valid_name(s)) else {continue;};
            let payload=path.join("payload").join(name);
            let Ok(meta)=fs::symlink_metadata(&payload) else {continue;};
            if !meta.is_file() || Some(meta.len())!=item["size"].as_u64() {continue;}
            item["path"]=json!(payload);
            records.push(item);
            if records.len()>=500 {break;}
        }
        Ok(records)
    }

    pub fn prune(&mut self) {
        self.outgoing.retain(|_,file| file.updated.elapsed() < OFFER_TTL);
        self.incoming.retain(|_,file| file.updated.elapsed() < OFFER_TTL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_traversal_and_invalid_signals() {
        assert!(!valid_name("../test")); assert!(!valid_name("x\\y")); assert!(!valid_name(".."));
        assert!(valid_name("Пример.pdf"));
        assert!(Signal::Offer { sdp:"".into() }.validate().is_err());
    }

    #[test]
    fn verifies_chunks_and_resumes() -> Result<()> {
        let root = std::env::temp_dir().join(Uuid::new_v4().to_string());
        fs::create_dir(&root)?;
        let source = root.join("sample.bin");
        let contents = vec![0x5a; CHUNK * 2 + 19];
        fs::write(&source,&contents)?;
        let a=PeerId::from_public_key(&libp2p::identity::Keypair::generate_ed25519().public());
        let b=PeerId::from_public_key(&libp2p::identity::Keypair::generate_ed25519().public());
        let mut sender=Transfers::new(&root)?;
        let mut receiver=Transfers::new(&root)?;
        let (offer,_) = sender.offer(b,Transfers::prepare(source,None)?)?;
        let id=offer.id().to_owned();
        receiver.receive(a,offer)?;
        let pull=receiver.accept(a,id.clone())?;
        receiver.pause(a,&id)?;
        let (reply,_) = sender.receive(b,pull)?;
        let Reply::Chunk { id,offset,data }=reply else { panic!() };
        assert!(receiver.chunk(a,id.clone(),offset,data)?.0.is_none());
        let mut next=receiver.resume(a,id)?;
        loop {
            let (reply,_) = sender.receive(b,next)?;
            let Reply::Chunk { id,offset,data }=reply else { panic!() };
            let (following,event)=receiver.chunk(a,id,offset,data)?;
            if event["event"]=="file_received" {
                assert_eq!(fs::read(event["path"].as_str().unwrap())?,contents);
                sender.receive(b,following.unwrap())?;
                break;
            }
            next=following.unwrap();
        }
        fs::remove_dir_all(root)?;
        Ok(())
    }
}
