import QtQuick
import Quickshell
import Quickshell.Wayland

// Renders the desktop wallpaper on the layer-shell Background layer, below the
// bar and regular windows, so it shows through translucent surfaces. When the
// active wallpaper changes, the incoming image is crossfaded over the current
// one; the initial wallpaper (shell startup) is applied instantly.
Variants {
    id: root

    property var appSettings: null

    readonly property real fadeDuration: 300
    readonly property int fadeEasing: Easing.InOutCubic

    model: Quickshell.screens

    delegate: PanelWindow {
        id: bg
        required property var modelData

        readonly property string filePrefix: "file://"
        // Path we last committed to (base image or cleared); guards against
        // reacting to the same value twice.
        property string lastPath: ""
        // True once a wallpaper has been placed. Startup placement skips the
        // animation; later changes crossfade.
        property bool ready: false

        function srcFor(path) {
            return path ? bg.filePrefix + path : ""
        }

        screen: modelData
        color: "transparent"
        focusable: false

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        WlrLayershell.layer: WlrLayer.Background
        // -1 (DontCare): don't reposition this surface to accommodate the bar's
        // exclusive zone, so the wallpaper extends all the way to the screen
        // edges (under the translucent bar).
        WlrLayershell.exclusiveZone: -1

        // Steady-state wallpaper.
        Image {
            id: baseImage
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            mipmap: true
            smooth: true
            sourceSize: Qt.size(bg.modelData.width * 2, bg.modelData.height * 2)
        }

        // Transition layer: staged with the incoming wallpaper and crossfaded
        // over the base image, then promoted into the base when the fade ends.
        Image {
            id: fadeImage
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            mipmap: true
            smooth: true
            sourceSize: baseImage.sourceSize
            opacity: 0

            onStatusChanged: {
                if (status !== Image.Ready) return
                if (fadeImage.source === "" || fadeImage.opacity !== 0) return
                fadeAnim.start()
            }
        }

        NumberAnimation {
            id: fadeAnim
            target: fadeImage
            property: "opacity"
            from: 0
            to: 1
            duration: root.fadeDuration
            easing.type: root.fadeEasing

            onFinished: {
                // The faded image is now fully covering the old one; make it
                // the steady state and reset the transition layer.
                baseImage.source = fadeImage.source
                fadeImage.opacity = 0
                fadeImage.source = ""
            }
        }

        Connections {
            target: root.appSettings
            function onWallpaperChanged() {
                const path = root.appSettings ? root.appSettings.wallpaper : ""
                if (path === bg.lastPath) return
                bg.lastPath = path

                if (!path) {
                    // Cleared: tear down so the compositor background shows.
                    fadeAnim.stop()
                    fadeImage.opacity = 0
                    fadeImage.source = ""
                    baseImage.source = ""
                    bg.ready = false
                    return
                }

                const src = bg.srcFor(path)
                if (!bg.ready) {
                    // First placement at startup: no animation.
                    baseImage.source = src
                    bg.ready = true
                    return
                }

                // Crossfade the new image over the still-visible base.
                fadeAnim.stop()
                fadeImage.opacity = 0
                fadeImage.source = src
            }
        }

        Component.onCompleted: {
            const path = root.appSettings ? root.appSettings.wallpaper : ""
            bg.lastPath = path
            bg.ready = path !== ""
            if (path)
                baseImage.source = bg.srcFor(path)
        }
    }
}
