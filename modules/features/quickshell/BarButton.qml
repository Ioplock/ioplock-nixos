import QtQuick

Rectangle {
    id: root

    property var appSettings
    property string icon: ""
    property string text: ""
    property color textColor: appSettings ? appSettings.textColor : "#cdd6f4"
    property bool clickable: false
    property bool dimmed: false
    signal activated()

    readonly property color baseColor: appSettings ? appSettings.barColor : "#1e1e2e"

    implicitWidth: contentRow.implicitWidth + 14
    implicitHeight: contentRow.implicitHeight + 6
    radius: 4
    color: clickable && hoverArea.containsMouse ? Qt.lighter(baseColor, 1.4) : "transparent"
    opacity: dimmed ? 0.55 : 1.0

    Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: 4

        Text {
            text: root.icon
            visible: text !== ""
            font.family: appSettings ? appSettings.iconFontFamily : "JetBrainsMono Nerd Font"
            font.pixelSize: (appSettings ? appSettings.fontSize : 13) + 1
            color: root.textColor
            verticalAlignment: Text.AlignVCenter
        }

        Text {
            text: root.text
            visible: text !== ""
            font.family: appSettings ? appSettings.fontFamily : "sans-serif"
            font.pixelSize: appSettings ? appSettings.fontSize : 13
            color: root.textColor
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: root.clickable
        cursorShape: root.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (root.clickable) root.activated()
    }
}
