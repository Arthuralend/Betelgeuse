//! Native clients share one actor and one JSON command/event protocol.
use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine as _};
use betelgeuse_core::{network::{self, Command}, storage::Store};
use libp2p::{identity, Multiaddr};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    cell::RefCell, ffi::{c_char, CStr, CString}, panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf, ptr, sync::Mutex, thread::{self, JoinHandle},
};
use tokio::sync::mpsc;
use zeroize::Zeroizing;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Options {
    listen: Vec<Multiaddr>,
    #[serde(default)]
    bootstrap: Vec<Multiaddr>,
    #[serde(default)]
    server: bool,
    #[serde(default)]
    relay_server: bool,
}

pub struct BglEngine {
    commands: Option<mpsc::Sender<Command>>,
    events: Mutex<mpsc::Receiver<Value>>,
    actor: Option<JoinHandle<()>>,
}

impl BglEngine {
    fn new(directory: PathBuf, secret: &str, options: &str) -> Result<Self> {
        let bytes = Zeroizing::new(B64.decode(secret)?);
        let key = identity::Keypair::from_protobuf_encoding(&bytes)?;
        anyhow::ensure!(key.key_type() == identity::KeyType::Ed25519, "Ed25519 identity required");
        let options: Options = serde_json::from_str(options)?;
        let config = network::Config {
            listen: options.listen, bootstrap: options.bootstrap,
            server: options.server, relay_server: options.relay_server,
        };
        let (commands, input) = mpsc::channel(64);
        let (sender, events) = mpsc::channel(128);
        let actor = thread::Builder::new().name("betelgeuse-core".into()).spawn(move || {
            let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<()> {
                let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build()?;
                let store = Store::open(&directory)?;
                runtime.block_on(network::run(key, store, config, input, sender.clone()))
            }));
            let error = match outcome {
                Ok(Ok(())) => None,
                Ok(Err(error)) => Some(format!("{error:#}")),
                Err(_) => Some("Native network actor panicked".into()),
            };
            if let Some(error) = error {
                let _ = sender.try_send(json!({"event":"fatal","error":error}));
            }
        })?;
        Ok(Self { commands: Some(commands), events: Mutex::new(events), actor: Some(actor) })
    }

    fn command(&self, json: &str) -> Result<()> {
        anyhow::ensure!(json.len() <= 65536, "command too large");
        let command = serde_json::from_str::<Command>(json)?;
        self.commands.as_ref().context("engine stopped")?.try_send(command).context("engine unavailable or busy")?;
        Ok(())
    }

    fn next(&self) -> Result<Option<String>> {
        match self.events.lock().map_err(|_| anyhow!("event queue poisoned"))?.try_recv() {
            Ok(event) => Ok(Some(serde_json::to_string(&event)?)),
            Err(mpsc::error::TryRecvError::Empty) => Ok(None),
            Err(mpsc::error::TryRecvError::Disconnected) => Ok(None),
        }
    }
}

impl Drop for BglEngine {
    fn drop(&mut self) {
        if let Ok(events) = self.events.get_mut() { events.close(); }
        self.commands.take();
        if let Some(actor) = self.actor.take() { let _ = actor.join(); }
    }
}

fn generate() -> Result<String> {
    let key = identity::Keypair::generate_ed25519();
    let bytes = Zeroizing::new(key.to_protobuf_encoding()?);
    Ok(B64.encode(bytes.as_slice()))
}

thread_local! {
    static LAST_ERROR: RefCell<String> = RefCell::new(String::new());
}

fn guarded<T>(default: T, operation: impl FnOnce() -> Result<T>) -> T {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => { LAST_ERROR.with(|s| *s.borrow_mut() = error.to_string()); default }
        Err(_) => { LAST_ERROR.with(|s| *s.borrow_mut() = "Native engine error".into()); default }
    }
}

fn allocated(text: String) -> Result<*mut c_char> { Ok(CString::new(text)?.into_raw()) }

unsafe fn string<'a>(pointer: *const c_char) -> Result<&'a str> {
    anyhow::ensure!(!pointer.is_null(), "null string");
    Ok(CStr::from_ptr(pointer).to_str()?)
}

#[no_mangle]
pub extern "C" fn bgl_generate_identity() -> *mut c_char {
    guarded(ptr::null_mut(), || allocated(generate()?))
}

