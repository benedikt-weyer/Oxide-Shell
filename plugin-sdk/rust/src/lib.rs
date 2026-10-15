//! SDK for caelestia-shell plugins, API version 1.
//!
//! A plugin is a normal executable that implements [`Plugin`] and hands it to
//! [`run`]. The SDK serves the gRPC contract from `plugin-sdk/proto`, performs
//! the version handshake with the shell and turns the protocol into plain
//! method calls:
//!
//! ```no_run
//! use caelestia_plugin_sdk::{async_trait, ui, Plugin, PluginInfo, DashboardTab};
//!
//! struct Hello;
//!
//! #[async_trait]
//! impl Plugin for Hello {
//!     fn info(&self) -> PluginInfo {
//!         PluginInfo::new(env!("CARGO_PKG_VERSION"))
//!             .dashboard_tab(DashboardTab::new("main", "Hello", "waving_hand"))
//!     }
//!
//!     async fn view(&self, view_id: &str) -> Option<ui::View> {
//!         (view_id == "main").then(|| ui::View::new("main", ui::text("Hello from a plugin")))
//!     }
//! }
//!
//! fn main() {
//!     caelestia_plugin_sdk::main(Hello);
//! }
//! ```
//!
//! The shell starts the process with these environment variables:
//!
//! | variable                  | meaning                                   |
//! |---------------------------|-------------------------------------------|
//! | `CAELESTIA_PLUGIN_SOCKET` | unix socket path the plugin must serve on |
//! | `CAELESTIA_PLUGIN_ID`     | the plugin id from its manifest           |

use std::collections::HashMap;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::Duration;

use tokio::net::UnixListener;
use tokio::sync::{broadcast, watch};
use tokio_stream::wrappers::{ReceiverStream, UnixListenerStream};
use tokio_stream::Stream;
use tonic::{Request, Response, Status};

pub use async_trait::async_trait;

/// Generated protocol types. Prefer the wrappers in [`ui`] and [`settings`].
pub mod proto {
    tonic::include_proto!("caelestia.plugin.v1");
}

pub mod settings;
pub mod ui;

pub use proto::{ApiVersion, DashboardTab};
pub use settings::{Field, Section, Settings, SettingsSchema};

/// The API version this SDK implements. Bumped together with
/// `plugin-sdk/proto/caelestia_plugin.proto`; see the versioning rules there.
pub const API_VERSION: ApiVersion = ApiVersion { major: 1, minor: 1 };

/// Whether a plugin built against `plugin` can run on a host that implements `host`.
pub fn is_compatible(plugin: &ApiVersion, host: &ApiVersion) -> bool {
    plugin.major == host.major && plugin.minor <= host.minor
}

impl DashboardTab {
    pub fn new(
        view_id: impl Into<String>,
        title: impl Into<String>,
        icon: impl Into<String>,
    ) -> Self {
        Self {
            view_id: view_id.into(),
            title: title.into(),
            icon: icon.into(),
        }
    }
}

/// Static description of a plugin, returned during the handshake.
#[derive(Clone, Debug)]
pub struct PluginInfo {
    version: String,
    dashboard_tabs: Vec<DashboardTab>,
    settings: SettingsSchema,
}

impl PluginInfo {
    pub fn new(version: impl Into<String>) -> Self {
        Self {
            version: version.into(),
            dashboard_tabs: Vec::new(),
            settings: SettingsSchema::new(),
        }
    }

    /// Adds a tab to the dashboard, rendered from [`Plugin::view`].
    pub fn dashboard_tab(mut self, tab: DashboardTab) -> Self {
        self.dashboard_tabs.push(tab);
        self
    }

    /// Adds a settings page to Nexus.
    pub fn settings(mut self, schema: SettingsSchema) -> Self {
        self.settings = schema;
        self
    }
}

/// What a plugin implements. Only [`info`](Self::info) and [`view`](Self::view)
/// are required.
#[async_trait]
pub trait Plugin: Send + Sync + 'static {
    fn info(&self) -> PluginInfo;

    /// Called once the handshake succeeded. Keep the [`Context`] to push
    /// updates later; spawn tasks from here rather than blocking.
    async fn start(&self, _ctx: Context) {}

    /// Renders `view_id`, one of the ids declared in [`PluginInfo`].
    async fn view(&self, view_id: &str) -> Option<ui::View>;

    /// A widget with an action id was used. An `Err` is logged by the shell.
    async fn action(&self, _view_id: &str, _action_id: &str, _payload: &str) -> Result<(), String> {
        Ok(())
    }

    /// New setting values arrived (also once right after [`start`](Self::start)).
    async fn settings_changed(&self, _settings: &Settings) {}

    /// The shell asked the plugin to exit; persist state here.
    async fn shutdown(&self) {}
}

