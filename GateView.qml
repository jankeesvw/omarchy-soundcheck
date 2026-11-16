import QtQuick
import qs.Commons

// The noise gate, over the last few seconds.
//
// One bar per twentieth of a second: how loud the microphone was, on the same
// scale as the gate's slider, with the threshold drawn across. A bar in the
// accent colour got through; a grey one was held back. Whether something got
// through is read from what the chain actually sent, not worked out here, so
// the strip shows what the gate did rather than what it was meant to do.
Item {
  id: view

  property var history: []          // [{ l: dB, o: passed }], oldest first
  property int length: 120
  property real threshold: -55
  property bool gateOn: true
  property string idleLabel: "GATE OFF"
  property real minimum: -90
  property real maximum: -10

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color background: Color.background
  property string fontFamily: Style.font.family

  implicitHeight: Style.space(48)

  function frac(db) { return Math.max(0, Math.min(1, (db - minimum) / (maximum - minimum))) }
  function fade(c, amount) {
    var bg = view.background
    return Qt.rgba(c.r + (bg.r - c.r) * amount, c.g + (bg.g - c.g) * amount, c.b + (bg.b - c.b) * amount, 1)
  }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  readonly property bool hasData: history.length > 0
  readonly property bool openNow: hasData && history[history.length - 1].o === true
  readonly property real slot: width / Math.max(1, length)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: view.alpha(view.foreground, 0.035)
  }

  Repeater {
    model: view.length
    delegate: Rectangle {
      required property int index
      // Newest on the right: the last sample sits in the last slot.
      readonly property int at: view.history.length - view.length + index
      readonly property var sample: at >= 0 && at < view.history.length ? view.history[at] : null
      visible: sample !== null && sample.l > view.minimum
      x: index * view.slot
      width: Math.max(1, view.slot - 1)
      height: sample ? Math.max(1, view.height * view.frac(sample.l)) : 0
      y: view.height - height
      color: sample && sample.o ? view.alpha(view.accent, 0.85) : view.alpha(view.foreground, 0.22)
    }
  }

  // Where the gate opens. In the foreground colour, so it reads across the
  // accent bars that got through.
  Rectangle {
    visible: view.gateOn
    x: 0
    width: parent.width
    height: Math.max(1, Style.space(1.5))
    y: Math.round(view.height * (1 - view.frac(view.threshold)) - height / 2)
    color: view.alpha(view.foreground, 0.9)
  }

  Text {
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.top: parent.top
    anchors.topMargin: Style.space(3)
    text: !view.gateOn ? view.idleLabel : (!view.hasData ? "" : (view.openNow ? "OPEN" : "CLOSED"))
    textFormat: Text.PlainText
    color: view.gateOn && view.openNow ? view.accent : view.fade(view.foreground, 0.45)
    font.family: view.fontFamily
    font.pixelSize: Math.round(Style.font.caption * 0.9)
    font.bold: true
    font.letterSpacing: 1.1
  }

  Text {
    visible: !view.hasData
    anchors.centerIn: parent
    text: "Waiting for the microphone"
    textFormat: Text.PlainText
    color: view.fade(view.foreground, 0.55)
    font.family: view.fontFamily
    font.pixelSize: Math.round(Style.font.caption * 0.9)
  }
}
