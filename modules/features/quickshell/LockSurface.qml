import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// Per-screen lock UI shown inside each WlSessionLockSurface.
// Clock + date, static wallpaper (from appSettings), password field, failure + caps/num hints.
// Theme matches Settings/WallpaperPicker/WifiMenu (barColor, accentColor, textColor).
Rectangle {
    id: surfaceRoot

    required property var context
    property var appSettings

    // Whether caps/num appear on. Best-effort via polling /sys LEDs + key tracking.
    property bool capsOn: false
    property bool numOn: false

    color: "transparent"

    // Wallpaper (static, same path the desktop uses) + dim so text stays readable.
    Image {
        id: wpImage
        anchors.fill: parent
        source: appSettings && appSettings.wallpaper ? "file://" + appSettings.wallpaper : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        mipmap: true
        smooth: true
        // 2x screen to stay sharp on hidpi
        sourceSize: Qt.size(parent.width * 2, parent.height * 2)
        visible: source !== ""
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(
            appSettings ? Qt.color(appSettings.barColor).r : 0.118,
            appSettings ? Qt.color(appSettings.barColor).g : 0.118,
            appSettings ? Qt.color(appSettings.barColor).b : 0.180,
            wpImage.visible ? 0.72 : 0.98
        )
    }

    // Clock + date + password card, centered.
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 18
        width: Math.min(parent.width - 32, 520)

        // Clock — large, native rendering like official example.
        Text {
            id: clockText
            property var now: new Date()
            Layout.alignment: Qt.AlignHCenter
            renderType: Text.NativeRendering
            font.pointSize: 56
            font.weight: Font.Light
            color: appSettings ? appSettings.textColor : "#cdd6f4"
            font.family: appSettings ? appSettings.fontFamily : "sans-serif"
            text: Qt.formatDateTime(clockText.now, "hh:mm")
            Timer {
                running: true
                repeat: true
                interval: 1000
                onTriggered: clockText.now = new Date()
            }
        }

        Text {
            id: dateText
            Layout.alignment: Qt.AlignHCenter
            font.pixelSize: (appSettings ? appSettings.fontSize : 13) + 1
            color: appSettings ? appSettings.textColor : "#cdd6f4"
            opacity: 0.75
            font.family: appSettings ? appSettings.fontFamily : "sans-serif"
            text: Qt.formatDateTime(clockText.now, "dddd, dd MMMM yyyy")
        }

        // Password card
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: cardColumn.implicitHeight + 28
            radius: 14
            color: Qt.rgba(0.118, 0.118, 0.180, 0.96)
            border.color: Qt.rgba(
                appSettings ? Qt.color(appSettings.accentColor).r : 0.969,
                appSettings ? Qt.color(appSettings.accentColor).g : 0.478,
                appSettings ? Qt.color(appSettings.accentColor).b : 0.961,
                context.showFailure ? 0.55 : 0.35
            )
            border.width: 1

            Behavior on border.color { ColorAnimation { duration: 150 } }

            ColumnLayout {
                id: cardColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14
                spacing: 10

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: context.unlockInProgress ? "Unlocking…" : "Enter password to unlock"
                    font.pixelSize: appSettings ? appSettings.fontSize : 13
                    font.family: appSettings ? appSettings.fontFamily : "sans-serif"
                    color: appSettings ? appSettings.textColor : "#cdd6f4"
                    opacity: 0.85
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 44
                        radius: 10
                        color: Qt.darker(appSettings ? appSettings.barColor : "#1e1e2e", 1.35)
                        border.color: pwField.activeFocus ? (appSettings ? appSettings.accentColor : "#f77af5ff") : "transparent"
                        border.width: pwField.activeFocus ? 1 : 0

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 8
                            spacing: 8

                            Text {
                                text: "\uF023"
                                font.family: appSettings ? appSettings.iconFontFamily : "JetBrainsMono Nerd Font"
                                font.pixelSize: (appSettings ? appSettings.fontSize : 13) + 2
                                color: appSettings ? appSettings.textColor : "#cdd6f4"
                                opacity: pwField.activeFocus ? 1.0 : 0.6
                            }

                            TextInput {
                                id: pwField
                                Layout.fillWidth: true
                                color: appSettings ? appSettings.textColor : "#cdd6f4"
                                font.family: appSettings ? appSettings.fontFamily : "sans-serif"
                                font.pixelSize: appSettings ? appSettings.fontSize : 13
                                echoMode: TextInput.Password
                                passwordCharacter: "\u2022"
                                inputMethodHints: Qt.ImhSensitiveData
                                focus: true
                                enabled: !context.unlockInProgress
                                clip: true
                                selectByMouse: false
                                // Keep context in sync (official pattern)
                                onTextChanged: if (text !== context.currentText) context.currentText = text
                                onAccepted: context.tryUnlock()
                                Keys.onEscapePressed: event => {
                                    // clear on Esc
                                    pwField.text = ""
                                }
                            }

                            // show / hide toggle
                            Text {
                                id: revealIcon
                                property bool revealed: false
                                text: revealed ? "\uF070" : "\uF06E"
                                font.family: appSettings ? appSettings.iconFontFamily : "JetBrainsMono Nerd Font"
                                font.pixelSize: (appSettings ? appSettings.fontSize : 13) - 1
                                color: revealMouse.containsMouse ? (appSettings ? appSettings.accentColor : "#f77af5ff") : (appSettings ? appSettings.textColor : "#cdd6f4")
                                opacity: revealMouse.containsMouse ? 1.0 : 0.55
                                MouseArea {
                                    id: revealMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        revealIcon.revealed = !revealIcon.revealed
                                        pwField.echoMode = revealIcon.revealed ? TextInput.Normal : TextInput.Password
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.preferredWidth: 92
                        Layout.preferredHeight: 44
                        radius: 10
                        color: unlockMouse.containsMouse
                            ? Qt.lighter(appSettings ? appSettings.accentColor : "#f77af5ff", 1.08)
                            : (appSettings ? appSettings.accentColor : "#f77af5ff")
                        opacity: context.currentText === "" || context.unlockInProgress ? 0.55 : 1.0

                        Text {
                            anchors.centerIn: parent
                            text: "Unlock"
                            font.family: appSettings ? appSettings.fontFamily : "sans-serif"
                            font.pixelSize: (appSettings ? appSettings.fontSize : 13)
                            font.weight: Font.Medium
                            color: appSettings ? appSettings.barColor : "#1e1e2e"
                        }

                        MouseArea {
                            id: unlockMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: context.currentText !== "" && !context.unlockInProgress
                            onClicked: context.tryUnlock()
                        }
                    }
                }

                // Keep field text in sync when context changes (multi-monitor)
                Connections {
                    target: context
                    function onCurrentTextChanged() {
                        if (pwField.text !== context.currentText) pwField.text = context.currentText
                    }
                }

                // Failure message
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    visible: context.showFailure
                    text: "Incorrect password"
                    font.family: appSettings ? appSettings.fontFamily : "sans-serif"
                    font.pixelSize: (appSettings ? appSettings.fontSize : 13) - 1
                    color: "#f38ba8"
                }

                // Caps / Num hints row
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    visible: surfaceRoot.capsOn || surfaceRoot.numOn
                    spacing: 12

                    Text {
                        visible: surfaceRoot.capsOn
                        text: "\u26A0 Caps Lock on"
                        font.family: appSettings ? appSettings.fontFamily : "sans-serif"
                        font.pixelSize: (appSettings ? appSettings.fontSize : 13) - 2
                        color: "#f9e2af"
                    }

                    Text {
                        visible: surfaceRoot.capsOn && surfaceRoot.numOn
                        text: "•"
                        font.pixelSize: 8
                        color: appSettings ? appSettings.textColor : "#cdd6f4"
                        opacity: 0.4
                    }

                    Text {
                        visible: surfaceRoot.numOn
                        text: "Num Lock on"
                        font.family: appSettings ? appSettings.fontFamily : "sans-serif"
                        font.pixelSize: (appSettings ? appSettings.fontSize : 13) - 2
                        color: appSettings ? appSettings.textColor : "#cdd6f4"
                        opacity: 0.7
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    visible: !(surfaceRoot.capsOn || surfaceRoot.numOn)
                    text: "Press Enter to unlock • Esc to clear"
                    font.family: appSettings ? appSettings.fontFamily : "sans-serif"
                    font.pixelSize: (appSettings ? appSettings.fontSize : 13) - 3
                    color: appSettings ? appSettings.textColor : "#cdd6f4"
                    opacity: 0.38
                }
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "Locked — " + (appSettings ? appSettings.textColor : "")
            visible: false
        }
    }

    // ---- Caps/Num detection ----
    // Poll /sys/class/leds for capslock/numlock brightness; fallback to key tracking.
    // Poll only while this surface exists (i.e., when locked) to avoid wakeups.
    // Using Process + SplitParser is heavier than needed; a simple Process with StdioCollector per tick is enough.
    Process {
        id: ledPoll
        // Try common LED names; wildcard via shell so missing paths don't error.
        command: ["sh", "-c", "for p in /sys/class/leds/*capslock/brightness /sys/class/leds/*caps*lock*/brightness; do [ -f \"$p\" ] && cat \"$p\" && exit; done; echo \"\""]
        stdout: StdioCollector {
            onStreamFinished: {
                const v = text.trim()
                if (v === "1" || v === "0") surfaceRoot.capsOn = (v === "1")
            }
        }
    }

    Process {
        id: numLedPoll
        command: ["sh", "-c", "for p in /sys/class/leds/*numlock/brightness /sys/class/leds/*num*lock*/brightness; do [ -f \"$p\" ] && cat \"$p\" && exit; done; echo \"\""]
        stdout: StdioCollector {
            onStreamFinished: {
                const v = text.trim()
                if (v === "1" || v === "0") surfaceRoot.numOn = (v === "1")
            }
        }
    }

    Timer {
        interval: 1200
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!ledPoll.running) ledPoll.running = true
            if (!numLedPoll.running) numLedPoll.running = true
        }
    }

    // Also track Caps/Num key presses to flip hint immediately between polls.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_CapsLock) {
            surfaceRoot.capsOn = !surfaceRoot.capsOn
            event.accepted = true
        } else if (event.key === Qt.Key_NumLock) {
            surfaceRoot.numOn = !surfaceRoot.numOn
            event.accepted = true
        }
    }

    Component.onCompleted: pwField.forceActiveFocus()
}
