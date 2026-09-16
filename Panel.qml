import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Wallpaper Engine gallery: browse local + online (Wallhaven/MoeWalls),
// download & apply, and tune rotation — all in one place.
// Summoned with: omarchy-shell shell summon sebas.wallpaper-engine
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string tab: "local" // local | wallhaven | moewalls | settings
  property var items: []
  property string itemsSource: ""
  property string query: ""
  property bool loading: false
  property string busyText: ""
  property string notice: ""
  property string errorText: ""
  property var engine: ({})
  property int serial: 0

  readonly property string pluginId: (manifest && manifest.id) || "sebas.wallpaper-engine"
  readonly property string script: Quickshell.env("HOME") + "/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh"
  readonly property color onScrim: "white"
  readonly property color onScrimDim: Qt.rgba(1, 1, 1, 0.6)
  readonly property color onScrimFaint: Qt.rgba(1, 1, 1, 0.32)
  readonly property color onScrimUrgent: "#ff7b72"
  readonly property color accent: "#7aa2f7"
  readonly property color cardBg: Qt.rgba(0.09, 0.09, 0.11, 0.97)
  readonly property string fontFamily: Style.font.family

  function providerOf(t) {
    return t === "wallhaven" || t === "moewalls" ? t : ""
  }

  function open(payloadJson) {
    root.opened = true
    root.notice = ""
    root.errorText = ""
    if (root.tab === "settings") loadConfig()
    else if (root.tab === "local") { if (root.itemsSource !== "local") runGrid() }
    else { if (root.itemsSource !== root.tab) runSearch(true) }
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.serial += 1
    for (var i = 0; i < [gridProc, searchProc, applyProc, configProc].length; i++) {
      var p = [gridProc, searchProc, applyProc, configProc][i]
      if (p.running) p.running = false
    }
    root.opened = false
    root.loading = false
    root.busyText = ""
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
    else close()
  }

  function switchTab(t) {
    if (root.tab === t) return
    root.tab = t
    root.errorText = ""
    root.notice = ""
    if (t === "settings") { loadConfig(); return }
    if (t === "local") { if (root.itemsSource !== "local") runGrid(); return }
    if (root.itemsSource !== t) runSearch(true)
  }

  function runGrid() {
    var s = ++root.serial
    root.loading = true
    root.busyText = "Loading local wallpapers…"
    root.errorText = ""
    gridProc.command = [root.script, "grid-local", "120"]
    gridProc.tag = s
    gridProc.running = true
  }

  function runSearch(withDefault) {
    var q = root.query.trim()
    if (q === "" && withDefault)
      q = root.tab === "moewalls" ? "anime" : "landscape"
    if (q === "") { root.errorText = "Type something to search"; return }
    root.query = q
    var s = ++root.serial
    root.loading = true
    root.busyText = "Searching " + root.tab + " for “" + q + "”…"
    root.errorText = ""
    root.notice = ""
    searchProc.command = [root.script, "grid-search", root.tab, q]
    searchProc.tag = s
    searchProc.running = true
  }

  function applyItem(item) {
    if (!item || root.loading) return
    var s = ++root.serial
    root.loading = true
    root.errorText = ""
    root.notice = ""
    if (root.itemsSource === "local") {
      root.busyText = "Applying “" + (item.title || "wallpaper") + "”…"
      applyProc.command = [root.script, "set", item.key]
    } else {
      root.busyText = "Downloading “" + (item.title || "wallpaper") + "”… (full quality, may take a minute)"
      applyProc.command = [root.script, "apply-key", item.key]
    }
    applyProc.tag = s
    applyProc.pendingTitle = item.title || "wallpaper"
    applyProc.running = true
  }

  function markCurrent(key) {
    var next = []
    for (var i = 0; i < root.items.length; i++) {
      var it = root.items[i]
      it.current = (it.key === key)
      next.push(it)
    }
    root.items = next
  }

  function loadConfig() {
    var s = ++root.serial
    root.loading = true
    root.busyText = "Loading settings…"
    root.errorText = ""
    configProc.command = [root.script, "config-get"]
    configProc.tag = s
    configProc.mode = "get"
    configProc.running = true
  }

  function setConfig(key, value) {
    var s = ++root.serial
    root.loading = true
    root.busyText = "Saving…"
    root.errorText = ""
    configProc.command = [root.script, "config-set", key, String(value)]
    configProc.tag = s
    configProc.mode = "get"
    configProc.running = true
  }

  function engineAction(action) {
    var s = ++root.serial
    root.loading = true
    root.busyText = action === "toggle" ? "Toggling rotation…" : "Switching wallpaper…"
    root.errorText = ""
    configProc.command = [root.script, action]
    configProc.tag = s
    configProc.mode = "refresh"
    configProc.running = true
  }

  function parseItems(text, source) {
    var arr = []
    try { arr = JSON.parse(String(text || "[]")) || [] } catch (e) { arr = [] }
    if (!Array.isArray(arr)) arr = []
    root.items = arr
    root.itemsSource = source
  }

  component TabButton: Rectangle {
    id: tabBtn
    required property string label
    required property string tabName
    height: 34
    width: tabLabel.implicitWidth + 32
    radius: 8
    color: root.tab === tabName ? Qt.rgba(1, 1, 1, 0.14) : "transparent"
    border.width: root.tab === tabName ? 1 : 0
    border.color: root.accent

    Text {
      id: tabLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tabBtn.label
      color: root.tab === tabBtn.tabName ? root.onScrim : root.onScrimDim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: root.tab === tabBtn.tabName
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.switchTab(tabBtn.tabName)
    }
  }

  component ActionButton: Rectangle {
    id: actBtn
    required property string label
    property bool enabled: true
    property bool primary: false
    height: 36
    width: Math.max(96, actLabel.implicitWidth + 36)
    radius: 8
    color: !actBtn.enabled ? Qt.rgba(1, 1, 1, 0.06)
      : actBtn.primary ? root.accent : Qt.rgba(1, 1, 1, 0.12)
    opacity: !actBtn.enabled ? 0.5 : 1.0
    signal clicked

    Text {
      id: actLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: actBtn.label
      color: actBtn.primary ? "#0b0d12" : root.onScrim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: actBtn.primary
    }
    MouseArea {
      anchors.fill: parent
      enabled: actBtn.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: actBtn.clicked()
    }
  }

  component SettingRow: RowLayout {
    id: setRow
    required property string label
    width: parent.width
    spacing: 12

    Text {
      textFormat: Text.PlainText
      text: setRow.label
      color: root.onScrimDim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      Layout.preferredWidth: 170
    }
  }

  Process {
    id: gridProc
    property int tag: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (gridProc.tag !== root.serial || !root.opened) return
        root.loading = false
        root.busyText = ""
        var ok = false
        try {
          var arr = JSON.parse(String(text || "[]"))
          ok = Array.isArray(arr)
        } catch (e) { ok = false }
        if (ok) root.parseItems(text, "local")
        else root.errorText = "Could not list local wallpapers"
      }
    }
    onExited: function(code) {
      if (gridProc.tag !== root.serial || !root.opened) return
      root.loading = false
      if (code !== 0 && root.itemsSource !== "local") {
        root.busyText = ""
        if (root.errorText === "") root.errorText = "Could not list local wallpapers"
      }
    }
  }

  Process {
    id: searchProc
    property int tag: 0
    property string wantSource: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (searchProc.tag !== root.serial || !root.opened) return
        root.loading = false
        root.busyText = ""
        var arr = null
        try { arr = JSON.parse(String(text || "")) } catch (e) { arr = null }
        if (Array.isArray(arr) && arr.length > 0) {
          root.parseItems(text, searchProc.wantSource)
          root.notice = arr.length + " results — click one to download & apply"
        } else if (Array.isArray(arr)) {
          root.items = []
          root.itemsSource = searchProc.wantSource
          root.errorText = "No results. Try another search."
        } else {
          root.errorText = "Search failed (network or provider changed)"
        }
      }
    }
    onExited: function(code) {
      if (searchProc.tag !== root.serial || !root.opened) return
      root.loading = false
      if (code !== 0 && root.errorText === "" && root.itemsSource !== searchProc.wantSource) {
        root.busyText = ""
        root.errorText = "Search failed (network or provider changed)"
      } else if (root.busyText !== "" && root.itemsSource === searchProc.wantSource) {
        root.busyText = ""
      }
    }
  }

  Process {
    id: applyProc
    property int tag: 0
    property string pendingTitle: ""
    property string appliedPath: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (applyProc.tag !== root.serial || !root.opened) return
        applyProc.appliedPath = String(text || "").trim().split("\n").filter(function(l) { return l !== "" }).pop() || ""
      }
    }
    onExited: function(code) {
      if (applyProc.tag !== root.serial || !root.opened) return
      root.loading = false
      root.busyText = ""
      if (code === 0) {
        root.errorText = ""
        root.notice = "Applied: " + applyProc.pendingTitle
        if (root.itemsSource === "local" && applyProc.appliedPath !== "")
          root.markCurrent(applyProc.appliedPath)
        else if (root.itemsSource !== "local")
          root.itemsSource = root.itemsSource // keep results; local cache refreshes on revisit
        loadConfigSilent()
      } else {
        root.errorText = "Could not apply wallpaper"
      }
    }
  }

  function loadConfigSilent() {
    var s = ++root.serial
    configProc.command = [root.script, "config-get"]
    configProc.tag = s
    configProc.mode = "silent"
    configProc.running = true
  }

  Process {
    id: configProc
    property int tag: 0
    property string mode: "get" // get | silent | refresh
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (configProc.tag !== root.serial || !root.opened) return
        if (configProc.mode === "refresh") return
        try {
          var d = JSON.parse(String(text || "{}")) || {}
          if (d.config) root.engine = d
          else if (d.status) root.engine = { status: d.status, config: root.engine.config || {} }
        } catch (e) {}
        if (configProc.mode === "get") {
          root.loading = false
          root.busyText = ""
        }
      }
    }
    onExited: function(code) {
      if (configProc.tag !== root.serial || !root.opened) return
      if (configProc.mode === "refresh") {
        configProc.mode = "silent"
        configProc.command = [root.script, "config-get"]
        configProc.running = true
        return
      }
      if (configProc.mode === "silent") return
      root.loading = false
      if (code !== 0 && root.errorText === "") {
        root.busyText = ""
        root.errorText = "Could not load settings"
      }
    }
  }

  Timer {
    id: watchdog
    interval: 150000
    repeat: false
    running: root.opened && root.loading
    onTriggered: {
      root.serial += 1
      root.loading = false
      root.busyText = ""
      if (root.errorText === "") root.errorText = "Timed out — check your connection and retry"
    }
  }

  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "sebas-wallpaper-engine-panel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.72)
      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.dismiss()

      Item {
        anchors.centerIn: parent
        width: Math.min(1020, keyCatcher.width - 60)
        height: Math.min(660, keyCatcher.height - 60)

        MouseArea { anchors.fill: parent; onClicked: {} }

        Rectangle {
          anchors.fill: parent
          radius: 14
          color: root.cardBg
          border.width: 1
          border.color: Qt.rgba(1, 1, 1, 0.12)

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 12

            RowLayout {
              Layout.fillWidth: true
              spacing: 12

              Text {
                textFormat: Text.PlainText
                text: "WALLPAPER ENGINE"
                color: root.onScrimDim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 2
              }

              Text {
                id: statusLine
                textFormat: Text.PlainText
                text: {
                  var st = (root.engine && root.engine.status) || {}
                  if (!st.file) return "rotation on • nothing applied yet"
                  var base = String(st.file).split("/").pop().replace(/\.[^/.]+$/, "")
                  var mins = Math.floor((st.nextInSec || 0) / 60)
                  var secs = (st.nextInSec || 0) % 60
                  return (st.paused ? "paused • " : "next in " + mins + "m " + secs + "s • ") + base
                }
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                Layout.fillWidth: true
              }

              ActionButton {
                label: "Close"
                Layout.preferredHeight: 32
                onClicked: root.dismiss()
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: 8

              TabButton { label: "Local"; tabName: "local" }
              TabButton { label: "Wallhaven"; tabName: "wallhaven" }
              TabButton { label: "Live (MoeWalls)"; tabName: "moewalls" }
              TabButton { label: "Settings"; tabName: "settings" }
            }

            RowLayout {
              id: searchRow
              visible: root.providerOf(root.tab) !== ""
              Layout.fillWidth: true
              spacing: 8

              Rectangle {
                Layout.fillWidth: true
                height: 38
                radius: 8
                color: Qt.rgba(1, 1, 1, 0.08)
                border.width: searchInput.activeFocus ? 1 : 0
                border.color: root.accent

                TextInput {
                  id: searchInput
                  anchors.fill: parent
                  anchors.leftMargin: 12
                  anchors.rightMargin: 12
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.onScrim
                  selectionColor: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  text: root.query
                  onTextChanged: root.query = text
                  Keys.onReturnPressed: root.runSearch(false)
                  Keys.onEnterPressed: root.runSearch(false)
                  Keys.onEscapePressed: root.dismiss()
                }

                Text {
                  visible: searchInput.displayText === ""
                  anchors.left: parent.left
                  anchors.leftMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.tab === "moewalls" ? "Search live wallpapers… (e.g. frieren)" : "Search wallpapers… (e.g. mountains)"
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              ActionButton {
                label: "Search"
                primary: true
                enabled: !root.loading
                onClicked: root.runSearch(false)
              }
            }

            // ---- grid view ----
            Flickable {
              id: gridScroll
              visible: root.tab !== "settings"
              Layout.fillWidth: true
              Layout.fillHeight: true
              contentWidth: width
              contentHeight: gridFlow.height
              clip: true

              Grid {
                id: gridFlow
                width: parent.width
                columns: 4
                spacing: 12

                Repeater {
                  model: root.items

                  Item {
                    required property var modelData
                    required property int index
                    width: (gridFlow.width - 3 * gridFlow.spacing) / 4
                    height: width * 9 / 16 + 30

                    Rectangle {
                      anchors.fill: parent
                      radius: 8
                      color: Qt.rgba(1, 1, 1, 0.05)
                      border.width: modelData.current ? 2 : 0
                      border.color: root.accent

                      Image {
                        id: cellImg
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: parent.height - 30
                        source: modelData.thumb ? "file://" + modelData.thumb : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        smooth: true
                      }

                      Rectangle {
                        visible: modelData.kind === "video"
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 6
                        width: badgeText.implicitWidth + 14
                        height: 20
                        radius: 5
                        color: Qt.rgba(0, 0, 0, 0.65)

                        Text {
                          id: badgeText
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: "LIVE"
                          color: "white"
                          font.family: root.fontFamily
                          font.pixelSize: 10
                          font.bold: true
                        }
                      }

                      Text {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        anchors.bottomMargin: 6
                        textFormat: Text.PlainText
                        text: (modelData.current ? "● " : "") + (modelData.title || "")
                        color: modelData.current ? root.accent : root.onScrimDim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.applyItem(modelData)
                      }
                    }
                  }
                }
              }
            }

            Text {
              visible: root.tab !== "settings" && !root.loading && root.items.length === 0 && root.errorText === ""
              Layout.fillWidth: true
              Layout.fillHeight: true
              textFormat: Text.PlainText
              text: root.tab === "local" ? "No wallpapers in this theme yet." : "Search to browse wallpapers."
              color: root.onScrimFaint
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }

            // ---- settings view ----
            Flickable {
              visible: root.tab === "settings"
              Layout.fillWidth: true
              Layout.fillHeight: true
              contentWidth: width
              contentHeight: settingsCol.height
              clip: true

              ColumnLayout {
                id: settingsCol
                width: parent.width
                spacing: 14

                SettingRow {
                  label: "Rotation"
                  ActionButton {
                    label: (root.engine.config && root.engine.config.enabled === false) || (root.engine.status && root.engine.status.paused) ? "Resume" : "Pause"
                    onClicked: root.engineAction("toggle")
                  }
                  ActionButton { label: "Next"; onClicked: root.engineAction("next") }
                  ActionButton { label: "Previous"; onClicked: root.engineAction("prev") }
                }

                SettingRow {
                  label: "Every (minutes)"
                  Rectangle {
                    Layout.preferredWidth: 90
                    height: 36
                    radius: 8
                    color: Qt.rgba(1, 1, 1, 0.08)

                    TextInput {
                      id: intervalInput
                      anchors.fill: parent
                      anchors.leftMargin: 10
                      anchors.rightMargin: 10
                      verticalAlignment: TextInput.AlignVCenter
                      color: root.onScrim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      inputMethodHints: Qt.ImhDigitsOnly
                      text: (root.engine.config && root.engine.config.intervalMinutes) || ""
                    }
                  }
                  ActionButton {
                    label: "Set"
                    onClicked: root.setConfig("interval", intervalInput.text)
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "1 – 1440"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                SettingRow {
                  label: "Order"
                  ActionButton {
                    label: "Shuffle"
                    primary: !!root.engine.config && root.engine.config.mode !== "sequential"
                    onClicked: root.setConfig("mode", "shuffle")
                  }
                  ActionButton {
                    label: "Sequential"
                    primary: !!root.engine.config && root.engine.config.mode === "sequential"
                    onClicked: root.setConfig("mode", "sequential")
                  }
                }

                SettingRow {
                  label: "Online cache"
                  Text {
                    textFormat: Text.PlainText
                    text: {
                      var st = (root.engine && root.engine.status) || {}
                      return "downloads live in the theme's online folder and join rotation"
                    }
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Schedules (fixed times) are edited in ~/.config/omarchy/wallpaper-engine.json → \"schedules\": [{\"time\": \"21:00\", \"pick\": \"night.mp4\"}]"
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                  Layout.fillWidth: true
                }
              }
            }

            // ---- footer ----
            Text {
              visible: root.loading
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.busyText
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: !root.loading && root.notice !== ""
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.notice
              color: root.onScrimDim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }

            Text {
              visible: !root.loading && root.errorText !== ""
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.errorText
              color: root.onScrimUrgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }
          }
        }
      }
    }
  }
}
