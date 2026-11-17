import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Soundcheck: a curve you draw, a noise gate and a few more steps in front of
// your microphone, so every app gets the processed sound. Plus a short test
// you hear straight back, and listening in on yourself.
//
// The bar shows a pair of headphones. Dimmed while Soundcheck is off, in the
// accent colour while it is on, with a dot beside it while you are listening
// in (the one state you must not forget about), and crossed out in red when
// the chain should be running and is not. Colour is never the only signal:
// listening in and a broken chain each change the shape as well.
//
// Everything with state lives in SoundcheckStore: this widget exists once per
// monitor, and a loopback per monitor would put you in your ears twice.
Panel {
  id: root

  moduleName: "jankeesvw.soundcheck"
  ipcTarget: "jankeesvw.soundcheck"

  readonly property var store: SoundcheckStore
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color barFg: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color background: Commons.Color.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function fade(c, amount) {
    var bg = root.background
    return Qt.rgba(c.r + (bg.r - c.r) * amount, c.g + (bg.g - c.g) * amount, c.b + (bg.b - c.b) * amount, 1)
  }

  readonly property string barGlyph: store.broken ? store.iconHeadphonesOff : store.iconHeadphones
  readonly property color barColor: store.broken ? root.urgent
                                  : store.on ? root.accent
                                  : Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.5)

  readonly property string statusLine: {
    if (store.busy) return store.busyLabel
    if (!store.loaded) return "Loading"
    if (store.broken) return "Chain stopped"
    if (!store.on) return "Off"
    if (store.bypass) return "Bypassed"
    if (store.bypassedByDefault) return "On, but apps use another input"
    return "On"
  }

  readonly property string tooltip: {
    var t = "Soundcheck: " + root.statusLine.toLowerCase()
    if (store.on && store.micLabel !== "") t += ", " + store.micLabel
    if (store.monitoring) t += ". Listening in"
    return store.label(t)
  }

  readonly property int barSlot: Style.bar.iconFont + Style.space(10)
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  onOpenedChanged: {
    store.viewers = Math.max(0, store.viewers + (opened ? 1 : -1))
    if (opened) store.refresh()
  }
  Component.onDestruction: if (opened) store.viewers = Math.max(0, store.viewers - 1)

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    tooltipText: root.tooltip
    onPressed: function(b) { root.toggle() }

    // Drawn here rather than through `text`, so the listening-in dot can sit
    // against the glyph; the shell scales an iconComponent down to icon size,
    // which would shrink the dot to a smudge.
    hasVisualContent: true

    Item {
      anchors.fill: parent

      Text {
        id: barGlyphText
        anchors.centerIn: parent
        text: root.barGlyph
        textFormat: Text.PlainText
        color: root.barColor
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
      }

      Rectangle {
        visible: store.monitoring && !store.broken
        width: Style.space(6)
        height: width
        radius: width / 2
        color: root.accent
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: Style.bar.iconFont / 2 + Style.space(3)
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Style.bar.iconFont / 2.4
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    readonly property int desiredWidth: Style.space(580)
    contentWidth: Math.min(desiredWidth, panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    // A form, not a list: a plain Item as the key catcher, so Tab walks the
    // controls the way Qt already knows how to and each one takes its own
    // keys. Only what belongs to the whole panel is handled here.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
        else if (event.key === Qt.Key_B && !(event.modifiers & Qt.ControlModifier)) { store.toggleBypass(); event.accepted = true }
        else if (event.key === Qt.Key_R && !(event.modifiers & Qt.ControlModifier)) { store.toggleRecord(); event.accepted = true }
        else if (event.key === Qt.Key_P && !(event.modifiers & Qt.ControlModifier)) { if (store.canPlay) store.togglePlay(); event.accepted = true }
        else if (event.key === Qt.Key_L && !(event.modifiers & Qt.ControlModifier)) { store.setMonitoring(!store.monitoring); event.accepted = true }
        else if (event.key === Qt.Key_A && !(event.modifiers & Qt.ControlModifier)) { store.analyse(); event.accepted = true }
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        interactive: column.implicitHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(12)

          // ---- hero: title, state, and the switch that puts it in front of the mic
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroText.implicitHeight, power.implicitHeight)

            Text {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.barGlyph
              textFormat: Text.PlainText
              color: store.broken ? root.urgent : (store.on ? root.accent : root.foreground)
              opacity: store.on ? 1 : 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            Column {
              id: heroText
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: power.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: "Soundcheck"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: (root.statusLine + (store.on && store.micLabel !== "" && !store.busy ? " · " + store.micLabel : "")).toUpperCase()
                textFormat: Text.PlainText
                color: store.broken ? root.urgent : root.fade(root.foreground, 0.35)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }

            Item {
              id: power
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              implicitWidth: powerSwitch.implicitWidth
              implicitHeight: powerSwitch.implicitHeight
              activeFocusOnTab: true
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  store.setPower(!store.on); event.accepted = true
                }
              }

              ToggleSwitch {
                id: powerSwitch
                anchors.fill: parent
                checked: store.on
                busy: store.busy
                hasCursor: power.activeFocus
                foreground: root.foreground
                accent: root.accent
                onToggled: store.setPower(!store.on)
              }
            }
          }

          Text {
            visible: !store.on && store.loaded && !store.busy
            width: parent.width
            text: "Switch it on and Soundcheck Microphone becomes your default input: Meet, Zoom and Slack get the processed sound. Off puts your microphone back."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.fade(root.foreground, 0.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: store.bypassedByDefault
            width: parent.width
            text: "The default input was switched to another microphone, so apps get it unprocessed. Switch Soundcheck off and on to take over again."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ---- microphone
          Dropdown {
            id: micPicker
            width: parent.width
            label: "MICROPHONE"
            value: store.mic
            options: store.mics.map(function(m) { return { value: m.name, label: m.label } })
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            enabled: !store.busy && store.mics.length > 0
            onChanged: function(v) { store.chooseMic(v) }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- presets: ways of treating a voice, fitted to yours by Analyse
          Item {
            width: parent.width
            implicitHeight: Math.max(presetHeader.implicitHeight, presetActions.implicitHeight)

            PanelSectionHeader {
              id: presetHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "PRESET"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: presetActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Button {
                visible: store.undoSettings !== null
                text: "Undo"
                focusable: true
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                foreground: root.foreground
                accent: root.accent
                verticalPadding: Style.space(3)
                onClicked: store.undoPreset()
              }

              Button {
                readonly property bool listening: store.analyseMode && store.recording
                text: listening ? "Stop" : store.analysing ? "Measuring" : "Analyse"
                iconText: listening ? store.iconStop : store.iconWand
                focusable: true
                bordered: true
                foreground: listening ? root.urgent : root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                iconSize: Style.font.caption
                verticalPadding: Style.space(3)
                onClicked: store.analyse()
              }
            }
          }

          ButtonGroup {
            options: store.presets.map(function(p) { return { value: p.id, label: p.label } })
            value: store.currentPreset
            spacing: Style.space(4)
            foreground: root.foreground
            background: root.background
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onChanged: function(v) { store.applyPreset(v) }
          }

          Text {
            width: parent.width
            text: root.presetLine
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: store.analysisError !== "" ? root.urgent : root.fade(root.foreground, 0.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: store.analysis && store.analysis.sameMic && !store.analyseMode && store.analysisError === ""
                   ? store.analysis.findings : []
            delegate: Text {
              required property var modelData
              width: column.width
              text: modelData.text
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: modelData.urgent ? root.urgent : root.fade(root.foreground, 0.35)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- the curve
          Item {
            width: parent.width
            implicitHeight: Math.max(curveHeader.implicitHeight, presets.implicitHeight)

            PanelSectionHeader {
              id: curveHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "CURVE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: presets
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Button {
                text: "Bypass"
                focusable: true
                selected: store.bypass
                bordered: true
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                foreground: root.foreground
                accent: root.accent
                verticalPadding: Style.space(3)
                onClicked: store.toggleBypass()
              }
            }
          }

          // The graph, and beside it how loud: whether anything clips.
          Row {
            width: parent.width
            spacing: Style.space(8)

            CurveView {
              id: curve
              width: parent.width - levels.width - parent.spacing
              target: store.settings.curve
              gains: store.settings.gains
              highpassOn: store.settings.highpass.on
              highpassFreq: store.settings.highpass.freq
              spectrum: store.spectrum
              spectrumOut: store.spectrumOut
              peaks: store.spectrumPeaks
              inputLabel: store.meterTap !== "" ? "Test recording" : "Microphone"
              spectrumTop: store.spectrumTop
              bypassed: store.bypass
              foreground: root.foreground
              accent: root.accent
              background: root.background
              fontFamily: root.fontFamily
              onEdited: function(c) { store.setCurve(c) }
            }

            LevelMeter {
              id: levels
              height: curve.height
              padTop: curve.padTop
              padBottom: curve.padBottom
              inLevel: store.levelIn
              inPeak: store.levelPeak
              outLevel: store.levelOut
              outPeak: store.levelOutPeak
              hasOutput: store.spectrumOut.length > 0
              foreground: root.foreground
              background: root.background
              urgent: root.urgent
              fontFamily: root.fontFamily
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- the sound: what makes your voice clean, in the order it goes through
          PanelSectionHeader {
            text: "SOUND"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Two steps to a row, except the gate: it gets the full width for
          // its strip of the last few seconds.
          Column {
            id: chain
            width: parent.width
            spacing: Style.space(6)
            readonly property real cell: (width - Style.space(14)) / 2

            Row {
              spacing: Style.space(14)

              StepRow {
                width: chain.cell
                bar: root.bar
                title: "High-pass"
                checked: store.settings.highpass.on
                minimum: 20; maximum: 300; step: 5; bigStep: 20
                value: store.settings.highpass.freq
                valueText: Math.round(store.settings.highpass.freq) + " Hz"
                foreground: root.foreground; accent: root.accent; background: root.background; fontFamily: root.fontFamily
                onToggled: store.change(function(s) { s.highpass.on = !s.highpass.on })
                onMoved: function(v) { store.change(function(s) { s.highpass.freq = Math.round(v) }) }
              }

              StepRow {
                width: chain.cell
                bar: root.bar
                title: "Noise removal"
                mode: !store.packages.rnnoise ? "missing" : (store.on && !store.graph.rnnoise ? "restart" : "ready")
                packageName: "noise-suppression-for-voice"
                checked: store.settings.denoise.on
                minimum: 0; maximum: 95; step: 5; bigStep: 15
                value: store.settings.denoise.amount
                valueText: Math.round(store.settings.denoise.amount) + "%"
                foreground: root.foreground; accent: root.accent; background: root.background; fontFamily: root.fontFamily
                onToggled: store.change(function(s) { s.denoise.on = !s.denoise.on })
                onMoved: function(v) { store.change(function(s) { s.denoise.amount = Math.round(v) }) }
                onCopyRequested: store.copyCommand("omarchy pkg add noise-suppression-for-voice")
                onRestartRequested: store.reload()
              }

            }

            StepRow {
              width: chain.width
              bar: root.bar
              title: "Noise gate"
              mode: store.on && store.graph.v < 2 ? "restart" : "ready"
              restartText: "Soundcheck has a new noise gate. Restarting the chain puts it in (a second of silence on the microphone)."
              onRestartRequested: store.reload()
              checked: store.settings.gate.on
              minimum: -90; maximum: -10; step: 1; bigStep: 6
              value: store.settings.gate.threshold
              valueText: Math.round(store.settings.gate.threshold) + " dB"
              showGate: true
              gateHistory: store.gateHistory
              gateActive: store.present
              gateIdleLabel: store.present ? "GATE OFF" : "SOUNDCHECK OFF"
              foreground: root.foreground; accent: root.accent; background: root.background; fontFamily: root.fontFamily
              onToggled: store.change(function(s) { s.gate.on = !s.gate.on })
              onMoved: function(v) { store.change(function(s) { s.gate.threshold = Math.round(v) }) }
            }

            Row {
              spacing: Style.space(14)

              StepRow {
                width: chain.cell
                bar: root.bar
                title: "Compressor"
                mode: !store.packages.lsp ? "missing" : (store.on && !store.graph.lsp ? "restart" : "ready")
                packageName: "lsp-plugins-lv2"
                checked: store.settings.compressor.on
                minimum: -50; maximum: 0; step: 1; bigStep: 6
                value: store.settings.compressor.threshold
                valueText: Math.round(store.settings.compressor.threshold) + " dB, " + Number(store.settings.compressor.ratio).toFixed(1).replace(/\.0$/, "") + ":1"
                foreground: root.foreground; accent: root.accent; background: root.background; fontFamily: root.fontFamily
                onToggled: store.change(function(s) { s.compressor.on = !s.compressor.on })
                onMoved: function(v) { store.change(function(s) { s.compressor.threshold = Math.round(v) }) }
                onCopyRequested: store.copyCommand("omarchy pkg add lsp-plugins-lv2")
                onRestartRequested: store.reload()
              }

              StepRow {
                width: chain.cell
                bar: root.bar
                title: "Limiter"
                mode: !store.packages.lsp ? "missing" : (store.on && !store.graph.lsp ? "restart" : "ready")
                packageName: "lsp-plugins-lv2"
                checked: store.settings.limiter.on
                minimum: -12; maximum: 0; step: 0.5; bigStep: 3
                value: store.settings.limiter.ceiling
                valueText: Number(store.settings.limiter.ceiling).toFixed(1) + " dB"
                foreground: root.foreground; accent: root.accent; background: root.background; fontFamily: root.fontFamily
                onToggled: store.change(function(s) { s.limiter.on = !s.limiter.on })
                onMoved: function(v) { store.change(function(s) { s.limiter.ceiling = Math.round(v * 2) / 2 }) }
                onCopyRequested: store.copyCommand("omarchy pkg add lsp-plugins-lv2")
                onRestartRequested: store.reload()
              }

            }

            StepRow {
              width: chain.width
              bar: root.bar
              title: "Volume"
              toggleable: false
              minimum: -12; maximum: 12; step: 0.5; bigStep: 3
              value: store.settings.gain
              valueText: (store.settings.gain > 0 ? "+" : "") + Number(store.settings.gain).toFixed(1) + " dB"
              foreground: root.foreground; accent: root.accent; background: root.background; fontFamily: root.fontFamily
              onMoved: function(v) { store.change(function(s) { s.gain = Math.round(v * 2) / 2 }) }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- effects: for fun rather than for a clean voice. Where they sit
          // in the chain is in the helper's render().
          PanelSectionHeader {
            text: "EFFECTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            id: effects
            width: parent.width
            spacing: Style.space(6)
            readonly property real cell: (width - Style.space(14)) / 2
            readonly property string newText: "New in Soundcheck. Restarting the chain adds it (a second of silence on the microphone)."

            StepRow {
              width: effects.width
              bar: root.bar
              title: "Distortion"
              mode: store.on && store.graph.v < 4 ? "restart" : "ready"
              restartText: store.graph.v < 3 ? effects.newText
                         : "Soundcheck has new kinds of distortion. Restarting the chain adds them (a second of silence on the microphone)."
              checked: store.settings.distortion.on
              minimum: 0; maximum: 100; step: 1; bigStep: 10
              value: store.settings.distortion.drive
              valueText: Math.round(store.settings.distortion.drive) + "% drive"
              choices: [{ value: "warm", label: "Warm" }, { value: "hard", label: "Hard" },
                        { value: "fuzz", label: "Fuzz" }, { value: "radio", label: "Radio" }]
              choice: store.settings.distortion.kind || "warm"
              foreground: root.foreground; accent: root.accent; background: root.background; fontFamily: root.fontFamily
              onToggled: store.change(function(s) { s.distortion.on = !s.distortion.on })
              onMoved: function(v) { store.change(function(s) { s.distortion.drive = Math.round(v) }) }
              onChose: function(v) { store.change(function(s) { s.distortion.kind = v }) }
              onRestartRequested: store.reload()
            }

            Row {
              spacing: Style.space(14)

              StepRow {
                width: effects.cell
                bar: root.bar
                title: "Pitch"
                mode: !store.packages.pitch ? "missing" : (store.on && !store.graph.pitch ? "restart" : "ready")
                packageName: "rubberband-ladspa"
                checked: store.settings.pitch.on
                minimum: -12; maximum: 12; step: 1; bigStep: 12
                value: store.settings.pitch.semitones
                valueText: (store.settings.pitch.semitones > 0 ? "+" : "") + store.settings.pitch.semitones
                           + (Math.abs(store.settings.pitch.semitones) === 1 ? " semitone" : " semitones")
                foreground: root.foreground; accent: root.accent; background: root.background; fontFamily: root.fontFamily
                onToggled: store.change(function(s) { s.pitch.on = !s.pitch.on })
                onMoved: function(v) { store.change(function(s) { s.pitch.semitones = Math.round(v) }) }
                onCopyRequested: store.copyCommand("omarchy pkg add rubberband-ladspa")
                onRestartRequested: store.reload()
              }

              StepRow {
                width: effects.cell
                bar: root.bar
                title: "Reverb"
                mode: store.on && store.graph.v < 3 ? "restart" : "ready"
                restartText: effects.newText
                checked: store.settings.reverb.on
                minimum: 0; maximum: 100; step: 1; bigStep: 10
                value: store.settings.reverb.amount
                valueText: Math.round(store.settings.reverb.amount) + "%"
                foreground: root.foreground; accent: root.accent; background: root.background; fontFamily: root.fontFamily
                onToggled: store.change(function(s) { s.reverb.on = !s.reverb.on })
                onMoved: function(v) { store.change(function(s) { s.reverb.amount = Math.round(v) }) }
                onRestartRequested: store.reload()
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- a test, and listening in
          Row {
            id: bottom
            width: parent.width
            spacing: Style.space(14)
            readonly property real cell: (width - spacing) / 2
            // The two columns line up row by row: both headers on one line
            // (the switch makes Listen in's the taller), the controls on the
            // next, the explanations under both.
            readonly property real headHeight: Math.max(testHeader.implicitHeight, listenToggle.implicitHeight)
            readonly property real controlHeight: Math.max(testControls.implicitHeight, sinkPicker.implicitHeight)

            Column {
              width: bottom.cell
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: bottom.headHeight

                PanelSectionHeader {
                  id: testHeader
                  anchors.verticalCenter: parent.verticalCenter
                  text: "TEST"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }
                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: store.recording ? root.clock(store.recordElapsed) + " / 0:10"
                        : store.playing ? root.clock(store.playPosition) + " / " + root.clock(store.playLength)
                        : store.recordingInfo.before ? root.clock(store.recordingInfo.seconds) : ""
                  textFormat: Text.PlainText
                  color: store.recording ? root.urgent : root.fade(root.foreground, 0.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Item {
                width: parent.width
                implicitHeight: bottom.controlHeight

                Row {
                  id: testControls
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Button {
                    text: store.recording ? "Stop" : "Record"
                    iconText: store.recording ? store.iconStop : store.iconRecord
                    focusable: true
                    bordered: true
                    foreground: store.recording ? root.urgent : root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    iconSize: Style.font.caption
                    onClicked: store.toggleRecord()
                  }

                  Button {
                    text: store.playing ? "Stop" : "Play"
                    iconText: store.playing ? store.iconStop : store.iconPlay
                    focusable: true
                    bordered: true
                    enabled: store.canPlay
                    opacity: store.canPlay ? 1 : 0.45
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    iconSize: Style.font.caption
                    onClicked: store.togglePlay()
                  }

                  ButtonGroup {
                    visible: store.hasAfter
                    options: [{ value: "before", label: "Before" }, { value: "after", label: "After" }]
                    value: store.listenTo
                    foreground: root.foreground
                    background: root.background
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onChanged: function(v) { store.setListenTo(v) }
                  }
                }
              }

              Text {
                width: parent.width
                text: store.on ? "Ten seconds, played straight back to you as the others hear it."
                               : "Ten seconds of your bare microphone. Switch Soundcheck on to compare before and after."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.fade(root.foreground, 0.45)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Column {
              width: bottom.cell
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: bottom.headHeight

                PanelSectionHeader {
                  id: listenHeader
                  anchors.verticalCenter: parent.verticalCenter
                  text: "LISTEN IN"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Item {
                  id: listenToggle
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  implicitWidth: listenSwitch.implicitWidth
                  implicitHeight: listenSwitch.implicitHeight
                  activeFocusOnTab: true
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      store.setMonitoring(!store.monitoring); event.accepted = true
                    }
                  }

                  ToggleSwitch {
                    id: listenSwitch
                    anchors.fill: parent
                    trackHeight: Math.max(16, Math.round(Style.spacing.controlHeight * 0.42))
                    checked: store.monitoring
                    hasCursor: listenToggle.activeFocus
                    foreground: root.foreground
                    accent: root.accent
                    onToggled: store.setMonitoring(!store.monitoring)
                  }
                }
              }

              Item {
                width: parent.width
                implicitHeight: bottom.controlHeight

                Dropdown {
                  id: sinkPicker
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  showLabel: false
                  value: store.monitorSink
                  // Without headphones nothing is picked for you, on purpose:
                  // the placeholder says so instead of an empty box.
                  options: (store.monitorSink === "" ? [{ value: "", label: "Choose an output" }] : [])
                           .concat(store.sinks.map(function(s) { return { value: s.name, label: s.label } }))
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { store.setMonitorSink(v) }
                }
              }

              Text {
                width: parent.width
                text: store.monitorSink === "" ? "Pick an output to listen on."
                      : store.monitorOnSpeakers ? "That is not a pair of headphones: your speakers will feed back into the microphone."
                      : "Your own voice in your ears, through every step above."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: store.monitorOnSpeakers ? root.urgent : root.fade(root.foreground, 0.45)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            visible: store.error !== ""
            width: parent.width
            text: store.error
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            text: "Drag to paint, right-drag to flatten, double-click for flat. Arrows nudge the curve when it has focus. A analyses, R records, P plays, L listens in, B bypasses, Esc closes."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.fade(root.foreground, 0.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // Under the presets: what Analyse is doing, or what the last one measured.
  readonly property string presetLine: {
    if (store.analyseMode && store.recording)
      return "Talk as you would on a call, with a pause now and then. " + root.clock(store.recordElapsed) + " / 0:10"
    if (store.analysing) return "Measuring your test"
    if (store.analysisError !== "") return store.analysisError
    var a = store.analysis
    if (!a) return "Analyse records ten seconds of you talking and fits every preset to your voice, your microphone and your room. Until then they are set for a voice like most."
    if (!a.sameMic) return "The last test was on another microphone, so the presets are set for a voice like most. Analyse fits them to this one."
    var d = new Date(a.at * 1000)
    var when = d.toDateString() === new Date().toDateString() ? "at " + Qt.formatTime(d, "HH:mm") : "of " + Qt.formatDate(d, "d MMMM")
    var t = "Fitted to your test " + when + ": your voice at " + Math.round(a.speech) + " dB"
    if (a.noiseSure) t += ", the room at " + Math.round(a.noise) + " dB"
    if (a.f0 > 0) t += ", your pitch around " + Math.round(a.f0) + " Hz"
    return t + "."
  }

  function clock(seconds) {
    var s = Math.max(0, Math.floor(Number(seconds) || 0))
    return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }
}
