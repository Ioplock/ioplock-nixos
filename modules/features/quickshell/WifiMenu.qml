pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Compact wifi dropdown under the bar's wifi button. Matches the
// WallpaperPicker card theme. Keyboard: Up/Down select, Return/Enter connect,
// Esc close.
PanelWindow {
    id: wifiMenu

    property var appSettings

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.exclusiveZone: 0
    // Exclusive keyboard focus while open: arrows/Enter/Esc work immediately.
    WlrLayershell.keyboardFocus: wifiMenu.visible
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    anchors {
        top: true
        right: true
    }

    margins {
        // The bar's exclusive zone already pushes this Overlay just below the
        // bar, so only a small visual gap is needed here.
        top: 4
        right: 12
    }

    focusable: true
    color: "transparent"
    visible: false
    implicitWidth: wifiMenu.cardW
    implicitHeight: contentColumn.implicitHeight + 2 * wifiMenu.pad

    // Sizing: the card shrink-wraps its content. The network list shows at
    // most `maxRows` rows and scrolls beyond that.
    readonly property real pad: 12
    readonly property real cardW: 320
    readonly property real rowH: 48
    readonly property int maxRows: 7
    readonly property real listH: Math.min(Math.max(wifiMenu.networks.length, 1), wifiMenu.maxRows) * wifiMenu.rowH

    // Theme
    readonly property color baseColor: appSettings ? appSettings.barColor : "#1e1e2e"
    readonly property color textColor: appSettings ? appSettings.textColor : "#cdd6f4"
    readonly property color accentColor: appSettings ? appSettings.accentColor : "#f77af5ff"
    readonly property color signalStrong: "#a6e3a1"
    readonly property color signalMid: "#f9e2af"
    readonly property color signalWeak: "#fab387"
    readonly property color signalDead: "#f38ba8"
    readonly property string fontFamily: appSettings ? appSettings.fontFamily : "sans-serif"
    readonly property string iconFamily: appSettings ? appSettings.iconFontFamily : "JetBrainsMono Nerd Font"
    readonly property int fontSize: appSettings ? appSettings.fontSize : 13

    property bool wifiEnabled: false
    property string currentNetwork: ""
    property var networks: []
    property var savedNames: []
    property bool savedLoaded: false
    property bool scanning: false
    property string connectingTo: ""
    property bool showPasswordPrompt: false
    property string selectedNetwork: ""
    property string passwordInput: ""
    property string connectionStatus: ""
    property string wifiInterface: "wlan0"

    // Parse a single nmcli terse output line correctly.
    // nmcli -t separates fields with ':' and escapes literal ':' in values as '\:'.
    // A naive split(":") breaks SSIDs that contain colons.
    function splitNmcliLine(line) {
        const parts = []
        let current = ""
        let i = 0
        while (i < line.length) {
            if (line[i] === '\\' && i + 1 < line.length) {
                current += line[i + 1]
                i += 2
            } else if (line[i] === ':') {
                parts.push(current)
                current = ""
                i++
            } else {
                current += line[i]
                i++
            }
        }
        parts.push(current)
        return parts
    }

    // Signal strength as Nerd Font MDI wifi glyphs (1–4 bars).
    function getSignalGlyph(signal) {
        if (signal >= 75) return "\uF0928"
        if (signal >= 50) return "\uF0925"
        if (signal >= 25) return "\uF0922"
        return "\uF091F"
    }

    function getSignalColor(signal) {
        if (signal >= 75) return wifiMenu.signalStrong
        if (signal >= 50) return wifiMenu.signalMid
        if (signal >= 25) return wifiMenu.signalWeak
        return wifiMenu.signalDead
    }

    // True only when the network is secured AND not already saved, so a saved
    // profile connects directly without prompting for a password.
    function needsPassword(net) {
        if (!net) return false
        if (net.saved) return false
        const sec = net.security
        return sec !== "" && sec !== "--"
    }

    // forceRescan=true → hardware rescan (slow, fresh); false → cached data.
    function refreshNetworks(forceRescan) {
        if (wifiMenu.scanning) return
        wifiMenu.scanning = true
        wifiMenu.networks = []
        if (!wifiMenu.savedLoaded || forceRescan)
            wifiConnectionsProcess.running = true
        wifiScanProcess.command = [
            "nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY,IN-USE",
            "device", "wifi", "list",
            "--rescan", forceRescan ? "yes" : "auto"
        ]
        wifiScanProcess.running = true
    }

    function toggleWifi() {
        wifiToggleProcess.running = true
    }

    function connectToNetwork(network) {
        if (!network || wifiMenu.connectingTo !== "") return
        if (network.inUse) {
            wifiMenu.disconnectWifi()
            return
        }
        if (wifiMenu.needsPassword(network)) {
            wifiMenu.selectedNetwork = network.ssid
            wifiMenu.passwordInput = ""
            wifiMenu.showPasswordPrompt = true
            Qt.callLater(() => passwd.forceActiveFocus())
        } else {
            wifiMenu.connectingTo = network.ssid
            wifiConnectProcess.command = ["nmcli", "device", "wifi", "connect", network.ssid]
            wifiConnectProcess.running = true
        }
    }

    function connectWithPassword() {
        if (!wifiMenu.passwordInput || wifiMenu.connectingTo !== "") return
        wifiMenu.connectingTo = wifiMenu.selectedNetwork
        wifiMenu.showPasswordPrompt = false
        wifiConnectProcess.command = [
            "nmcli", "device", "wifi", "connect", wifiMenu.selectedNetwork,
            "password", wifiMenu.passwordInput
        ]
        wifiConnectProcess.running = true
    }

    function disconnectWifi() {
        if (wifiMenu.connectingTo !== "") return
        wifiDisconnectProcess.command = ["nmcli", "device", "disconnect", wifiMenu.wifiInterface]
        wifiDisconnectProcess.running = true
    }

    function activate(indexOrNet) {
        const net = typeof indexOrNet === "object"
            ? indexOrNet
            : (indexOrNet >= 0 ? wifiMenu.networks[indexOrNet] : null)
        if (net) wifiMenu.connectToNetwork(net)
    }

    Process {
        id: wifiStatusProcess
        command: ["nmcli", "-t", "-f", "WIFI", "general"]
        stdout: StdioCollector {
            onStreamFinished: {
                const newState = text.trim() === "enabled"
                const wasEnabled = wifiMenu.wifiEnabled
                wifiMenu.wifiEnabled = newState
                if (!wasEnabled && newState)
                    wifiMenu.refreshNetworks(true)
            }
        }
    }

    Process {
        id: wifiInterfaceProcess
        command: ["nmcli", "-t", "-f", "DEVICE,TYPE", "device"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n")
                for (const line of lines) {
                    const parts = wifiMenu.splitNmcliLine(line)
                    if (parts.length >= 2 && parts[1] === "wifi") {
                        wifiMenu.wifiInterface = parts[0]
                        break
                    }
                }
            }
        }
    }

    // Saved NetworkManager wifi profiles, used to skip the password prompt for
    // networks that already carry stored credentials.
    Process {
        id: wifiConnectionsProcess
        command: ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"]
        stdout: StdioCollector {
            onStreamFinished: {
                const names = []
                const lines = text.trim().split("\n")
                for (const line of lines) {
                    const parts = wifiMenu.splitNmcliLine(line)
                    // Wifi-type connections may escape ':' in the NAME field.
                    if (parts.length >= 2 && parts[1] === "802-11-wireless")
                        names.push(parts[0])
                }
                wifiMenu.savedNames = names
                wifiMenu.savedLoaded = true
            }
        }
    }

    Process {
        id: wifiToggleProcess
        command: wifiMenu.wifiEnabled
            ? ["nmcli", "radio", "wifi", "off"]
            : ["nmcli", "radio", "wifi", "on"]
        onExited: {
            if (wifiMenu.wifiEnabled) {
                wifiMenu.networks = []
                wifiMenu.currentNetwork = ""
            }
            wifiStatusProcess.running = true
        }
    }

    Process {
        id: wifiScanProcess
        command: ["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY,IN-USE", "device", "wifi", "list", "--rescan", "yes"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n")
                const seen = {}
                const nets = []
                let current = ""

                for (const line of lines) {
                    if (!line) continue

                    const parts = wifiMenu.splitNmcliLine(line)
                    if (parts.length < 4) continue

                    const ssid = parts[0]
                    if (!ssid || ssid.trim() === "") continue

                    const signal = parseInt(parts[1]) || 0
                    const security = parts[2] || ""
                    const inUse = parts[3].trim() === "*"
                    const saved = wifiMenu.savedLoaded && wifiMenu.savedNames.indexOf(ssid) >= 0

                    const entry = {
                        ssid: ssid,
                        signal: signal,
                        security: security,
                        inUse: inUse,
                        saved: saved
                    }

                    if (!seen[ssid] || seen[ssid].signal < signal)
                        seen[ssid] = entry
                }

                for (const key in seen) {
                    const e = seen[key]
                    nets.push(e)
                }

                nets.sort((a, b) => {
                    if (a.inUse !== b.inUse) return a.inUse ? -1 : 1
                    return b.signal - a.signal
                })

                wifiMenu.networks = nets
                wifiMenu.currentNetwork = current
                wifiMenu.scanning = false
            }
        }
        onExited: wifiMenu.scanning = false
    }

    Process {
        id: wifiConnectProcess
        onExited: (code) => {
            // Capture the target before connectingTo is cleared below.
            const target = wifiMenu.connectingTo
            wifiMenu.connectingTo = ""
            if (code === 0) {
                wifiMenu.connectionStatus = "Connected to " + target
                wifiMenu.visible = false
            } else {
                wifiMenu.connectionStatus = "Failed to connect to " + target
                wifiMenu.visible = true
            }
            statusClearTimer.restart()
            wifiMenu.refreshNetworks(true)
        }
    }

    Process {
        id: wifiDisconnectProcess
        onExited: {
            wifiMenu.connectionStatus = "Disconnected"
            wifiMenu.visible = false
            statusClearTimer.restart()
            wifiMenu.refreshNetworks(false)
        }
    }

    Timer {
        id: statusClearTimer
        interval: 4000
        onTriggered: wifiMenu.connectionStatus = ""
    }

    Timer {
        id: refreshTimer
        interval: 30000
        repeat: true
        running: wifiMenu.visible && wifiMenu.wifiEnabled
        triggeredOnStart: false
        onTriggered: {
            wifiStatusProcess.running = true
            wifiMenu.refreshNetworks(false)
        }
    }

    onVisibleChanged: {
        if (visible) {
            wifiStatusProcess.running = true
            wifiInterfaceProcess.running = true
            wifiConnectionsProcess.running = true
            wifiMenu.refreshNetworks(true)
            listView.currentIndex = -1
            listView.forceActiveFocus()
        } else {
            wifiMenu.showPasswordPrompt = false
            wifiMenu.connectionStatus = ""
            wifiMenu.passwordInput = ""
            passwd.text = ""
            statusClearTimer.stop()
        }
    }

    Rectangle {
        id: card
        anchors.fill: parent
        radius: 14
        color: Qt.rgba(wifiMenu.baseColor.r, wifiMenu.baseColor.g, wifiMenu.baseColor.b, 0.96)
        border.color: Qt.rgba(wifiMenu.accentColor.r, wifiMenu.accentColor.g, wifiMenu.accentColor.b, 0.35)
        border.width: 1

        ColumnLayout {
            id: contentColumn
            anchors.fill: parent
            anchors.margins: wifiMenu.pad
            spacing: 6

            // Header: icon, title + dynamic subtitle, refresh button.
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: "\uF1EB"
                    font.family: wifiMenu.iconFamily
                    font.pixelSize: wifiMenu.fontSize + 4
                    color: wifiMenu.accentColor
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                        Layout.fillWidth: true
                        text: "Wi-Fi"
                        font.family: wifiMenu.fontFamily
                        font.pixelSize: wifiMenu.fontSize + 2
                        font.weight: Font.Bold
                        color: wifiMenu.textColor
                    }

                    Text {
                        Layout.fillWidth: true
                        text: wifiMenu.wifiEnabled
                            ? (wifiMenu.scanning
                                ? "Scanning\u2026"
                                : (wifiMenu.networks.length + " networks found"))
                            : "Wi-Fi is off"
                        font.family: wifiMenu.fontFamily
                        font.pixelSize: wifiMenu.fontSize - 3
                        color: wifiMenu.textColor
                        opacity: 0.5
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    radius: 6
                    color: refreshArea.containsMouse
                        ? Qt.lighter(wifiMenu.baseColor, 1.4)
                        : "transparent"
                    visible: wifiMenu.wifiEnabled && !wifiMenu.scanning

                    Text {
                        anchors.centerIn: parent
                        text: "\uF021"
                        font.family: wifiMenu.iconFamily
                        font.pixelSize: wifiMenu.fontSize - 1
                        color: wifiMenu.textColor
                        opacity: refreshArea.containsMouse ? 1.0 : 0.7
                    }

                    MouseArea {
                        id: refreshArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: wifiMenu.refreshNetworks(true)
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: wifiMenu.accentColor
                opacity: 0.3
            }

            // On/off toggle.
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: wifiMenu.wifiEnabled ? "Turned on" : "Turned off"
                    font.family: wifiMenu.fontFamily
                    font.pixelSize: wifiMenu.fontSize
                    color: wifiMenu.textColor
                    Layout.fillWidth: true
                }

                Rectangle {
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 24
                    radius: 12
                    color: wifiMenu.wifiEnabled ? wifiMenu.accentColor : "#585b70"

                    Rectangle {
                        width: 20
                        height: 20
                        radius: 10
                        anchors.verticalCenter: parent.verticalCenter
                        x: wifiMenu.wifiEnabled ? parent.width - width - 2 : 2
                        color: "#ffffff"

                        Behavior on x {
                            NumberAnimation { duration: 150 }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: wifiMenu.toggleWifi()
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: wifiMenu.accentColor
                opacity: 0.3
                visible: wifiMenu.wifiEnabled
            }

            // Transient status / error message.
            Text {
                Layout.fillWidth: true
                visible: wifiMenu.connectionStatus !== ""
                text: wifiMenu.connectionStatus
                font.family: wifiMenu.fontFamily
                font.pixelSize: wifiMenu.fontSize - 1
                color: wifiMenu.connectionStatus.startsWith("Connected")
                    ? wifiMenu.signalStrong
                    : wifiMenu.signalDead
                wrapMode: Text.WordWrap
            }

            // Network list.
            ListView {
                id: listView
                Layout.fillWidth: true
                Layout.preferredHeight: wifiMenu.showPasswordPrompt ? 0 : wifiMenu.listH
                visible: wifiMenu.wifiEnabled && !wifiMenu.showPasswordPrompt && wifiMenu.networks.length > 0
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: wifiMenu.networks
                focus: wifiMenu.visible && !wifiMenu.showPasswordPrompt
                keyNavigationWraps: false
                highlightFollowsCurrentItem: true
                currentIndex: -1

                Keys.onReturnPressed: event => {
                    wifiMenu.activate(Math.max(0, listView.currentIndex))
                    event.accepted = true
                }
                Keys.onEnterPressed: event => {
                    wifiMenu.activate(Math.max(0, listView.currentIndex))
                    event.accepted = true
                }
                Keys.onEscapePressed: event => {
                    wifiMenu.visible = false
                    event.accepted = true
                }

                delegate: Rectangle {
                    required property var modelData
                    required property int index

                    readonly property bool isCurrent: listView.currentIndex === index
                    readonly property bool isConnecting: wifiMenu.connectingTo === modelData.ssid
                    readonly property bool hovered: rowMouse.containsMouse

                    width: listView.width
                    implicitHeight: wifiMenu.rowH
                    radius: 8
                    color: (hovered || isCurrent) && !isConnecting
                        ? Qt.lighter(wifiMenu.baseColor, 1.35)
                        : "transparent"

                    Behavior on color { ColorAnimation { duration: 90 } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8

                        // Signal glyph, colored by level.
                        Text {
                            text: wifiMenu.getSignalGlyph(modelData.signal)
                            font.family: wifiMenu.iconFamily
                            font.pixelSize: wifiMenu.fontSize + 2
                            color: wifiMenu.getSignalColor(modelData.signal)
                            Layout.preferredWidth: 24
                            opacity: isConnecting ? 0.4 : 1.0
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Text {
                                Layout.fillWidth: true
                                text: modelData.ssid
                                font.family: wifiMenu.fontFamily
                                font.pixelSize: wifiMenu.fontSize
                                font.weight: modelData.inUse ? Font.Bold : Font.Normal
                                color: modelData.inUse ? wifiMenu.accentColor : wifiMenu.textColor
                                elide: Text.ElideRight
                            }

                            Text {
                                Layout.fillWidth: true
                                text: modelData.inUse
                                ? "Connected"
                                : (modelData.saved
                                    ? "Saved"
                                    : (modelData.security === "" || modelData.security === "--"
                                        ? "Open"
                                        : modelData.security))
                                font.family: wifiMenu.fontFamily
                                font.pixelSize: wifiMenu.fontSize - 4
                                color: modelData.inUse ? wifiMenu.signalStrong : wifiMenu.textColor
                                opacity: 0.6
                                elide: Text.ElideRight
                            }
                        }

                        // Right-side status: connecting dot, signal %, locked/saved/connected.
                        Text {
                            text: isConnecting ? "\u2026" : (modelData.signal + "%")
                            font.family: wifiMenu.fontFamily
                            font.pixelSize: wifiMenu.fontSize - 2
                            color: isConnecting ? wifiMenu.accentColor : wifiMenu.textColor
                            opacity: isConnecting ? 1.0 : 0.55
                        }

                        Text {
                            text: modelData.inUse ? "\uF00C" : "\uF023"
                            font.family: wifiMenu.iconFamily
                            font.pixelSize: wifiMenu.fontSize - 1
                            color: modelData.inUse
                                ? wifiMenu.signalStrong
                                : (modelData.saved ? wifiMenu.accentColor : wifiMenu.signalWeak)
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: wifiMenu.connectingTo === ""
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onEntered: listView.currentIndex = index
                        onClicked: wifiMenu.connectToNetwork(modelData)
                    }
                }
            }

            // Placeholder shown in place of the list.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: wifiMenu.wifiEnabled ? 70 : 64
                visible: !wifiMenu.showPasswordPrompt && wifiMenu.networks.length === 0
                spacing: 4

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34

                    Text {
                        id: placeholderIcon
                        // Natural-width text box so the rotation pivot sits at the
                        // glyph's own center, not the center of a stretched box.
                        anchors.centerIn: parent
                        text: !wifiMenu.wifiEnabled
                            ? "\uF1EB"
                            : "\uF1CE"
                        font.family: wifiMenu.iconFamily
                        font.pixelSize: wifiMenu.fontSize + 8
                        color: wifiMenu.textColor
                        opacity: wifiMenu.scanning ? 1.0 : 0.35
                    }

                    RotationAnimator {
                        running: wifiMenu.wifiEnabled && wifiMenu.scanning
                        target: placeholderIcon
                        from: 0
                        to: 360
                        duration: 900
                        loops: Animation.Infinite
                    }
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: !wifiMenu.wifiEnabled
                        ? "Wi-Fi is off"
                        : (wifiMenu.scanning ? "Scanning for networks\u2026" : "No networks found")
                    font.family: wifiMenu.fontFamily
                    font.pixelSize: wifiMenu.fontSize - 1
                    color: wifiMenu.textColor
                    opacity: 0.5
                }
            }

            // Password prompt.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: wifiMenu.showPasswordPrompt

                Text {
                    Layout.fillWidth: true
                    text: "Connect to: " + wifiMenu.selectedNetwork
                    font.family: wifiMenu.fontFamily
                    font.pixelSize: wifiMenu.fontSize
                    font.weight: Font.Bold
                    color: wifiMenu.textColor
                    elide: Text.ElideRight
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    radius: 8
                    color: Qt.darker(wifiMenu.baseColor, 1.3)
                    border.color: passwd.activeFocus ? wifiMenu.accentColor : "transparent"
                    border.width: passwd.activeFocus ? 1 : 0

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 4
                        spacing: 4

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            TextInput {
                                id: passwd
                                anchors.fill: parent
                                verticalAlignment: TextInput.AlignVCenter
                                color: wifiMenu.textColor
                                font.family: wifiMenu.fontFamily
                                font.pixelSize: wifiMenu.fontSize
                                echoMode: passwdShow.showPassword ? TextInput.Normal : TextInput.Password
                                passwordCharacter: "\u2022"
                                clip: true
                                onTextChanged: wifiMenu.passwordInput = text

                                Keys.onReturnPressed: wifiMenu.connectWithPassword()
                                Keys.onEnterPressed: wifiMenu.connectWithPassword()
                                Keys.onEscapePressed: {
                                    wifiMenu.showPasswordPrompt = false
                                    passwd.text = ""
                                    wifiMenu.passwordInput = ""
                                }
                            }

                            Text {
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                text: "Password"
                                font.family: wifiMenu.fontFamily
                                font.pixelSize: wifiMenu.fontSize
                                color: wifiMenu.textColor
                                opacity: 0.3
                                visible: passwd.text.length === 0
                            }
                        }

                        // Show / hide password toggle.
                        Item {
                            id: passwdShow
                            property bool showPassword: false
                            Layout.preferredWidth: 34
                            Layout.fillHeight: true

                            Text {
                                anchors.centerIn: parent
                                text: passwdShow.showPassword ? "\uF070" : "\uF06E"
                                font.family: wifiMenu.iconFamily
                                font.pixelSize: wifiMenu.fontSize - 1
                                color: passwdMouse.containsMouse ? wifiMenu.accentColor : wifiMenu.textColor
                                opacity: passwdMouse.containsMouse ? 1.0 : 0.6
                            }

                            MouseArea {
                                id: passwdMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: passwdShow.showPassword = !passwdShow.showPassword
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 32
                        radius: 8
                        color: passwdCancel.containsMouse
                            ? Qt.lighter(wifiMenu.baseColor, 1.4)
                            : Qt.darker(wifiMenu.baseColor, 1.3)

                        Text {
                            anchors.centerIn: parent
                            text: "Cancel"
                            font.family: wifiMenu.fontFamily
                            font.pixelSize: wifiMenu.fontSize - 1
                            color: wifiMenu.textColor
                        }

                        MouseArea {
                            id: passwdCancel
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                wifiMenu.showPasswordPrompt = false
                                passwd.text = ""
                                wifiMenu.passwordInput = ""
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 32
                        radius: 8
                        color: passwdConnect.containsMouse
                            ? Qt.lighter(wifiMenu.accentColor, 1.1)
                            : wifiMenu.accentColor

                        Text {
                            anchors.centerIn: parent
                            text: "Connect"
                            font.family: wifiMenu.fontFamily
                            font.pixelSize: wifiMenu.fontSize - 1
                            font.weight: Font.Bold
                            color: wifiMenu.baseColor
                        }

                        MouseArea {
                            id: passwdConnect
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: wifiMenu.connectWithPassword()
                        }
                    }
                }
            }
        }
    }
}