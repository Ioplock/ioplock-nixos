import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: settings

    readonly property string settingsPath: "/home/ioplock/.config/quickshell/settings.json"

    property int barHeight: 34
    property string barColor: "#1e1e2e"
    property string textColor: "#cdd6f4"
    property string accentColor: "#f77af5ff"
    property int fontSize: 13
    property string fontFamily: "sans-serif"
    property string clockFormat: "ddd, dd MMM  HH:mm"

    property bool _loaded: false

    property FileView fileView: FileView {
        path: settings.settingsPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: adapter
            property int barHeight: 34
            property string barColor: "#1e1e2e"
            property string textColor: "#cdd6f4"
            property string accentColor: "#f77af5ff"
            property int fontSize: 13
            property string fontFamily: "sans-serif"
            property string clockFormat: "ddd, dd MMM  HH:mm"
        }

        onLoaded: {
            settings._loaded = true
            settings.barHeight = adapter.barHeight
            settings.barColor = adapter.barColor
            settings.textColor = adapter.textColor
            settings.accentColor = adapter.accentColor
            settings.fontSize = adapter.fontSize
            settings.fontFamily = adapter.fontFamily
            settings.clockFormat = adapter.clockFormat
        }
    }

    function save() {
        if (!_loaded) return
        adapter.barHeight = barHeight
        adapter.barColor = barColor
        adapter.textColor = textColor
        adapter.accentColor = accentColor
        adapter.fontSize = fontSize
        adapter.fontFamily = fontFamily
        adapter.clockFormat = clockFormat
        fileView.writeAdapter()
    }

    function resetToDefaults() {
        barHeight = 34
        barColor = "#1e1e2e"
        textColor = "#cdd6f4"
        accentColor = "#f77af5ff"
        fontSize = 13
        fontFamily = "sans-serif"
        clockFormat = "ddd, dd MMM  HH:mm"
        save()
    }

    onBarHeightChanged: save()
    onBarColorChanged: save()
    onTextColorChanged: save()
    onAccentColorChanged: save()
    onFontSizeChanged: save()
    onFontFamilyChanged: save()
    onClockFormatChanged: save()
}
