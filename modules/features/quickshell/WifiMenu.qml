import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

PanelWindow {
    id: wifiMenu

    property var appSettings
    property var barWindow

    implicitWidth: 320
    implicitHeight: 400
    visible: false
    color: appSettings ? appSettings.barColor : "#1e1e2e"

    focusable: true

    anchors {
        top: true
        right: true
    }

    margins {
        top: barWindow ? barWindow.height + 4 : 38
        right: 12
    }

    property bool wifiEnabled: false
    property string currentNetwork: ""
    property var networks: []
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
                // Escaped character — take next char literally
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

    // Signal strength as filled/empty circles (●○).
    // Fixed: previously all four branches returned the same emoji.
    function getSignalIcon(signal) {
        if (signal >= 75) return "\u25CF\u25CF\u25CF\u25CF"
        if (signal >= 50) return "\u25CF\u25CF\u25CF\u25CB"
        if (signal >= 25) return "\u25CF\u25CF\u25CB\u25CB"
        return "\u25CF\u25CB\u25CB\u25CB"
    }

    // Color-code signal strength: green → yellow → orange → red.
    function getSignalColor(signal) {
        if (signal >= 75) return "#a6e3a1"
        if (signal >= 50) return "#f9e2af"
        if (signal >= 25) return "#fab387"
        return "#f38ba8"
    }

    // forceRescan=true  → nmcli triggers a hardware scan (slower, fresh data)
    // forceRescan=false → nmcli uses cached data (fast, good for background refreshes)
    function refreshNetworks(forceRescan) {
        if (scanning) return
        scanning = true
        wifiMenu.networks = []
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

    function connectToNetwork(name, needPassword) {
        if (needPassword) {
            selectedNetwork = name
            showPasswordPrompt = true
            // Cleanup (focus, text clear) is handled by passwordPrompt.onVisibleChanged
        } else {
            connectingTo = name
            wifiConnectProcess.command = ["nmcli", "device", "wifi", "connect", name]
            wifiConnectProcess.running = true
        }
    }

    function connectWithPassword() {
        if (!wifiMenu.passwordInput) return
        connectingTo = selectedNetwork
        showPasswordPrompt = false
        wifiConnectProcess.command = [
            "nmcli", "device", "wifi", "connect", selectedNetwork,
            "password", wifiMenu.passwordInput
        ]
        wifiConnectProcess.running = true
    }

    function disconnectWifi() {
        wifiDisconnectProcess.command = ["nmcli", "device", "disconnect", wifiInterface]
        wifiDisconnectProcess.running = true
    }

    Process {
        id: wifiStatusProcess
        command: ["nmcli", "-t", "-f", "WIFI", "general"]
        stdout: StdioCollector {
            onStreamFinished: {
                const newState = text.trim() === "enabled"
                const wasEnabled = wifiMenu.wifiEnabled
                wifiMenu.wifiEnabled = newState
                // If wifi just turned on via toggle, automatically scan.
                // Fixed: old code did the opposite — it scanned when turning OFF
                // and cleared the list when turning ON.
                if (!wasEnabled && newState) {
                    wifiMenu.refreshNetworks(true)
                }
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
                    const parts = line.split(":")
                    if (parts.length >= 2 && parts[1] === "wifi") {
                        wifiMenu.wifiInterface = parts[0]
                        break
                    }
                }
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
                // wifiEnabled still holds the pre-toggle state here.
                // Was on → command was "off" → clear the list immediately.
                wifiMenu.networks = []
                wifiMenu.currentNetwork = ""
            }
            // Refresh status. If wifi just turned on, wifiStatusProcess.onStreamFinished
            // will detect the transition and call refreshNetworks(true).
            wifiStatusProcess.running = true
        }
    }

    Process {
        id: wifiScanProcess
        // Default command; overwritten by refreshNetworks() before each run
        command: ["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY,IN-USE", "device", "wifi", "list", "--rescan", "yes"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n")
                const seen = {}
                const nets = []
                let current = ""

                for (const line of lines) {
                    if (!line) continue

                    // Use custom parser to handle SSIDs containing colons
                    const parts = wifiMenu.splitNmcliLine(line)
                    if (parts.length < 4) continue

                    const ssid = parts[0]
                    if (!ssid || ssid.trim() === "") continue

                    const signal = parseInt(parts[1]) || 0
                    const security = parts[2] || ""
                    const inUse = parts[3].trim() === "*"

                    if (inUse) current = ssid

                    if (!seen[ssid] || seen[ssid].signal < signal) {
                        seen[ssid] = { ssid: ssid, signal: signal, security: security, inUse: inUse }
                    } else if (inUse) {
                        seen[ssid].inUse = true
                    }
                }

                for (const key in seen) {
                    nets.push(seen[key])
                }

                nets.sort((a, b) => {
                    if (a.inUse) return -1
                    if (b.inUse) return 1
                    return b.signal - a.signal
                })

                wifiMenu.networks = nets
                wifiMenu.currentNetwork = current
                wifiMenu.scanning = false
            }
        }
        onExited: {
            // Safety net: ensure scanning is cleared even if stdout was empty
            wifiMenu.scanning = false
        }
    }

    Process {
        id: wifiConnectProcess
        onExited: (code) => {
            // Fixed: capture SSID before clearing connectingTo
            if (code === 0) {
                wifiMenu.connectionStatus = "Connected to " + wifiMenu.connectingTo
            } else {
                wifiMenu.connectionStatus = "Failed to connect to " + wifiMenu.connectingTo
            }
            wifiMenu.connectingTo = ""
            statusClearTimer.restart()
            wifiMenu.refreshNetworks(true)
        }
    }

    Process {
        id: wifiDisconnectProcess
        onExited: {
            // Use cached data — no need for a hardware rescan after disconnect
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
            // Background refresh: use cached data to avoid slow hardware rescan
            wifiMenu.refreshNetworks(false)
        }
    }

    onVisibleChanged: {
        if (visible) {
            wifiStatusProcess.running = true
            wifiInterfaceProcess.running = true
            wifiMenu.refreshNetworks(true)
        } else {
            // Reset transient state so the menu opens cleanly next time
            wifiMenu.showPasswordPrompt = false
            wifiMenu.connectionStatus = ""
            statusClearTimer.stop()
        }
    }

    ColumnLayout {
        id: contentColumn
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                text: "Wi-Fi"
                font.pixelSize: 15
                font.weight: Font.Bold
                color: appSettings ? appSettings.textColor : "#cdd6f4"
                Layout.fillWidth: true
            }

            Text {
                text: "scanning\u2026"
                font.pixelSize: 11
                color: appSettings ? appSettings.textColor : "#cdd6f4"
                opacity: 0.5
                visible: wifiMenu.scanning
            }

            Rectangle {
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                radius: 4
                color: refreshArea.containsMouse
                    ? Qt.lighter(appSettings ? appSettings.barColor : "#1e1e2e", 1.4)
                    : "transparent"
                visible: wifiMenu.wifiEnabled && !wifiMenu.scanning

                Text {
                    anchors.centerIn: parent
                    text: "\u21BB"
                    font.pixelSize: 14
                    color: appSettings ? appSettings.textColor : "#cdd6f4"
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
            height: 1
            color: appSettings ? appSettings.accentColor : "#f77af5ff"
            opacity: 0.3
        }

        // On/off toggle
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                text: wifiMenu.wifiEnabled ? "Wi-Fi On" : "Wi-Fi Off"
                font.pixelSize: 13
                color: appSettings ? appSettings.textColor : "#cdd6f4"
                Layout.fillWidth: true
            }

            Rectangle {
                Layout.preferredWidth: 44
                Layout.preferredHeight: 24
                radius: 12
                color: wifiMenu.wifiEnabled
                    ? (appSettings ? appSettings.accentColor : "#f77af5ff")
                    : "#585b70"

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
            height: 1
            color: appSettings ? appSettings.accentColor : "#f77af5ff"
            opacity: 0.3
            visible: wifiMenu.wifiEnabled
        }

        // Connection status message
        Text {
            text: wifiMenu.connectionStatus
            font.pixelSize: 12
            color: wifiMenu.connectionStatus.startsWith("Connected") ? "#a6e3a1" : "#f38ba8"
            visible: wifiMenu.connectionStatus !== ""
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
        }

        // Network list
        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: networkList.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            visible: wifiMenu.wifiEnabled && !wifiMenu.showPasswordPrompt

            ColumnLayout {
                id: networkList
                width: parent.width
                spacing: 2

                Repeater {
                    model: wifiMenu.networks

                    Rectangle {
                        required property var modelData
                        property bool isConnecting: wifiMenu.connectingTo === modelData.ssid

                        Layout.fillWidth: true
                        height: 44
                        radius: 6
                        color: (netArea.containsMouse && !isConnecting)
                            ? Qt.lighter(appSettings ? appSettings.barColor : "#1e1e2e", 1.3)
                            : "transparent"
                        opacity: isConnecting ? 0.5 : 1.0

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 6

                            // Signal strength indicator — color-coded by level
                            Text {
                                text: wifiMenu.getSignalIcon(modelData.signal)
                                font.pixelSize: 10
                                color: wifiMenu.getSignalColor(modelData.signal)
                                Layout.preferredWidth: 30
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                Text {
                                    text: modelData.ssid
                                    font.pixelSize: 13
                                    color: modelData.inUse
                                        ? (appSettings ? appSettings.accentColor : "#f77af5ff")
                                        : (appSettings ? appSettings.textColor : "#cdd6f4")
                                    font.weight: modelData.inUse ? Font.Bold : Font.Normal
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                Text {
                                    // Treat "" and "--" both as Open (nmcli uses "" in terse mode)
                                    text: (modelData.security && modelData.security !== "--")
                                        ? modelData.security
                                        : "Open"
                                    font.pixelSize: 10
                                    color: appSettings ? appSettings.textColor : "#cdd6f4"
                                    opacity: 0.5
                                }
                            }

                            // Show "…" while connecting, otherwise show signal %
                            Text {
                                text: isConnecting ? "\u2026" : (modelData.signal + "%")
                                font.pixelSize: 11
                                color: isConnecting
                                    ? (appSettings ? appSettings.accentColor : "#f77af5ff")
                                    : (appSettings ? appSettings.textColor : "#cdd6f4")
                                opacity: isConnecting ? 1.0 : 0.7
                            }

                            Text {
                                text: "\u2713"
                                font.pixelSize: 14
                                color: appSettings ? appSettings.accentColor : "#f77af5ff"
                                visible: modelData.inUse && !isConnecting
                            }
                        }

                        MouseArea {
                            id: netArea
                            anchors.fill: parent
                            hoverEnabled: true
                            // Disable interaction while any connection attempt is running
                            enabled: wifiMenu.connectingTo === ""
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                                if (modelData.inUse) {
                                    wifiMenu.disconnectWifi()
                                } else {
                                    const needsPass = modelData.security !== ""
                                        && modelData.security !== "--"
                                    wifiMenu.connectToNetwork(modelData.ssid, needsPass)
                                }
                            }
                        }
                    }
                }

                Text {
                    text: wifiMenu.scanning
                        ? "Scanning for networks\u2026"
                        : "No networks found"
                    font.pixelSize: 12
                    color: appSettings ? appSettings.textColor : "#cdd6f4"
                    opacity: 0.5
                    Layout.alignment: Qt.AlignHCenter
                    visible: wifiMenu.networks.length === 0
                    topPadding: 12
                    bottomPadding: 8
                }
            }
        }

        // Password prompt
        ColumnLayout {
            id: passwordPrompt
            Layout.fillWidth: true
            spacing: 8
            visible: wifiMenu.showPasswordPrompt

            onVisibleChanged: {
                if (visible) {
                    // Reset prompt state each time it opens
                    passInput.text = ""
                    showPassToggle.showPassword = false
                    Qt.callLater(() => passInput.forceActiveFocus())
                }
            }

            Text {
                text: "Connect to: " + wifiMenu.selectedNetwork
                font.pixelSize: 13
                font.weight: Font.Bold
                color: appSettings ? appSettings.textColor : "#cdd6f4"
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Rectangle {
                Layout.fillWidth: true
                height: 36
                radius: 6
                color: Qt.darker(appSettings ? appSettings.barColor : "#1e1e2e", 1.3)
                border.color: passInput.activeFocus
                    ? (appSettings ? appSettings.accentColor : "#f77af5ff")
                    : "transparent"
                border.width: passInput.activeFocus ? 1 : 0

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 4
                    spacing: 4

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        TextInput {
                            id: passInput
                            anchors.fill: parent
                            verticalAlignment: TextInput.AlignVCenter
                            color: appSettings ? appSettings.textColor : "#cdd6f4"
                            font.pixelSize: 13
                            echoMode: showPassToggle.showPassword
                                ? TextInput.Normal
                                : TextInput.Password
                            passwordCharacter: "\u2022"
                            clip: true
                            onTextChanged: wifiMenu.passwordInput = text

                            Keys.onReturnPressed: wifiMenu.connectWithPassword()
                            Keys.onEscapePressed: {
                                wifiMenu.showPasswordPrompt = false
                                passInput.text = ""
                            }
                        }

                        // Placeholder text
                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: "Password"
                            font.pixelSize: 13
                            color: appSettings ? appSettings.textColor : "#cdd6f4"
                            opacity: 0.3
                            visible: passInput.text.length === 0
                        }
                    }

                    // Show / hide password toggle
                    Item {
                        id: showPassToggle
                        property bool showPassword: false
                        Layout.preferredWidth: 36
                        Layout.fillHeight: true

                        Text {
                            anchors.centerIn: parent
                            text: showPassToggle.showPassword ? "hide" : "show"
                            font.pixelSize: 10
                            color: showPassMouse.containsMouse
                                ? (appSettings ? appSettings.accentColor : "#f77af5ff")
                                : (appSettings ? appSettings.textColor : "#cdd6f4")
                            opacity: showPassMouse.containsMouse ? 1.0 : 0.5
                        }

                        MouseArea {
                            id: showPassMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: showPassToggle.showPassword = !showPassToggle.showPassword
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                    Layout.fillWidth: true
                    height: 32
                    radius: 6
                    color: cancelArea.containsMouse
                        ? Qt.lighter(appSettings ? appSettings.barColor : "#1e1e2e", 1.4)
                        : Qt.darker(appSettings ? appSettings.barColor : "#1e1e2e", 1.3)

                    Text {
                        anchors.centerIn: parent
                        text: "Cancel"
                        font.pixelSize: 12
                        color: appSettings ? appSettings.textColor : "#cdd6f4"
                    }

                    MouseArea {
                        id: cancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            wifiMenu.showPasswordPrompt = false
                            passInput.text = ""
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 32
                    radius: 6
                    color: connectArea.containsMouse
                        ? Qt.lighter(appSettings ? appSettings.accentColor : "#f77af5ff", 1.1)
                        : (appSettings ? appSettings.accentColor : "#f77af5ff")

                    Text {
                        anchors.centerIn: parent
                        text: "Connect"
                        font.pixelSize: 12
                        font.weight: Font.Bold
                        color: appSettings ? appSettings.barColor : "#1e1e2e"
                    }

                    MouseArea {
                        id: connectArea
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
