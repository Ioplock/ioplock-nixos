import QtQuick
import Quickshell
import Quickshell.Services.Pam

// Shared lock state across all WlSessionLockSurface instances (one per screen).
// Taken from quickshell-examples/lockscreen/LockContext.qml with minimal adaptation.
Scope {
    id: root
    signal unlocked()
    signal failed()

    property string currentText: ""
    property bool unlockInProgress: false
    property bool showFailure: false

    // Clear the failure text once the user starts typing.
    onCurrentTextChanged: showFailure = false

    function tryUnlock() {
        if (currentText === "") return
        root.unlockInProgress = true
        pam.start()
    }

    PamContext {
        id: pam

        // Bundled PAM config next to shell.qml; see pam/password.conf.
        // Resolved relative to this QML file if not absolute.
        configDirectory: "pam"
        config: "password.conf"

        // pam_unix will ask for a response for the password prompt
        onPamMessage: {
            if (this.responseRequired) {
                this.respond(root.currentText)
            }
        }

        // pam_unix won't send any important messages so all we need is the completion status.
        onCompleted: result => {
            if (result == PamResult.Success) {
                root.unlocked()
            } else {
                root.currentText = ""
                root.showFailure = true
            }
            root.unlockInProgress = false
        }
    }
}