/// Handle for talking to the shell outside of a request. Cheap to clone.
#[derive(Clone)]
pub struct Context {
    events: broadcast::Sender<proto::PluginEvent>,
    settings: Arc<RwLock<Settings>>,
    data_dir: Arc<Mutex<PathBuf>>,
}

impl Context {
    /// Replaces what the shell shows for a view. Call after any state change.
    pub fn push_view(&self, view: ui::View) {
        self.send(proto::plugin_event::Event::ViewUpdate(proto::ViewUpdate {
            view: Some(view.into_proto()),
        }));
    }

    /// Shows a toast.
    pub fn notify(&self, n: ui::Notification) {
        self.send(proto::plugin_event::Event::Notification(
            proto::Notification {
                title: n.title,
                body: n.body,
                icon: n.icon,
                urgency: n.urgency,
            },
        ));
    }

    /// The latest setting values.
    pub fn settings(&self) -> Settings {
        self.settings.read().map(|s| s.clone()).unwrap_or_default()
    }

    /// A directory the plugin may keep state in (set by the shell, empty
    /// path before the handshake).
    pub fn data_dir(&self) -> PathBuf {
        self.data_dir.lock().map(|p| p.clone()).unwrap_or_default()
    }

    fn send(&self, event: proto::plugin_event::Event) {
        // Nobody subscribed (shell not connected yet) is fine: the shell
        // fetches every view after subscribing.
        let _ = self.events.send(proto::PluginEvent { event: Some(event) });
    }
}

/// Resolves once shutdown was requested. (Not `watch::Receiver::wait_for`:
/// its guard isn't `Send`.)
async fn stopped(mut rx: watch::Receiver<bool>) {
    loop {
        if *rx.borrow() || rx.changed().await.is_err() {
            return;
        }
    }
}

type EventStream = Pin<Box<dyn Stream<Item = Result<proto::PluginEvent, Status>> + Send>>;

struct Service<P> {
    plugin: Arc<P>,
    ctx: Context,
    started: OnceLock<()>,
    shutdown: watch::Sender<bool>,
}

#[tonic::async_trait]
impl<P: Plugin> proto::plugin_server::Plugin for Service<P> {
    type EventsStream = EventStream;

    async fn handshake(
        &self,
        request: Request<proto::HandshakeRequest>,
    ) -> Result<Response<proto::HandshakeReply>, Status> {
        let req = request.into_inner();
        let host = req.host_api_version.unwrap_or_default();
        if !is_compatible(&API_VERSION, &host) {
            return Err(Status::failed_precondition(format!(
                "plugin needs API {}.{} but the shell provides {}.{}",
                API_VERSION.major, API_VERSION.minor, host.major, host.minor
            )));
        }

        if let Ok(mut dir) = self.ctx.data_dir.lock() {
            *dir = PathBuf::from(&req.data_dir);
        }

        let info = self.plugin.info();
        if self.started.set(()).is_ok() {
            let (plugin, ctx) = (self.plugin.clone(), self.ctx.clone());
            tokio::spawn(async move { plugin.start(ctx).await });
        }

        Ok(Response::new(proto::HandshakeReply {
            api_version: Some(API_VERSION),
            plugin_version: info.version,
            contributions: Some(proto::Contributions {
                dashboard_tabs: info.dashboard_tabs,
            }),
            settings_schema: Some(info.settings.0),
        }))
    }

    async fn apply_settings(
        &self,
        request: Request<proto::ApplySettingsRequest>,
    ) -> Result<Response<proto::ApplySettingsReply>, Status> {
        let settings = Settings::from_proto(request.into_inner().values);
        if let Ok(mut current) = self.ctx.settings.write() {
            *current = settings.clone();
        }
        self.plugin.settings_changed(&settings).await;
        Ok(Response::new(proto::ApplySettingsReply {
            error: String::new(),
        }))
    }

