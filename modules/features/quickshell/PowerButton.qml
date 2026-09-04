import QtQuick
import Quickshell.Io

// Data + action for one power menu button.
// Mirrors quickshell-examples/wlogout/LogoutButton.qml but does not Qt.quit()
// the whole shell — it just runs the command detached and hides the overlay.
QtObject {
    id: button
    required property string command
    required property string text
    required property string icon
    property var keybind: null
    property string description: ""

    // Not readonly var — qmllint 6.10 complains about binding loop if var.
    property Process process: Process {
        command: ["sh", "-c", button.command]
    }

    function exec() {
        process.startDetached()
    }
}
