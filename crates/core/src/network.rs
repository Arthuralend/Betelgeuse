use crate::{
    invitations::Invitation,
    nearby::{PairRequest, PairReply},
    exchange::{Request as Exchange, Reply as ExchangeReply, Signal, Transfers},
    records::{now_ms, Kind, Payload, SignedRecord, MAX_RECORD},
    storage::{Message, Store},
};
use anyhow::{ensure, Context, Result};
use futures::StreamExt;
use libp2p::{
    identify, identity, autonat, relay, dcutr,
    kad::{self, store::{MemoryStore, MemoryStoreConfig, RecordStore}},
    multiaddr::Protocol, noise, ping, request_response, swarm::{NetworkBehaviour, SwarmEvent, behaviour::toggle::Toggle, dial_opts::{DialOpts, PeerCondition}, DialError},
    core::transport::ListenerId, tcp, yamux, Multiaddr, PeerId, StreamProtocol, Swarm, SwarmBuilder,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet}, num::NonZeroUsize, time::{Duration, Instant},
};
use tokio::sync::mpsc;

const DHT_PROTOCOL: &str = "/betelgeuse/kad/1.0.0";
const MESSAGE_PROTOCOL: &str = "/betelgeuse/message/1.0.0";
const EXCHANGE_PROTOCOL: &str = "/betelgeuse/exchange/1.0.0";
const PAIR_PROTOCOL: &str = "/betelgeuse/pair/1.0.0";
const HOP_PROTOCOL: &str = "/libp2p/circuit/relay/0.2.0/hop";
const MAX_PAIR: usize = 12;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AutoSettings {
    pub enabled: bool,
    pub name: Option<String>,
    pub addresses: Vec<String>,
}

struct Seed {
    address: Multiaddr,
    listener: Option<ListenerId>,
    supported_relay: bool,
    reserved: bool,
    next_attempt: Instant,
    reservation_deadline: Option<Instant>,
    backoff: u64,
}
struct PairIncoming {
    peer: PeerId,
    request: PairRequest,
    channel: request_response::ResponseChannel<PairReply>,
    expires: Instant,
}
struct PairWaiting { peer: PeerId, request: PairRequest, expires: Instant }
struct PairOutbound { peer: PeerId, id: String }


#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Ack { id: String, accepted: bool }

#[derive(NetworkBehaviour)]
struct Behaviour {
    kad: kad::Behaviour<MemoryStore>,
    identify: identify::Behaviour,
    messages: request_response::cbor::Behaviour<Message, Ack>,
    exchange: request_response::cbor::Behaviour<Exchange, ExchangeReply>,
    pairing: request_response::cbor::Behaviour<PairRequest, PairReply>,
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
    ConfigureNetwork { settings: AutoSettings },
    NetworkChanged { reset: Option<bool> },
    PairRequest { address: String, name: Option<String> },
    PairAccept { id: String, name: Option<String> },
    PairDecline { id: String },
    PreviewInvitation { link: String, token: String },
    AppleInvitation { name: Option<String>, token: String },
    ImportVerified { link: String, expected_peer: String },
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
    CallSignal { peer: String, id: String, signal: Signal },
    FileSend { peer: String, path: String, name: Option<String> },
    FileAccept { peer: String, id: String },
    FilePause { peer: String, id: String },
    FileResume { peer: String, id: String },
    FileCancel { peer: String, id: String },
    Files,
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
    exchanges: HashMap<request_response::OutboundRequestId,(PeerId,Exchange)>,
    transfers: Transfers,
    events: mpsc::Sender<Value>,
    routed: HashSet<PeerId>,
    server: bool,
    auto_config: Option<AutoSettings>,
    seeds: HashMap<PeerId, Seed>,
    publish_due: Instant,
    refresh_due: Instant,
    refresh_index: usize,
    pair_incoming: HashMap<String, PairIncoming>,
    pair_waiting: HashMap<PeerId, PairWaiting>,
    pair_outbound: HashMap<request_response::OutboundRequestId, PairOutbound>,
}

