import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// Per-screen lock UI shown inside each WlSessionLockSurface.
// Minimal: clock + date, wallpaper with dim, password pill, dot indicators.
// Theme matches Settings (barColor, accentColor, textColor).
Rectangle {
    id: surfaceRoot

    required property var context
    property var appSettings

    // Caps/num state. Polled from /sys LEDs; key tracking gives instant flip.
    property bool capsOn: false
    property bool numOn: false

    readonly property color textC: appSettings ? appSettings.textColor : "#cdd6f4"
    readonly property color accentC: appSettings ? appSettings.accentColor : "#f77af5ff"
    readonly property color barC: appSettings ? appSettings.barColor : "#1e1e2e"
    readonly property string fontFam: appSettings ? appSettings.fontFamily : "sans-serif"
    readonly property string iconFam: appSettings ? appSettings.iconFontFamily : "JetBrainsMono Nerd Font"
    readonly property int fontSz: appSettings ? appSettings.fontSize : 13

    // Solid base so the compositor default (white) never flashes through.
    color: barC

    // Static wallpaper (same path the desktop uses). No sourceSize: with
    // parent-based sourceSize the image could bind to 0x0 on surface creation
    // and stay blank — PreserveAspectCrop scales without it.
    Image {
        id: wpImage
        anchors.fill: parent
        source: appSettings && appSettings.wallpaper ? "file://" + appSettings.wallpaper : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        mipmap: true
        smooth: true
        visible: source !== ""
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(barC.r, barC.g, barC.b, wpImage.visible ? 0.55 : 0.0)
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 14
        width: Math.min(parent.width - 48, 380)

        Text {
            id: clockText
            property var now: new Date()
            Layout.alignment: Qt.AlignHCenter
            renderType: Text.NativeRendering
            font.pointSize: 64
            font.weight: Font.Light
            color: textC
            font.family: fontFam
            text: Qt.formatDateTime(clockText.now, "hh:mm")
            Timer {
                running: true
                repeat: true
                interval: 1000
                onTriggered: clockText.now = new Date()
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: -10
            font.pixelSize: fontSz
            color: textC
            opacity: 0.6
            font.family: fontFam
            text: Qt.formatDateTime(clockText.now, "ddd, d MMM")
        }

        // Password pill
        Rectangle {
            id: pill
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            radius: 24
            color: Qt.darker(barC, 1.35)
            border.color: context.showFailure ? "#f38ba8" : (pwField.activeFocus ? accentC : "transparent")
            border.width: (context.showFailure || pwField.activeFocus) ? 1 : 0

            Behavior on border.color { ColorAnimation { duration: 120 } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 8
                spacing: 8

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: "\uF023"
                    font.family: iconFam
                    font.pixelSize: fontSz + 1
                    color: textC
                    opacity: pwField.activeFocus ? 1.0 : 0.55
                }

                TextInput {
                    id: pwField
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    color: textC
                    font.family: fontFam
                    font.pixelSize: fontSz
                    echoMode: TextInput.Password
                    passwordCharacter: "\u2022"
                    inputMethodHints: Qt.ImhSensitiveData
                    focus: true
                    enabled: !context.unlockInProgress
                    clip: true
                    selectByMouse: false
                    onTextChanged: if (text !== context.currentText) context.currentText = text
                    onAccepted: context.tryUnlock()
                    Keys.onEscapePressed: event => {
                        pwField.text = ""
                        event.accepted = true
                    }
                    // Instant caps/num flip between LED polls.
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_CapsLock) {
                            surfaceRoot.capsOn = !surfaceRoot.capsOn
                            event.accepted = true
                        } else if (event.key === Qt.Key_NumLock) {
                            surfaceRoot.numOn = !surfaceRoot.numOn
                            event.accepted = true
                        }
                    }
                }

                Text {
                    id: revealIcon
                    Layout.alignment: Qt.AlignVCenter
                    property bool revealed: false
                    text: revealed ? "\uF070" : "\uF06E"
                    font.family: iconFam
                    font.pixelSize: fontSz - 1
                    color: revealMouse.containsMouse ? accentC : textC
                    opacity: revealMouse.containsMouse ? 1.0 : 0.5
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

                Rectangle {
                    id: goBtn
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    Layout.alignment: Qt.AlignVCenter
                    radius: 16
                    color: goMouse.containsMouse ? Qt.lighter(accentC, 1.08) : accentC
                    opacity: (context.currentText === "" || context.unlockInProgress) ? 0.35 : 1.0

                    Text {
                        anchors.centerIn: parent
                        text: "\uF061"
                        font.family: iconFam
                        font.pixelSize: fontSz
                        color: barC
                    }

                    MouseArea {
                        id: goMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: context.currentText !== "" && !context.unlockInProgress
                        onClicked: context.tryUnlock()
                    }
                }
            }
        }

        // Keep field text in sync when context changes (multi-monitor).
        Connections {
            target: context
            function onCurrentTextChanged() {
                if (pwField.text !== context.currentText) pwField.text = context.currentText
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            visible: context.showFailure
            text: "Incorrect password"
            font.family: fontFam
            font.pixelSize: fontSz - 1
            color: "#f38ba8"
        }

        // Caps / Num indicators: colored dot + short label. Always visible so
        // the layout doesn't jump; dim when off, amber/green when on.
        Row {
            Layout.alignment: Qt.AlignHCenter
            spacing: 16

            Row {
                spacing: 6
                opacity: surfaceRoot.capsOn ? 1.0 : 0.32
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8
                    height: 8
                    radius: 4
                    color: surfaceRoot.capsOn ? "#f9e2af" : textC
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "CAPS"
                    font.family: fontFam
                    font.pixelSize: fontSz - 3
                    font.weight: surfaceRoot.capsOn ? Font.Bold : Font.Normal
                    color: surfaceRoot.capsOn ? "#f9e2af" : textC
                }
            }

            Row {
                spacing: 6
                opacity: surfaceRoot.numOn ? 1.0 : 0.32
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8
                    height: 8
                    radius: 4
                    color: surfaceRoot.numOn ? "#a6e3a1" : textC
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "NUM"
                    font.family: fontFam
                    font.pixelSize: fontSz - 3
                    font.weight: surfaceRoot.numOn ? Font.Bold : Font.Normal
                    color: surfaceRoot.numOn ? "#a6e3a1" : textC
                }
            }
        }
    }

    // ---- Caps/Num detection via /sys LEDs (covers initial state) ----
    Process {
        id: ledPoll
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
        interval: 1500
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!ledPoll.running) ledPoll.running = true
            if (!numLedPoll.running) numLedPoll.running = true
        }
    }

    // Re-focus the field when this screen's window becomes active (one surface
    // per screen; only the active one can hold focus).
    Connections {
        target: surfaceRoot.Window.window
        ignoreUnknownSignals: true
        function onActiveChanged() {
            if (surfaceRoot.Window.window && surfaceRoot.Window.window.active && !context.unlockInProgress)
                pwField.forceActiveFocus()
        }
    }
}
