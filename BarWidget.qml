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
  // Live player state from the QML service (distinct from the engine's
  // manual rotation pause above): the video decoder freezes on battery /
  // idle while rotation itself keeps going.
  property bool systemPaused: false
  property string pauseReason: ""

  function shortName() {
    if (!currentFile) return "Wallpaper"
    var base = String(currentFile).split("/").pop()
    base = base.replace(/\.[^/.]+$/, "").replace(/[-_]+/g, " ")
    if (base.length > 18) base = base.substring(0, 17) + "…"
    return base
  }

  function pauseReasonLabel() {
    if (pauseReason === "battery") return "on battery"
    if (pauseReason === "idle") return "idle"
    if (pauseReason === "battery+idle") return "battery, idle"
    return "auto-paused"
  }

  function tooltip() {
    var parts = ["Wallpaper Engine"]
    var n = shortName()
    if (currentFile) parts.push(n + (paused ? " (paused)" : ""))
    if (systemPaused) parts.push("video paused — " + pauseReasonLabel())
    if (!paused && nextInSec >= 0) {
      var m = Math.floor(nextInSec / 60)
      var s = nextInSec % 60
      parts.push("next in " + m + "m " + s + "s")
    }
    parts.push("click: gallery · right: next · middle: pause")
    return parts.join("\n")
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
    if (!playerProc.running) playerProc.running = true
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
    active: root.paused || root.systemPaused
    tooltipText: root.tooltip()
    onPressed: function(btn) {
      if (btn === Qt.RightButton) {
        Quickshell.execDetached(["omarchy-shell", "-q", "sebas.wallpaper-engine", "next"])
        Qt.callLater(root.refresh)
      } else if (btn === Qt.MiddleButton) {
        Quickshell.execDetached(["omarchy-shell", "-q", "sebas.wallpaper-engine", "toggle"])
        Qt.callLater(root.refresh)
      } else if (root.bar) {
        root.bar.run("omarchy-shell shell summon sebas.wallpaper-engine '{}'")
      } else {
        Quickshell.execDetached(["omarchy-shell", "shell", "summon", "sebas.wallpaper-engine", "{}"])
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

  // Player state comes from the QML service IPC (not the bash engine),
  // which is the only place that knows whether the decoder is currently
  // frozen by a battery/idle condition and why.
  Process {
    id: playerProc
    command: ["omarchy-shell", "-q", "sebas.wallpaper-engine", "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.systemPaused = d.systemPaused === true
          root.pauseReason = d.pauseReason || ""
        } catch (e) {
          // keep last known values on parse failure (e.g. service not loaded)
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
