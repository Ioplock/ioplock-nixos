import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Compact wallpaper overlay that drops down under the status bar. The card
// auto-sizes to the tile grid (fixed cell size), so spacing is always even -
// no ragged edges. Browse with the arrow keys or pointer, apply with
// Enter/Space/click, close with Esc.
// Opened from niri via: Mod+Shift+W -> quickshell ipc call wallpaperPicker toggle.
PanelWindow {
    id: picker

    property var appSettings

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.exclusiveZone: 0
    // Exclusive keyboard focus while open: arrows/Enter/Esc work immediately.
    WlrLayershell.keyboardFocus: picker.visible
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    // Full-width transparent window (PanelWindow has no horizontalCenter
    // anchor); the card is centered inside it.
    anchors {
        top: true
        left: true
        right: true
    }

    margins {
        top: (appSettings ? appSettings.barHeight : 34) + 8
    }

    focusable: false
    color: "transparent"
    visible: false
    implicitHeight: picker.cardH

    // Sizing: a fixed tile grid plus chrome (title, hint, padding). The card
    // shrink-wraps the grid so tiles always fill it evenly.
    readonly property real tileW: 204
    readonly property real tileH: 116
    readonly property real spacing: 12
    readonly property real pad: 14
    readonly property int maxRows: 4
    readonly property real placeholderW: 420
    // Cell size equals the tile size; the tile is inset by spacing/2, so the
    // grid is exactly cols*tileW wide and every column fits evenly.
    readonly property real cellW: picker.tileW
    readonly property real cellH: picker.tileH
    readonly property int cols: Math.max(1, Math.min(picker.wallpapers.length, 4))
    readonly property int rows: Math.max(1, Math.ceil(picker.wallpapers.length / picker.cols))
    readonly property real gridW: picker.cols * picker.tileW
    readonly property real gridH: Math.min(picker.rows, picker.maxRows) * picker.tileH
    readonly property real cardW: picker.wallpapers.length > 0
        ? picker.gridW + 2 * picker.pad
        : picker.placeholderW + 2 * picker.pad
    readonly property real cardH: (picker.wallpapers.length > 0 ? picker.gridH : 116)
        + 2 * picker.pad + 24 + 16 + 2 * 10

    property var wallpapers: []

    onVisibleChanged: {
        if (picker.visible) {
            picker.refresh()
            grid.forceActiveFocus()
        }
    }

    // Highlights the wallpaper that is currently applied, so reopening the
    // picker preselected the last choice. Runs once the listing has finished,
    // since `appSettings.wallpaper` may not be loaded yet when the picker is
    // first created.
    function selectApplied() {
        if (grid.count === 0) return
        for (let i = 0; i < picker.wallpapers.length; i++) {
            if (picker.wallpapers[i].path === appSettings.wallpaper) {
                grid.currentIndex = i
                grid.positionViewAtIndex(i, GridView.Center)
                return
            }
        }
    }

    function apply(path) {
        if (!path) return
        appSettings.wallpaper = path
        picker.visible = false
    }

    function refresh() {
        picker.wallpapers = []
        listProcess.running = true
    }

    Process {
        id: listProcess
        command: [ "list-wallpapers" ]

        onExited: picker.selectApplied()

        stdout: SplitParser {
            onRead: data => {
                const line = `${data}`.trim()
                if (!line) return

                const file = line.split("/").pop()
                const dot = file.lastIndexOf(".")
                const stem = dot > 0 ? file.slice(0, dot) : file

                picker.wallpapers = picker.wallpapers.concat([{
                    path: line,
                    name: stem.replace(/[_-]+/g, " ")
                        .replace(/\s+/g, " ").trim(),
                }])
            }
        }
    }

    Rectangle {
        id: card
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: picker.cardW
        height: picker.cardH
        radius: 14
        color: Qt.rgba(0.118, 0.118, 0.180, 0.96)
        border.color: Qt.rgba(0.969, 0.478, 0.961, 0.35)
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: picker.pad
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: picker.wallpapers.length > 0 ? "Wallpapers" : "No wallpapers"
                    font.pixelSize: appSettings ? appSettings.fontSize + 5 : 18
                    font.weight: Font.Bold
                    color: appSettings ? appSettings.textColor : "#cdd6f4"
                }

                Item {
                    Layout.fillWidth: true
                }

                Text {
                    visible: picker.wallpapers.length > 0
                    text: picker.wallpapers.length + " found"
                    font.pixelSize: appSettings ? appSettings.fontSize - 2 : 11
                    color: appSettings ? appSettings.textColor : "#cdd6f4"
                    opacity: 0.5
                }
            }

            GridView {
                id: grid
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: picker.gridW
                Layout.preferredHeight: picker.gridH
                visible: picker.wallpapers.length > 0
                clip: true
                cellWidth: picker.cellW
                cellHeight: picker.cellH
                model: picker.wallpapers
                boundsBehavior: Flickable.StopAtBounds
                keyNavigationWraps: true
                focus: picker.visible
                currentIndex: -1

                Keys.onLeftPressed: event => {
                    grid.moveCurrentIndexLeft()
                    event.accepted = true
                }
                Keys.onRightPressed: event => {
                    grid.moveCurrentIndexRight()
                    event.accepted = true
                }
                Keys.onUpPressed: event => {
                    grid.moveCurrentIndexUp()
                    event.accepted = true
                }
                Keys.onDownPressed: event => {
                    grid.moveCurrentIndexDown()
                    event.accepted = true
                }
                Keys.onReturnPressed: event => {
                    grid.commit()
                    event.accepted = true
                }
                Keys.onSpacePressed: event => {
                    grid.commit()
                    event.accepted = true
                }
                Keys.onEscapePressed: event => {
                    picker.visible = false
                    event.accepted = true
                }

                onCountChanged: {
                    if (grid.count > 0 && picker.visible)
                        picker.selectApplied()
                }

                function commit() {
                    if (grid.currentIndex >= 0 && grid.currentIndex < picker.wallpapers.length)
                        picker.apply(picker.wallpapers[grid.currentIndex].path)
                }

                delegate: Item {
                    id: tile
                    required property var modelData
                    required property int index

                    readonly property bool active: tile.index === grid.currentIndex
                    readonly property bool hovered: mouse.containsMouse

                    width: picker.tileW
                    height: picker.tileH

                    Rectangle {
                        id: tileCard
                        anchors.fill: parent
                        anchors.margins: picker.spacing / 2
                        radius: 10
                        color: tile.hovered || tile.active
                            ? Qt.lighter(appSettings.barColor, 1.4)
                            : Qt.lighter(appSettings.barColor, 1.1)
                        border.color: tile.active
                            ? appSettings.accentColor
                            : (tile.hovered ? Qt.rgba(0.969, 0.478, 0.961, 0.5) : "transparent")
                        border.width: 2

                        Behavior on color { ColorAnimation { duration: 90 } }
                        Behavior on border.color { ColorAnimation { duration: 90 } }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 5
                            spacing: 4

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: 7
                                clip: true
                                color: "#0a0a0f"

                                Image {
                                    anchors.fill: parent
                                    source: "file://" + tile.modelData.path
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize: Qt.size(picker.tileW * 2, picker.tileH * 2)
                                    mipmap: true
                                    asynchronous: true
                                }

                                Rectangle {
                                    visible: tile.modelData.path === appSettings.wallpaper
                                    anchors.top: parent.top
                                    anchors.right: parent.right
                                    anchors.margins: 5
                                    width: 17
                                    height: 17
                                    radius: 9
                                    color: appSettings.accentColor

                                    Text {
                                        anchors.centerIn: parent
                                        text: "\u2713"
                                        color: "#14141f"
                                        font.pixelSize: 11
                                        font.weight: Font.Bold
                                    }
                                }
                            }

                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.maximumWidth: picker.tileW - picker.spacing
                                text: tile.modelData.name
                                font.pixelSize: appSettings ? appSettings.fontSize - 1 : 12
                                color: appSettings ? appSettings.textColor : "#cdd6f4"
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                grid.currentIndex = tile.index
                                picker.apply(tile.modelData.path)
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: picker.placeholderW
                Layout.preferredHeight: 116
                radius: 10
                color: Qt.lighter(appSettings.barColor, 1.1)
                visible: picker.wallpapers.length === 0

                Text {
                    anchors.centerIn: parent
                    text: "No wallpapers found in ~/wallpapers"
                    font.pixelSize: appSettings ? appSettings.fontSize : 13
                    color: appSettings ? appSettings.textColor : "#cdd6f4"
                    opacity: 0.7
                }
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                visible: picker.wallpapers.length > 0
                text: "\u2190\u2192\u2191\u2193 move   \u2022   Enter apply   \u2022   Esc close"
                font.pixelSize: appSettings ? appSettings.fontSize - 2 : 11
                color: appSettings ? appSettings.textColor : "#cdd6f4"
                opacity: 0.45
            }
        }
    }
}
