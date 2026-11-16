import QtQuick
import QtQuick.Shapes
import qs.Commons
import "Eq.js" as Eq

// The curve you draw.
//
// Drag to paint: wherever the pointer goes, the curve goes to its height,
// with a soft brush about a third of an octave wide, so it stays smooth. A
// right drag paints back towards 0 dB, a double click makes it flat.
//
// Four layers. Behind: what your microphone picks up right now (a faint
// shadow) and what the chain sends on (a thin line over it), both live from
// the meter. In front: what you painted (filled), and what the filters
// together with the high-pass actually do (the thin line). That last one is
// computed with the same formulas PipeWire runs, so it is what you hear.
Item {
  id: view

  property var target: Eq.flat()
  property var gains: []
  property bool highpassOn: true
  property real highpassFreq: 80
  property var spectrum: []
  property var spectrumOut: []
  property bool bypassed: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color background: Color.background
  property string fontFamily: Style.font.family

  signal edited(var curve)
  signal committed()

  activeFocusOnTab: true
  implicitHeight: Style.space(210)

  readonly property real fMin: 20
  readonly property real fMax: 20000
  readonly property real dbRange: 15
  readonly property real padTop: Style.space(8)
  readonly property real padBottom: Style.space(20)
  readonly property real plotH: Math.max(10, height - padTop - padBottom)

  function xOf(freq) { return width * Math.log(freq / fMin) / Math.log(fMax / fMin) }
  function freqOf(x) { return fMin * Math.pow(fMax / fMin, Math.max(0, Math.min(1, x / Math.max(1, width)))) }
  function yOf(db) { return padTop + plotH / 2 - db / dbRange * (plotH / 2) }
  function dbOf(y) { return Math.max(-Eq.MAX_TARGET, Math.min(Eq.MAX_TARGET, (padTop + plotH / 2 - y) / (plotH / 2) * dbRange)) }

  // Blend towards the background rather than darken: darkening inverts the
  // hierarchy on a light theme, where the foreground is already dark.
  function fade(c, amount) {
    var bg = view.background
    return Qt.rgba(c.r + (bg.r - c.r) * amount, c.g + (bg.g - c.g) * amount, c.b + (bg.b - c.b) * amount, 1)
  }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // While dragging, the painted curve is redrawn from a local copy at once;
  // the solver and PipeWire hear about it at most every 40 ms.
  property bool drawing: false
  property var local: Eq.flat()
  readonly property var shown: drawing ? local : target

  property real lastPos: 0
  property real lastLevel: 0
  property bool erasing: false

  Timer {
    id: emitTimer
    interval: 40
    onTriggered: view.edited(view.local)
  }

  function paintAt(x, y, first) {
    var pos = Eq.gridPos(freqOf(x))
    var level = erasing ? 0 : dbOf(y)
    if (first) {
      local = Eq.dab(local, pos, level, 0.85)
    } else {
      local = Eq.stroke(local, lastPos, lastLevel, pos, level)
    }
    lastPos = pos
    lastLevel = level
    hoverX = x
    if (!emitTimer.running) emitTimer.start()
  }

  // ---- keyboard ----------------------------------------------------------

  property int cursorBand: 16   // 1 kHz
  readonly property bool keyboardCursor: activeFocus

  function nudge(delta) {
    view.edited(Eq.nudge(view.target, cursorBand * 2, delta))
    view.committed()
  }

  Keys.onPressed: function(event) {
    var big = event.modifiers & Qt.ShiftModifier
    if (event.key === Qt.Key_Left) { cursorBand = Math.max(0, cursorBand - (big ? 3 : 1)); event.accepted = true }
    else if (event.key === Qt.Key_Right) { cursorBand = Math.min(Eq.BANDS - 1, cursorBand + (big ? 3 : 1)); event.accepted = true }
    else if (event.key === Qt.Key_Up) { nudge(big ? 3 : 0.5); event.accepted = true }
    else if (event.key === Qt.Key_Down) { nudge(big ? -3 : -0.5); event.accepted = true }
    else if (event.key === Qt.Key_0 || event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
      var t = Eq.dab(Eq.dab(view.target, cursorBand * 2, 0, 1), cursorBand * 2, 0, 1)
      view.edited(t); view.committed(); event.accepted = true
    }
    else if (event.key === Qt.Key_F) { view.edited(Eq.flat()); view.committed(); event.accepted = true }
  }

  // ---- geometry ----------------------------------------------------------

  function targetPoints() {
    var t = view.shown, pts = [Qt.point(0, yOf(t[0]))]
    for (var k = 0; k < Eq.GRID; k++) pts.push(Qt.point(xOf(Eq.gridFreq(k)), yOf(t[k])))
    pts.push(Qt.point(width, yOf(t[Eq.GRID - 1])))
    return pts
  }

  function fillPoints() {
    var pts = targetPoints()
    pts.push(Qt.point(width, yOf(0)))
    pts.push(Qt.point(0, yOf(0)))
    return pts
  }

  readonly property var responsePoints: {
    var pts = [], g = view.gains && view.gains.length === Eq.BANDS ? view.gains : null
    var w = width
    if (w <= 0) return [Qt.point(0, 0)]
    for (var n = 0; n <= 160; n++) {
      var x = w * n / 160
      var db = g ? Eq.responseDb(g, view.highpassOn, view.highpassFreq, freqOf(x)) : 0
      pts.push(Qt.point(x, yOf(Math.max(-dbRange - 3, Math.min(dbRange + 3, db)))))
    }
    return pts
  }

  // The spectrum gets its own scale: -96 to -24 dBFS fills the plot.
  function specY(db) { return padTop + plotH - (Math.max(-96, Math.min(-24, db)) + 96) / 72 * plotH }

  // closed: down to the bottom and back, for a filled area; open: just the line.
  function spectrumPath(s, closed) {
    if (!s || s.length !== Eq.GRID || width <= 0) return []
    var pts = closed ? [Qt.point(0, padTop + plotH)] : []
    pts.push(Qt.point(0, specY(s[0])))
    for (var k = 0; k < Eq.GRID; k++) pts.push(Qt.point(xOf(Eq.gridFreq(k)), specY(s[k])))
    pts.push(Qt.point(width, specY(s[Eq.GRID - 1])))
    if (closed) pts.push(Qt.point(width, padTop + plotH))
    return pts
  }

  readonly property var spectrumPoints: spectrumPath(view.spectrum, true)
  readonly property var outputFill: spectrumPath(view.spectrumOut, true)
  readonly property var outputLine: spectrumPath(view.spectrumOut, false)

  // ---- drawing -----------------------------------------------------------

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? Style.space(6) : 0
    color: view.alpha(view.foreground, 0.035)
    border.width: view.activeFocus ? Math.max(1, Style.space(2)) : 1
    border.color: view.activeFocus ? view.accent : view.alpha(view.foreground, 0.10)
  }

  // Frequency grid.
  Repeater {
    model: [50, 100, 200, 500, 1000, 2000, 5000, 10000]
    delegate: Item {
      required property var modelData
      x: view.xOf(modelData)
      y: 0
      width: 1
      height: view.height

      Rectangle {
        x: 0; y: view.padTop
        width: 1; height: view.plotH
        color: view.alpha(view.foreground, modelData === 100 || modelData === 1000 || modelData === 10000 ? 0.10 : 0.05)
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: view.padTop + view.plotH + Style.space(3)
        text: modelData >= 1000 ? (modelData / 1000) + "k" : String(modelData)
        textFormat: Text.PlainText
        color: view.fade(view.foreground, 0.5)
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Level grid.
  Repeater {
    model: [12, 6, 0, -6, -12]
    delegate: Item {
      required property var modelData
      x: 0
      y: view.yOf(modelData)
      width: view.width
      height: 1

      Rectangle {
        width: parent.width; height: 1
        color: view.alpha(view.foreground, modelData === 0 ? 0.16 : 0.05)
      }
      Text {
        x: Style.space(5)
        anchors.bottom: parent.top
        text: modelData > 0 ? "+" + modelData : String(modelData)
        textFormat: Text.PlainText
        color: view.fade(view.foreground, 0.62)
        font.family: view.fontFamily
        font.pixelSize: Math.round(Style.font.caption * 0.9)
      }
    }
  }

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    preferredRendererType: Shape.CurveRenderer

    // What the microphone hears right now.
    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: view.alpha(view.foreground, view.spectrumPoints.length ? 0.07 : 0)
      PathPolyline { path: view.spectrumPoints.length ? view.spectrumPoints : [Qt.point(0, 0)] }
    }

    // What the chain sends on: a lighter wash with an edge, so where it
    // parts from the shadow above is where the chain changed something.
    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: view.alpha(view.foreground, view.outputFill.length ? 0.05 : 0)
      PathPolyline { path: view.outputFill.length ? view.outputFill : [Qt.point(0, 0)] }
    }
    ShapePath {
      strokeWidth: 1
      strokeColor: view.alpha(view.foreground, view.outputLine.length ? 0.38 : 0)
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      PathPolyline { path: view.outputLine.length ? view.outputLine : [Qt.point(0, 0)] }
    }

    // What you painted.
    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: view.alpha(view.accent, view.bypassed ? 0.06 : 0.20)
      PathPolyline { path: view.fillPoints() }
    }
    ShapePath {
      strokeWidth: Math.max(1.5, Style.space(2))
      strokeColor: view.alpha(view.accent, view.bypassed ? 0.35 : 0.95)
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      capStyle: ShapePath.RoundCap
      PathPolyline { path: view.targetPoints() }
    }

    // What the filters do.
    ShapePath {
      strokeWidth: Math.max(1, Style.space(1.2))
      strokeColor: view.alpha(view.foreground, view.bypassed ? 0.25 : 0.75)
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      PathPolyline { path: view.responsePoints }
    }
  }

  // Keyboard cursor and pointer readout share one marker.
  property real hoverX: -1
  readonly property real markerX: view.keyboardCursor && !mouse.containsMouse ? xOf(Eq.bandFreq(cursorBand))
                                 : (mouse.containsMouse || drawing ? hoverX : -1)
  readonly property real markerFreq: markerX >= 0 ? freqOf(markerX) : 0
  readonly property real markerDb: {
    if (markerX < 0) return 0
    var pos = Math.max(0, Math.min(Eq.GRID - 1, Eq.gridPos(markerFreq)))
    var k = Math.floor(pos), f = pos - k, t = view.shown
    return k >= Eq.GRID - 1 ? t[Eq.GRID - 1] : t[k] * (1 - f) + t[k + 1] * f
  }

  function freqText(f) {
    if (f >= 1000) return (f >= 10000 ? Math.round(f / 1000) : Math.round(f / 100) / 10) + " kHz"
    return Math.round(f) + " Hz"
  }

  Rectangle {
    visible: view.markerX >= 0
    x: view.markerX
    y: view.padTop
    width: 1
    height: view.plotH
    color: view.alpha(view.foreground, 0.35)
  }

  Rectangle {
    id: readout
    visible: view.markerX >= 0
    readonly property real wanted: view.markerX + Style.space(8)
    x: wanted + width > view.width - Style.space(4) ? view.markerX - width - Style.space(8) : wanted
    y: view.padTop + Style.space(4)
    width: readoutText.implicitWidth + Style.space(12)
    height: readoutText.implicitHeight + Style.space(6)
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: view.alpha(view.background, 0.92)
    border.width: 1
    border.color: view.alpha(view.foreground, 0.15)

    Text {
      id: readoutText
      anchors.centerIn: parent
      text: view.freqText(view.markerFreq) + "   " + (view.markerDb >= 0 ? "+" : "") + view.markerDb.toFixed(1) + " dB"
      textFormat: Text.PlainText
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Text {
    visible: view.bypassed
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    y: view.padTop + Style.space(4)
    text: "BYPASSED"
    textFormat: Text.PlainText
    color: view.foreground
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
  }

  Row {
    id: legend
    visible: view.spectrumPoints.length > 0
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    y: view.padTop + view.plotH - height - Style.space(5)
    spacing: Style.space(10)

    Repeater {
      model: view.outputLine.length ? [{ label: "Microphone", line: false }, { label: "Soundcheck output", line: true }]
                                    : [{ label: "Microphone", line: false }]
      delegate: Row {
        required property var modelData
        spacing: Style.space(4)
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(12)
          height: modelData.line ? 1 : Style.space(7)
          color: view.alpha(view.foreground, modelData.line ? 0.55 : 0.16)
        }
        Text {
          text: modelData.label
          textFormat: Text.PlainText
          color: view.fade(view.foreground, 0.5)
          font.family: view.fontFamily
          font.pixelSize: Math.round(Style.font.caption * 0.9)
        }
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled: true
    preventStealing: true
    cursorShape: Qt.CrossCursor

    onPressed: function(m) {
      view.forceActiveFocus()
      view.erasing = m.button === Qt.RightButton
      view.local = view.target.slice()
      view.drawing = true
      view.paintAt(m.x, m.y, true)
    }
    onPositionChanged: function(m) {
      view.hoverX = Math.max(0, Math.min(view.width, m.x))
      if (view.drawing) view.paintAt(Math.max(0, Math.min(view.width, m.x)), m.y, false)
    }
    onReleased: {
      if (!view.drawing) return
      emitTimer.stop()
      view.edited(view.local)
      view.drawing = false
      view.committed()
    }
    onCanceled: {
      emitTimer.stop()
      view.drawing = false
    }
    onDoubleClicked: function(m) {
      if (m.button !== Qt.LeftButton) return
      view.drawing = false
      view.edited(Eq.flat())
      view.committed()
    }
  }
}
