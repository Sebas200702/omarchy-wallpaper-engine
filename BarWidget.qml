import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "sebas.wallpaper-engine"

  property string script: Quickshell.env("HOME") + "/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh"
  property string currentFile: ""
  property bool paused: false
  property int nextInSec: -1

  function shortName() {
    if (!currentFile) return "Wallpaper"
    var base = String(currentFile).split("/").pop()
    base = base.replace(/\.[^/.]+$/, "").replace(/[-_]+/g, " ")
    if (base.length > 18) base = base.substring(0, 17) + "…"
    return base
  }

  function tooltip() {
    var parts = ["Wallpaper Engine"]
    var n = shortName()
    if (currentFile) parts.push(n + (paused ? " (paused)" : ""))
    if (!paused && nextInSec >= 0) {
      var m = Math.floor(nextInSec / 60)
      var s = nextInSec % 60
      parts.push("next in " + m + "m " + s + "s")
    }
    parts.push("click: next · right: pause · middle: prev")
    return parts.join("\n")
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf03e" // Nerd Font image icon U+F03E (ascii escape)
    // U+F03E image icon (explicit glyph; Nerd Font in bar font stack)
    slotSize: Style.bar.statusSlot
    active: root.paused
    tooltipText: root.tooltip()
    onPressed: function(btn) {
      if (btn === Qt.RightButton) {
        Quickshell.execDetached(["omarchy-shell", "-q", "sebas.wallpaper-engine", "toggle"])
        Qt.callLater(root.refresh)
      } else if (btn === Qt.MiddleButton) {
        Quickshell.execDetached(["omarchy-shell", "-q", "sebas.wallpaper-engine", "prev"])
        Qt.callLater(root.refresh)
      } else {
        Quickshell.execDetached(["omarchy-shell", "-q", "sebas.wallpaper-engine", "next"])
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: statusProc
    command: [root.script, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.currentFile = d.file || ""
          root.paused = d.paused === true
          root.nextInSec = (d.nextInSec !== undefined) ? d.nextInSec : -1
        } catch (e) {
          // keep last known values on parse failure
        }
      }
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
}
