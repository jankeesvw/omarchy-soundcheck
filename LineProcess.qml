import QtQuick
import Quickshell.Io

// A Process that hands over one parsed JSON object per line, and never holds
// more than `maxBytes` of unread output.
//
// The object goes to `handler`, a plain function, and not out through a
// signal: a signal's var argument is turned into a QVariantMap on the way, and
// the arrays inside it stop being arrays (Array.isArray says false). That
// silently emptied the device lists and the spectrum.
//
// Deliberately not StdioCollector, which keeps a child's whole output before
// anything can measure it. The helper bounds what it prints as well; this is
// the second wall, so a misbehaving child cannot grow the shell, which every
// widget on the desktop shares.
Process {
  id: proc

  property int maxBytes: 262144
  property string _pending: ""

  // function(obj): called once per JSON object the child prints.
  property var handler: null

  stdout: SplitParser {
    splitMarker: ""
    onRead: function(chunk) {
      var text = proc._pending + chunk
      if (text.length > proc.maxBytes) {
        proc._pending = ""
        proc.signal(15)
        return
      }
      var lines = text.split("\n")
      proc._pending = lines.pop()
      for (var i = 0; i < lines.length; i++) {
        if (lines[i] === "") continue
        var obj
        try { obj = JSON.parse(lines[i]) } catch (e) { continue }
        if (obj && typeof obj === "object" && typeof proc.handler === "function") proc.handler(obj)
      }
    }
  }

  onRunningChanged: if (!running) _pending = ""
}
