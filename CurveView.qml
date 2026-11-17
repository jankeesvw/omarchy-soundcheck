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
// Behind: what your microphone picks up right now, as a live spectrum, with
// a dotted line over it for the loudest each frequency has been in the last
// second or two, and a label on the one that sticks out most. That is how you
// find the frequency to paint away. With the chain on, a line for what it
// sends on. In front: what you painted (filled), and what the filters together
// with the high-pass actually do (the thin line). That last one is computed
// with the same formulas PipeWire runs, so it is what you hear.
//
// Each of those has a colour of its own, named in the legend under the graph:
// the curve in the accent, the microphone and the output in two hues picked
// to stand apart from the accent and from each other.
Item {
  id: view

  property var target: Eq.flat()
  property var gains: []
  property bool highpassOn: true
  property real highpassFreq: 80
  property var spectrum: []
  property var spectrumOut: []
  property var peaks: []
  // What the spectrum is of: the microphone, or the test recording while it plays.
  property string inputLabel: "Microphone"
  // The top of the spectrum's own scale, in dBFS; the plot shows spectrumSpan
  // below it. The meter moves it to follow the microphone.
  property real spectrumTop: -40
  readonly property real spectrumSpan: 70
  property bool bypassed: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color background: Color.background
  property string fontFamily: Style.font.family

  signal edited(var curve)
  signal committed()

  activeFocusOnTab: true
  implicitHeight: Style.space(210) + legendBand

  readonly property real fMin: 20
  readonly property real fMax: 20000
  readonly property real dbRange: 15
  readonly property real padTop: Style.space(8)
  // Under the plot: the frequencies, then the legend outside the card.
  readonly property real legendBand: Style.space(22)
  readonly property real padBottom: Style.space(20) + legendBand
  readonly property real cardH: height - legendBand
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

  // The hues of the microphone and the output: the first of each list that
  // is far enough round the colour wheel from the accent, so neither reads
  // as the curve. A grey accent leaves the first of each.
  readonly property bool darkTheme: background.r * 0.299 + background.g * 0.587 + background.b * 0.114 < 0.5
  function hueAway(candidates, avoid) {
    for (var i = 0; i < candidates.length; i++) {
      var ok = true
      for (var j = 0; j < avoid.length; j++) {
        var d = Math.abs(candidates[i] - avoid[j])
        if (Math.min(d, 1 - d) < 0.12) ok = false
      }
      if (ok) return candidates[i]
    }
    return candidates[0]
  }
  readonly property var accentHues: accent.hslSaturation > 0.2 ? [accent.hslHue] : []
  readonly property real micHue: hueAway([0.53, 0.78, 0.36], accentHues)            // cyan, violet, green
  readonly property real outHue: hueAway([0.10, 0.95, 0.36], accentHues.concat([micHue]))  // amber, pink, green
  function tone(hue) { return Qt.hsla(hue, darkTheme ? 0.65 : 0.7, darkTheme ? 0.62 : 0.42, 1) }
  readonly property color micColor: tone(micHue)
  readonly property color outColor: tone(outHue)

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

  // The spectrum gets its own scale, separate from the curve's dB.
  function specY(db) {
    var bottom = spectrumTop - spectrumSpan
    return padTop + plotH - (Math.max(bottom, Math.min(spectrumTop, db)) - bottom) / spectrumSpan * plotH
  }

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
  readonly property var spectrumEdge: spectrumPath(view.spectrum, false)
  readonly property var peakLine: spectrumPath(view.peaks, false)
  readonly property var outputLine: spectrumPath(view.spectrumOut, false)
  readonly property bool hasOutput: outputLine.length > 0

  // The band that sticks out: the highest peak, if it stands at least 12 dB
  // above the median of all of them. A flat room hum shows nothing; a voice,
  // a whine or a boomy resonance does.
  readonly property int loudest: {
    var p = view.peaks
    if (!p || p.length !== Eq.GRID) return -1
    var sorted = p.slice().sort(function(a, b) { return a - b })
    var median = sorted[Math.floor(sorted.length / 2)]
    var best = 0
    for (var k = 1; k < Eq.GRID; k++) if (p[k] > p[best]) best = k
    return p[best] - median >= 12 ? best : -1
  }

  // ---- drawing -----------------------------------------------------------

  Rectangle {
    width: parent.width
    height: view.cardH
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

    // What the microphone hears right now: a filled spectrum with an edge.
    // It steps back a little when the output line is drawn over it.
    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: view.alpha(view.micColor, view.spectrumPoints.length ? (view.hasOutput ? 0.16 : 0.22) : 0)
      PathPolyline { path: view.spectrumPoints.length ? view.spectrumPoints : [Qt.point(0, 0)] }
    }
    ShapePath {
      strokeWidth: 1
      strokeColor: view.alpha(view.micColor, view.spectrumEdge.length ? (view.hasOutput ? 0.5 : 0.7) : 0)
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      PathPolyline { path: view.spectrumEdge.length ? view.spectrumEdge : [Qt.point(0, 0)] }
    }

    // The loudest each frequency has been lately: the microphone's colour, dotted.
    ShapePath {
      strokeWidth: Math.max(1, Style.space(1.2))
      strokeColor: view.alpha(view.micColor, view.peakLine.length ? 0.95 : 0)
      fillColor: "transparent"
      strokeStyle: ShapePath.DashLine
      dashPattern: [2, 3]
      joinStyle: ShapePath.RoundJoin
      PathPolyline { path: view.peakLine.length ? view.peakLine : [Qt.point(0, 0)] }
    }

    // What the chain sends on: where it parts from the spectrum below is
    // where the chain changed something.
    ShapePath {
      strokeWidth: Math.max(1.5, Style.space(1.6))
      strokeColor: view.alpha(view.outColor, view.hasOutput ? 0.95 : 0)
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      PathPolyline { path: view.hasOutput ? view.outputLine : [Qt.point(0, 0)] }
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

  // The frequency that sticks out: a dot on the peak line and its frequency,
  // so you know where to paint.
  Item {
    id: loudMark
    visible: view.loudest >= 0 && view.peaks.length === Eq.GRID
    readonly property real fx: view.loudest >= 0 ? view.xOf(Eq.gridFreq(view.loudest)) : 0
    readonly property real fy: view.loudest >= 0 ? view.specY(view.peaks[view.loudest]) : 0
    anchors.fill: parent

    Rectangle {
      width: Style.space(6)
      height: width
      radius: width / 2
      x: loudMark.fx - width / 2
      y: loudMark.fy - height / 2
      color: view.micColor
    }

    Rectangle {
      readonly property real wanted: loudMark.fx - width / 2
      x: Math.max(Style.space(2), Math.min(view.width - width - Style.space(2), wanted))
      y: Math.max(view.padTop, loudMark.fy - height - Style.space(6))
      width: loudText.implicitWidth + Style.space(8)
      height: loudText.implicitHeight + Style.space(2)
      radius: Style.cornerRadius > 0 ? Style.space(3) : 0
      color: view.alpha(view.background, 0.85)

      Text {
        id: loudText
        anchors.centerIn: parent
        text: view.loudest >= 0 ? view.freqText(Eq.gridFreq(view.loudest)) : ""
        textFormat: Text.PlainText
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Math.round(Style.font.caption * 0.9)
        font.bold: true
      }
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

  // Under the card: every line in the graph, with its colour and its style.
  Row {
    id: legend
    x: Style.space(2)
    y: view.cardH + Math.round((view.legendBand - height) / 2)
    spacing: Style.space(12)

    Repeater {
      // w and a: the width and opacity of the line in the graph.
      model: [{ label: "Your curve", kind: "curve", c: view.accent, w: 2, a: 0.95, on: true },
              { label: "Filters", kind: "line", c: view.foreground, w: 1.2, a: 0.75, on: true },
              { label: view.inputLabel, kind: "fill", c: view.micColor, w: 1, a: 0.7, on: view.spectrumPoints.length > 0 },
              { label: "Peak", kind: "dots", c: view.micColor, w: 1.2, a: 0.95, on: view.peakLine.length > 0 },
              { label: "Soundcheck output", kind: "line", c: view.outColor, w: 1.6, a: 0.95, on: view.hasOutput }]
      delegate: Row {
        id: entry
        required property var modelData
        visible: modelData.on
        spacing: Style.space(5)

        Item {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(14)
          height: Style.space(9)

          Rectangle {
            visible: modelData.kind === "fill" || modelData.kind === "curve"
            anchors.fill: parent
            color: view.alpha(modelData.c, 0.25)
            Rectangle {
              width: parent.width
              height: Math.max(1, Style.space(entry.modelData.w))
              color: view.alpha(entry.modelData.c, entry.modelData.a)
            }
          }
          Rectangle {
            visible: modelData.kind === "line"
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: Math.max(1.5, Style.space(modelData.w))
            color: view.alpha(modelData.c, modelData.a)
          }
          Row {
            visible: modelData.kind === "dots"
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Repeater {
              model: 4
              delegate: Rectangle { width: 2; height: Math.max(1.5, Style.space(entry.modelData.w)); color: entry.modelData.c }
            }
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.label
          textFormat: Text.PlainText
          color: view.fade(view.foreground, 0.4)
          font.family: view.fontFamily
          font.pixelSize: Math.round(Style.font.caption * 0.9)
        }
      }
    }
  }

  MouseArea {
    id: mouse
    width: parent.width
    height: view.cardH
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
