import QtQuick
import qs.Commons

// Two level bars beside the graph: what comes in, and what Soundcheck sends
// on. The bar is the average level, the tick above it the peak, held for a
// moment. Green is room to spare, yellow is loud, red is close to the top.
// A peak at full scale lights the lamp on top of its bar and the CLIP under
// both for two seconds: that is where the sound breaks up, in the microphone
// itself (IN) or in the app that gets it (OUT).
Item {
  id: meter

  property real inLevel: -120
  property real inPeak: -120
  property real outLevel: -120
  property real outPeak: -120
  property bool hasOutput: false
  // Lined up with the graph's plot: its top margin, and what is under it.
  property real padTop: 0
  property real padBottom: 0

  property color foreground: Color.foreground
  property color background: Color.background
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  readonly property real floor: -60
  readonly property real loud: -18
  readonly property real hot: -6
  // A 16-bit microphone at full scale reads -0.0003 dB; an app turns
  // anything over 0 dB into the same full scale, and the shape is gone.
  readonly property real clipAt: -0.3

  readonly property real barW: Style.space(8)
  readonly property real gap: Style.space(10)
  readonly property real labelW: scaleProbe.implicitWidth + Style.space(4)
  implicitWidth: labelW + barW * 2 + gap
  readonly property bool clipping: (sides.in.clip > now) || (hasOutput && sides.out.clip > now)
  property real now: 0

  readonly property real plotH: Math.max(10, height - padTop - padBottom)
  function frac(db) { return Math.max(0, Math.min(1, (db - floor) / -floor)) }
  function yOf(db) { return padTop + plotH * (1 - frac(db)) }

  readonly property bool darkTheme: background.r * 0.299 + background.g * 0.587 + background.b * 0.114 < 0.5
  readonly property color okColor: Qt.hsla(0.36, 0.5, darkTheme ? 0.55 : 0.38, 1)
  readonly property color loudColor: Qt.hsla(0.12, 0.75, darkTheme ? 0.58 : 0.45, 1)
  function fade(c, amount) {
    var bg = meter.background
    return Qt.rgba(c.r + (bg.r - c.r) * amount, c.g + (bg.g - c.g) * amount, c.b + (bg.b - c.b) * amount, 1)
  }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Ballistics: up at once, down at a pace the eye can follow; the peak
  // waits a moment before it falls, and CLIP stays lit for two seconds.
  property var sides: ({
    in: { level: -120, peak: -120, held: 0, clip: 0 },
    out: { level: -120, peak: -120, held: 0, clip: 0 }
  })
  property real lastTick: 0

  function settle(side, level, peak, now, dt) {
    var s = sides[side]
    var nextLevel = Math.max(level, s.level - 30 * dt)
    var nextPeak = s.peak, held = s.held
    if (peak >= s.peak) { nextPeak = peak; held = now + 1500 }
    else if (now > s.held) nextPeak = Math.max(peak, s.peak - 20 * dt)
    return { level: nextLevel, peak: nextPeak, held: held, clip: peak >= clipAt ? now + 2000 : s.clip }
  }

  Timer {
    interval: 33
    repeat: true
    running: meter.visible
    onTriggered: {
      var now = Date.now()
      meter.now = now
      var dt = meter.lastTick > 0 ? Math.min(0.2, (now - meter.lastTick) / 1000) : 0
      meter.lastTick = now
      meter.sides = {
        in: meter.settle("in", meter.inLevel, meter.inPeak, now, dt),
        out: meter.hasOutput ? meter.settle("out", meter.outLevel, meter.outPeak, now, dt)
                             : { level: -120, peak: -120, held: 0, clip: 0 }
      }
    }
    onRunningChanged: meter.lastTick = 0
  }

  Text {
    id: scaleProbe
    visible: false
    text: "-48"
    font.family: meter.fontFamily
    font.pixelSize: Math.round(Style.font.caption * 0.85)
  }

  // The scale, on the left.
  Repeater {
    model: [0, -6, -18, -36]
    delegate: Text {
      required property var modelData
      x: meter.labelW - Style.space(4) - implicitWidth
      y: meter.yOf(modelData) - implicitHeight / 2
      text: String(modelData)
      textFormat: Text.PlainText
      color: meter.fade(meter.foreground, 0.55)
      font.family: meter.fontFamily
      font.pixelSize: Math.round(Style.font.caption * 0.85)
    }
  }

  Repeater {
    model: [{ key: "in", label: "IN" }, { key: "out", label: "OUT" }]
    delegate: Item {
      id: bar
      required property var modelData
      required property int index
      readonly property var side: meter.sides[modelData.key]
      readonly property bool live: modelData.key === "in" || meter.hasOutput
      readonly property bool clipping: side.clip > meter.now && live
      x: meter.labelW + index * (meter.barW + meter.gap)
      width: meter.barW
      height: meter.height

      // The track, and the lamp on top of it.
      Rectangle {
        x: 0; y: meter.padTop
        width: parent.width; height: meter.plotH
        radius: Style.cornerRadius > 0 ? Style.space(2) : 0
        color: meter.alpha(meter.foreground, 0.06)
      }
      Rectangle {
        x: 0; y: Style.space(1)
        width: parent.width
        height: Math.max(2, meter.padTop - Style.space(3))
        radius: Style.cornerRadius > 0 ? Style.space(1.5) : 0
        color: bar.clipping ? meter.urgent : meter.alpha(meter.foreground, 0.10)
      }

      // The level: three zones, shown as far as the level reaches.
      Item {
        x: 0
        width: parent.width
        y: meter.yOf(bar.side.level)
        height: meter.padTop + meter.plotH - y
        clip: true

        Repeater {
          model: [{ from: meter.floor, to: meter.loud, c: meter.okColor },
                  { from: meter.loud, to: meter.hot, c: meter.loudColor },
                  { from: meter.hot, to: 0, c: meter.urgent }]
          delegate: Rectangle {
            required property var modelData
            x: 0
            width: bar.width
            y: meter.yOf(modelData.to) - meter.yOf(bar.side.level)
            height: meter.yOf(modelData.from) - meter.yOf(modelData.to)
            color: modelData.c
          }
        }
      }

      // The peak, held for a moment.
      Rectangle {
        visible: bar.side.peak > meter.floor
        x: -1
        width: parent.width + 2
        height: Math.max(2, Style.space(2))
        y: meter.yOf(bar.side.peak) - height / 2
        color: bar.side.peak >= meter.hot ? meter.urgent : meter.foreground
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: meter.padTop + meter.plotH + Style.space(3)
        text: bar.modelData.label
        textFormat: Text.PlainText
        color: meter.fade(meter.foreground, bar.live ? 0.45 : 0.75)
        font.family: meter.fontFamily
        font.pixelSize: Math.round(Style.font.caption * 0.8)
        font.bold: true
      }
    }
  }

  // CLIP under both bars: dim until something clips, so you know where to look.
  Rectangle {
    x: meter.labelW + (meter.barW * 2 + meter.gap) / 2 - width / 2
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    width: clipText.implicitWidth + Style.space(8)
    height: clipText.implicitHeight + Style.space(2)
    radius: Style.cornerRadius > 0 ? Style.space(3) : 0
    color: meter.clipping ? meter.urgent : "transparent"
    border.width: 1
    border.color: meter.clipping ? meter.urgent : meter.alpha(meter.foreground, 0.15)

    Text {
      id: clipText
      anchors.centerIn: parent
      text: "CLIP"
      textFormat: Text.PlainText
      color: meter.clipping ? meter.background : meter.fade(meter.foreground, 0.7)
      font.family: meter.fontFamily
      font.pixelSize: Math.round(Style.font.caption * 0.8)
      font.bold: true
      font.letterSpacing: 0.8
    }
  }
}
