pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

// Fullscreen Overlay power menu, shown per-screen via Variants.
// Adapted from quickshell-examples/wlogout/WLogout.qml but:
// - controlled by a `visible` bool (no Qt.quit())
// - themed via appSettings (barColor/accentColor/textColor)
// - minimal set: Lock/Suspend/Reboot/Poweroff; mimosa hides Lock via showLock.
Variants {
    id: root

    property var appSettings
    property bool showLock: true
    property bool overlayVisible: false

    // Built button model; filtered by showLock so mimosa has 3 entries grid adapts.
    property list<PowerButton> allButtons: [
        PowerButton { command: "qs ipc call lock lock"; text: "Lock"; icon: "\uF023"; keybind: Qt.Key_L; description: "Lock screen" },
        PowerButton { command: "systemctl suspend"; text: "Suspend"; icon: "\uF28C"; keybind: Qt.Key_S; description: "Suspend" },
        PowerButton { command: "systemctl reboot"; text: "Reboot"; icon: "\uF021"; keybind: Qt.Key_R; description: "Reboot" },
        PowerButton { command: "systemctl poweroff"; text: "Power Off"; icon: "\uF011"; keybind: Qt.Key_P; description: "Power off" }
    ]

    readonly property var buttons: showLock ? allButtons : allButtons.slice(1)
    readonly property color bgDim: Qt.rgba(
        appSettings ? Qt.color(appSettings.barColor).r : 0.118,
        appSettings ? Qt.color(appSettings.barColor).g : 0.118,
        appSettings ? Qt.color(appSettings.barColor).b : 0.180,
        0.78
    )
    readonly property color cardBg: appSettings ? appSettings.barColor : "#1e1e2e"
    readonly property color accent: appSettings ? appSettings.accentColor : "#f77af5ff"
    readonly property color textC: appSettings ? appSettings.textColor : "#cdd6f4"
    readonly property string fontFam: appSettings ? appSettings.fontFamily : "sans-serif"
    readonly property string iconFam: appSettings ? appSettings.iconFontFamily : "JetBrainsMono Nerd Font"
    readonly property int fontSz: appSettings ? appSettings.fontSize : 13

    model: root.overlayVisible ? Quickshell.screens : []

    delegate: PanelWindow {
        id: win
        required property var modelData

        screen: modelData

        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.overlayVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        color: "transparent"
        focusable: true

        anchors {
            top: true
            left: true
            bottom: true
            right: true
        }

        // Dismiss on Escape / handle keybinds at window level.
        contentItem {
            focus: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    root.overlayVisible = false
                    event.accepted = true
                } else {
                    for (let i = 0; i < root.buttons.length; i++) {
                        const b = root.buttons[i]
                        if (b.keybind !== null && event.key === b.keybind) {
                            root.overlayVisible = false
                            b.exec()
                            event.accepted = true
                            return
                        }
                    }
                    // Enter on focused tile
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (grid.currentIndex >= 0 && grid.currentIndex < root.buttons.length) {
                            const b2 = root.buttons[grid.currentIndex]
                            root.overlayVisible = false
                            b2.exec()
                            event.accepted = true
                        }
                    }
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            color: root.bgDim

            MouseArea {
                anchors.fill: parent
                onClicked: root.overlayVisible = false

                // Centered card
                Rectangle {
                    id: card
                    anchors.centerIn: parent
                    width: Math.min(parent.width * 0.56, 560)
                    implicitHeight: cardCol.implicitHeight + 28
                    radius: 16
                    color: Qt.rgba(Qt.color(root.cardBg).r, Qt.color(root.cardBg).g, Qt.color(root.cardBg).b, 0.96)
                    border.color: Qt.rgba(Qt.color(root.accent).r, Qt.color(root.accent).g, Qt.color(root.accent).b, 0.35)
                    border.width: 1

                    // click inside card shouldn't dismiss
                    MouseArea { anchors.fill: parent; onClicked: mouse => mouse.accepted = true }

                    ColumnLayout {
                        id: cardCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 14
                        spacing: 12

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text {
                                text: "\uF011"
                                font.family: root.iconFam
                                font.pixelSize: root.fontSz + 6
                                color: root.accent
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Text {
                                    text: "Power"
                                    font.family: root.fontFam
                                    font.pixelSize: root.fontSz + 4
                                    font.weight: Font.Bold
                                    color: root.textC
                                }
                                Text {
                                    text: "Esc to close • Arrow keys + Enter, or L/S/R/P"
                                    font.family: root.fontFam
                                    font.pixelSize: root.fontSz - 3
                                    color: root.textC
                                    opacity: 0.5
                                }
                            }
                            Rectangle {
                                Layout.preferredWidth: 28
                                Layout.preferredHeight: 28
                                radius: 14
                                color: closeMa.containsMouse ? Qt.lighter(root.cardBg, 1.4) : "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: "\uF00D"
                                    font.family: root.iconFam
                                    font.pixelSize: root.fontSz
                                    color: root.textC
                                    opacity: closeMa.containsMouse ? 1.0 : 0.6
                                }
                                MouseArea {
                                    id: closeMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.overlayVisible = false
                                }
                            }
                        }

                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.accent; opacity: 0.28 }

                        GridView {
                            id: grid
                            Layout.fillWidth: true
                            Layout.preferredHeight: cellHeight * Math.ceil(root.buttons.length / 2)
                            clip: true
                            model: root.buttons
                            cellWidth: width / 2
                            cellHeight: 112
                            focus: root.overlayVisible
                            currentIndex: 0
                            keyNavigationWraps: true
                            boundsBehavior: Flickable.StopAtBounds

                            Keys.onLeftPressed: event => { grid.moveCurrentIndexLeft(); event.accepted = true }
                            Keys.onRightPressed: event => { grid.moveCurrentIndexRight(); event.accepted = true }
                            Keys.onUpPressed: event => { grid.moveCurrentIndexUp(); event.accepted = true }
                            Keys.onDownPressed: event => { grid.moveCurrentIndexDown(); event.accepted = true }

                            delegate: Item {
                                id: tile
                                required property PowerButton modelData
                                required property int index
                                readonly property bool isCurrent: grid.currentIndex === index
                                readonly property bool hovered: ma.containsMouse

                                width: grid.cellWidth
                                height: grid.cellHeight

                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    radius: 12
                                    color: (hovered || isCurrent) ? Qt.lighter(root.cardBg, 1.35) : Qt.darker(root.cardBg, 1.1)
                                    border.color: isCurrent ? root.accent : (hovered ? Qt.rgba(Qt.color(root.accent).r, Qt.color(root.accent).g, Qt.color(root.accent).b, 0.5) : "transparent")
                                    border.width: isCurrent || hovered ? 1 : 0

                                    Behavior on color { ColorAnimation { duration: 90 } }

                                    ColumnLayout {
                                        anchors.centerIn: parent
                                        spacing: 6
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: tile.modelData.icon
                                            font.family: root.iconFam
                                            font.pixelSize: 28
                                            color: tile.isCurrent || tile.hovered ? root.accent : root.textC
                                        }
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: tile.modelData.text
                                            font.family: root.fontFam
                                            font.pixelSize: root.fontSz
                                            font.weight: tile.isCurrent ? Font.Bold : Font.Normal
                                            color: root.textC
                                        }
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            visible: tile.modelData.keybind !== null
                                            text: {
                                                const k = tile.modelData.keybind
                                                if (k === Qt.Key_L) return "[L]"
                                                if (k === Qt.Key_S) return "[S]"
                                                if (k === Qt.Key_R) return "[R]"
                                                if (k === Qt.Key_P) return "[P]"
                                                return ""
                                            }
                                            font.family: root.fontFam
                                            font.pixelSize: root.fontSz - 4
                                            color: root.textC
                                            opacity: 0.45
                                        }
                                    }

                                    MouseArea {
                                        id: ma
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onEntered: grid.currentIndex = tile.index
                                        onClicked: {
                                            grid.currentIndex = tile.index
                                            root.overlayVisible = false
                                            tile.modelData.exec()
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "Tip: Lock is also available via Mod+Ctrl+Alt+L"
                            visible: root.showLock
                            font.family: root.fontFam
                            font.pixelSize: root.fontSz - 3
                            color: root.textC
                            opacity: 0.38
                        }
                    }
                }
            }
        }

        // Ensure grid gets focus when overlay appears
        onVisibleChanged: if (visible) grid.forceActiveFocus()
    }

    onOverlayVisibleChanged: {
        if (overlayVisible && Quickshell.screens.length > 0) {
            // focus will be handled per-window onVisibleChanged
        }
    }
}
