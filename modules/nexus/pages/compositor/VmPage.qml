import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.nexus.common

PageBase {
    id: root

    readonly property var cfg: IronlandCtl.config
    readonly property var vm: cfg?.vm

    title: qsTr("Virtual machines")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        CompositorError {}

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: Tokens.spacing.small
            text: qsTr("In the launcher, Left opens the apps that start in a throw-away VM and Right the ones that start in a persistent VM, which keeps its files and resumes quickly. Changes apply to the next VM launch.")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.label.small
            wrapMode: Text.WordWrap
        }

        SectionHeader {
            first: true
            text: qsTr("Programs")
        }

        InfoRow {
            first: true
            last: true
            label: qsTr("Set up for VMs")
            subtext: qsTr("Each runs in its own VM image with only that program installed. Add them under [vm.programs] in the compositor config or, on NixOS, services.ironland-compositor.vm.programs")
            value: VmLauncher.programs.length > 0 ? VmLauncher.programs.join(", ") : qsTr("None")
        }

        SectionHeader {
            text: qsTr("Guest")
        }

        TextFieldRow {
            first: true
            last: true
            label: qsTr("Guest user")
            subtext: qsTr("Account the compositor logs in as inside the guest")
            value: root.vm?.user ?? "user"
            onEditingFinished: v => IronlandCtl.setValue("vm.user", v.trim() || "user")
        }

        SectionHeader {
            text: qsTr("Login")
        }

        TextFieldRow {
            first: true
            label: qsTr("Private key")
            subtext: qsTr("Empty logs in through your ssh-agent or ~/.ssh")
            placeholderText: qsTr("~/.ssh/id_ed25519")
            value: root.vm?.ssh_key ?? ""
            onEditingFinished: v => IronlandCtl.setValue("vm.ssh_key", v.trim())
        }

        TextFieldRow {
            label: qsTr("Public key file")
            subtext: qsTr("The key the guest accepts. With this and the field below empty: the private key's .pub, else ~/.ssh/id_ed25519.pub plus the ssh-agent's keys")
            placeholderText: qsTr("~/.ssh/id_ed25519.pub")
            value: root.vm?.public_key_file ?? ""
            onEditingFinished: v => IronlandCtl.setValue("vm.public_key_file", v.trim())
        }

        TextFieldRow {
            last: true
            label: qsTr("Public key")
            subtext: qsTr("The key itself, instead of a file")
            placeholderText: qsTr("ssh-ed25519 AAAA…")
            value: root.vm?.public_key ?? ""
            onEditingFinished: v => IronlandCtl.setValue("vm.public_key", v.trim())
        }

        SectionHeader {
            text: qsTr("Resources")
        }

        StepperRow {
            first: true
            label: qsTr("Memory (MiB)")
            subtext: qsTr("RAM for each VM")
            from: 256
            to: 65536
            stepSize: 256
            value: root.vm?.memory_mb ?? 2048
            onMoved: v => IronlandCtl.setValue("vm.memory_mb", String(v))
        }

        StepperRow {
            label: qsTr("CPUs")
            subtext: qsTr("Virtual CPUs for each VM")
            from: 1
            to: 64
            value: root.vm?.cpus ?? 2
            onMoved: v => IronlandCtl.setValue("vm.cpus", String(v))
        }

        StepperRow {
            label: qsTr("Max running VMs")
            subtext: qsTr("Further launches are refused until one exits")
            from: 1
            to: 64
            value: root.vm?.max_instances ?? 8
            onMoved: v => IronlandCtl.setValue("vm.max_instances", String(v))
        }

        ToggleRow {
            last: true
            text: qsTr("Use KVM acceleration")
            subtext: qsTr("Turn off only where /dev/kvm isn't available; the guest is then far slower")
            checked: root.vm?.kvm ?? true
            onToggled: IronlandCtl.setValue("vm.kvm", checked ? "true" : "false")
        }
    }
}
