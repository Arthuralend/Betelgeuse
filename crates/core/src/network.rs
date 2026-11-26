use crate::{
    invitations::Invitation,
    records::{now_ms, Kind, Payload, SignedRecord, MAX_RECORD},
    storage::{Message, Store},
};
use anyhow::{ensure, Context, Result};
use futures::StreamExt;
use libp2p::{
    identify, identity, autonat, relay, dcutr,
    kad::{self, store::{MemoryStore, MemoryStoreConfig, RecordStore}},
    multiaddr::Protocol, noise, ping, request_response, swarm::{NetworkBehaviour, SwarmEvent, behaviour::toggle::Toggle},
    tcp, yamux, Multiaddr, PeerId, StreamProtocol, Swarm, SwarmBuilder,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet}, num::NonZeroUsize, time::{Duration, Instant},
};
use tokio::sync::mpsc;

const DHT_PROTOCOL: &str = "/betelgeuse/kad/1.0.0";
const MESSAGE_PROTOCOL: &str = "/betelgeuse/message/1.0.0";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Ack { id: String, accepted: bool }

#[derive(NetworkBehaviour)]
struct Behaviour {
    kad: kad::Behaviour<MemoryStore>,
    identify: identify::Behaviour,
    messages: request_response::cbor::Behaviour<Message, Ack>,
    ping: ping::Behaviour,
    relay_client: relay::client::Behaviour,
    relay_server: Toggle<relay::Behaviour>,
    dcutr: dcutr::Behaviour,
    autonat: autonat::Behaviour,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Connect { address: String },
    Bootstrap,
    ReserveRelay { address: String },
    Announce { address: String },
    Put { name: Option<String> },
    PublishRoutes { addresses: Option<Vec<String>> },
    Get { peer: String, kind: Option<Kind> },
    Invite { name: Option<String>, addresses: Option<Vec<String>>, qr_path: Option<String> },
    Import { link: String },
    Contacts,
    History { peer: String },
    Send { peer: String, text: String },
    Retry { peer: String },
    Status,
    Quit,
}

pub struct Config {
    pub listen: Vec<Multiaddr>,
    pub bootstrap: Vec<Multiaddr>,
    pub server: bool,
    pub relay_server: bool,
}

struct Lookup {
    peer: PeerId,
    kind: Kind,
    best: Option<(SignedRecord, Option<PeerId>)>,
}

struct Node {
    swarm: Swarm<Behaviour>,
    store: Store,
    key: identity::Keypair,
    peer: PeerId,
    lookups: HashMap<kad::QueryId, Lookup>,
    publications: HashMap<kad::QueryId, SignedRecord>,
    outbound: HashMap<request_response::OutboundRequestId, (PeerId, String)>,
    events: mpsc::Sender<Value>,
    routed: HashSet<PeerId>,
    server: bool,
}

impl Node {
    fn new(key: identity::Keypair, store: Store, server: bool, relay_server: bool, events: mpsc::Sender<Value>) -> Result<Self> {
        let peer = key.public().to_peer_id();
        let mut kconfig = kad::Config::new(StreamProtocol::new(DHT_PROTOCOL));
        kconfig.set_record_filtering(kad::StoreInserts::FilterBoth)
            .set_caching(kad::Caching::Disabled)
            .set_record_ttl(Some(Duration::from_secs(86_400)))
            .set_query_timeout(Duration::from_secs(25))
            .set_replication_factor(NonZeroUsize::new(8).unwrap())
            .set_parallelism(NonZeroUsize::new(3).unwrap())
            .set_max_packet_size(32_768);
        let memory = MemoryStore::with_config(peer, MemoryStoreConfig {
            max_records: 5000, max_value_bytes: MAX_RECORD + 1,
            max_providers_per_key: 8, max_provided_keys: 0,
        });
        let mut kad = kad::Behaviour::with_config(peer, memory, kconfig);
        kad.set_mode(Some(if server { kad::Mode::Server } else { kad::Mode::Client }));
        let message_config = request_response::Config::default()
            .with_request_timeout(Duration::from_secs(15))
            .with_max_concurrent_streams(64);
        let codec = request_response::cbor::codec::Codec::default()
            .set_request_size_maximum(16_384).set_response_size_maximum(1024);
        let public = key.public();
        let swarm = SwarmBuilder::with_existing_identity(key.clone())
            .with_tokio()
            .with_tcp(tcp::Config::default().nodelay(true), noise::Config::new, yamux::Config::default)?
            .with_quic()
            .with_dns()?
            .with_relay_client(noise::Config::new, yamux::Config::default)?
            .with_behaviour(move |_, relay_client| Behaviour {
            kad,
            identify: identify::Behaviour::new(identify::Config::new(
                "/betelgeuse/1.0.0".into(), public
            )),
            messages: request_response::cbor::Behaviour::with_codec(codec,
                [(StreamProtocol::new(MESSAGE_PROTOCOL), request_response::ProtocolSupport::Full)],
                message_config),
            ping: ping::Behaviour::default(),
            relay_client,
            relay_server: Toggle::from(relay_server.then(|| relay::Behaviour::new(peer, relay::Config::default()))),
            dcutr: dcutr::Behaviour::new(peer),
            autonat: autonat::Behaviour::new(peer, autonat::Config::default()),
        })?
            .with_swarm_config(|config| config.with_idle_connection_timeout(Duration::from_secs(120)))
            .build();
        Ok(Self { swarm, store, key, peer, lookups: HashMap::new(), publications: HashMap::new(),
            outbound: HashMap::new(), events, routed: HashSet::new(), server })
    }

