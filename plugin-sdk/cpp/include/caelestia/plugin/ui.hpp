#pragma once

#include <string>
#include <variant>
#include <vector>

// The declarative widget vocabulary of the plugin API (see
// plugin-sdk/proto/caelestia_plugin.proto). Everything is a plain aggregate,
// so a view reads like a literal:
//
//   using namespace caelestia::plugin::ui;
//   View{"main", Column{
//       .spacing = 12,
//       .align = Align::Center,
//       .children = {
//           Text{.text = "25:00", .style = TextStyle::Display},
//           Button{.label = "Start", .icon = "play_arrow", .actionId = "toggle"},
//       }}};
namespace caelestia::plugin::ui {

enum class Tone {
    Default,
    Primary,
    Secondary,
    Tertiary,
    Muted,
    Error
};
enum class Align {
    Start,
    Center,
    End
};
enum class TextStyle {
    Body,
    Label,
    Title,
    Display
};
enum class ProgressShape {
    Circular,
    Linear
};
enum class ButtonStyle {
    Filled,
    Tonal,
    Text
};
enum class Urgency {
    Normal,
    Low,
    Critical
};

struct Node;

// Vertical stack. `fill` stretches it to the available width.
struct Column {
    double spacing = 0;
    Align align = Align::Start;
    bool fill = false;
    std::vector<Node> children;
};

struct Row {
    double spacing = 0;
    Align align = Align::Start;
    bool fill = false;
    std::vector<Node> children;
};

struct Text {
    std::string text;
    TextStyle style = TextStyle::Body;
    Tone tone = Tone::Default;
};

struct Icon {
    // Material Symbols name.
    std::string name;
    double size = 0;
    Tone tone = Tone::Default;
};

struct Progress {
    // 0..1, clamped when sent.
    double fraction = 0;
    ProgressShape shape = ProgressShape::Circular;
    std::string label;
    std::string sublabel;
    Tone tone = Tone::Default;
    // Diameter (circular) or width (linear); 0 picks a default.
    double size = 0;
};

struct Button {
    std::string label;
    std::string icon;
    // Delivered to Plugin::action().
    std::string actionId;
    std::string payload;
    ButtonStyle style = ButtonStyle::Filled;
    bool disabled = false;
};

// Flexible space, or a fixed `size` px if non-zero.
struct Spacer {
    double size = 0;
};

struct Divider {};

struct Node {
    std::variant<Column, Row, Text, Icon, Progress, Button, Spacer, Divider> value;

    Node(Column v)
        : value(std::move(v)) {}

    Node(Row v)
        : value(std::move(v)) {}

    Node(Text v)
        : value(std::move(v)) {}

    Node(Icon v)
        : value(std::move(v)) {}

    Node(Progress v)
        : value(std::move(v)) {}

    Node(Button v)
        : value(std::move(v)) {}

    Node(Spacer v)
        : value(std::move(v)) {}

    Node(Divider v)
        : value(std::move(v)) {}
};

// The root of one dashboard tab.
struct View {
    std::string id;
    Node root;
};

// A toast the shell shows on the plugin's behalf.
struct Notification {
    std::string title;
    std::string body;
    std::string icon;
    Urgency urgency = Urgency::Normal;
};

} // namespace caelestia::plugin::ui