#[no_mangle]
pub unsafe extern "C" fn bgl_open(directory: *const c_char, secret: *const c_char, options: *const c_char) -> *mut BglEngine {
    guarded(ptr::null_mut(), || {
        let engine = BglEngine::new(PathBuf::from(string(directory)?), string(secret)?, string(options)?)?;
        Ok(Box::into_raw(Box::new(engine)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn bgl_send(engine: *mut BglEngine, json: *const c_char) -> i32 {
    guarded(-1, || {
        engine.as_ref().context("engine missing")?.command(string(json)?)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn bgl_poll(engine: *mut BglEngine) -> *mut c_char {
    guarded(ptr::null_mut(), || {
        match engine.as_ref().context("engine missing")?.next()? {
            Some(event) => allocated(event),
            None => Ok(ptr::null_mut()),
        }
    })
}

#[no_mangle]
pub extern "C" fn bgl_last_error() -> *mut c_char {
    guarded(ptr::null_mut(), || allocated(LAST_ERROR.with(|s| s.borrow().clone())))
}

#[no_mangle]
pub unsafe extern "C" fn bgl_string_free(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}

#[no_mangle]
pub unsafe extern "C" fn bgl_close(engine: *mut BglEngine) {
    if !engine.is_null() { drop(Box::from_raw(engine)); }
}

#[cfg(target_os = "android")]
mod android {
    use super::*;
    use jni::{objects::{JClass, JString}, sys::{jint, jlong, jstring}, JNIEnv};

    fn read(env: &mut JNIEnv, value: &JString) -> Result<String> { Ok(env.get_string(value)?.into()) }
    fn output(env: &mut JNIEnv, text: String) -> Result<jstring> { Ok(env.new_string(text)?.into_raw()) }

    #[no_mangle]
    extern "system" fn Java_am_supernova_local_RustCore_nativeGenerate(mut env: JNIEnv, _: JClass) -> jstring {
        guarded(ptr::null_mut(), || output(&mut env, generate()?))
    }
    #[no_mangle]
    extern "system" fn Java_am_supernova_local_RustCore_nativeOpen(mut env: JNIEnv, _: JClass,
        directory: JString, secret: JString, options: JString) -> jlong {
        guarded(0, || {
            let directory = PathBuf::from(read(&mut env, &directory)?);
            let secret = Zeroizing::new(read(&mut env, &secret)?);
            let options = read(&mut env, &options)?;
            Ok(Box::into_raw(Box::new(BglEngine::new(directory, &secret, &options)?)) as jlong)
        })
    }
    #[no_mangle]
    extern "system" fn Java_am_supernova_local_RustCore_nativeSend(mut env: JNIEnv, _: JClass,
        handle: jlong, message: JString) -> jint {
        guarded(-1, || {
            let engine = unsafe { (handle as *mut BglEngine).as_ref() }.context("engine missing")?;
            engine.command(&read(&mut env, &message)?)?;
            Ok(0)
        })
    }
    #[no_mangle]
    extern "system" fn Java_am_supernova_local_RustCore_nativePoll(mut env: JNIEnv, _: JClass,
        handle: jlong) -> jstring {
        guarded(ptr::null_mut(), || {
            let engine = unsafe { (handle as *mut BglEngine).as_ref() }.context("engine missing")?;
            match engine.next()? { Some(event) => output(&mut env, event), None => Ok(ptr::null_mut()) }
        })
    }
    #[no_mangle]
    extern "system" fn Java_am_supernova_local_RustCore_nativeError(mut env: JNIEnv, _: JClass) -> jstring {
        guarded(ptr::null_mut(), || output(&mut env, LAST_ERROR.with(|s| s.borrow().clone())))
    }
    #[no_mangle]
    extern "system" fn Java_am_supernova_local_RustCore_nativeClose(_: JNIEnv, _: JClass, handle: jlong) {
        unsafe { bgl_close(handle as *mut BglEngine); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn ffi_engine_starts_and_returns_status() -> Result<()> {
        let directory = std::env::temp_dir().join(format!("betelgeuse-ffi-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos()));
        let secret = Zeroizing::new(generate()?);
        let engine = BglEngine::new(directory.clone(), &secret,
            r#"{"listen":["/ip4/127.0.0.1/tcp/0"],"server":true}"#)?;
        engine.command(r#"{"op":"status"}"#)?;
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut started = false;
        let mut status = false;
        while Instant::now() < deadline && !(started && status) {
            if let Some(event) = engine.next()? {
                let event: Value = serde_json::from_str(&event)?;
                match event["event"].as_str() {
                    Some("started") => started = event["peer"].as_str().map_or(false, |peer| !peer.is_empty()),
                    Some("status") => status = event["protocol"] == "/betelgeuse/kad/1.0.0",
                    Some("fatal") => anyhow::bail!("engine failure: {}", event),
                    _ => {}
                }
            } else { thread::sleep(Duration::from_millis(20)); }
        }
        drop(engine);
        std::fs::remove_dir_all(directory)?;
        anyhow::ensure!(started && status, "missing FFI lifecycle events");
        Ok(())
    }
}
