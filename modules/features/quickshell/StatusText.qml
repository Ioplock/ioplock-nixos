import QtQuick

Text {
    property var appSettings

    color: appSettings ? appSettings.textColor : "#cdd6f4"
    font.family: appSettings ? appSettings.fontFamily : "sans-serif"
    font.pixelSize: appSettings ? appSettings.fontSize : 13
    verticalAlignment: Text.AlignVCenter
}
