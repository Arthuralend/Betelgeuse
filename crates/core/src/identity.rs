use anyhow::{ensure, Context, Result};
use libp2p::{identity, PeerId};
use std::{fs, io::Write, path::Path};
use zeroize::Zeroizing;

#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};

pub fn create_directory(path: &Path) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    builder.mode(0o700);
    builder.create(path)?;
    let metadata = fs::symlink_metadata(path)?;
    ensure!(metadata.is_dir() && !metadata.file_type().is_symlink(), "invalid account directory");
    #[cfg(unix)]
    ensure!(metadata.permissions().mode() & 0o077 == 0, "account directory must be private (chmod 700)");
    Ok(())
}

/// An Ed25519 key is created exactly once. Hard-link publication is atomic and
/// cannot replace an existing identity, including under concurrent creation.
pub fn create(path: &Path) -> Result<PeerId> {
    create_directory(path)?;
    let target = path.join("identity.pb");
    let temporary = path.join(format!(".identity-{}.tmp", uuid::Uuid::new_v4()));
    let key = identity::Keypair::generate_ed25519();
    let bytes = Zeroizing::new(key.to_protobuf_encoding()?);
    let result = (|| -> Result<()> {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::hard_link(&temporary, &target).context("identity already exists or cannot be published")?;
        #[cfg(unix)]
        fs::File::open(path)?.sync_all()?;
        Ok(())
    })();
    let _ = fs::remove_file(temporary);
    result?;
    Ok(key.public().to_peer_id())
}

pub fn load(path: &Path) -> Result<identity::Keypair> {
    create_directory(path)?;
    let target = path.join("identity.pb");
    let info = fs::symlink_metadata(&target).context("create an account first")?;
    ensure!(info.file_type().is_file() && !info.file_type().is_symlink() && info.len() <= 1024,
        "invalid stored identity");
    #[cfg(unix)]
    ensure!(info.permissions().mode() & 0o077 == 0, "identity file must be private (chmod 600)");
    let bytes = Zeroizing::new(fs::read(target)?);
    let key = identity::Keypair::from_protobuf_encoding(&bytes)?;
    ensure!(key.key_type() == identity::KeyType::Ed25519, "Ed25519 identity required");
    Ok(key)
}
