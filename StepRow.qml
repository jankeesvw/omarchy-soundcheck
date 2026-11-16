import QtQuick
import qs.Commons
import qs.Ui

// One step of the chain: a switch, a name, one slider and its value.
//
// The whole row is a single stop for the keyboard: Space switches the step,
// Left and Right move the slider (Shift for bigger steps). A step that needs a
// package shows the command to install it instead of a slider, and copies it
// on Enter or a click.
Item {
  id: row

  property QtObject bar: null
  property string title: ""
  property bool checked: true
  property bool toggleable: true
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 1
  property real bigStep: 5
  property string valueText: ""
  // "ready", "missing" (package not installed) or "restart" (installed, the
  // chain has not been rebuilt with it yet).
  property string mode: "ready"
  property string packageName: ""
  property string hint: ""

  // The gate's meter: the level of the microphone on the same scale as the
  // slider, so the knob sits exactly where the gate opens.
  property bool showMeter: false
  property real meterLevel: -120
  property real meterPeak: -120

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color background: Color.background
  property string fontFamily: Style.font.family

  signal toggled()
  signal moved(real value)
  signal copyRequested()
  signal restartRequested()

  activeFocusOnTab: true
  implicitHeight: content.implicitHeight + Style.space(10)

  function fade(c, amount) {
    var bg = row.background
    return Qt.rgba(c.r + (bg.r - c.r) * amount, c.g + (bg.g - c.g) * amount, c.b + (bg.b - c.b) * amount, 1)
  }

  function nudge(direction, big) {
    var v = Math.max(row.minimum, Math.min(row.maximum, row.value + direction * (big ? row.bigStep : row.step)))
    if (v !== row.value) row.moved(v)
  }

  function activate() {
    if (row.mode === "missing") row.copyRequested()
    else if (row.mode === "restart") row.restartRequested()
    else if (row.toggleable) row.toggled()
  }

  Keys.onPressed: function(event) {
    var big = event.modifiers & Qt.ShiftModifier
    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      row.activate(); event.accepted = true
    } else if (row.mode === "ready" && event.key === Qt.Key_Left) {
      row.nudge(-1, big); event.accepted = true
    } else if (row.mode === "ready" && event.key === Qt.Key_Right) {
      row.nudge(1, big); event.accepted = true
    }
  }

  CursorSurface {
    anchors.fill: parent
    hasCursor: row.activeFocus
    foreground: row.foreground
    accent: row.accent
  }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: Math.max(toggle.implicitHeight, titleText.implicitHeight, action.visible ? action.implicitHeight : 0)

      ToggleSwitch {
        id: toggle
        visible: row.toggleable && row.mode === "ready"
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        trackHeight: Math.max(16, Math.round(Style.spacing.controlHeight * 0.42))
        cursorRing: false
        checked: row.checked
        foreground: row.foreground
        accent: row.accent
        onToggled: { row.forceActiveFocus(); row.toggled() }
      }

      Text {
        id: titleText
        anchors.left: toggle.visible ? toggle.right : parent.left
        anchors.leftMargin: toggle.visible ? Style.space(8) : 0
        anchors.right: row.mode === "ready" ? valueLabel.left : action.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: row.title
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: row.mode === "ready" && (row.checked || !row.toggleable) ? row.foreground : row.fade(row.foreground, 0.4)
        font.family: row.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Button {
        id: action
        visible: row.mode !== "ready"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: row.mode === "missing" ? "Copy command" : "Restart chain"
        iconText: row.mode === "missing" ? SoundcheckStore.iconCopy : ""
        iconSize: Style.font.caption
        fontFamily: row.fontFamily
        fontSize: Style.font.caption
        verticalPadding: Style.space(3)
        foreground: row.foreground
        accent: row.accent
        bordered: true
        hasCursor: row.activeFocus
        onClicked: { row.forceActiveFocus(); row.activate() }
      }

      Text {
        id: valueLabel
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: row.mode === "ready"
        text: row.valueText
        textFormat: Text.PlainText
        color: row.fade(row.foreground, row.checked || !row.toggleable ? 0.3 : 0.55)
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    PanelSlider {
      id: slider
      visible: row.mode === "ready"
      width: parent.width
      bar: row.bar
      minimum: row.minimum
      maximum: row.maximum
      step: row.step
      value: row.value
      opacity: row.checked || !row.toggleable ? 1.0 : 0.45
      onMoved: function(v) { row.forceActiveFocus(); row.moved(v) }
    }

    // The gate's level meter, under the slider and on its scale.
    Item {
      visible: row.showMeter && row.mode === "ready"
      width: parent.width
      height: Style.space(5)

      readonly property real span: row.maximum - row.minimum
      function frac(db) { return Math.max(0, Math.min(1, (db - row.minimum) / span)) }

      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(row.foreground.r, row.foreground.g, row.foreground.b, 0.08)
      }
      Rectangle {
        width: parent.width * parent.frac(row.meterLevel)
        height: parent.height
        radius: height / 2
        // Lit while the level is past the threshold: the gate is letting you through.
        color: row.checked && row.meterLevel >= row.value ? row.accent : row.fade(row.foreground, 0.45)
      }
      Rectangle {
        x: parent.width * parent.frac(row.meterPeak) - width / 2
        width: Math.max(2, Style.space(2))
        height: parent.height
        color: row.fade(row.foreground, 0.2)
        visible: row.meterPeak > row.minimum
      }
    }

    // A step that needs a package: what to install, under the button that copies it.
    Text {
      visible: row.mode !== "ready"
      width: parent.width
      text: row.mode === "missing" ? "Needs " + row.packageName + ". The button copies omarchy pkg add " + row.packageName + "."
                                   : "Installed. Restarting the chain adds it (a second of silence on the microphone)."
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: row.fade(row.foreground, 0.35)
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: row.hint !== "" && row.mode === "ready"
      width: parent.width
      text: row.hint
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: row.fade(row.foreground, 0.45)
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
