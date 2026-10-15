//! Spins up a plugin on a temp socket and drives it like the shell does.

use caelestia_plugin_sdk::proto::plugin_client::PluginClient;
use caelestia_plugin_sdk::proto::{self, node::Kind};
use caelestia_plugin_sdk::settings::{Field, Section, SettingsSchema};
use caelestia_plugin_sdk::{async_trait, ui, Context, DashboardTab, Plugin, PluginInfo, Settings};
use std::sync::{Arc, Mutex};
use tokio_stream::StreamExt;
use tonic::transport::{Channel, Endpoint};

#[derive(Default)]
struct Demo {
    ctx: Mutex<Option<Context>>,
    seen: Arc<Mutex<Vec<String>>>,
}

#[async_trait]
impl Plugin for Demo {
    fn info(&self) -> PluginInfo {
        PluginInfo::new("0.3.1")
            .dashboard_tab(DashboardTab::new("main", "Demo", "star"))
            .settings(SettingsSchema::new().section(
                Section::new("General").field(Field::number("n", "N", 5.0, 1.0, 10.0).integer()),
            ))
    }

    async fn start(&self, ctx: Context) {
        *self.ctx.lock().unwrap() = Some(ctx);
    }

    async fn view(&self, id: &str) -> Option<ui::View> {
        (id == "main").then(|| ui::View::new("main", ui::column().child(ui::text("hi"))))
    }

    async fn action(&self, _view: &str, action: &str, payload: &str) -> Result<(), String> {
        if action == "fail" {
            return Err("nope".into());
        }
        self.seen
            .lock()
            .unwrap()
            .push(format!("{action}:{payload}"));
        if let Some(ctx) = self.ctx.lock().unwrap().clone() {
            ctx.push_view(ui::View::new("main", ui::text("updated")));
            ctx.notify(ui::Notification::new("t", "b"));
        }
        Ok(())
    }

    async fn settings_changed(&self, s: &Settings) {
        self.seen
            .lock()
            .unwrap()
            .push(format!("n={}", s.u32("n", 0)));
    }
}

async fn connect(path: std::path::PathBuf) -> PluginClient<Channel> {
    for _ in 0..50 {
        let p = path.clone();
        let res = Endpoint::try_from("http://localhost")
            .unwrap()
            .connect_with_connector(tower::service_fn(move |_| {
                tokio::net::UnixStream::connect(p.clone())
            }))
            .await;
        if let Ok(ch) = res {
            return PluginClient::new(ch);
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("plugin never came up");
}

fn handshake(major: u32, minor: u32) -> proto::HandshakeRequest {
    proto::HandshakeRequest {
        host_api_version: Some(proto::ApiVersion { major, minor }),
        host_version: "test".into(),
        data_dir: "/tmp/x".into(),
    }
}

#[tokio::test]
async fn full_roundtrip() {
    let dir = std::env::temp_dir().join(format!("caelestia-sdk-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("p.sock");

    let demo = Demo::default();
    let seen = demo.seen.clone();
    let sock = socket.clone();
    let server = tokio::spawn(async move { caelestia_plugin_sdk::serve(demo, &sock).await });

    let mut client = connect(socket.clone()).await;

    // Too new for a host that only knows 1.0, and a different major.
    assert_eq!(
        client.handshake(handshake(2, 0)).await.unwrap_err().code(),
        tonic::Code::FailedPrecondition
    );

    let reply = client
        .handshake(handshake(1, 1))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(reply.plugin_version, "0.3.1");
    assert_eq!(
        reply.api_version.unwrap(),
        caelestia_plugin_sdk::API_VERSION
    );
    assert_eq!(reply.contributions.unwrap().dashboard_tabs[0].title, "Demo");
    assert_eq!(
        reply.settings_schema.unwrap().sections[0].fields[0].key,
        "n"
    );

    let mut events = client
        .events(proto::EventsRequest {})
        .await
        .unwrap()
        .into_inner();

    let mut values = std::collections::HashMap::new();
    values.insert(
        "n".to_string(),
        proto::SettingValue {
            value: Some(proto::setting_value::Value::NumberValue(7.0)),
        },
    );
    client
        .apply_settings(proto::ApplySettingsRequest { values })
        .await
        .unwrap();

    let view = client
        .get_view(proto::GetViewRequest {
            view_id: "main".into(),
        })
        .await
        .unwrap()
        .into_inner();
    assert!(matches!(view.root.unwrap().kind, Some(Kind::Column(_))));
    assert_eq!(
        client
            .get_view(proto::GetViewRequest {
                view_id: "x".into()
            })
            .await
            .unwrap_err()
            .code(),
        tonic::Code::NotFound
    );

    let bad = client
        .invoke_action(proto::InvokeActionRequest {
            view_id: "main".into(),
            action_id: "fail".into(),
            payload: String::new(),
        })
        .await
        .unwrap()
        .into_inner();
    assert_eq!(bad.error, "nope");

    client
        .invoke_action(proto::InvokeActionRequest {
            view_id: "main".into(),
            action_id: "go".into(),
            payload: "1".into(),
        })
        .await
        .unwrap();

    let first = events.next().await.unwrap().unwrap();
    assert!(matches!(
        first.event,
        Some(proto::plugin_event::Event::ViewUpdate(_))
    ));
    let second = events.next().await.unwrap().unwrap();
    assert!(matches!(
        second.event,
        Some(proto::plugin_event::Event::Notification(_))
    ));

    assert_eq!(
        *seen.lock().unwrap(),
        vec!["n=7".to_string(), "go:1".to_string()]
    );

    client.shutdown(proto::ShutdownRequest {}).await.unwrap();
    // The open event stream ends and the server exits.
    assert!(events.next().await.is_none());
    tokio::time::timeout(std::time::Duration::from_secs(5), server)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(!socket.exists());
}

#[test]
fn version_rules() {
    use caelestia_plugin_sdk::{is_compatible, ApiVersion};
    let v = |major, minor| ApiVersion { major, minor };
    assert!(is_compatible(&v(1, 0), &v(1, 0)));
    assert!(is_compatible(&v(1, 0), &v(1, 4)));
    assert!(!is_compatible(&v(1, 2), &v(1, 1)));
    assert!(!is_compatible(&v(1, 0), &v(2, 0)));
}
