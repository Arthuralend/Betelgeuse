use anyhow::{Context, Result};
use betelgeuse_core::{identity, invitations::Invitation, network::{self, Command}, storage::Store};
use clap::{Parser, Subcommand};
use libp2p::Multiaddr;
use serde_json::{json, Value};
use std::{io::Write, path::PathBuf};
use tokio::{io::{AsyncBufReadExt, BufReader}, sync::mpsc};

#[derive(Parser)]
#[command(version, about="Betelgeuse decentralized network CLI")]
struct Arguments {
    #[arg(long, default_value = "./betelgeuse-data")]
    data_dir: PathBuf,
    #[command(subcommand)]
    action: Action,
}

#[derive(Subcommand)]
enum Action {
    Account { #[command(subcommand)] action: Account },
    Node { #[command(subcommand)] action: Node },
    Invite { #[command(subcommand)] action: Invite },
    Contacts,
}

#[derive(Subcommand)]
enum Account { Create, Show }

#[derive(Subcommand)]
enum Node {
    Start {
        #[arg(long, default_value="/ip4/127.0.0.1/tcp/0")]
        listen: Vec<Multiaddr>,
        #[arg(long)]
        bootstrap: Vec<Multiaddr>,
        #[arg(long)]
        server: bool,
        #[arg(long)]
        relay_server: bool,
    },
}

#[derive(Subcommand)]
enum Invite { Import { link: String } }

fn emit(event: &Value) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, event)?;
    writeln!(stdout)?;
    stdout.flush()?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Arguments::parse();
    let directory = &args.data_dir;
    match args.action {
        Action::Account { action: Account::Create } => {
            let peer = identity::create(directory)?;
            emit(&json!({"peer":peer.to_string()}))?;
        }
        Action::Account { action: Account::Show } => {
            let key = identity::load(directory)?;
            emit(&json!({"peer":key.public().to_peer_id().to_string()}))?;
        }
        Action::Contacts => {
            let store = Store::open(directory)?;
            emit(&json!({"contacts":store.contacts()?}))?;
        }
        Action::Invite { action: Invite::Import { link } } => {
            let key = identity::load(directory)?;
            let mut store = Store::open(directory)?;
            let contact = Invitation::decode(&link)?.import(&mut store, &key.public().to_peer_id())?;
            emit(&json!({"contact":contact}))?;
        }
        Action::Node { action: Node::Start { listen, bootstrap, server, relay_server } } => {
            let key = identity::load(directory)?;
            let store = Store::open(directory)?;
            let (command_tx, command_rx) = mpsc::channel(64);
            let (event_tx, mut event_rx) = mpsc::channel(128);
            let input = tokio::spawn(async move {
                let mut lines = BufReader::new(tokio::io::stdin()).lines();
                loop {
                    tokio::select! {
                        result = lines.next_line() => match result {
                            Ok(Some(line)) => {
                                if line.len() > 32_768 {
                                    eprintln!("command too large");
                                    continue;
                                }
                                match serde_json::from_str::<Command>(&line) {
                                    Ok(command) => if command_tx.send(command).await.is_err() { break; },
                                    Err(error) => eprintln!("invalid command: {error}"),
                                }
                            }
                            _ => break,
                        },
                        _ = tokio::signal::ctrl_c() => {
                            let _ = command_tx.send(Command::Quit).await;
                            break;
                        }
                    }
                }
            });
            let output = tokio::spawn(async move {
                while let Some(event) = event_rx.recv().await { emit(&event)?; }
                Ok::<_, anyhow::Error>(())
            });
            let result = network::run(key, store, network::Config { listen, bootstrap, server, relay_server }, command_rx, event_tx).await;
            input.abort();
            output.await.context("event writer failed")??;
            // Tokio's stdin uses a blocking thread. A terminal can remain open
            // after Quit. After all events are flushed, terminate the process.
            result?;
            std::process::exit(0);
        }
    }
    Ok(())
}