    async fn emit(&self, value: Value) -> Result<()> {
        self.events.send(value).await.context("event receiver closed")
    }

    fn connect(&mut self, address: Multiaddr) -> Result<()> {
        ensure!(address.to_vec().len() <= 384, "invalid address");
        let mut base = address.clone();
        let Some(Protocol::P2p(peer)) = base.pop() else {
            anyhow::bail!("include /p2p/<PeerId> in the address");
        };
        ensure!(peer != self.peer, "cannot connect to own node");
        self.swarm.dial(address)?;
        Ok(())
    }

    fn reserve_relay(&mut self, address: Multiaddr) -> Result<()> {
        ensure!(matches!(address.iter().last(), Some(Protocol::P2p(_))) &&
            !address.iter().any(|part| part == Protocol::P2pCircuit), "relay address must end in /p2p/<relay PeerId>");
        self.swarm.listen_on(address.with(Protocol::P2pCircuit))?;
        Ok(())
    }

    fn normalize_listener(&self, mut address: Multiaddr) -> Multiaddr {
        if matches!(address.iter().last(), Some(Protocol::P2p(peer)) if peer == self.peer) {
            address.pop();
        }
        address
    }

    fn addresses(&self, provided: Option<Vec<String>>) -> Result<Vec<Multiaddr>> {
        if let Some(addresses) = provided {
            return addresses.into_iter().map(|s| s.parse().map_err(anyhow::Error::from)).collect();
        }
        let mut addresses: Vec<_> = self.swarm.listeners().cloned().map(|a| self.normalize_listener(a)).collect();
        addresses.sort_by_key(|address| !address.iter().any(|part| part == Protocol::P2pCircuit));
        addresses.truncate(8);
        Ok(addresses)
    }

    fn profile(&mut self, name: Option<String>) -> Result<SignedRecord> {
        let sequence = self.store.next_sequence(Kind::Account, &self.peer)?;
        SignedRecord::sign(&self.key, sequence, Payload::Account { name })
    }

    fn routes(&mut self, addresses: Option<Vec<String>>) -> Result<SignedRecord> {
        let addresses = self.addresses(addresses)?;
        let sequence = self.store.next_sequence(Kind::Routes, &self.peer)?;
        SignedRecord::routes(&self.key, sequence, addresses)
    }

    fn kad_record(data: &SignedRecord) -> Result<kad::Record> {
        let owner = data.verify(now_ms()?)?;
        let mut record = kad::Record::new(data.kind().key(&owner), data.encode()?);
        record.expires = Some(Instant::now() + Duration::from_millis(data.body.expires_ms.saturating_sub(now_ms()?)));
        Ok(record)
    }

    fn publish(&mut self, data: SignedRecord) -> Result<()> {
        ensure!(self.publications.len() < 16, "too many pending publications");
        ensure!(self.store.accept(&data)?, "record superseded");
        let id = self.swarm.behaviour_mut().kad.put_record(Self::kad_record(&data)?, kad::Quorum::One)?;
        self.publications.insert(id, data);
        Ok(())
    }

