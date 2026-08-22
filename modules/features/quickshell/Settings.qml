import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: settings

    readonly property string settingsPath: Quickshell.env("HOME") + "/.config/quickshell/settings.json"

property int barHeight: 34
            property real barOpacity: 0.96
    property string barColor: "#1e1e2e"
    property string textColor: "#cdd6f4"
    property string accentColor: "#f77af5ff"
    property int fontSize: 13
    property string fontFamily: "sans-serif"
    property string iconFontFamily: "JetBrainsMono Nerd Font"
    property string clockFormat: "ddd, dd MMM  HH:mm"
    property string wallpaper: ""

    property bool _loaded: false
    // Guards against mid-load save() calls: applying the loaded values fires
    // on*Changed, which would otherwise serialize fields that haven't been
    // assigned yet (e.g. `wallpaper` gets written back as its default "" and
    // the persisted selection is lost on every fresh start).
    property bool _saving: false

    property FileView fileView: FileView {
        path: settings.settingsPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: adapter
            property int barHeight: 34
    property real barOpacity: 0.96
            property string barColor: "#1e1e2e"
            property string textColor: "#cdd6f4"
            property string accentColor: "#f77af5ff"
            property int fontSize: 13
            property string fontFamily: "sans-serif"
            property string iconFontFamily: "JetBrainsMono Nerd Font"
            property string clockFormat: "ddd, dd MMM  HH:mm"
            property string wallpaper: ""
        }

        onLoaded: {
            settings._saving = true
            settings._loaded = true
            settings.barHeight = adapter.barHeight
            settings.barOpacity = adapter.barOpacity
            settings.barColor = adapter.barColor
            settings.textColor = adapter.textColor
            settings.accentColor = adapter.accentColor
            settings.fontSize = adapter.fontSize
            settings.fontFamily = adapter.fontFamily
            settings.iconFontFamily = adapter.iconFontFamily
            settings.clockFormat = adapter.clockFormat
            settings.wallpaper = adapter.wallpaper
            settings._saving = false
            settings.save()
        }
    }

    function save() {
        if (!_loaded || _saving) return
        adapter.barHeight = barHeight
        adapter.barOpacity = barOpacity
        adapter.barColor = barColor
        adapter.textColor = textColor
        adapter.accentColor = accentColor
        adapter.fontSize = fontSize
        adapter.fontFamily = fontFamily
        adapter.iconFontFamily = iconFontFamily
        adapter.clockFormat = clockFormat
        adapter.wallpaper = wallpaper
        fileView.writeAdapter()
    }

    function resetToDefaults() {
        barHeight = 34
        barOpacity = 0.7
        barColor = "#1e1e2e"
        textColor = "#cdd6f4"
        accentColor = "#f77af5ff"
        fontSize = 13
        fontFamily = "sans-serif"
        iconFontFamily = "JetBrainsMono Nerd Font"
        clockFormat = "ddd, dd MMM  HH:mm"
        wallpaper = ""
        save()
    }

    onBarHeightChanged: save()
    onBarOpacityChanged: save()
    onBarColorChanged: save()
    onTextColorChanged: save()
    onAccentColorChanged: save()
    onFontSizeChanged: save()
    onFontFamilyChanged: save()
    onIconFontFamilyChanged: save()
    onClockFormatChanged: save()
    onWallpaperChanged: save()
}
