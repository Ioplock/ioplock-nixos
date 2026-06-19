import QtQuick
import QtQuick.Layouts
import Quickshell

FloatingWindow {
    id: settingsWindow

    property var appSettings

    title: "Quickshell Settings"
    implicitWidth: 380
    implicitHeight: 480
    visible: false
    color: appSettings ? appSettings.barColor : "#1e1e2e"

    onClosed: {
        settingsWindow.visible = false
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 16

        Text {
            text: "Settings"
            font.pixelSize: 18
            font.weight: Font.Bold
            color: appSettings ? appSettings.textColor : "#cdd6f4"
            Layout.alignment: Qt.AlignHCenter
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: appSettings ? appSettings.accentColor : "#f77af5ff"
            opacity: 0.3
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: settingsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: settingsColumn
                width: parent.width
                spacing: 12

                Text {
                    text: "Appearance"
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: appSettings ? appSettings.accentColor : "#f77af5ff"
                }

                RowLayout {
                    spacing: 12
                    Text {
                        text: "Bar Height"
                        font.pixelSize: appSettings ? appSettings.fontSize : 13
                        color: appSettings ? appSettings.textColor : "#cdd6f4"
                        Layout.fillWidth: true
                    }
                    Row {
                        spacing: 4
                        Rectangle {
                            width: 28; height: 28; radius: 4
                            color: barHDown.containsMouse ? Qt.lighter(appSettings.barColor, 1.4) : Qt.darker(appSettings.barColor, 1.3)
                            Text { anchors.centerIn: parent; text: "-"; color: appSettings.textColor; font.pixelSize: 16 }
                            MouseArea { id: barHDown; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: appSettings.barHeight = Math.max(20, appSettings.barHeight - 2) }
                        }
                        Rectangle {
                            width: 40; height: 28; radius: 4
                            color: Qt.darker(appSettings.barColor, 1.3)
                            Text { anchors.centerIn: parent; text: appSettings.barHeight; color: appSettings.textColor; font.pixelSize: 12 }
                        }
                        Rectangle {
                            width: 28; height: 28; radius: 4
                            color: barHUp.containsMouse ? Qt.lighter(appSettings.barColor, 1.4) : Qt.darker(appSettings.barColor, 1.3)
                            Text { anchors.centerIn: parent; text: "+"; color: appSettings.textColor; font.pixelSize: 16 }
                            MouseArea { id: barHUp; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: appSettings.barHeight = Math.min(60, appSettings.barHeight + 2) }
                        }
                    }
                }

                RowLayout {
                    spacing: 12
                    Text {
                        text: "Font Size"
                        font.pixelSize: appSettings ? appSettings.fontSize : 13
                        color: appSettings ? appSettings.textColor : "#cdd6f4"
                        Layout.fillWidth: true
                    }
                    Row {
                        spacing: 4
                        Rectangle {
                            width: 28; height: 28; radius: 4
                            color: fontDown.containsMouse ? Qt.lighter(appSettings.barColor, 1.4) : Qt.darker(appSettings.barColor, 1.3)
                            Text { anchors.centerIn: parent; text: "-"; color: appSettings.textColor; font.pixelSize: 16 }
                            MouseArea { id: fontDown; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: appSettings.fontSize = Math.max(8, appSettings.fontSize - 1) }
                        }
                        Rectangle {
                            width: 40; height: 28; radius: 4
                            color: Qt.darker(appSettings.barColor, 1.3)
                            Text { anchors.centerIn: parent; text: appSettings.fontSize; color: appSettings.textColor; font.pixelSize: 12 }
                        }
                        Rectangle {
                            width: 28; height: 28; radius: 4
                            color: fontUp.containsMouse ? Qt.lighter(appSettings.barColor, 1.4) : Qt.darker(appSettings.barColor, 1.3)
                            Text { anchors.centerIn: parent; text: "+"; color: appSettings.textColor; font.pixelSize: 16 }
                            MouseArea { id: fontUp; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: appSettings.fontSize = Math.min(24, appSettings.fontSize + 1) }
                        }
                    }
                }

                RowLayout {
                    spacing: 12
                    Text {
                        text: "Bar Color"
                        font.pixelSize: appSettings ? appSettings.fontSize : 13
                        color: appSettings ? appSettings.textColor : "#cdd6f4"
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        width: 80; height: 28; radius: 4
                        color: appSettings.barColor
                        border.color: Qt.darker(appSettings.barColor, 1.5); border.width: 1
                        TextInput {
                            anchors.centerIn: parent
                            text: appSettings.barColor
                            color: "#cdd6f4"
                            font.pixelSize: 11; font.family: "monospace"
                            selectByMouse: true
                            onEditingFinished: appSettings.barColor = text
                        }
                    }
                }

                RowLayout {
                    spacing: 12
                    Text {
                        text: "Text Color"
                        font.pixelSize: appSettings ? appSettings.fontSize : 13
                        color: appSettings ? appSettings.textColor : "#cdd6f4"
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        width: 80; height: 28; radius: 4
                        color: appSettings.textColor
                        border.color: Qt.darker(appSettings.textColor, 1.5); border.width: 1
                        TextInput {
                            anchors.centerIn: parent
                            text: appSettings.textColor
                            color: "#1e1e2e"
                            font.pixelSize: 11; font.family: "monospace"
                            selectByMouse: true
                            onEditingFinished: appSettings.textColor = text
                        }
                    }
                }

                RowLayout {
                    spacing: 12
                    Text {
                        text: "Accent Color"
                        font.pixelSize: appSettings ? appSettings.fontSize : 13
                        color: appSettings ? appSettings.textColor : "#cdd6f4"
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        width: 80; height: 28; radius: 4
                        color: appSettings.accentColor
                        border.color: Qt.darker(appSettings.accentColor, 1.5); border.width: 1
                        TextInput {
                            anchors.centerIn: parent
                            text: appSettings.accentColor
                            color: "#1e1e2e"
                            font.pixelSize: 11; font.family: "monospace"
                            selectByMouse: true
                            onEditingFinished: appSettings.accentColor = text
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: appSettings ? appSettings.accentColor : "#f77af5ff"
                    opacity: 0.3
                }

                Text {
                    text: "Behavior"
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: appSettings ? appSettings.accentColor : "#f77af5ff"
                }

                RowLayout {
                    spacing: 12
                    Text {
                        text: "Clock Format"
                        font.pixelSize: appSettings ? appSettings.fontSize : 13
                        color: appSettings ? appSettings.textColor : "#cdd6f4"
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        width: 160; height: 28; radius: 4
                        color: Qt.darker(appSettings.barColor, 1.3)
                        TextInput {
                            anchors.centerIn: parent
                            text: appSettings.clockFormat
                            color: appSettings.textColor
                            font.pixelSize: 12
                            selectByMouse: true
                            onEditingFinished: appSettings.clockFormat = text
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: appSettings ? appSettings.accentColor : "#f77af5ff"
                    opacity: 0.3
                }

                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 140
                    Layout.preferredHeight: 36
                    radius: 6
                    color: resetArea.containsMouse ? Qt.lighter(appSettings.accentColor, 1.1) : appSettings.accentColor

                    Text {
                        anchors.centerIn: parent
                        text: "Reset to Defaults"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: appSettings.barColor
                    }

                    MouseArea {
                        id: resetArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: appSettings.resetToDefaults()
                    }
                }
            }
        }
    }
}