impl Node {
    fn new(key: identity::Keypair, store: Store, server: bool, relay_server: bool, events: mpsc::Sender<Value>) -> Result<Self> {
        let peer = key.public().to_peer_id();
        let transfers = Transfers::new(store.directory())?;
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
        let builder = SwarmBuilder::with_existing_identity(key.clone())
            .with_tokio()
            .with_tcp(tcp::Config::default().nodelay(true), noise::Config::new, yamux::Config::default)?
            .with_quic();
        // Mobile sandbox resolver initialization must not prevent IP-only networking.
        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        let builder = builder.with_dns().context("initialize system DNS")?;
        let swarm = builder.with_relay_client(noise::Config::new, yamux::Config::default)?
            .with_behaviour(move |_, relay_client| Behaviour {
            kad,
            identify: identify::Behaviour::new(identify::Config::new(
                "/betelgeuse/1.0.0".into(), public
            )),
            messages: request_response::cbor::Behaviour::with_codec(codec,
                [(StreamProtocol::new(MESSAGE_PROTOCOL), request_response::ProtocolSupport::Full)],
                message_config),
            exchange: request_response::cbor::Behaviour::with_codec(
                request_response::cbor::codec::Codec::default()
                    .set_request_size_maximum(65_536).set_response_size_maximum(131_072),
                [(StreamProtocol::new(EXCHANGE_PROTOCOL), request_response::ProtocolSupport::Full)],
                request_response::Config::default().with_request_timeout(Duration::from_secs(30))
                    .with_max_concurrent_streams(32)),
            pairing: request_response::cbor::Behaviour::with_codec(
                request_response::cbor::codec::Codec::default()
                    .set_request_size_maximum(32_768).set_response_size_maximum(32_768),
                [(StreamProtocol::new(PAIR_PROTOCOL), request_response::ProtocolSupport::Full)],
                request_response::Config::default().with_request_timeout(Duration::from_secs(90))
                    .with_max_concurrent_streams(24)),
            ping: ping::Behaviour::default(),
            relay_client,
            relay_server: Toggle::from(relay_server.then(|| relay::Behaviour::new(peer, relay::Config {
                max_circuit_bytes: 1024 * 1024 * 1024, max_circuit_duration: Duration::from_secs(900),
                ..relay::Config::default()
            }))),
            dcutr: dcutr::Behaviour::new(peer),
            autonat: autonat::Behaviour::new(peer, autonat::Config::default()),
        })?
            .with_swarm_config(|config| config.with_idle_connection_timeout(Duration::from_secs(120)))
            .build();
        Ok(Self { swarm, store, key, peer, lookups: HashMap::new(), publications: HashMap::new(),
            outbound: HashMap::new(), exchanges: HashMap::new(), transfers, events, routed: HashSet::new(), server,
            auto_config:None, seeds:HashMap::new(), publish_due:Instant::now(), refresh_due:Instant::now(), refresh_index:0,
            pair_incoming:HashMap::new(),pair_waiting:HashMap::new(),pair_outbound:HashMap::new() })
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
        self.dial_fresh(peer, vec![address])
    }