    async fn get_view(
        &self,
        request: Request<proto::GetViewRequest>,
    ) -> Result<Response<proto::View>, Status> {
        let id = request.into_inner().view_id;
        match self.plugin.view(&id).await {
            Some(view) => Ok(Response::new(view.into_proto())),
            None => Err(Status::not_found(format!("no view '{id}'"))),
        }
    }

    async fn invoke_action(
        &self,
        request: Request<proto::InvokeActionRequest>,
    ) -> Result<Response<proto::InvokeActionReply>, Status> {
        let r = request.into_inner();
        let error = self
            .plugin
            .action(&r.view_id, &r.action_id, &r.payload)
            .await
            .err()
            .unwrap_or_default();
        Ok(Response::new(proto::InvokeActionReply { error }))
    }

    async fn events(
        &self,
        _request: Request<proto::EventsRequest>,
    ) -> Result<Response<Self::EventsStream>, Status> {
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        let mut events = self.ctx.events.subscribe();
        let stop = self.shutdown.subscribe();
        tokio::spawn(async move {
            // Ends (and so closes the stream) on shutdown, otherwise the
            // open stream would block the server's graceful stop.
            loop {
                tokio::select! {
                    event = events.recv() => match event {
                        Ok(event) => {
                            if tx.send(Ok(event)).await.is_err() {
                                break;
                            }
                        }
                        // A slow shell lost events; it re-fetches views when it reconnects.
                        Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => break,
                    },
                    _ = stopped(stop.clone()) => break,
                }
            }
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    async fn shutdown(
        &self,
        _request: Request<proto::ShutdownRequest>,
    ) -> Result<Response<proto::ShutdownReply>, Status> {
        self.plugin.shutdown().await;
        let _ = self.shutdown.send(true);
        Ok(Response::new(proto::ShutdownReply {}))
    }
}

/// Serves `plugin` until the shell asks it to shut down or the process gets
/// SIGTERM/SIGINT.
pub async fn run<P: Plugin>(plugin: P) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let socket = std::env::var_os("CAELESTIA_PLUGIN_SOCKET")
        .map(PathBuf::from)
        .ok_or("CAELESTIA_PLUGIN_SOCKET is not set: plugins are started by caelestia-shell")?;
    serve(plugin, &socket).await
}

/// Like [`run`] with an explicit socket path (used by tests).
pub async fn serve<P: Plugin>(
    plugin: P,
    socket: &std::path::Path,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use std::os::unix::fs::PermissionsExt;

    // A previous run may have left the socket behind.
    let _ = std::fs::remove_file(socket);
    let listener = UnixListener::bind(socket)?;
    // The plugin runs commands for the user: nobody else may connect.
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))?;

    let (events, _) = broadcast::channel(64);
    let (shutdown, shutdown_rx) = watch::channel(false);
    let service = Service {
        plugin: Arc::new(plugin),
        ctx: Context {
            events,
            settings: Arc::new(RwLock::new(Settings::from_proto(HashMap::new()))),
            data_dir: Arc::new(Mutex::new(PathBuf::new())),
        },
        started: OnceLock::new(),
        shutdown,
    };
    let signal_tx = service.shutdown.clone();

    tokio::spawn(async move {
        use tokio::signal::unix::{signal, SignalKind};
        let (Ok(mut term), Ok(mut int)) = (
            signal(SignalKind::terminate()),
            signal(SignalKind::interrupt()),
        ) else {
            return;
        };
        tokio::select! { _ = term.recv() => {}, _ = int.recv() => {} }
        let _ = signal_tx.send(true);
    });

    let stopped = stopped(shutdown_rx);
    let server = tonic::transport::Server::builder()
        .add_service(proto::plugin_server::PluginServer::new(service))
        .serve_with_incoming_shutdown(UnixListenerStream::new(listener), stopped);

    let result = server.await;
    let _ = std::fs::remove_file(socket);
    // Give a late-closing client a moment instead of hanging forever.
    tokio::time::sleep(Duration::from_millis(10)).await;
    result.map_err(Into::into)
}

/// Entry point for a plugin's `fn main`: sets up logging (to stderr, which the
/// shell captures) and a tokio runtime, then calls [`run`].
pub fn main<P: Plugin>(plugin: P) {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_writer(std::io::stderr)
        .init();

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("failed to start the async runtime: {e}");
            std::process::exit(1);
        }
    };
    if let Err(e) = runtime.block_on(run(plugin)) {
        tracing::error!("plugin failed: {e}");
        std::process::exit(1);
    }
}