    fn lookup(&mut self, peer: PeerId, kind: Kind) -> Result<()> {
        ensure!(self.lookups.len() < 32, "too many pending lookups");
        let id = self.swarm.behaviour_mut().kad.get_record(kind.key(&peer));
        self.lookups.insert(id, Lookup { peer, kind, best: None });
        Ok(())
    }

    fn add_contact_addresses(&mut self, record: &SignedRecord) -> Result<()> {
        let peer = record.verify(now_ms()?)?;
        for address in record.addresses()? {
            self.swarm.add_peer_address(peer, address);
        }
        Ok(())
    }

    fn retry(&mut self, peer: PeerId) -> Result<()> {
        if self.outbound.len() >= 100 { return Ok(()); }
        let Some(contact) = self.store.contact(&peer)? else { return Ok(()); };
        // Expired addresses cannot be used to seed a new dial.
        if !self.swarm.is_connected(&peer) {
            if contact.routes.verify(now_ms()?).is_err() {
                return self.lookup(peer, Kind::Routes);
            }
            self.add_contact_addresses(&contact.routes)?;
        }
        for message in self.store.pending(&peer)? {
            if self.outbound.len() >= 100 { break; }
            if self.outbound.values().any(|(p, id)| *p == peer && *id == message.id) { continue; }
            let id = message.id.clone();
            let request = self.swarm.behaviour_mut().messages.send_request(&peer, message);
            self.outbound.insert(request, (peer, id));
        }
        Ok(())
    }

    async fn command(&mut self, command: Command) -> Result<bool> {
        match command {
            Command::Connect { address } => self.connect(address.parse()?)?,
            Command::Bootstrap => { self.swarm.behaviour_mut().kad.bootstrap()?; }
            Command::ReserveRelay { address } => self.reserve_relay(address.parse()?)?,
            Command::Announce { address } => {
                let address = self.normalize_listener(address.parse()?);
                // Explicit operator assertion, independently checked for shape.
                let sequence = self.store.next_sequence(Kind::Routes, &self.peer)?;
                SignedRecord::routes(&self.key, sequence, vec![address.clone()])?;
                self.swarm.add_external_address(address);
                self.emit(json!({"event":"announced"})).await?;
            }
            Command::Put { name } => {
                let data = self.profile(name)?;
                self.publish(data)?;
            }
            Command::PublishRoutes { addresses } => {
                let data = self.routes(addresses)?;
                self.publish(data)?;
            }
            Command::Get { peer, kind } => self.lookup(peer.parse()?, kind.unwrap_or(Kind::Account))?,
            Command::Invite { name, addresses, qr_path } => {
                let account = self.profile(name)?;
                let routes = self.routes(addresses)?;
                let invite = Invitation { account, routes };
                let link = invite.encode()?;
                if let Some(path) = qr_path.as_ref() {
                    // No overwrite, even if destination is an existing symlink.
                    use std::io::Write;
                    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(path)?;
                    file.write_all(invite.qr_svg()?.as_bytes())?;
                }
                self.emit(json!({"event":"invite", "link":link, "qr_path":qr_path})).await?;
            }
            Command::Import { link } => {
                let invite = Invitation::decode(&link)?;
                let contact = invite.import(&mut self.store, &self.peer)?;
                self.add_contact_addresses(&contact.routes)?;
                self.emit(json!({"event":"contact", "contact":contact})).await?;
            }
            Command::Contacts => self.emit(json!({"event":"contacts", "contacts":self.store.contacts()?})).await?,
            Command::History { peer } => {
                let peer: PeerId = peer.parse()?;
                self.emit(json!({"event":"history","peer":peer.to_string(),"messages":self.store.history(&peer)?})).await?;
            }
            Command::Send { peer, text } => {
                let peer: PeerId = peer.parse()?;
                let message = self.store.queue(&peer, text)?;
                self.emit(json!({"event":"queued", "peer":peer.to_string(), "id":message.id})).await?;
                self.retry(peer)?;
            }
            Command::Retry { peer } => self.retry(peer.parse()?)?,
            Command::Status => {
                let connected: Vec<_> = self.swarm.connected_peers().map(ToString::to_string).collect();
                let listeners: Vec<_> = self.swarm.listeners().map(ToString::to_string).collect();
                let peers: Vec<_> = self.routed.iter().map(ToString::to_string).collect();
                self.emit(json!({"event":"status","peer":self.peer.to_string(), "server": self.server,
                    "connected":connected, "routing_peers":peers, "listen":listeners,
                    "stored_records":self.store.record_count()?, "pending_messages":self.outbound.len(),
                    "protocol":DHT_PROTOCOL, "version":env!("CARGO_PKG_VERSION")})).await?;
            }
            Command::Quit => return Ok(false),
        }
        Ok(true)
    }

