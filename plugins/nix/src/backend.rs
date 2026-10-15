//! Client side of `nix-backend-generic`, the daemon that actually runs
//! `nix flake update` / `nixos-rebuild`-style steps (see
//! `nix-backend-generic/proto/nix_backend.proto`). It is reached over a unix
//! socket and started on demand, so the shell needs no service for it.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use tonic::transport::{Channel, Endpoint};

pub mod pb {
    tonic::include_proto!("caelestia.nixbackend.v1");
}

pub use pb::nix_backend_client::NixBackendClient;

/// Which flake/host to operate on; empty fields let the daemon pick its own
/// default (`NIX_BACKEND_CONFIG_DIR`/`NIX_BACKEND_HOST_NAME`, then
/// `/etc/nixos` and the machine's hostname).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Target {
    pub config_dir: String,
    pub host_name: String,
}

impl Target {
    pub fn to_proto(&self) -> pb::SystemTarget {
        pb::SystemTarget {
            config_dir: self.config_dir.clone(),
            host_name: self.host_name.clone(),
        }
    }
}

fn socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("NIX_BACKEND_SOCKET").filter(|p| !p.is_empty()) {
        return PathBuf::from(path);
    }
    let runtime_dir = std::env::var_os("XDG_RUNTIME_DIR").unwrap_or_else(|| "/tmp".into());
    PathBuf::from(runtime_dir).join("nix-backend-generic.sock")
}

async fn try_connect(path: &PathBuf) -> Option<Channel> {
    // The URI is only a placeholder (it becomes the HTTP/2 :authority); the
    // connector decides where the bytes really go.
    let path = path.clone();
    Endpoint::try_from("http://localhost")
        .ok()?
        .connect_with_connector(tower::service_fn(move |_| {
            tokio::net::UnixStream::connect(path.clone())
        }))
        .await
        .ok()
}

/// Waits up to ~5s for the daemon, spawning it (expected on PATH, see
/// nix/default.nix) once if nothing answers straight away.
pub async fn connect() -> Result<NixBackendClient<Channel>, String> {
    let path = socket_path();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut spawned = false;

    loop {
        if let Some(channel) = try_connect(&path).await {
            return Ok(NixBackendClient::new(channel));
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "could not reach nix-backend-generic at {}",
                path.display()
            ));
        }
        if !spawned {
            spawned = true;
            // Detached on purpose: the daemon outlives this plugin and is
            // shared by whoever needs it next.
            let _ = tokio::process::Command::new("nix-backend-generic")
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(false)
                .spawn();
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}
