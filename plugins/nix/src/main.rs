//! First-party NixOS plugin for caelestia-shell: updates the system flake and
//! rebuilds from the dashboard, showing live build/download activity.

mod backend;
mod state;
mod view;

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use backend::{pb, Target};
use caelestia_plugin_sdk::settings::{Field, Section, SettingsSchema};
use caelestia_plugin_sdk::ui;
use caelestia_plugin_sdk::{async_trait, Context, DashboardTab, Plugin, PluginInfo, Settings};
use state::State;
use tokio::io::AsyncWriteExt;
use tokio::sync::Notify;

pub const VIEW: &str = "nix";

/// Minimum time between two pushes of the view: nix reports progress far
/// faster than anybody can read it.
const REDRAW_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    target: Mutex<Target>,
    redraw: Notify,
}

impl Shared {
    fn state(&self) -> MutexGuard<'_, State> {
        // A poisoned lock only means a panic elsewhere; the state is still usable.
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn target(&self) -> Target {
        self.target.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn changed(&self) {
        self.redraw.notify_one();
    }
}

#[derive(Clone, Copy)]
enum Op {
    Update,
    Rebuild(pb::RebuildMode),
}

async fn run_op(shared: Arc<Shared>, op: Op, target: Target) {
    let result = stream_op(&shared, op, &target).await;
    let success = result.is_ok();
    shared.state().finish(result.err());
    shared.changed();
    if success {
        refresh_status(shared).await;
    }
}

async fn stream_op(shared: &Shared, op: Op, target: &Target) -> Result<(), String> {
    let mut client = backend::connect().await?;
    let mut stream = match op {
        Op::Update => {
            client
                .update_flake(pb::UpdateFlakeRequest {
                    target: Some(target.to_proto()),
                })
                .await
        }
        Op::Rebuild(mode) => {
            client
                .rebuild(pb::RebuildRequest {
                    target: Some(target.to_proto()),
                    mode: mode as i32,
                })
                .await
        }
    }
    .map_err(|s| s.message().to_string())?
    .into_inner();

    while let Some(event) = stream
        .message()
        .await
        .map_err(|s| s.message().to_string())?
    {
        shared.state().apply(event);
        shared.changed();
    }
    Ok(())
}

async fn refresh_status(shared: Arc<Shared>) {
    let Ok(mut client) = backend::connect().await else {
        return;
    };
    let request = pb::FlakeStatusRequest {
        target: Some(shared.target().to_proto()),
    };
    if let Ok(reply) = client.get_flake_status(request).await {
        shared.state().flake = Some(reply.into_inner());
        shared.changed();
    }
}

/// Copies through a login shell: the shell's service runs with a minimal PATH
/// that lacks `wl-copy`, and Qt's own clipboard can't take the Wayland
/// selection without keyboard focus.
async fn copy_to_clipboard(text: &str) -> std::io::Result<()> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
    let mut child = tokio::process::Command::new(shell)
        .args(["-lc", "wl-copy"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(text.as_bytes()).await?;
    }
    child.wait().await?;
    Ok(())
}

struct Nix {
    shared: Arc<Shared>,
}

impl Nix {
    fn start_op(&self, op: Op) {
        {
            let mut s = self.shared.state();
            if s.running {
                return;
            }
            s.begin();
        }
        self.shared.changed();
        tokio::spawn(run_op(self.shared.clone(), op, self.shared.target()));
    }
}

#[async_trait]
impl Plugin for Nix {
    fn info(&self) -> PluginInfo {
        PluginInfo::new(env!("CARGO_PKG_VERSION"))
            .dashboard_tab(DashboardTab::new(VIEW, "Nix", "terminal"))
            .settings(
                SettingsSchema::new().section(
                    Section::new("System flake")
                        .description(
                            "Registering a system generation and activating it each prompt for \
                             authorization separately; the backend itself never runs as root.",
                        )
                        .field(
                            Field::text("config_dir", "Config directory", "")
                                .placeholder("/etc/nixos")
                                .description(
                                    "Flake directory (empty = NIX_BACKEND_CONFIG_DIR, then /etc/nixos)",
                                ),
                        )
                        .field(
                            Field::text("host_name", "Host name", "")
                                .placeholder("machine hostname")
                                .description(
                                    "nixosConfigurations.<name> (empty = NIX_BACKEND_HOST_NAME, then the machine's hostname)",
                                ),
                        ),
                ),
            )
    }

    async fn start(&self, ctx: Context) {
        let shared = self.shared.clone();
        tokio::spawn(async move {
            loop {
                shared.redraw.notified().await;
                let view = view::render(&shared.state());
                ctx.push_view(view);
                tokio::time::sleep(REDRAW_INTERVAL).await;
            }
        });
    }

    async fn view(&self, view_id: &str) -> Option<ui::View> {
        (view_id == VIEW).then(|| view::render(&self.shared.state()))
    }

