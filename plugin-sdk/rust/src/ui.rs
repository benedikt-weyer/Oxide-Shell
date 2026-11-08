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
pub use crate::proto::{
    Align, ButtonStyle, Elide, ProgressShape, Surface, TextStyle, Tone, Urgency,
};

/// A widget. Convert the typed builders with `.into()`.
#[derive(Clone, Debug)]
pub struct Node(pub proto::Node);

impl Node {
    /// Names the node among its siblings (API 1.2). A node whose key is the
    /// same in the next view keeps its widget, so a [`text_input`] keeps its
    /// text and focus and a [`scroll`] its position while the rest changes.
    /// Nodes without a key are matched by position.
    pub fn key(mut self, key: impl Into<String>) -> Self {
        self.0.key = key.into();
        self
    }
}

/// Shorthand for `Node::from(node).key(key)`, usable on any builder.
pub fn keyed(key: impl Into<String>, node: impl Into<Node>) -> Node {
    node.into().key(key)
}

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
                    key: String::new(),
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

    /// Draws the container as a rounded card (API 1.1).
    pub fn surface(mut self, surface: Surface) -> Self {
        self.inner.set_surface(surface);
        self
    }

    /// Inset between a card's edge and its children, in px (API 1.1).
    pub fn padding(mut self, padding: f64) -> Self {
        self.inner.padding = padding;
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
        Node(proto::Node {
            kind: Some(kind),
            key: String::new(),
        })
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

    /// Takes the remaining width of the parent row and elides instead of
    /// wrapping (API 1.1).
    pub fn fill(mut self, elide: Elide) -> Self {
        self.0.fill = true;
        self.0.set_elide(elide);
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

    /// Endless animation instead of `fraction` (API 1.1, linear bars only).
    pub fn indeterminate(mut self, indeterminate: bool) -> Self {
        self.0.indeterminate = indeterminate;
        self
    }

    /// Stretches a linear bar to the available width (API 1.1).
    pub fn fill(mut self) -> Self {
        self.0.fill = true;
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

    /// Stretches to the available width (API 1.1).
    pub fn fill(mut self) -> Self {
        self.0.fill = true;
        self
    }
}
into_node!(Button, Button, |w: Button| w.0);

/// Flexible space, or fixed `size` px when non-zero.
pub fn spacer(size: f64) -> Node {
    Node(proto::Node {
        kind: Some(proto::node::Kind::Spacer(proto::Spacer { size })),
        key: String::new(),
    })
}

pub fn divider() -> Node {
    Node(proto::Node {
        kind: Some(proto::node::Kind::Divider(proto::Divider {})),
        key: String::new(),
    })
}

#[derive(Clone, Debug)]
pub struct Spinner(proto::Spinner);

/// A small animated activity indicator (API 1.1).
pub fn spinner() -> Spinner {
    Spinner(proto::Spinner::default())
}

impl Spinner {
    pub fn size(mut self, size: f64) -> Self {
        self.0.size = size;
        self
    }
}
into_node!(Spinner, Spinner, |w: Spinner| w.0);

#[derive(Clone, Debug)]
pub struct LogView(proto::LogView);

/// A bounded, scrolling list of monospace lines that follows the newest one
/// (API 1.1).
pub fn log_view() -> LogView {
    LogView(proto::LogView::default())
}

impl LogView {
    /// Appends a line; `is_error` lines are shown in the error colour.
    pub fn line(mut self, text: impl Into<String>, is_error: bool) -> Self {
        self.0.lines.push(proto::LogLine {
            text: text.into(),
            is_error,
        });
        self
    }

    pub fn height(mut self, height: f64) -> Self {
        self.0.height = height;
        self
    }

    /// Shown while there are no lines.
    pub fn placeholder(mut self, placeholder: impl Into<String>) -> Self {
        self.0.placeholder = placeholder.into();
        self
    }
}
into_node!(LogView, LogView, |w: LogView| w.0);

#[derive(Clone, Debug)]
pub struct Markdown(proto::Markdown);

/// Text with Markdown formatting, selectable (API 1.2).
pub fn markdown(text: impl Into<String>) -> Markdown {
    Markdown(proto::Markdown {
        text: text.into(),
        ..Default::default()
    })
}

impl Markdown {
    pub fn tone(mut self, tone: Tone) -> Self {
        self.0.set_tone(tone);
        self
    }
}
into_node!(Markdown, Markdown, |w: Markdown| w.0);

#[derive(Clone, Debug)]
pub struct TextInput(proto::TextInput);

/// A text field. Enter (and the submit button) deliver the text to
/// [`Plugin::action`](crate::Plugin::action) as the payload of `action_id`
/// and empty the field; it is only ever changed from the plugin by
/// [`reset_token`](TextInput::reset_token) (API 1.2).
pub fn text_input(action_id: impl Into<String>) -> TextInput {
    TextInput(proto::TextInput {
        action_id: action_id.into(),
        ..Default::default()
    })
}

impl TextInput {
    pub fn placeholder(mut self, placeholder: impl Into<String>) -> Self {
        self.0.placeholder = placeholder.into();
        self
    }

    /// What the field holds initially and after the reset token changed.
    pub fn value(mut self, value: impl Into<String>) -> Self {
        self.0.value = value.into();
        self
    }

    /// Setting this to a different string than in the previous view sets the
    /// field back to its [`value`](Self::value).
    pub fn reset_token(mut self, token: impl Into<String>) -> Self {
        self.0.reset_token = token.into();
        self
    }

    /// Several lines; Shift+Enter inserts a line break.
    pub fn multiline(mut self) -> Self {
        self.0.multiline = true;
        self
    }

    /// Lines the field grows to before it scrolls.
    pub fn max_lines(mut self, lines: u32) -> Self {
        self.0.max_lines = lines;
        self
    }

    /// Material Symbols icon of a submit button inside the field.
    pub fn submit_icon(mut self, icon: impl Into<String>) -> Self {
        self.0.submit_icon = icon.into();
        self
    }

    /// Submitting does nothing while set; typing still works.
    pub fn disabled(mut self, disabled: bool) -> Self {
        self.0.disabled = disabled;
        self
    }

    /// Takes keyboard focus when it appears.
    pub fn autofocus(mut self) -> Self {
        self.0.autofocus = true;
        self
    }
}
into_node!(TextInput, TextInput, |w: TextInput| w.0);

#[derive(Clone, Debug)]
pub struct Select(proto::Select);

/// A chip that opens a list of options; the picked value is delivered to
/// [`Plugin::action`](crate::Plugin::action) as the payload of `action_id`
/// (API 1.2).
pub fn select(action_id: impl Into<String>, selected: impl Into<String>) -> Select {
    Select(proto::Select {
        action_id: action_id.into(),
        selected: selected.into(),
        ..Default::default()
    })
}

impl Select {
    pub fn icon(mut self, icon: impl Into<String>) -> Self {
        self.0.icon = icon.into();
        self
    }

    /// Shown while no option is selected.
    pub fn placeholder(mut self, placeholder: impl Into<String>) -> Self {
        self.0.placeholder = placeholder.into();
        self
    }

    /// Heading of the list.
    pub fn title(mut self, title: impl Into<String>) -> Self {
        self.0.title = title.into();
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.0.disabled = disabled;
        self
    }

    pub fn option(mut self, value: impl Into<String>, label: impl Into<String>) -> Self {
        self.0.options.push(proto::SelectOption {
            value: value.into(),
            label: label.into(),
            ..Default::default()
        });
        self
    }

    /// An option with an icon and a second line.
    pub fn option_full(
        mut self,
        value: impl Into<String>,
        label: impl Into<String>,
        icon: impl Into<String>,
        description: impl Into<String>,
    ) -> Self {
        self.0.options.push(proto::SelectOption {
            value: value.into(),
            label: label.into(),
            icon: icon.into(),
            description: description.into(),
        });
        self
    }
}
into_node!(Select, Select, |w: Select| w.0);

#[derive(Clone, Debug)]
pub struct Scroll(proto::Scroll);

/// Scrolls `child` vertically (API 1.2).
pub fn scroll(child: impl Into<Node>) -> Scroll {
    Scroll(proto::Scroll {
        child: Some(Box::new(child.into().0)),
        ..Default::default()
    })
}

impl Scroll {
    /// Height in px; without it (and without [`expand`](Self::expand)) as high as the child.
    pub fn height(mut self, height: f64) -> Self {
        self.0.height = height;
        self
    }

    /// Takes the remaining height of the parent column.
    pub fn expand(mut self) -> Self {
        self.0.expand = true;
        self
    }

    /// Follows the end while the child grows, until the user scrolls up.
    pub fn stick_to_end(mut self) -> Self {
        self.0.stick_to_end = true;
        self
    }
}
impl From<Scroll> for Node {
    fn from(w: Scroll) -> Node {
        // The variant is boxed: a scroll area contains a node.
        Node(proto::Node {
            kind: Some(proto::node::Kind::Scroll(Box::new(w.0))),
            key: String::new(),
        })
    }
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
