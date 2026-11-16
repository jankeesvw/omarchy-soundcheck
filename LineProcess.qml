import QtQuick
import Quickshell.Io

// A Process that hands over one parsed JSON object per line, and never holds
// more than `maxBytes` of unread output.
//
// Deliberately not StdioCollector, which keeps a child's whole output before
// anything can measure it. The helper bounds what it prints as well; this is
// the second wall, so a misbehaving child cannot grow the shell, which every
// widget on the desktop shares.
Process {
  id: proc

  property int maxBytes: 262144
  property string _pending: ""

  signal message(var obj)

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
        if (obj && typeof obj === "object") proc.message(obj)
      }
    }
  }

  onRunningChanged: if (!running) _pending = ""
}
