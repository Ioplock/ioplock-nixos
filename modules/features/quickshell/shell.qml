import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property var status: ["?", "Desktop", "unknown", "unknown", "disconnected", "off", "AC"]
    property date dateTime: new Date()

    Variants {
        model: Quickshell.screens

        delegate: PanelWindow {
            required property var modelData

            screen: modelData
            color: "#1e1e2e"
            implicitHeight: 34
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
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 12

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    StatusText {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.status[0] + "  " + root.status[1]
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    StatusText {
                        anchors.centerIn: parent
                        text: Qt.formatDateTime(root.dateTime, "ddd, dd MMM  HH:mm")
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

                    StatusText {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.status[2] + "  |  vol " + root.status[3]
                            + "  |  wifi " + root.status[4]
                            + "  |  bt " + root.status[5]
                            + "  |  bat " + root.status[6]
                    }
                }
            }
        }
    }
}
