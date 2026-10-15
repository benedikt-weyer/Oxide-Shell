//! Builders for the declarative widget tree a plugin returns from
//! [`Plugin::view`](crate::Plugin::view).
//!
//! ```
//! use caelestia_plugin_sdk::ui::*;
//!
//! let root = column()
//!     .child(text("25:00").style(TextStyle::Display))
//!     .child(button("Start").icon("play_arrow").action("toggle"))
//!     .spacing(12.0)
//!     .align(Align::Center);
//! # let _ = root;
//! ```

use crate::proto;
pub use crate::proto::{Align, ButtonStyle, ProgressShape, TextStyle, Tone, Urgency};

/// A widget. Convert the typed builders with `.into()`.
#[derive(Clone, Debug)]
pub struct Node(pub proto::Node);

impl From<Node> for proto::Node {
    fn from(n: Node) -> Self {
        n.0
    }
}

macro_rules! into_node {
    ($ty:ident, $variant:ident, $inner:expr) => {
        impl From<$ty> for Node {
            fn from(w: $ty) -> Node {
                #[allow(clippy::redundant_closure_call)]
                Node(proto::Node {
                    kind: Some(proto::node::Kind::$variant(($inner)(w))),
                })
            }
        }
    };
}

/// A rendered view: the root node of one dashboard tab.
#[derive(Clone, Debug)]
pub struct View {
    pub id: String,
    pub root: Node,
}

impl View {
    pub fn new(id: impl Into<String>, root: impl Into<Node>) -> Self {
        Self {
            id: id.into(),
            root: root.into(),
        }
    }

    pub(crate) fn into_proto(self) -> proto::View {
        proto::View {
            view_id: self.id,
            root: Some(self.root.0),
        }
    }
}

// ------------------------------------------------------------- containers

/// Vertical or horizontal container, see [`column`] / [`row`].
#[derive(Clone, Debug)]
pub struct Container {
    vertical: bool,
    inner: proto::Box,
}

pub fn column() -> Container {
    Container {
        vertical: true,
        inner: proto::Box::default(),
    }
}

pub fn row() -> Container {
    Container {
        vertical: false,
        inner: proto::Box::default(),
    }
}

impl Container {
    pub fn child(mut self, child: impl Into<Node>) -> Self {
        self.inner.children.push(child.into().0);
        self
    }

    pub fn children(mut self, children: impl IntoIterator<Item = impl Into<Node>>) -> Self {
        self.inner
            .children
            .extend(children.into_iter().map(|c| c.into().0));
        self
    }

    pub fn spacing(mut self, spacing: f64) -> Self {
        self.inner.spacing = spacing;
        self
    }

    pub fn align(mut self, align: Align) -> Self {
        self.inner.set_align(align);
        self
    }

    /// Stretch to the available width.
    pub fn fill(mut self) -> Self {
        self.inner.fill = true;
        self
    }
}

impl From<Container> for Node {
    fn from(b: Container) -> Node {
        let kind = if b.vertical {
            proto::node::Kind::Column(b.inner)
        } else {
            proto::node::Kind::Row(b.inner)
        };
        Node(proto::Node { kind: Some(kind) })
    }
}

// ----------------------------------------------------------------- leaves

#[derive(Clone, Debug)]
pub struct Text(proto::Text);

pub fn text(text: impl Into<String>) -> Text {
    Text(proto::Text {
        text: text.into(),
        ..Default::default()
    })
}

impl Text {
    pub fn style(mut self, style: TextStyle) -> Self {
        self.0.set_style(style);
        self
    }

    pub fn tone(mut self, tone: Tone) -> Self {
        self.0.set_tone(tone);
        self
    }
}
into_node!(Text, Text, |w: Text| w.0);

#[derive(Clone, Debug)]
pub struct Icon(proto::Icon);

pub fn icon(name: impl Into<String>) -> Icon {
    Icon(proto::Icon {
        name: name.into(),
        ..Default::default()
    })
}

impl Icon {
    pub fn size(mut self, size: f64) -> Self {
        self.0.size = size;
        self
    }

    pub fn tone(mut self, tone: Tone) -> Self {
        self.0.set_tone(tone);
        self
    }
}
into_node!(Icon, Icon, |w: Icon| w.0);

#[derive(Clone, Debug)]
pub struct Progress(proto::Progress);

/// Ring indicator. `fraction` is clamped to 0..=1.
pub fn progress_circular(fraction: f64) -> Progress {
    Progress(proto::Progress {
        fraction: clamp01(fraction),
        ..Default::default()
    })
}

/// Horizontal bar. `fraction` is clamped to 0..=1.
pub fn progress_linear(fraction: f64) -> Progress {
    let mut p = progress_circular(fraction);
    p.0.set_shape(ProgressShape::Linear);
    p
}

fn clamp01(v: f64) -> f64 {
    if v.is_nan() {
        0.0
    } else {
        v.clamp(0.0, 1.0)
    }
}

impl Progress {
    pub fn label(mut self, label: impl Into<String>) -> Self {
        self.0.label = label.into();
        self
    }

    pub fn sublabel(mut self, sublabel: impl Into<String>) -> Self {
        self.0.sublabel = sublabel.into();
        self
    }

    pub fn tone(mut self, tone: Tone) -> Self {
        self.0.set_tone(tone);
        self
    }

    pub fn size(mut self, size: f64) -> Self {
        self.0.size = size;
        self
    }
}
into_node!(Progress, Progress, |w: Progress| w.0);

#[derive(Clone, Debug)]
pub struct Button(proto::Button);

pub fn button(label: impl Into<String>) -> Button {
    Button(proto::Button {
        label: label.into(),
        ..Default::default()
    })
}

impl Button {
    pub fn icon(mut self, icon: impl Into<String>) -> Self {
        self.0.icon = icon.into();
        self
    }

    /// Identifier delivered to [`Plugin::action`](crate::Plugin::action).
    pub fn action(mut self, action_id: impl Into<String>) -> Self {
        self.0.action_id = action_id.into();
        self
    }

    pub fn payload(mut self, payload: impl Into<String>) -> Self {
        self.0.payload = payload.into();
        self
    }

    pub fn style(mut self, style: ButtonStyle) -> Self {
        self.0.set_style(style);
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.0.disabled = disabled;
        self
    }
}
into_node!(Button, Button, |w: Button| w.0);

/// Flexible space, or fixed `size` px when non-zero.
pub fn spacer(size: f64) -> Node {
    Node(proto::Node {
        kind: Some(proto::node::Kind::Spacer(proto::Spacer { size })),
    })
}

pub fn divider() -> Node {
    Node(proto::Node {
        kind: Some(proto::node::Kind::Divider(proto::Divider {})),
    })
}

/// A toast the shell shows on the plugin's behalf, see [`Context::notify`](crate::Context::notify).
#[derive(Clone, Debug, Default)]
pub struct Notification {
    pub title: String,
    pub body: String,
    pub icon: String,
    pub urgency: i32,
}

impl Notification {
    pub fn new(title: impl Into<String>, body: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            body: body.into(),
            ..Default::default()
        }
    }

    pub fn icon(mut self, icon: impl Into<String>) -> Self {
        self.icon = icon.into();
        self
    }

    pub fn urgency(mut self, urgency: Urgency) -> Self {
        self.urgency = urgency as i32;
        self
    }
}
