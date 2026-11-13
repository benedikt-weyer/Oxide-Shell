pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.utils
import qs.modules.nexus.common

// Password sub-page for a secured Wi-Fi network that needs one. Opened by
// NetworkList when NetworkManager reports that secrets are required.
PageBase {
    id: root

    readonly property string ssid: nState.selectedNetworkSsid
    readonly property var ap: Nmcli.findNetwork(root.ssid)
    readonly property bool isActive: !!Nmcli.active && Nmcli.active.ssid === root.ssid

    property bool connecting: false
    property bool failed: false
    property bool done: false

    function submit(): void {
        if (root.connecting || !root.ap || passwordField.text.length === 0)
            return;

        root.failed = false;
        root.connecting = true;
        timeout.restart();

        NetworkConnection.connectWithPassword(root.ap, passwordField.text, result => {
            // Nmcli reports a timeout while the activation can still be going
            // on (the success is picked up through Nmcli.active below).
            if (root.done || !root.connecting || (result && result.error === "Connection timeout"))
                return;

            if (result && result.success) {
                root.finish();
            } else {
                root.fail();
            }
        });
    }

    function finish(): void {
        if (root.done)
            return;

        root.done = true;
        root.connecting = false;
        timeout.stop();
        root.nState.closeSubPage();
    }

    function fail(): void {
        if (root.done || !root.connecting)
            return;

        root.connecting = false;
        root.failed = true;
        timeout.stop();
        passwordField.isError = true;
        passwordField.text = "";
        passwordField.forceActiveFocus();
        // Don't keep the half-created profile around, or the next try would
        // start from a profile with a wrong password.
        Nmcli.forgetNetwork(root.ssid);
    }

    title: qsTr("Enter password")
    isSubPage: true

    Component.onCompleted: passwordField.forceActiveFocus()

    onIsActiveChanged: {
        if (root.isActive && root.connecting)
            root.finish();
    }

    Timer {
        id: timeout

        interval: 45000
        onTriggered: root.fail()
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.large

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.extraSmall
            text: qsTr("Enter the password for %1.").arg(root.ssid)
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            wrapMode: Text.WordWrap
        }

        StyledTextField {
            id: passwordField

            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.extraSmall
            enabled: !root.connecting
            placeholderText: qsTr("Password")
            leadingIcon: "key"
            echoMode: TextInput.Password
            errorText: root.failed ? qsTr("Connection failed — check the password") : ""

            onAccepted: root.submit()
            onTextChanged: {
                if (text.length > 0) {
                    isError = false;
                    root.failed = false;
                }
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignRight
            Layout.topMargin: Tokens.spacing.extraSmall - parent.spacing
            spacing: Tokens.spacing.small

            TextButton {
                Layout.fillHeight: true
                isRound: true
                horizontalPadding: Tokens.padding.extraLarge
                type: TextButton.Tonal
                text: qsTr("Cancel")
                onClicked: root.nState.closeSubPage()
            }

            ButtonBase {
                id: connectBtn

                shapeMorph: true
                isRound: true
                inactiveColour: Colours.palette.m3primary
                inactiveOnColour: Colours.palette.m3onPrimary
                stateLayer.disabled: root.connecting || passwordField.text.length === 0

                implicitWidth: connectMetrics.width + Tokens.padding.extraLarge * 2
                implicitHeight: connectMetrics.height + Tokens.padding.medium * 2

                onClicked: root.submit()

                TextMetrics {
                    id: connectMetrics

                    text: qsTr("Connect")
                    font: connectBtn.font
                }

                AnimLoader {
                    anchors.centerIn: parent
                    sourceComp: root.connecting ? connectLoadingComp : connectTextComp
                    outAnimType: Anim.SlowEffects
                    inAnimType: Anim.SlowEffects
                }

                Component {
                    id: connectLoadingComp

                    LoadingIndicator {
                        implicitSize: Math.round(Tokens.font.body.medium.pointSize * 1.4)
                        color: connectBtn.onColour
                    }
                }

                Component {
                    id: connectTextComp

                    StyledText {
                        text: connectMetrics.text
                        font: connectBtn.font
                        color: connectBtn.onColour
                    }
                }
            }
        }
    }
}
