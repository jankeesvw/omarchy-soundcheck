pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "Eq.js" as Eq

// All Soundcheck state lives here, for a concrete reason: a bar widget is
// instantiated once per monitor, so a Process declared in Panel.qml would run
// once per screen. For most widgets that only means polling twice. For this
// one it would mean hearing yourself twice in your headphones.
//
// The helper in bin/ is the only thing that touches PipeWire's configuration,
// systemd or files. This store runs it, keeps the settings you are editing,
// and starts the two things that have to live as long as the shell does: the
// meter while a panel is open, and pw-loopback while you listen in.
Singleton {
  id: root

  readonly property string cli: Qt.resolvedUrl("bin/soundcheck").toString().replace(/^file:\/\//, "")
  function argv(args) { return ["/usr/bin/python3", "-I", "-S", root.cli].concat(args) }

  // Written as \u escapes: a literal private-use glyph does not always survive
  // the editor, and an empty string fails silently as an invisible icon.
  readonly property string iconMic: "\uf130"
  readonly property string iconMicOff: "\uf131"
  readonly property string iconHeadphones: "\uf025"
  // nf-md-headphones_off, U+F07CE: past U+FFFF, so a surrogate pair.
  readonly property string iconHeadphonesOff: "\uDB81\uDFCE"
  readonly property string iconRecord: "\uf111"
  readonly property string iconStop: "\uf04d"
  readonly property string iconPlay: "\uf04b"
  readonly property string iconCopy: "\uf0c5"
  readonly property string iconWarn: "\uf071"

  readonly property string sourceName: "soundcheck_mic"

  // --- status, from `soundcheck status` -------------------------------------

  property bool loaded: false
  property bool demo: false
  property bool installed: false
  property bool active: false
  property bool present: false
  property bool isDefault: false
  property string mic: ""
  property string micLabel: ""
  property bool micPresent: false
  property var mics: []
  // False while the running chain was built by an older version of the
  // plugin: the gate row then offers the restart that brings it up to date.
  property bool graphCurrent: true
  property var sinks: []
  property var packages: ({ lsp: false, rnnoise: false })
  property var graph: ({ lsp: false, rnnoise: false })
  property var recordingInfo: ({ before: false, after: false, seconds: 0 })

  // On means installed: the unit exists and is meant to run. Broken means it
  // should be running and the microphone it provides is not there.
  readonly property bool on: installed
  readonly property bool broken: loaded && installed && !present && !busy
  // On, but the apps are not getting it: the default input was switched back
  // to the bare microphone somewhere else.
  readonly property bool bypassedByDefault: loaded && installed && present && !isDefault

  property bool busy: false
  property string busyLabel: ""
  property string error: ""

  // --- settings being edited -------------------------------------------------

  property var settings: defaultSettings()
  // Set from the first change until the save lands, so a status poll arriving
  // mid-drag does not snap the curve back to what is on disk.
  property bool dirty: false
  property bool bypass: false

  function defaultSettings() {
    var curve = Eq.flat(), gains = []
    for (var i = 0; i < Eq.BANDS; i++) gains.push(0)
    return {
      version: 1, mic: "", monitorSink: "", curve: curve, gains: gains,
      highpass: { on: true, freq: 80 }, denoise: { on: true, amount: 50 },
      gate: { on: true, threshold: -55 }, compressor: { on: true, threshold: -24, ratio: 3 },
      limiter: { on: true, ceiling: -1 }, distortion: { on: false, drive: 40 },
      reverb: { on: false, amount: 30 }, gain: 0
    }
  }

  function copy(obj) { return JSON.parse(JSON.stringify(obj)) }

  // Every edit goes through here: copy, change, assign, so bindings see a new
  // object, then the running chain hears it and the disk gets it a moment later.
  function change(mutate) {
    var next = copy(root.settings)
    mutate(next)
    root.settings = next
    root.dirty = true
    root.sendLive()
    saveTimer.restart()
  }

  function setCurve(curve) {
    root.change(function(s) {
      s.curve = curve
      s.gains = Eq.solve(curve)
    })
  }

  function preset(id) { root.setCurve(Eq.preset(id)) }

  function toggleBypass() {
    root.bypass = !root.bypass
    root.sendLive()
  }

  // What goes to the chain: the settings, or everything neutral while
  // bypassed. Bypass never touches what is stored.
  function liveSettings() {
    if (!root.bypass) return root.settings
    var s = copy(root.settings)
    s.highpass.on = false; s.denoise.on = false; s.gate.on = false
    s.compressor.on = false; s.limiter.on = false; s.gain = 0
    if (s.distortion) s.distortion.on = false
    if (s.reverb) s.reverb.on = false
    for (var i = 0; i < s.gains.length; i++) s.gains[i] = 0
    return s
  }

  // --- talking to the helper -------------------------------------------------

  property int viewers: 0

  function refresh() { if (!statusProc.running) statusProc.running = true }

  Timer {
    interval: root.viewers > 0 ? 2500 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  LineProcess {
    id: statusProc
    command: root.argv(["status"])
    handler: function(s) { root.applyStatus(s) }
  }

  function applyStatus(s) {
    if (s.ok === false && !root.loaded) { root.error = String(s.error || ""); return }
    root.demo = s.demo === true
    root.installed = s.installed === true
    root.active = s.active === true
    root.present = s.present === true
    root.isDefault = s.isDefault === true
    // Checked here as well as in the helper: this name goes into pw-loopback's argv.
    root.mic = root.validName(s.mic) ? s.mic : ""
    root.micLabel = root.label(s.micLabel)
    root.micPresent = s.micPresent === true
    root.mics = root.cleanDevices(s.mics)
    root.sinks = root.cleanDevices(s.sinks)
    root.packages = { lsp: !!(s.packages && s.packages.lsp), rnnoise: !!(s.packages && s.packages.rnnoise) }
    root.graph = { lsp: !!(s.graph && s.graph.lsp), rnnoise: !!(s.graph && s.graph.rnnoise) }
    root.graphCurrent = s.graphCurrent !== false
    root.recordingInfo = {
      before: !!(s.recording && s.recording.before), after: !!(s.recording && s.recording.after),
      seconds: Number(s.recording && s.recording.seconds) || 0
    }
    if (!root.dirty && s.settings && typeof s.settings === "object") {
      var next = s.settings
      // The demo ships a curve, not band gains: the solver lives here, so the
      // gains are worked out here too and the drawn response is the real one.
      if (root.demo) { next = root.copy(next); next.gains = Eq.solve(next.curve) }
      root.settings = next
    }
    root.loaded = true
  }

  // Device names come from the devices. They are rendered as plain text, and
  // also pass through here so they stay short and carry no markup on their way
  // to the shell's own dropdown and tooltip, whose text format is not ours.
  function label(value) {
    return String(value === undefined || value === null ? "" : value).replace(/[<>&\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g, "").slice(0, 60)
  }

  function validName(name) {
    return typeof name === "string" && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,190}$/.test(name)
  }

  function cleanDevices(list) {
    var out = []
    if (!Array.isArray(list)) return out
    for (var i = 0; i < list.length && out.length < 32; i++) {
      var d = list[i]
      if (!d || !root.validName(d.name)) continue
      out.push({ name: d.name, label: root.label(d.label || d.name), headphones: d.headphones === true })
    }
    return out
  }

  // Live: one helper call at a time, always carrying the latest settings. A
  // drag produces far more changes than PipeWire needs to hear; whatever came
  // in while one was in flight goes out as a single call after it.
  property bool livePending: false

  function sendLive() {
    if (root.demo) return
    if (liveProc.running) { root.livePending = true; return }
    liveProc.command = root.argv(["live", JSON.stringify(root.liveSettings())])
    liveProc.running = true
  }

  LineProcess {
    id: liveProc
    onRunningChanged: if (!running && root.livePending) { root.livePending = false; root.sendLive() }
  }

  Timer {
    id: saveTimer
    interval: 900
    onTriggered: root.save()
  }

  function save() {
    if (saveProc.running) { saveTimer.restart(); return }
    saveProc.command = root.argv(["save", JSON.stringify(root.settings)])
    saveProc.running = true
  }

  LineProcess {
    id: saveProc
    handler: function(r) { if (r.ok === false) root.error = root.label(r.error) }
    onRunningChanged: if (!running && !saveTimer.running) { root.dirty = false; root.refresh() }
  }

  // On, off and reload change the system's default input, so they run one at
  // a time and the panel shows that something is happening.
  function runAction(args, label) {
    if (actionProc.running) return
    root.error = ""
    root.busy = true
    root.busyLabel = label
    actionProc.command = root.argv(args)
    actionProc.running = true
  }

  function turnOn() { root.runAction(["on"], "Starting") }
  function turnOff() { root.runAction(["off"], "Stopping") }
  function reload() { root.runAction(["reload"], "Restarting") }
  function setPower(on) { on ? root.turnOn() : root.turnOff() }

  function chooseMic(name) {
    if (name === root.mic) return
    root.mic = name
    root.runAction(["mic", name], "Switching")
  }

  LineProcess {
    id: actionProc
    handler: function(r) { if (r.ok === false) root.error = root.label(r.error) }
    onRunningChanged: if (!running) {
      root.busy = false
      root.busyLabel = ""
      root.refresh()
      if (root.monitoring) monitorRestart.restart()
    }
  }

  // --- the meter, only while a panel is open ---------------------------------

  property real levelIn: -120
  property real levelPeak: -120
  property real levelOut: -120
  property var spectrum: []
  // What the chain sends on, measured the same way. Empty while it is off.
  property var spectrumOut: []
  // The loudest each band has been in the last moment or two, and the top of
  // the spectrum's scale, which follows the microphone (see the helper).
  property var spectrumPeaks: []
  property real spectrumTop: -40
  // The last six seconds for the gate's strip: the microphone's peak level,
  // and whether anything came out of the chain at that moment.
  property var gateHistory: []
  readonly property int gateHistoryLength: 120

  readonly property bool meterWanted: root.viewers > 0 && root.loaded && !root.busy && !root.recording

  onMeterWantedChanged: {
    if (meterWanted) meterStart.restart()
    else if (meterProc.running) meterProc.signal(15)
  }

  // A beat of delay, so a mic switch or an on/off has settled before the
  // meter picks its sources.
  Timer {
    id: meterStart
    interval: 250
    onTriggered: if (root.meterWanted) { root.meterStartedAt = Date.now(); meterProc.running = true }
  }
  property real meterStartedAt: 0

  // While a test plays, the meter listens to it instead of the microphone,
  // so the graph shows what you hear: the recording, and with After also what
  // the preview of the chain makes of it.
  readonly property string meterTap: root.playing && root.previewLive ? root.playWhich : ""
  onMeterTapChanged: {
    if (meterProc.running) meterProc.signal(15)   // comes back with the new source
    else if (root.meterWanted) meterStart.restart()
  }

  LineProcess {
    id: meterProc
    command: root.argv(root.meterTap !== "" ? ["meter", root.meterTap] : ["meter"])
    handler: function(m) {
      if (m.type === "level") {
        root.levelIn = root.db(m.in)
        root.levelPeak = root.db(m.inPeak)
        root.levelOut = root.db(m.out)
        var h = root.gateHistory.slice(Math.max(0, root.gateHistory.length - root.gateHistoryLength + 1))
        // The average level, not the peak: that is what the gate listens to.
        h.push({ l: root.levelIn, o: root.present && root.levelOut > -100 })
        root.gateHistory = h
      } else if (m.type === "spectrum") {
        root.spectrum = root.bands(m.bands)
        root.spectrumOut = root.bands(m.out)
        root.spectrumPeaks = root.bands(m.peaks)
        var top = Number(m.top)
        root.spectrumTop = isFinite(top) ? Math.max(-40, Math.min(0, top)) : -40
      }
    }
    onRunningChanged: if (!running) {
      root.levelIn = -120; root.levelPeak = -120; root.levelOut = -120
      root.spectrum = []
      root.spectrumOut = []
      root.spectrumPeaks = []
      root.spectrumTop = -40
      root.gateHistory = []
      if (!root.meterWanted) { meterStart.interval = 250; return }
      // Quick deaths (no microphone yet) back off instead of spinning.
      meterStart.interval = Date.now() - root.meterStartedAt < 2000 ? Math.min(10000, meterStart.interval * 2) : 250
      meterStart.restart()
    }
  }

  function bands(list) {
    if (!Array.isArray(list) || list.length !== Eq.GRID) return []
    var out = []
    for (var i = 0; i < Eq.GRID; i++) out.push(root.db(list[i]))
    return out
  }

  function db(v) {
    var n = Number(v)
    return isFinite(n) ? Math.max(-120, Math.min(0, n)) : -120
  }

  // --- listening in ----------------------------------------------------------

  property bool monitoring: false

  // Where you hear yourself: the output you picked, else the first one that
  // is a pair of headphones, else nothing. Never silently the speakers.
  readonly property string monitorSink: {
    var wanted = String(root.settings.monitorSink || "")
    for (var i = 0; i < root.sinks.length; i++) if (root.sinks[i].name === wanted) return wanted
    for (var j = 0; j < root.sinks.length; j++) if (root.sinks[j].headphones) return root.sinks[j].name
    return ""
  }
  readonly property bool monitorOnSpeakers: {
    for (var i = 0; i < root.sinks.length; i++)
      if (root.sinks[i].name === root.monitorSink) return !root.sinks[i].headphones
    return false
  }

  // With the chain up you hear what the apps hear. With it off you hear the
  // bare microphone, which is still what you would be sending.
  readonly property string monitorSource: root.present ? root.sourceName : root.mic

  function setMonitorSink(name) { root.change(function(s) { s.monitorSink = name }) }

  function setMonitoring(on) {
    root.monitoring = on
    root.monitorFailures = 0
    monitorRestart.interval = 150
    monitorRestart.restart()
  }

  // A loopback that dies straight after starting (an output that went away)
  // is retried with a growing pause, and given up on after a few tries rather
  // than restarted every 150 ms for the rest of the session.
  property int monitorFailures: 0
  property real monitorStartedAt: 0

  readonly property bool monitorShouldRun: root.monitoring && !root.demo && !root.playing
                                           && root.monitorSink !== "" && root.monitorSource !== ""

  onMonitorShouldRunChanged: monitorRestart.restart()
  onMonitorSourceChanged: if (root.monitoring) monitorRestart.restart()
  onMonitorSinkChanged: if (root.monitoring) monitorRestart.restart()

  Timer {
    id: monitorRestart
    interval: 150
    onTriggered: {
      if (monitorProc.running) { monitorProc.signal(15); return }   // onRunningChanged starts it again
      if (root.monitorShouldRun) root.startMonitor()
    }
  }

  function startMonitor() {
    monitorProc.command = [
      "/usr/bin/pw-loopback", "-n", "soundcheck_monitor",
      "-C", root.monitorSource, "-P", root.monitorSink,
      "-c", "1", "-m", "[ MONO ]", "-l", "10",
      "-i", "{ node.name = soundcheck_monitor_in node.dont-fallback = true }",
      "-o", "{ node.name = soundcheck_monitor_out node.dont-fallback = true media.role = Communication }"
    ]
    root.monitorStartedAt = Date.now()
    monitorProc.running = true
  }

  Process {
    id: monitorProc
    onRunningChanged: {
      if (running || !root.monitorShouldRun) return
      if (Date.now() - root.monitorStartedAt < 2000) {
        root.monitorFailures++
        if (root.monitorFailures > 4) {
          root.monitoring = false
          root.error = "Listening in stopped: the output did not accept it"
          return
        }
        monitorRestart.interval = Math.min(8000, 500 * Math.pow(2, root.monitorFailures))
      } else {
        root.monitorFailures = 0
        monitorRestart.interval = 150
      }
      monitorRestart.restart()
    }
  }

  // --- a test recording ------------------------------------------------------

  property bool recording: false
  property real recordElapsed: 0
  property real recordLevel: -120
  property bool playing: false
  property string playWhich: "after"
  property real playPosition: 0
  property real playLength: 0
  // Before or After, for the next Play. After by default: what the others hear.
  property string listenTo: "after"

  readonly property bool canPlay: root.recordingInfo.before && !root.recording
  readonly property bool hasAfter: root.recordingInfo.after

  function toggleRecord() {
    if (root.recording) { recordProc.signal(15); return }
    if (root.playing) playProc.signal(15)
    root.recordElapsed = 0
    root.recording = true
    recordProc.running = true
  }

  LineProcess {
    id: recordProc
    command: root.argv(["record"])
    handler: function(m) {
      if (m.type === "record") {
        root.recordElapsed = Number(m.elapsed) || 0
        root.recordLevel = root.db(m.level)
      } else if (m.type === "done") {
        root.recordingInfo = { before: true, after: m.after === true, seconds: Number(m.seconds) || 0 }
        root.listenTo = m.after === true ? "after" : "before"
        root.autoplay = true
      } else if (m.ok === false) {
        root.error = root.label(m.error)
      }
    }
    onRunningChanged: if (!running) {
      root.recording = false
      // Straight back to you: the point of a test is hearing it.
      if (root.autoplay) { root.autoplay = false; root.play(root.listenTo) }
      root.refresh()
    }
  }
  property bool autoplay: false

  function play(which) {
    if (root.recording) return
    var target = which === "before" || !root.hasAfter ? "before" : "after"
    var sink = root.monitorSink !== "" ? root.monitorSink : (root.sinks.length ? root.sinks[0].name : "")
    if (sink === "") { root.error = "No output to play on"; return }
    root.playWhich = target
    root.listenTo = target
    if (playProc.running) { root.pendingPlay = target; playProc.signal(15); return }
    root.playPosition = 0
    root.playing = true
    playProc.command = root.argv(["play", target, sink])
    playProc.running = true
  }
  property string pendingPlay: ""
  // True once the playback is actually running (the preview takes a moment).
  property bool previewLive: false

  function stopPlay() { if (playProc.running) playProc.signal(15) }

  function togglePlay() { root.playing ? root.stopPlay() : root.play(root.listenTo) }

  // Switching Before/After while it plays starts the other one from the top.
  function setListenTo(which) {
    root.listenTo = which
    if (root.playing) root.play(which)
  }

  LineProcess {
    id: playProc
    handler: function(m) {
      if (m.type === "play") {
        root.previewLive = true
        root.playPosition = Number(m.position) || 0
        root.playLength = Number(m.length) || 0
      } else if (m.ok === false) {
        root.error = root.label(m.error)
      }
    }
    onRunningChanged: if (!running) {
      root.playing = false
      root.previewLive = false
      if (root.pendingPlay !== "") { var next = root.pendingPlay; root.pendingPlay = ""; root.play(next) }
    }
  }

  // --- packages --------------------------------------------------------------

  function copyCommand(text) {
    Quickshell.execDetached(["/usr/bin/wl-copy", "--", text])
  }

  Component.onDestruction: {
    if (monitorProc.running) monitorProc.signal(15)
    if (meterProc.running) meterProc.signal(15)
    if (recordProc.running) recordProc.signal(15)
    if (playProc.running) playProc.signal(15)
  }
}