    /// Allocate a fresh local port rather than binding to the listening socket.
    /// In particular Apple network stacks may reject the reused bind.
    fn dial_fresh(&mut self, peer: PeerId, addresses: Vec<Multiaddr>) -> Result<()> {
        if self.swarm.is_connected(&peer) { return Ok(()); }
        let options = DialOpts::peer_id(peer)
            .condition(PeerCondition::DisconnectedAndNotDialing)
            .addresses(addresses)
            .allocate_new_port()
            .build();
        match self.swarm.dial(options) {
            Ok(()) | Err(DialError::DialPeerConditionFalse(_)) => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    fn reserve_relay(&mut self, address: Multiaddr) -> Result<()> {
        ensure!(matches!(address.iter().last(), Some(Protocol::P2p(_))) &&
            !address.iter().any(|part| part == Protocol::P2pCircuit), "relay address must end in /p2p/<relay PeerId>");
        if let Some(Protocol::P2p(peer))=address.iter().last() {
            if self.seeds.get(&peer).and_then(|s|s.listener).is_some() { return Ok(()); }
        }
        self.swarm.listen_on(address.with(Protocol::P2pCircuit))?;
        Ok(())
    }

    fn configure(&mut self, config: AutoSettings, persist: bool) -> Result<()> {
        ensure!(config.addresses.len()<=8, "at most eight trusted nodes");
        if let Some(name)=config.name.as_ref() {
            ensure!(!name.trim().is_empty()&&name.len()<=120&&!name.chars().any(char::is_control),"invalid display name");
        }
        let mut wanted=HashMap::new();
        for value in &config.addresses {
            let address:Multiaddr=value.parse()?;
            let parts:Vec<_>=address.iter().collect();
            let peer=match parts.as_slice() {
                [Protocol::Ip4(ip),Protocol::Tcp(port),Protocol::P2p(peer)] if !ip.is_unspecified()&&!ip.is_multicast()&&*port!=0=>*peer,
                [Protocol::Ip6(ip),Protocol::Tcp(port),Protocol::P2p(peer)] if !ip.is_unspecified()&&!ip.is_multicast()&&*port!=0=>*peer,
                _=>anyhow::bail!("trusted node must use a numeric IP, TCP port and Peer ID"),
            };
            ensure!(peer!=self.peer,"cannot use own identity as a trusted node");
            wanted.insert(peer,address);
        }
        if persist { self.store.set_network_settings(&serde_json::to_string(&config)?)?; }
        let old:Vec<_>=self.seeds.keys().copied().collect();
        for peer in old {
            let keep=config.enabled&&wanted.get(&peer).map_or(false,|a|self.seeds.get(&peer).map_or(false,|s|s.address==*a));
            if !keep {
                if let Some(seed)=self.seeds.remove(&peer) {
                    if let Some(id)=seed.listener { self.swarm.remove_listener(id); }
                }
            }
        }
        if config.enabled {
            for (peer,address) in wanted {
                self.seeds.entry(peer).or_insert_with(||Seed {address,listener:None,supported_relay:false,reserved:false,
                    next_attempt:Instant::now(),reservation_deadline:None,backoff:2});
            }
        }
        self.auto_config=Some(config);
        self.publish_due=Instant::now();
        self.refresh_due=Instant::now();
        Ok(())
    }

    fn clear_seed_listener(&mut self, peer: PeerId) {
        if let Some(seed)=self.seeds.get_mut(&peer) {
            if let Some(id)=seed.listener.take() { self.swarm.remove_listener(id); }
            seed.reserved=false;
            seed.reservation_deadline=None;
            seed.next_attempt=Instant::now()+Duration::from_secs(seed.backoff);
        }
    }

    async fn auto_tick(&mut self) -> Result<()> {
        let now=Instant::now();
        let expired:Vec<_>=self.pair_incoming.iter().filter_map(|(id,v)|(now>=v.expires).then(||id.clone())).collect();
        for id in expired {
            if let Some(v)=self.pair_incoming.remove(&id) {
                let _=self.swarm.behaviour_mut().pairing.send_response(v.channel,PairReply{id:v.request.id,link:None});
                self.emit(json!({"event":"pair_expired","id":id})).await?;
            }
        }
        let expired:Vec<_>=self.pair_waiting.iter().filter_map(|(p,v)|(now>=v.expires).then_some(*p)).collect();
        for p in expired {
            if let Some(v)=self.pair_waiting.remove(&p) {
                self.emit(json!({"event":"pair_result","peer":p.to_string(),"id":v.request.id,"ok":false,"error":"connection timeout"})).await?;
            }
        }
        let targets:Vec<_>=self.seeds.keys().copied().collect();
        for peer in targets {
            let connected=self.swarm.is_connected(&peer);
            if self.seeds[&peer].reservation_deadline.map_or(false, |d|now>=d) {
                self.clear_seed_listener(peer);
            }
            let seed=&self.seeds[&peer];
            if now<seed.next_attempt {continue;}
            if !connected {
                let address=seed.address.clone();
                let result=self.dial_fresh(peer,vec![address]);
                let seed=self.seeds.get_mut(&peer).unwrap();
                seed.next_attempt=now+Duration::from_secs(seed.backoff);
                seed.backoff=(seed.backoff*2).min(60);
                if let Err(error)=result {
                    self.emit(json!({"event":"network_state","state":"retrying","error":error.to_string()})).await?;
                }
            } else if seed.supported_relay&&seed.listener.is_none() {
                let route=seed.address.clone().with(Protocol::P2pCircuit);
                let result=self.swarm.listen_on(route);
                let seed=self.seeds.get_mut(&peer).unwrap();
                seed.next_attempt=now+Duration::from_secs(seed.backoff);
                match result {
                    Ok(id)=>{seed.listener=Some(id);seed.reservation_deadline=Some(now+Duration::from_secs(25));}
                    Err(_)=>{seed.backoff=(seed.backoff*2).min(60);}
                }
            }
        }
        let Some(settings)=self.auto_config.clone().filter(|s|s.enabled) else {return Ok(());};
        let ready_count=self.seeds.values().filter(|s|s.reserved).count();
        if ready_count>0&&now>=self.publish_due {
            // Route announcements include only public relay routes, not the local LAN address.
            let routes:Vec<_>=self.addresses(None)?.into_iter().filter(|a|a.iter().any(|p|p==Protocol::P2pCircuit)).collect();
            if !routes.is_empty() {
                let profile=self.profile(settings.name)?;
                let routing=self.routes(Some(routes.iter().map(ToString::to_string).collect()))?;
                if self.publications.len()<14 {
                    self.publish(profile)?;
                    self.publish(routing)?;
                    self.publish_due=now+Duration::from_secs(5*60);
                }
            }
        }
        if ready_count>0&&now>=self.refresh_due {
            let contacts=self.store.contacts()?;
            let count=contacts.len();
            if count>0 {
                // Bounded round-robin to avoid monopolizing the network actor.
                for step in 0..count.min(8) {
                    let item=&contacts[(self.refresh_index+step)%count];
                    if let Ok(peer)=item.peer.parse::<PeerId>() {
                        if self.lookups.len()<24 { let _=self.lookup(peer,Kind::Routes); }
                        if self.store.pending(&peer).map_or(false,|m|!m.is_empty()) { let _=self.retry(peer); }
                    }
                }
                self.refresh_index=(self.refresh_index+count.min(8))%count;
            }
            self.refresh_due=now+Duration::from_secs(60);
        }
        Ok(())
    }

    fn invitation(&mut self,name:Option<String>) -> Result<Invitation> {
        Ok(Invitation{account:self.profile(name)?,routes:self.routes(None)?})
    }

    fn send_pair(&mut self, sender:PairWaiting) {
        let id=sender.request.id.clone();
        let request_id=self.swarm.behaviour_mut().pairing.send_request(&sender.peer,sender.request);
        self.pair_outbound.insert(request_id,PairOutbound{peer:sender.peer,id});
    }

    async fn add_invitation(&mut self, invite:&Invitation) -> Result<()> {
        let contact=invite.import(&mut self.store,&self.peer)?;
        self.add_contact_addresses(&contact.routes)?;
        self.emit(json!({"event":"contact","contact":contact})).await?;
        Ok(())
    }

    async fn on_pair(&mut self,event:request_response::Event<PairRequest,PairReply>) -> Result<()> {
        match event {
            request_response::Event::Message{peer,message,..}=>match message {
                request_response::Message::Request{request,channel,..}=>{
                    let valid=uuid::Uuid::parse_str(&request.id).map_or(false,|v|v.to_string()==request.id);
                    let invite=Invitation::decode(&request.link).and_then(|i|{ensure!(i.verify()?==peer,"pair peer mismatch"); Ok(i)});
                    if !valid||self.pair_incoming.len()>=MAX_PAIR||self.pair_incoming.contains_key(&request.id)||
                        self.pair_incoming.values().any(|x|x.peer==peer)||invite.is_err() {
                        let _=self.swarm.behaviour_mut().pairing.send_response(channel,PairReply{id:request.id,link:None});
                        return Ok(());
                    }
                    let invite=invite?;
                    let name=match &invite.account.body.payload {Payload::Account{name}=>name.clone(),_=>None};
                    let id=request.id.clone();
                    self.pair_incoming.insert(id.clone(),PairIncoming{peer,request,channel,expires:Instant::now()+Duration::from_secs(75)});
                    self.emit(json!({"event":"pair_offer","id":id,"peer":peer.to_string(),"name":name})).await?;
                }
                request_response::Message::Response{request_id,response}=>{
                    if let Some(out)=self.pair_outbound.remove(&request_id) {
                        let result:Result<()> = async {
                            ensure!(peer==out.peer&&response.id==out.id,"pair response mismatch");
                            let link=response.link.context("pair request declined")?;
                            let invite=Invitation::decode(&link)?;
                            ensure!(invite.verify()?==peer,"pair peer mismatch");
                            self.add_invitation(&invite).await?;
                            Ok(())
                        }.await;
                        self.emit(json!({"event":"pair_result","id":out.id,"peer":peer.to_string(),"ok":result.is_ok(),
                             "error":result.err().map(|e|e.to_string())})).await?;
                    }
                }
            },
            request_response::Event::OutboundFailure{peer,request_id,error,..}=>{
                if let Some(out)=self.pair_outbound.remove(&request_id) {
                    self.emit(json!({"event":"pair_result","peer":peer.to_string(),"id":out.id,"ok":false,"error":error.to_string()})).await?;
                }
            }
            _=>{}
        }
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
        if self.lookups.values().any(|q|q.peer==peer&&q.kind==kind) { return Ok(()); }
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
            if !self.store.pending(&peer)?.is_empty() {
                self.dial_fresh(peer,contact.routes.addresses()?)?;
            }
            return Ok(());
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

    fn prepare_exchange(&mut self, peer: PeerId) -> Result<()> {
        let contact = self.store.contact(&peer)?.context("add this contact first")?;
        if !self.swarm.is_connected(&peer) {
            if contact.routes.verify(now_ms()?).is_err() {
                self.lookup(peer,Kind::Routes)?;
                anyhow::bail!("refreshing contact route; try again after the lookup")
            }
            self.add_contact_addresses(&contact.routes)?;
            self.dial_fresh(peer,contact.routes.addresses()?)?;
        }
        ensure!(self.exchanges.len() < 128,"too many pending exchange requests");
        Ok(())
    }

    fn exchange(&mut self, peer: PeerId, request: Exchange) -> Result<()> {
        ensure!(self.exchanges.len() < 128, "too many pending exchange requests");
        let outbound = self.swarm.behaviour_mut().exchange.send_request(&peer,request.clone());
        self.exchanges.insert(outbound,(peer,request));
        Ok(())
    }

    async fn exchange_failure(&mut self, peer: PeerId, request: Exchange, error: String) -> Result<()> {
        let id = request.id().to_owned();
        match request {
            Exchange::Signal { signal, .. } => self.emit(json!({"event":"call_delivery","peer":peer.to_string(),"id":id,"signal":signal,"ok":false,"error":error})).await?,
            Exchange::FilePull { .. } => {
                self.transfers.fail_pull(peer,&id);
                self.emit(json!({"event":"file_paused","peer":peer.to_string(),"id":id,"error":error})).await?;
            }
            Exchange::FileOffer { .. } => {
                self.transfers.cancel(peer,&id);
                self.emit(json!({"event":"file_failed","peer":peer.to_string(),"id":id,"error":error})).await?;
            }
            Exchange::FileFinish { .. } => self.emit(json!({"event":"file_ack_failed","peer":peer.to_string(),"id":id,"error":error})).await?,
            Exchange::FileCancel { .. } => {}
        }
        Ok(())
    }

    async fn on_exchange(&mut self, event: request_response::Event<Exchange,ExchangeReply>) -> Result<()> {
        match event {
            request_response::Event::Message { peer, message, .. } => match message {
                request_response::Message::Request { request,channel,.. } => {
                    let id=request.id().to_owned();
                    let response=if self.store.contact(&peer)?.is_some() {
                        self.transfers.receive(peer,request)
                    } else { Err(anyhow::anyhow!("unknown contact")) };
                    match response {
                        Ok((reply, event)) => {
                            let _=self.swarm.behaviour_mut().exchange.send_response(channel,reply);
                            if let Some(event)=event { self.emit(event).await?; }
                        }
                        Err(_) => {
                            let _=self.swarm.behaviour_mut().exchange.send_response(channel,ExchangeReply::Ack { id,accepted:false });
                        }
                    }
                }
                request_response::Message::Response { request_id,response } => {
                    let Some((expected,request))=self.exchanges.remove(&request_id) else {return Ok(())};
                    let id=request.id().to_owned();
                    if expected!=peer {
                        return self.exchange_failure(expected,request,"unexpected peer".into()).await;
                    }
                    match (&request,response) {
                        (Exchange::FilePull { offset,.. },ExchangeReply::Chunk { id:received_id,offset:received_offset,data })
                            if received_id==id && received_offset==*offset => {
                                if !self.transfers.has_incoming(peer,&id) { return Ok(()); }
                                match self.transfers.chunk(peer,id.clone(),received_offset,data) {
                                    Ok((next,event)) => {
                                        if event["event"]=="file_progress" {
                                            // Coalesce progress events to avoid blocking the network actor.
                                            if event["received"].as_u64().unwrap_or(0) % (256 * 1024) == 0 || event["active"]==false {
                                                let _=self.events.try_send(event);
                                            }
                                        } else { self.emit(event).await?; }
                                        if let Some(next)=next {
                                            if let Err(error)=self.exchange(peer,next.clone()) {
                                                self.exchange_failure(peer,next,error.to_string()).await?;
                                            }
                                        }
                                    }
                                    Err(error) => {
                                        self.transfers.cancel(peer,&id);
                                        self.emit(json!({"event":"file_failed","peer":peer.to_string(),"id":id,"error":error.to_string()})).await?;
                                        let _=self.exchange(peer,Exchange::FileCancel{id});
                                    }
                                }
                            }
                        (_,ExchangeReply::Ack{id:received_id,accepted:true}) if received_id==id &&
                            !matches!(request,Exchange::FilePull { .. }) => {}
                        _ => self.exchange_failure(peer,request,"request rejected or invalid response".into()).await?,
                    }
                }
            },
            request_response::Event::OutboundFailure { peer,request_id,error,.. } => {
                if let Some((_,request))=self.exchanges.remove(&request_id) {
                    self.exchange_failure(peer,request,error.to_string()).await?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    async fn command(&mut self, command: Command) -> Result<bool> {
        match command {
            Command::Connect { address } => self.connect(address.parse()?)?,
            Command::Bootstrap => { self.swarm.behaviour_mut().kad.bootstrap()?; }
            Command::ConfigureNetwork{settings}=>{
                self.configure(settings,true)?;
                self.emit(json!({"event":"network_state","state":"configured","nodes":self.seeds.len()})).await?;
                self.auto_tick().await?;
                if self.seeds.values().any(|seed|seed.reserved) {
                    self.emit(json!({"event":"network_state","state":"ready"})).await?;
                }
            }
            Command::NetworkChanged{reset}=>{
                if reset.unwrap_or(false) {
                    let peers:Vec<_>=self.seeds.keys().copied().collect();
                    for peer in peers {
                        self.clear_seed_listener(peer);
                        let _=self.swarm.disconnect_peer_id(peer);
                    }
                }
                for seed in self.seeds.values_mut() {seed.next_attempt=Instant::now();seed.backoff=2;}
                self.refresh_due=Instant::now();
                self.publish_due=Instant::now();
                self.auto_tick().await?;
            }
            Command::PairRequest{address,name}=>{
                let addr:Multiaddr=address.parse()?;
                let peer=match addr.iter().last(){Some(Protocol::P2p(p))=>p,_=>anyhow::bail!("invalid pair address")};
                ensure!(peer!=self.peer&&self.pair_waiting.len()+self.pair_outbound.len()<MAX_PAIR,"too many pending pair requests");
                ensure!(!self.pair_waiting.contains_key(&peer)&&!self.pair_outbound.values().any(|p|p.peer==peer),"pair request already pending");
                let id=uuid::Uuid::new_v4().to_string();
                let request=PairRequest{id:id.clone(),link:self.invitation(name)?.encode()?};
                let pending=PairWaiting{peer,request,expires:Instant::now()+Duration::from_secs(25)};
                if self.swarm.is_connected(&peer) {self.send_pair(pending);} else {
                    self.connect(addr)?;
                    self.pair_waiting.insert(peer,pending);
                }
                self.emit(json!({"event":"pair_sent","id":id,"peer":peer.to_string()})).await?;
            }
            Command::PairAccept{id,name}=>{
                let pending=self.pair_incoming.remove(&id).context("pair request expired")?;
                let peer=pending.peer;
                let result:Result<()> = async {
                    ensure!(Instant::now()<pending.expires,"pair request expired");
                    let remote=Invitation::decode(&pending.request.link)?;
                    ensure!(remote.verify()?==peer,"pair peer mismatch");
                    let local=self.invitation(name)?.encode()?;
                    self.add_invitation(&remote).await?;
                    self.swarm.behaviour_mut().pairing.send_response(pending.channel,PairReply{id:id.clone(),link:Some(local)})
                        .map_err(|_|anyhow::anyhow!("pair response no longer deliverable"))?;
                    Ok(())
                }.await;
                self.emit(json!({"event":"pair_result","peer":peer.to_string(),"id":id,"ok":result.is_ok(),"error":result.err().map(|e|e.to_string())})).await?;
            }
            Command::PairDecline{id}=>{
                if let Some(pending)=self.pair_incoming.remove(&id) {
                    let _=self.swarm.behaviour_mut().pairing.send_response(pending.channel,PairReply{id:id.clone(),link:None});
                }
                self.emit(json!({"event":"pair_expired","id":id})).await?;
            }
            Command::PreviewInvitation{link,token}=>{
                let result=Invitation::decode(&link);
                let event=match result {
                    Ok(invite)=>{let name=match &invite.account.body.payload{Payload::Account{name}=>name.clone(),_=>None};
                        json!({"event":"invite_preview","token":token,"ok":true,"peer":invite.verify()?.to_string(),"name":name})}
                    Err(error)=>json!({"event":"invite_preview","token":token,"ok":false,"error":error.to_string()})
                };
                self.emit(event).await?;
            }
            Command::AppleInvitation{name,token}=>{
                let result=self.invitation(name).and_then(|i|i.encode());
                let event=match result {
                    Ok(link)=>json!({"event":"apple_invite","token":token,"ok":true,"link":link}),
                    Err(error)=>json!({"event":"apple_invite","token":token,"ok":false,"error":error.to_string()})
                };
                self.emit(event).await?;
            }
            Command::ImportVerified{link,expected_peer}=>{
                let invite=Invitation::decode(&link)?;
                ensure!(invite.verify()?.to_string()==expected_peer,"invitation identity changed");
                self.add_invitation(&invite).await?;
            }
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
            Command::CallSignal { peer,id,signal } => {
                let peer:PeerId=peer.parse()?;
                ensure!(uuid::Uuid::parse_str(&id)?.to_string()==id,"invalid call id");
                signal.validate()?;
                if let Err(error)=self.prepare_exchange(peer).and_then(|_|self.exchange(peer,Exchange::Signal{id:id.clone(),signal:signal.clone()})) {
                    self.emit(json!({"event":"call_delivery","peer":peer.to_string(),"id":id,"signal":signal,"ok":false,"error":error.to_string()})).await?;
                }
            }
            Command::Files => self.emit(json!({"event":"files","files":self.transfers.received()?})).await?,
            Command::FileSend { peer,path,name } => {
                let peer:PeerId=peer.parse()?;
                let result:Result<()> = async {
                    self.prepare_exchange(peer)?;
                    let prepared=tokio::task::spawn_blocking(move || Transfers::prepare(path.into(),name)).await??;
                    let (request,event)=self.transfers.offer(peer,prepared)?;
                    self.exchange(peer,request)?;
                    self.emit(event).await?;
                    Ok(())
                }.await;
                if let Err(error)=result {
                    self.emit(json!({"event":"file_prepare_failed","peer":peer.to_string(),"error":error.to_string()})).await?;
                }
            }
            Command::FileAccept { peer,id } => {
                let peer:PeerId=peer.parse()?;
                let result:Result<()> = (|| {
                    self.prepare_exchange(peer)?;
                    let request=self.transfers.accept(peer,id.clone())?;
                    self.exchange(peer,request)?;
                    Ok(())
                })();
                match result {
                    Ok(()) => self.emit(json!({"event":"file_started","peer":peer.to_string(),"id":id})).await?,
                    Err(error) => self.emit(json!({"event":"file_action_failed","peer":peer.to_string(),"id":id,"error":error.to_string()})).await?,
                }
            }
            Command::FilePause { peer,id } => {
                let peer:PeerId=peer.parse()?;
                self.transfers.pause(peer,&id)?;
                self.emit(json!({"event":"file_paused","peer":peer.to_string(),"id":id})).await?;
            }
            Command::FileResume { peer,id } => {
                let peer:PeerId=peer.parse()?;
                let result:Result<()> = (|| {
                    self.prepare_exchange(peer)?;
                    let request=self.transfers.resume(peer,id.clone())?;
                    self.exchange(peer,request)?;
                    Ok(())
                })();
                match result {
                    Ok(()) => self.emit(json!({"event":"file_started","peer":peer.to_string(),"id":id})).await?,
                    Err(error) => self.emit(json!({"event":"file_action_failed","peer":peer.to_string(),"id":id,"error":error.to_string()})).await?,
                }
            }
            Command::FileCancel { peer,id } => {
                let peer:PeerId=peer.parse()?;
                self.transfers.cancel(peer,&id);
                if self.prepare_exchange(peer).is_ok() { let _=self.exchange(peer,Exchange::FileCancel{id:id.clone()}); }
                self.emit(json!({"event":"file_cancelled","peer":peer.to_string(),"id":id})).await?;
            }
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
                        if result.is_err() && self.auto_config.as_ref().map_or(false,|s|s.enabled) {
                            self.publish_due=Instant::now()+Duration::from_secs(30);
                        }
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
                if full.iter().any(|p|p==Protocol::P2pCircuit) { self.publish_due=Instant::now(); }
                let port=match full.iter().collect::<Vec<_>>().as_slice() {
                    [Protocol::Ip4(_),Protocol::Tcp(port),Protocol::P2p(_)]=>Some(*port),_=>None
                };
                self.emit(json!({"event":"listen","address":full.to_string(),"tcp_port":port})).await?;
            }
            SwarmEvent::ListenerClosed{listener_id,..}=>{
                for seed in self.seeds.values_mut() {
                    if seed.listener==Some(listener_id) {
                        seed.listener=None;seed.reserved=false;seed.reservation_deadline=None;
                        seed.next_attempt=Instant::now()+Duration::from_secs(seed.backoff);
                        seed.backoff=(seed.backoff*2).min(60);
                    }
                }
            }
            SwarmEvent::ConnectionEstablished { peer_id, endpoint, .. } => {
                self.emit(json!({"event":"connected","peer":peer_id.to_string(),
                    "route":if endpoint.is_relayed() { "relay" } else { "direct" }})).await?;
                if let Some(seed)=self.seeds.get_mut(&peer_id) {
                    seed.backoff=2;seed.next_attempt=Instant::now();
                    self.emit(json!({"event":"network_state","state":"connected","peer":peer_id.to_string()})).await?;
                }
                if let Some(pair)=self.pair_waiting.remove(&peer_id) {self.send_pair(pair);}
                if self.store.contact(&peer_id)?.is_some() { self.retry(peer_id)?; }
            }
            SwarmEvent::ConnectionClosed { peer_id, num_established:0, .. } => {
                if self.seeds.contains_key(&peer_id) {
                    self.clear_seed_listener(peer_id);
                    self.emit(json!({"event":"network_state","state":"retrying","peer":peer_id.to_string()})).await?;
                }
                self.emit(json!({"event":"disconnected","peer":peer_id.to_string()})).await?;
            }
            SwarmEvent::OutgoingConnectionError { peer_id, error, .. } => {
                self.emit(json!({"event":"connection_error","peer":peer_id.map(|p| p.to_string()),"error":error.to_string()})).await?;
            }
            SwarmEvent::Behaviour(BehaviourEvent::Identify(identify::Event::Received { peer_id, info, .. })) => {
                if let Some(seed)=self.seeds.get_mut(&peer_id) {
                    seed.supported_relay=info.protocols.iter().any(|p|p.as_ref()==HOP_PROTOCOL);
                    self.swarm.behaviour_mut().kad.add_address(&peer_id,seed.address.clone());
                    let _=self.swarm.behaviour_mut().kad.bootstrap();
                }
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
                if let Some(seed)=self.seeds.get_mut(&relay_peer_id) {
                    seed.reserved=true;seed.reservation_deadline=None;seed.backoff=2;
                    self.publish_due=Instant::now(); self.refresh_due=Instant::now();
                    self.emit(json!({"event":"network_state","state":"ready","peer":relay_peer_id.to_string()})).await?;
                }
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
            SwarmEvent::Behaviour(BehaviourEvent::Exchange(event)) => self.on_exchange(event).await?,
            SwarmEvent::Behaviour(BehaviourEvent::Pairing(event)) => self.on_pair(event).await?,
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
    if let Some(saved)=node.store.network_settings()? {
        let result=serde_json::from_str::<AutoSettings>(&saved).map_err(anyhow::Error::from).and_then(|config|node.configure(config,false));
        if let Err(error)=result {node.emit(json!({"event":"error","error":format!("saved network configuration: {error}")})).await?;}
    }
    let mut automation=tokio::time::interval(Duration::from_secs(3));
    automation.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut cleanup=tokio::time::interval(Duration::from_secs(60));
    loop {
        tokio::select! {
            _=cleanup.tick()=>node.transfers.prune(),
            _=automation.tick()=>if let Err(error)=node.auto_tick().await {
                node.emit(json!({"event":"error","error":error.to_string()})).await?;
            },
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
