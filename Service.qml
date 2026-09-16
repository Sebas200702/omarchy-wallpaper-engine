pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtMultimedia
import qs.Commons

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string script: home + "/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh"
  readonly property string cleanupHelper: stateHome + "/omarchy/wallpaper-engine/cleanup"
  property string videoPath: ""
  property var readyScreens: ({})
  property int playGeneration: 0
  property int revealGeneration: 0
  property bool revealVideo: true
  readonly property int maxVideoPathLen: 4096
  readonly property int maxTransitionMs: 4000
  readonly property string allowedConfigPrefix: home + "/.config/omarchy/backgrounds/"
  readonly property string allowedStatePrefix: home + "/.local/state/omarchy/current/theme/backgrounds/"
  readonly property string allowedSystemPrefix: "/usr/share/omarchy/"
  readonly property string allowedLocalSharePrefix: home + "/.local/share/omarchy/"
  readonly property string allowedCachePrefix: home + "/.cache/omarchy/wallpaper-engine/online/"

  function isValidVideoPath(p) {
    if (!p) return false
    var s = String(p)
    if (s.length === 0 || s.length > maxVideoPathLen) return false
    if (s.indexOf("\n") !== -1 || s.indexOf("\t") !== -1 || s.indexOf("\0") !== -1) return false
    if (s.charAt(0) !== "/") return false
    if (s.indexOf("..") !== -1) return false
    if (!(s.indexOf(allowedConfigPrefix) === 0 || s.indexOf(allowedStatePrefix) === 0
          || s.indexOf(allowedSystemPrefix) === 0 || s.indexOf(allowedLocalSharePrefix) === 0
          || s.indexOf(allowedCachePrefix) === 0)) {
      return false
    }
    var lower = s.toLowerCase()
    if (!(lower.endsWith(".mp4") || lower.endsWith(".mkv") || lower.endsWith(".webm") || lower.endsWith(".mov") || lower.endsWith(".m4v")))
      return false
    return true
  }

  function clampTransitionMs(v) {
    var n = Number(v)
    if (!isFinite(n)) return 0
    n = Math.floor(n)
    if (n < 0) return 0
    if (n > maxTransitionMs) return maxTransitionMs
    return n
  }

  function openSelector() {
    if (!pickerProc.running) pickerProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  function play(path, transitionMs) {
    revealTimer.stop()
    readyScreens = ({})
    var raw = String(path || "").trim()
    if (raw.length > maxVideoPathLen) raw = raw.substring(0, maxVideoPathLen)
    var ms = clampTransitionMs(transitionMs)
    if (raw !== "" && !isValidVideoPath(raw)) {
      videoPath = ""
      playGeneration += 1
      revealVideo = false
      console.warn("wallpaper-engine: rejected invalid video path", raw)
      return
    }
    revealVideo = ms <= 0
    videoPath = raw
    playGeneration += 1
    if (!revealVideo) {
      revealGeneration = playGeneration
      revealTimer.interval = ms
      revealTimer.restart()
    }
  }

  function stop() {
    revealTimer.stop()
    revealVideo = false
    videoPath = ""
    readyScreens = ({})
    playGeneration += 1
  }

  function markFrameReady(screenName) {
    if (readyScreens[screenName]) return
    var next = {}
    for (var key in readyScreens) next[key] = readyScreens[key]
    next[screenName] = true
    readyScreens = next
  }

  // Rotation triggers: delegate selection logic to the bash engine so QML
  // stays a thin player. Timers only spawn short-lived script processes.
  function advanceIfDue() {
    if (!advanceProc.running) advanceProc.running = true
  }

  function engineNext() {
    if (!nextProc.running) nextProc.running = true
  }

  function enginePrev() {
    if (!prevProc.running) prevProc.running = true
  }

  function engineToggle() {
    if (!toggleProc.running) toggleProc.running = true
  }

  Timer {
    id: pickerWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (pickerProc.running) pickerProc.running = false
  }
  Timer {
    id: resumeWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (resumeProc.running) resumeProc.running = false
  }
  Timer {
    id: wireMenuWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (wireMenuProc.running) wireMenuProc.running = false
  }
  Timer {
    id: preparePickerWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (preparePickerProc.running) preparePickerProc.running = false
  }
  Timer {
    id: changeCheckWatchdog
    interval: 8000
    repeat: false
    onTriggered: if (changeCheckProc.running) changeCheckProc.running = false
  }
  Timer {
    id: advanceWatchdog
    interval: 30000
    repeat: false
    onTriggered: if (advanceProc.running) advanceProc.running = false
  }
  Timer {
    id: themeSwitchWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (themeSwitchProc.running) themeSwitchProc.running = false
  }

  Process {
    id: pickerProc
    command: ["timeout", "30", root.script]
    onRunningChanged: if (running) pickerWatchdog.restart(); else pickerWatchdog.stop()
  }

  Process {
    id: resumeProc
    command: ["timeout", "15", root.script, "--resume"]
    onRunningChanged: if (running) resumeWatchdog.restart(); else resumeWatchdog.stop()
  }

  Process {
    id: wireMenuProc
    command: ["timeout", "15", root.script, "--wire-menu"]
    onRunningChanged: if (running) wireMenuWatchdog.restart(); else wireMenuWatchdog.stop()
  }

  Process {
    id: preparePickerProc
    command: ["timeout", "30", root.script, "--prepare-picker"]
    onRunningChanged: if (running) preparePickerWatchdog.restart(); else preparePickerWatchdog.stop()
  }

  Process {
    id: changeCheckProc
    command: ["timeout", "8", root.script, "--stop-if-changed"]
    onRunningChanged: if (running) changeCheckWatchdog.restart(); else changeCheckWatchdog.stop()
  }

  Process {
    id: advanceProc
    command: ["timeout", "25", root.script, "--advance-if-due"]
    onRunningChanged: if (running) advanceWatchdog.restart(); else advanceWatchdog.stop()
  }

  Process {
    id: nextProc
    command: ["timeout", "30", root.script, "next"]
  }

  Process {
    id: prevProc
    command: ["timeout", "30", root.script, "prev"]
  }

  Process {
    id: toggleProc
    command: ["timeout", "10", root.script, "toggle"]
  }

  Process {
    id: themeSwitchProc
    command: ["bash", "-c", "timeout 12 bash -c 'theme=$(timeout 8 omarchy-theme-switcher); [[ -n $theme ]] && timeout 8 omarchy-theme-set \"$theme\" >/dev/null 2>&1 &'"]
    onRunningChanged: if (running) themeSwitchWatchdog.restart(); else themeSwitchWatchdog.stop()
  }

  Timer {
    id: revealTimer
    repeat: false
    onTriggered: {
      if (root.revealGeneration === root.playGeneration && root.videoPath !== "")
        root.revealVideo = true
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: true
    onTriggered: {
      if (!changeCheckProc.running) changeCheckProc.running = true
    }
  }

  Timer {
    id: rotationTimer
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.advanceIfDue()
  }

  IpcHandler {
    target: "sebas.wallpaper-engine"

    function play(path: string, transitionMs: int): void { root.play(path, transitionMs) }
    function playSimple(path: string): void { root.play(path, 0) }
    function stop(): void { root.stop() }
    function next(): void { root.engineNext() }
    function prev(): void { root.enginePrev() }
    function toggle(): void { root.engineToggle() }
    function advance(): void { root.advanceIfDue() }
    function status(): string {
      return JSON.stringify({
        active: root.videoPath !== "",
        video: root.videoPath,
        readyScreens: Object.keys(root.readyScreens).length,
        revealed: root.revealVideo,
        generation: root.playGeneration
      })
    }
  }

  Component.onCompleted: {
    wireMenuProc.running = true
    resumeProc.running = true
    preparePickerProc.running = true
  }

  Component.onDestruction: Quickshell.execDetached(["bash", "-c", 'p="$1"; [[ ! -L "$p" && -f "$p" && -x "$p" ]] && exec "$p" --cleanup-after-unload', "bash", root.cleanupHelper])

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      property bool frameDecoded: false
      property int playerGeneration: -1
      property int acceptedGeneration: -1

      function syncPlayer() {
        var generation = root.playGeneration
        playerGeneration = generation
        acceptedGeneration = -1
        frameDecoded = false
        player.stop()
        player.source = ""
        if (root.videoPath === "") {
          return
        }
        if (!root.isValidVideoPath(root.videoPath)) {
          console.warn("wallpaper-engine: blocked invalid source in syncPlayer")
          return
        }
        player.source = Util.fileUrl(root.videoPath)
        player.play()
        Qt.callLater(function() {
          if (panel.playerGeneration === generation && root.playGeneration === generation)
            panel.acceptedGeneration = generation
        })
      }

      screen: modelData
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore

      WlrLayershell.namespace: "sebas-wallpaper-engine"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      MediaPlayer {
        id: player
        videoOutput: videoOutput
        loops: MediaPlayer.Infinite
        onErrorOccurred: function(error, errorString) {
          console.warn("wallpaper-engine: MediaPlayer error", error, errorString, "source", player.source)
          if (panel.playerGeneration === root.playGeneration) {
            panel.frameDecoded = false
          }
        }
      }

      VideoOutput {
        id: videoOutput
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        visible: root.videoPath !== "" && panel.frameDecoded && root.revealVideo
      }

      Connections {
        target: root
        function onPlayGenerationChanged() { panel.syncPlayer() }
        function onRevealVideoChanged() {
          if (root.revealVideo && panel.frameDecoded && panel.playerGeneration === root.playGeneration)
            player.play()
        }
      }

      Connections {
        target: videoOutput.videoSink
        function onVideoFrameChanged() {
          if (root.videoPath !== "" && !panel.frameDecoded
              && panel.acceptedGeneration === root.playGeneration
              && panel.playerGeneration === root.playGeneration) {
            panel.frameDecoded = true
            if (!root.revealVideo) player.pause()
            root.markFrameReady(panel.modelData.name)
          }
        }
      }

      Component.onCompleted: syncPlayer()

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