    async fn on_kad(&mut self, event: kad::Event) -> Result<()> {
        match event {
            kad::Event::InboundRequest { request: kad::InboundRequest::PutRecord { record: Some(record), .. } } => {
                match SignedRecord::from_kad(&record).and_then(|data| {
                    ensure!(self.store.accept(&data)?, "stale or conflicting record");
                    Ok(data)
                }) {
                    Ok(data) => {
                        self.swarm.behaviour_mut().kad.store_mut().put(Self::kad_record(&data)?)?;
                        self.emit(json!({"event":"record_stored","record":data})).await?;
                    }
                    Err(error) => self.emit(json!({"event":"record_rejected","reason":error.to_string()})).await?,
                }
            }
            kad::Event::RoutingUpdated { peer, old_peer, .. } => {
                if let Some(old) = old_peer { self.routed.remove(&old); }
                self.routed.insert(peer);
                self.emit(json!({"event":"routing","peer":peer.to_string()})).await?;
            }
            kad::Event::OutboundQueryProgressed { id, result, step, .. } => match result {
                kad::QueryResult::PutRecord(result) if step.last => {
                    if let Some(data) = self.publications.remove(&id) {
                        // libp2p's quorum confirms protocol-level responses; a remote
                        // node's custom validation decision is not part of that ACK.
                        self.emit(json!({"event":"put","ok":result.is_ok(),"record":data,
                            "error":result.err().map(|e| e.to_string())})).await?;
                    }
                }
                kad::QueryResult::GetRecord(result) => {
                    if let Some(lookup) = self.lookups.get_mut(&id) {
                        if let Ok(kad::GetRecordOk::FoundRecord(found)) = &result {
                            if let Ok(data) = SignedRecord::from_kad(&found.record) {
                                if data.body.peer == lookup.peer.to_string() && data.kind() == lookup.kind
                                    && self.store.accept(&data)? {
                                    let replace = lookup.best.as_ref().map_or(true, |(old, source)| {
                                        data.body.sequence > old.body.sequence ||
                                        (data.body.sequence == old.body.sequence && source.is_none() && found.peer.is_some())
                                    });
                                    if replace { lookup.best = Some((data, found.peer)); }
                                }
                            }
                        }
                    }
                    if step.last {
                        if let Some(lookup) = self.lookups.remove(&id) {
                            if let Some((data, source)) = lookup.best {
                                if data.kind() == Kind::Routes && self.store.contact(&lookup.peer)?.is_some() {
                                    self.store.update_contact_routes(&lookup.peer, &data)?;
                                    self.add_contact_addresses(&data)?;
                                    self.retry(lookup.peer)?;
                                }
                                self.emit(json!({"event":"get","ok":true,"peer":lookup.peer.to_string(),
                                    "kind":lookup.kind, "record":data,"source":source.map(|p| p.to_string())})).await?;
                            } else {
                                self.emit(json!({"event":"get","ok":false,"peer":lookup.peer.to_string(),
                                    "kind":lookup.kind,"error":result.err().map(|e| e.to_string()).unwrap_or("no verified record".into())})).await?;
                            }
                        }
                    }
                }
                _ => {}
            },
            _ => {}
        }
        Ok(())
    }

