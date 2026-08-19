import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property var status: ["?", "Desktop", "unknown", "unknown", "disconnected", "off", "AC"]
    property date dateTime: new Date()

    Settings {
        id: appSettings
    }

    SettingsWindow {
        id: settingsWindow
        appSettings: appSettings
    }

    // Wallpaper is managed by swaybg: niri draws swaybg's image as the
    // compositor background, which shows through our translucent bar. Applying
    // a wallpaper (re)spawns swaybg with the new image.
    function applyWallpaper() {
        if (!appSettings.wallpaper) return
        wallpaperProcess.running = false
        wallpaperProcess.command = ["set-wallpaper", appSettings.wallpaper]
        wallpaperProcess.running = true
    }

    Connections {
        target: appSettings
        function onWallpaperChanged() {
            root.applyWallpaper()
        }
    }

    Process {
        id: wallpaperProcess
        command: []
    }

    WallpaperPicker {
        id: wallpaperPicker
        appSettings: appSettings
    }

    IpcHandler {
        target: "wallpaperPicker"

        function toggle(): void {
            wallpaperPicker.visible = !wallpaperPicker.visible
        }
    }

    Variants {
        id: barVariants
        model: Quickshell.screens

        delegate: PanelWindow {
            id: bar
            required property var modelData

            property var appSettingsRef: appSettings

            // Bar background is semi-transparent so the wallpaper (rendered by
            // swaybg behind everything) shows through. Tunable via the
            // `barOpacity` setting.
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

            WifiMenu {
                id: wifiMenu
                appSettings: appSettingsRef
                barWindow: bar
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

                Rectangle {
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    Layout.alignment: Qt.AlignVCenter
                    radius: 4
                    color: settingsArea.containsMouse ? Qt.lighter(appSettingsRef.barColor, 1.4) : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "\u2699"
                        font.pixelSize: 16
                        color: appSettingsRef.textColor
                        opacity: settingsArea.containsMouse ? 1.0 : 0.7
                    }

                    MouseArea {
                        id: settingsArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            settingsWindow.visible = !settingsWindow.visible
                        }
                    }
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

                    StatusText {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.status[0] + "  " + root.status[1]
                        appSettings: appSettingsRef
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
                        spacing: 12

                        StatusText {
                            text: root.status[2]
                            color: appSettingsRef.accentColor
                            appSettings: appSettingsRef
                        }

                        StatusText {
                            text: "\u2022"
                            color: appSettingsRef.textColor
                            opacity: 0.3
                            appSettings: appSettingsRef
                        }

                        StatusText {
                            text: "vol " + root.status[3]
                            appSettings: appSettingsRef
                        }

                        StatusText {
                            text: "\u2022"
                            color: appSettingsRef.textColor
                            opacity: 0.3
                            appSettings: appSettingsRef
                        }

                        Rectangle {
                            width: wifiText.implicitWidth + 8
                            height: wifiText.implicitHeight + 4
                            radius: 4
                            color: wifiArea.containsMouse ? Qt.lighter(appSettingsRef.barColor, 1.4) : "transparent"

                            StatusText {
                                id: wifiText
                                anchors.centerIn: parent
                                text: "wifi " + root.status[4]
                                color: wifiMenu.visible ? appSettingsRef.accentColor : appSettingsRef.textColor
                                appSettings: appSettingsRef
                            }

                            MouseArea {
                                id: wifiArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    wifiMenu.visible = !wifiMenu.visible
                                    if (wifiMenu.visible) {
                                        wifiMenu.refreshNetworks()
                                    }
                                }
                            }
                        }

                        StatusText {
                            text: "\u2022"
                            color: appSettingsRef.textColor
                            opacity: 0.3
                            appSettings: appSettingsRef
                        }

                        StatusText {
                            text: "bt " + root.status[5]
                            appSettings: appSettingsRef
                        }

                        StatusText {
                            text: "\u2022"
                            color: appSettingsRef.textColor
                            opacity: 0.3
                            appSettings: appSettingsRef
                        }

                        StatusText {
                            text: "bat " + root.status[6]
                            appSettings: appSettingsRef
                        }
                    }
                }
            }
        }
    }
}
