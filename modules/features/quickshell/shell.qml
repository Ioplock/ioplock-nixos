import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    property var status: ["?", "Desktop", "unknown", "unknown", "disconnected", "off", "AC"]
    property date dateTime: new Date()

    // QS_MINIMAL=1 hides the status bar entirely (wallpaper and picker only).
    // QS_COMPACT=1 (gaming niri build) keeps only gaming-relevant widgets:
    // settings, workspace, focused window, clock, keyboard layout and
    // volume. Wifi, bluetooth and battery are hidden.
    readonly property bool minimal: Quickshell.env("QS_MINIMAL") === "1"
    readonly property bool compact: Quickshell.env("QS_COMPACT") === "1"

    Settings {
        id: appSettings
    }

    SettingsWindow {
        id: settingsWindow
        appSettings: appSettings
    }

    // QS_ENABLE_LOCK=0 disables the lock screen entirely (gaming host mimosa).
    // QuickShell.env returns "" if unset, so default is enabled.
    readonly property bool lockEnabled: Quickshell.env("QS_ENABLE_LOCK") !== "0"

    LockContext {
        id: lockContext
        onUnlocked: lock.locked = false
    }

    // Secure session lock — one WlSessionLockSurface per screen when locked.
    // Must set locked=false before exit or compositor shows solid fallback.
    WlSessionLock {
        id: lock
        locked: false
        WlSessionLockSurface {
            LockSurface {
                anchors.fill: parent
                context: lockContext
                appSettings: appSettings
            }
        }
    }

    PowerOverlay {
        id: powerOverlay
        appSettings: appSettings
        showLock: root.lockEnabled
    }

    function volumeLevel() {
        const m = root.status[3].match(/(\d+)%/)
        return m ? parseInt(m[1]) : -1
    }
    function volumeMuted() {
        return root.status[3] === "muted"
    }
    function volumeGlyph() {
        if (root.volumeMuted()) return "\uF028"
        const v = root.volumeLevel()
        if (v < 34) return "\uF026"
        if (v < 67) return "\uF027"
        return "\uF028"
    }
    function volumeText() {
        if (root.volumeMuted()) return "muted"
        const v = root.volumeLevel()
        return v >= 0 ? v + "%" : "?"
    }

    function wifiConnected() {
        return root.status[4] !== "disconnected"
    }

    function btPowered() {
        return root.status[5] !== "off"
    }
    function btText() {
        if (!root.btPowered()) return "off"
        const m = root.status[5].match(/(\d+) connected/)
        return m ? m[1] : "on"
    }
    function btColor() {
        if (!root.btPowered()) return appSettings.textColor
        const m = root.status[5].match(/(\d+) connected/)
        return m ? appSettings.accentColor : appSettings.textColor
    }

    function batteryLevel() {
        const m = root.status[6].match(/(\d+)%/)
        return m ? parseInt(m[1]) : -1
    }
    function batteryCharging() {
        return root.status[6].includes("Charging")
    }
    function batteryGlyph() {
        if (root.batteryLevel() < 0) return "\uF1E6"
        const v = root.batteryLevel()
        if (v >= 90) return "\uF240"
        if (v >= 75) return "\uF241"
        if (v >= 50) return "\uF242"
        if (v >= 25) return "\uF243"
        return "\uF244"
    }
    function batteryText() {
        const v = root.batteryLevel()
        const pct = v >= 0 ? v + "%" : root.status[6]
        return (root.batteryCharging() ? "\uF0E7 " : "") + pct
    }
    function batteryColor() {
        const v = root.batteryLevel()
        if (v < 0) return appSettings.textColor
        if (v <= 15) return "#f38ba8"
        if (v <= 30) return "#fab387"
        return appSettings.textColor
    }

    WallpaperBackground {
        id: wallpaperBg
        appSettings: appSettings
    }

    WallpaperPicker {
        id: wallpaperPicker
        appSettings: appSettings
    }

    WifiMenu {
        id: wifiMenu
        appSettings: appSettings
    }

    IpcHandler {
        target: "wallpaperPicker"

        function toggle(): void {
            wallpaperPicker.visible = !wallpaperPicker.visible
        }
    }

    IpcHandler {
        target: "lock"

        function lock(): void {
            if (root.lockEnabled) lock.locked = true
        }

        function unlock(): void {
            lock.locked = false
        }

        function toggle(): void {
            if (root.lockEnabled) lock.locked = !lock.locked
        }
    }

    IpcHandler {
        target: "powerMenu"

        function toggle(): void {
            powerOverlay.overlayVisible = !powerOverlay.overlayVisible
        }

        function show(): void {
            powerOverlay.overlayVisible = true
        }

        function hide(): void {
            powerOverlay.overlayVisible = false
        }
    }

    Variants {
        id: barVariants
        model: root.minimal ? [] : Quickshell.screens

        delegate: PanelWindow {
            id: bar
            required property var modelData

            property var appSettingsRef: appSettings

            // Bar background is semi-transparent so the wallpaper (rendered on
            // the layer-shell Background layer behind everything) shows
            // through. Tunable via the `barOpacity` setting.
            readonly property color barColorValue: appSettingsRef.barColor
            readonly property color barTranslucent: Qt.rgba(
                barColorValue.r, barColorValue.g, barColorValue.b,
                appSettingsRef.barOpacity)

            screen: modelData
            color: barTranslucent
            implicitHeight: appSettingsRef.barHeight
            exclusiveZone: implicitHeight

            anchors {
                top: true
                left: true
                right: true
            }

            Process {
                id: statusProcess
                command: ["quickshell-status"]

                stdout: SplitParser {
                    onRead: data => {
                        const fields = data.trim().split("\t")
                        if (fields.length === 7)
                            root.status = fields
                    }
                }
            }

            Process {
                id: volumeMuteProcess
                command: ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]
            }

            Process {
                id: layoutCycleProcess
                command: ["niri", "msg", "action", "switch-layout", "next"]
            }

            Process {
                id: btToggleProcess
                command: ["toggle-bluetooth"]
            }

            Timer {
                interval: 1000
                repeat: true
                running: true
                triggeredOnStart: true
                onTriggered: {
                    if (!statusProcess.running)
                        statusProcess.running = true
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 12
                spacing: 8

                BarButton {
                    Layout.alignment: Qt.AlignVCenter
                    appSettings: appSettingsRef
                    icon: "\uF013"
                    clickable: true
                    onActivated: settingsWindow.visible = !settingsWindow.visible
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    color: appSettingsRef.accentColor
                    opacity: 0.3
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    RowLayout {
                        anchors.fill: parent
                        spacing: 8

                        Rectangle {
                            Layout.preferredWidth: wsText.implicitWidth + 14
                            Layout.preferredHeight: 20
                            Layout.alignment: Qt.AlignVCenter
                            radius: 6
                            color: Qt.rgba(0.969, 0.478, 0.961, 0.14)
                            border.color: Qt.rgba(0.969, 0.478, 0.961, 0.35)
                            border.width: 1

                            Text {
                                id: wsText
                                anchors.centerIn: parent
                                text: root.status[0]
                                font.family: appSettingsRef.fontFamily
                                font.pixelSize: appSettingsRef.fontSize - 1
                                font.weight: Font.Bold
                                color: appSettingsRef.accentColor
                            }
                        }

                        Rectangle {
                            Layout.preferredWidth: 1
                            Layout.preferredHeight: 14
                            Layout.alignment: Qt.AlignVCenter
                            color: appSettingsRef.textColor
                            opacity: 0.25
                        }

                        Text {
                            text: "\uF108"
                            font.family: appSettingsRef.iconFontFamily
                            font.pixelSize: appSettingsRef.fontSize + 1
                            color: appSettingsRef.textColor
                            opacity: 0.7
                            Layout.alignment: Qt.AlignVCenter
                        }

                        StatusText {
                            Layout.fillWidth: true
                            text: root.status[1]
                            elide: Text.ElideRight
                            opacity: 0.85
                            appSettings: appSettingsRef
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    StatusText {
                        anchors.centerIn: parent
                        text: Qt.formatDateTime(root.dateTime, appSettingsRef.clockFormat)
                        appSettings: appSettingsRef
                    }

                    Timer {
                        interval: 1000
                        repeat: true
                        running: true
                        onTriggered: root.dateTime = new Date()
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        BarButton {
                            appSettings: appSettingsRef
                            icon: "\uF11C"
                            text: root.status[2]
                            clickable: true
                            onActivated: layoutCycleProcess.running = true
                        }

                        BarButton {
                            appSettings: appSettingsRef
                            icon: root.volumeGlyph()
                            text: root.volumeText()
                            textColor: root.volumeMuted() ? "#f38ba8" : appSettingsRef.accentColor
                            clickable: true
                            onActivated: volumeMuteProcess.running = true
                        }

                        BarButton {
                            visible: !root.compact
                            appSettings: appSettingsRef
                            icon: "\uF1EB"
                            text: root.status[4]
                            textColor: root.wifiConnected() ? appSettingsRef.accentColor : appSettingsRef.textColor
                            dimmed: !root.wifiConnected()
                            clickable: true
                            onActivated: wifiMenu.visible = !wifiMenu.visible
                        }

                        BarButton {
                            visible: !root.compact
                            appSettings: appSettingsRef
                            icon: "\uF293"
                            text: root.btText()
                            textColor: root.btColor()
                            clickable: true
                            onActivated: btToggleProcess.running = true
                        }

                        BarButton {
                            visible: !root.compact
                            appSettings: appSettingsRef
                            icon: root.batteryGlyph()
                            text: root.batteryText()
                            textColor: root.batteryColor()
                        }
                    }
                }
            }
        }
    }
}
