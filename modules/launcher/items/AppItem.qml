import QtQuick
import Quickshell
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.services
import qs.utils
import qs.modules.launcher.services

Item {
    id: root

    required property DesktopEntry modelData
    required property ScreenState screenState

    // The key hint for starting this app in a VM, shown only on the
    // highlighted entry and only while the compositor can do that.
    readonly property bool showVmHint: ListView.isCurrentItem && VmLauncher.usable

    implicitHeight: Tokens.sizes.launcher.itemHeight

    anchors.left: parent?.left
    anchors.right: parent?.right

    StateLayer {
        radius: Tokens.rounding.large
        onClicked: {
            Apps.launch(root.modelData);
            root.screenState.launcher = false;
        }
    }

    Item {
        anchors.fill: parent
        anchors.leftMargin: Tokens.padding.medium
        anchors.rightMargin: Tokens.padding.medium
        anchors.margins: Tokens.padding.small

        IconImage {
            id: icon

            asynchronous: true
            source: Quickshell.iconPath(root.modelData?.icon, "image-missing")
            implicitSize: parent.height * 0.8

            anchors.verticalCenter: parent.verticalCenter
        }

        Item {
            anchors.left: icon.right
            anchors.leftMargin: Tokens.spacing.medium
            anchors.verticalCenter: icon.verticalCenter

            implicitWidth: parent.width - icon.width - favouriteIcon.width - (root.showVmHint ? vmHint.implicitWidth + Tokens.spacing.medium : 0)
            implicitHeight: name.implicitHeight + comment.implicitHeight

            StyledText {
                id: name

                text: root.modelData?.name ?? ""
                font: Tokens.font.body.medium
            }

            StyledText {
                id: comment

                text: (root.modelData?.comment || root.modelData?.genericName || root.modelData?.name) ?? ""
                font: Tokens.font.body.small
                color: Colours.palette.m3outline

                elide: Text.ElideRight
                width: root.width - icon.width - favouriteIcon.width - Tokens.rounding.extraLargeIncreased - (root.showVmHint ? vmHint.implicitWidth + Tokens.spacing.medium : 0)

                anchors.top: name.bottom
            }
        }

        Row {
            id: vmHint

            visible: root.showVmHint
            spacing: Tokens.spacing.small

            anchors.verticalCenter: parent.verticalCenter
            anchors.right: favouriteIcon.left
            anchors.rightMargin: Tokens.spacing.medium

            MaterialIcon {
                anchors.verticalCenter: parent.verticalCenter
                text: "chevron_left"
                color: Colours.palette.m3outline
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("VM")
                font: Tokens.font.body.small
                color: Colours.palette.m3outline
            }

            MaterialIcon {
                anchors.verticalCenter: parent.verticalCenter
                text: "chevron_right"
                color: Colours.palette.m3outline
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Persistent")
                font: Tokens.font.body.small
                color: Colours.palette.m3outline
            }
        }

        Loader {
            id: favouriteIcon

            asynchronous: true
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            active: root.modelData && Strings.testRegexList(GlobalConfig.launcher.favouriteApps, root.modelData.id)

            sourceComponent: MaterialIcon {
                text: "favorite"
                fill: 1
                color: Colours.palette.m3primary
            }
        }
    }
}