    async fn on_message(&mut self, event: request_response::Event<Message, Ack>) -> Result<()> {
        match event {
            request_response::Event::Message { peer, message, .. } => match message {
                request_response::Message::Request { request, channel, .. } => {
                    let result = self.store.receive(&peer, &request);
                    let accepted = result.is_ok();
                    let new = matches!(result, Ok(true));
                    let ack = Ack { id: request.id.clone(), accepted };
                    let _ = self.swarm.behaviour_mut().messages.send_response(channel, ack);
                    if new {
                        self.emit(json!({"event":"message","peer":peer.to_string(),"id":request.id,"text":request.text})).await?;
                    }
                }
                request_response::Message::Response { request_id, response } => {
                    if let Some((expected, id)) = self.outbound.remove(&request_id) {
                        let delivered = peer == expected && response.id == id && response.accepted;
                        if delivered { self.store.delivered(&peer, &id)?; }
                        self.emit(json!({"event":"delivery","peer":peer.to_string(),"id":id,"ok":delivered})).await?;
                        // Do not loop on negative acknowledgments.
                        if delivered { self.retry(peer)?; }
                    }
                }
            },
            request_response::Event::OutboundFailure { request_id, peer, error, .. } => {
                if let Some((_, id)) = self.outbound.remove(&request_id) {
                    self.emit(json!({"event":"delivery","peer":peer.to_string(),"id":id,"ok":false,"error":error.to_string()})).await?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    async fn on_event(&mut self, event: SwarmEvent<BehaviourEvent>) -> Result<()> {
        match event {
            SwarmEvent::NewListenAddr { address, .. } => {
                let full = self.normalize_listener(address).with(Protocol::P2p(self.peer));
                self.emit(json!({"event":"listen","address":full.to_string()})).await?;
            }
            SwarmEvent::ConnectionEstablished { peer_id, endpoint, .. } => {
                self.emit(json!({"event":"connected","peer":peer_id.to_string(),
                    "route":if endpoint.is_relayed() { "relay" } else { "direct" }})).await?;
                if self.store.contact(&peer_id)?.is_some() { self.retry(peer_id)?; }
            }
            SwarmEvent::ConnectionClosed { peer_id, num_established:0, .. } => {
                self.emit(json!({"event":"disconnected","peer":peer_id.to_string()})).await?;
            }
            SwarmEvent::OutgoingConnectionError { peer_id, error, .. } => {
                self.emit(json!({"event":"connection_error","peer":peer_id.map(|p| p.to_string()),"error":error.to_string()})).await?;
            }
            SwarmEvent::Behaviour(BehaviourEvent::Identify(identify::Event::Received { peer_id, info, .. })) => {
                if info.protocols.iter().any(|p| p.as_ref() == DHT_PROTOCOL) {
                    // This identifies an authenticated connection; addresses remain
                    // discovery hints until a signed routing record is verified.
                    for address in info.listen_addrs.into_iter().take(8) {
                        self.swarm.behaviour_mut().kad.add_address(&peer_id, address);
                    }
                    self.emit(json!({"event":"identified","peer":peer_id.to_string()})).await?;
                }
            }
            SwarmEvent::Behaviour(BehaviourEvent::RelayClient(relay::client::Event::ReservationReqAccepted { relay_peer_id, renewal, .. })) => {
                self.emit(json!({"event":"relay_reserved","relay":relay_peer_id.to_string(),"renewal":renewal})).await?;
            }
            SwarmEvent::Behaviour(BehaviourEvent::Dcutr(event)) => {
                self.emit(json!({"event":"direct_upgrade","peer":event.remote_peer_id.to_string(),"ok":event.result.is_ok()})).await?;
            }
            SwarmEvent::Behaviour(BehaviourEvent::Autonat(_)) => {
                self.emit(json!({"event":"nat","status":format!("{:?}",self.swarm.behaviour().autonat.nat_status())})).await?;
            }
            SwarmEvent::Behaviour(BehaviourEvent::Kad(event)) => self.on_kad(event).await?,
            SwarmEvent::Behaviour(BehaviourEvent::Messages(event)) => self.on_message(event).await?,
            _ => {}
        }
        Ok(())
    }
}

pub async fn run(key: identity::Keypair, store: Store, config: Config,
    mut commands: mpsc::Receiver<Command>, events: mpsc::Sender<Value>) -> Result<()> {
    let mut node = Node::new(key, store, config.server, config.relay_server, events)?;
    for address in config.listen { node.swarm.listen_on(address)?; }
    for address in config.bootstrap { node.connect(address)?; }
    node.emit(json!({"event":"started","peer":node.peer.to_string()})).await?;
    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else { break; };
                match node.command(command).await {
                    Ok(true) => {},
                    Ok(false) => break,
                    Err(error) => node.emit(json!({"event":"error","error":error.to_string()})).await?,
                }
            }
            event = node.swarm.select_next_some() => {
                if let Err(error) = node.on_event(event).await {
                    node.emit(json!({"event":"error","error":error.to_string()})).await?;
                }
            }
        }
    }
    node.emit(json!({"event":"stopped"})).await?;
    Ok(())
}