    async fn action(&self, _view_id: &str, action_id: &str, _payload: &str) -> Result<(), String> {
        match action_id {
            "refresh" => {
                tokio::spawn(refresh_status(self.shared.clone()));
            }
            "update" => self.start_op(Op::Update),
            "rebuild_switch" => self.start_op(Op::Rebuild(pb::RebuildMode::Switch)),
            "rebuild_boot" => self.start_op(Op::Rebuild(pb::RebuildMode::Boot)),
            "toggle_console" => {
                let mut s = self.shared.state();
                s.console_expanded = !s.console_expanded;
                drop(s);
                self.shared.changed();
            }
            "copy_error" => {
                let text = self.shared.state().error_text();
                let shared = self.shared.clone();
                tokio::spawn(async move {
                    if copy_to_clipboard(&text).await.is_ok() {
                        shared.state().copied = true;
                        shared.changed();
                        tokio::time::sleep(Duration::from_secs(2)).await;
                        shared.state().copied = false;
                        shared.changed();
                    }
                });
            }
            other => return Err(format!("unknown action '{other}'")),
        }
        Ok(())
    }

    async fn settings_changed(&self, settings: &Settings) {
        let target = Target {
            config_dir: settings.string("config_dir", "").trim().to_string(),
            host_name: settings.string("host_name", "").trim().to_string(),
        };
        let first = self.shared.state().flake.is_none();
        let changed = {
            let mut current = self.shared.target.lock().unwrap_or_else(|e| e.into_inner());
            let changed = *current != target;
            *current = target;
            changed
        };
        // Also covers the first call after startup, when nothing is known yet.
        if changed || first {
            tokio::spawn(refresh_status(self.shared.clone()));
        }
    }
}

fn main() {
    caelestia_plugin_sdk::main(Nix {
        shared: Arc::new(Shared::default()),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use backend::pb::nix_backend_server::{NixBackend, NixBackendServer};
    use std::pin::Pin;
    use tokio_stream::wrappers::UnixListenerStream;
    use tokio_stream::Stream;
    use tonic::{Request, Response, Status};

    type Events = Pin<Box<dyn Stream<Item = Result<pb::ProgressEvent, Status>> + Send>>;

    /// A daemon that "rebuilds" in two steps, or fails when asked to update.
    struct Fake;

    #[tonic::async_trait]
    impl NixBackend for Fake {
        type UpdateFlakeStream = Events;
        type RebuildStream = Events;

        async fn update_flake(
            &self,
            _: Request<pb::UpdateFlakeRequest>,
        ) -> Result<Response<Events>, Status> {
            Err(Status::unavailable("no network"))
        }

        async fn rebuild(&self, request: Request<pb::RebuildRequest>) -> Result<Response<Events>, Status> {
            assert_eq!(
                request.into_inner().target.unwrap().host_name,
                "box",
                "the configured target must reach the daemon"
            );
            let event = |phase: pb::EventPhase, message: &str, fraction: f64| {
                Ok(pb::ProgressEvent {
                    phase: phase as i32,
                    message: message.into(),
                    fraction_done: fraction,
                    ..Default::default()
                })
            };
            let events = vec![
                event(pb::EventPhase::Build, "building", 0.5),
                event(pb::EventPhase::Finished, "done", 1.0),
            ];
            Ok(Response::new(Box::pin(tokio_stream::iter(events))))
        }

        async fn get_flake_status(
            &self,
            _: Request<pb::FlakeStatusRequest>,
        ) -> Result<Response<pb::FlakeStatusReply>, Status> {
            Ok(Response::new(pb::FlakeStatusReply {
                has_git_history: true,
                last_modified_iso8601: "2026-10-15T13:45:00+02:00".into(),
                ..Default::default()
            }))
        }
    }

    #[tokio::test]
    async fn operations_run_against_the_daemon() {
        let socket = std::env::temp_dir().join(format!("nix-plugin-test-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket);
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        std::env::set_var("NIX_BACKEND_SOCKET", &socket);
        tokio::spawn(
            tonic::transport::Server::builder()
                .add_service(NixBackendServer::new(Fake))
                .serve_with_incoming(UnixListenerStream::new(listener)),
        );

        let shared = Arc::new(Shared::default());
        *shared.target.lock().unwrap() = Target {
            config_dir: String::new(),
            host_name: "box".into(),
        };

        shared.state().begin();
        run_op(shared.clone(), Op::Rebuild(pb::RebuildMode::Switch), shared.target()).await;
        {
            let s = shared.state();
            assert!(!s.running && !s.failed());
            assert_eq!(s.status, "done");
            assert_eq!(s.log.len(), 2);
            // A successful run re-reads when the flake last changed.
            assert!(s.flake.as_ref().unwrap().has_git_history);
        }

        shared.state().begin();
        run_op(shared.clone(), Op::Update, shared.target()).await;
        let s = shared.state();
        assert!(!s.running);
        assert_eq!(s.last_error, "no network");
        assert_eq!(s.error_text(), "no network");

        let _ = std::fs::remove_file(&socket);
    }
}
