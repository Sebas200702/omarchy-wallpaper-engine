import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Wallpaper Engine gallery v2: sidebar (library / playlists / online),
// center grid with search feedback, right properties panel.
// Summoned with: omarchy-shell shell summon sebas.wallpaper-engine
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  // view: {section: "lib" | "playlist" | "online", name: playlistName, provider: wallhaven|moewalls}
  property var view: ({ section: "lib", name: "", provider: "" })
  property var items: []
  property string itemsSource: "" // lib | playlist:<name> | online:<provider>:<query>
  property string query: ""
  property string filterText: ""
  property bool loading: false
  property string busyText: ""
  property int busySince: 0
  property int busyElapsed: 0
  property string notice: ""
  property string errorText: ""
  property var engine: ({ status: ({}), config: ({ intervalMinutes: 10, mode: "shuffle", playlists: [] }) })
  property int serial: 0
  // selection
  property string selectedKey: ""
  property var selectedItem: null
  property bool selectMode: false
  property var marked: ({})
  property int markedCount: 0
  property string addTarget: ""
  property string newPlaylistName: ""

  readonly property string pluginId: (manifest && manifest.id) || "sebas.wallpaper-engine"
  readonly property string script: Quickshell.env("HOME") + "/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh"
  // Theme-faithful palette: popup/menu roles follow the active Omarchy
  // theme (catppuccin-dark right now), with translucent text steps derived
  // from the themed text color instead of hardcoded white.
  readonly property color onScrim: Color.popups.text
  readonly property color onScrimDim: Util.alpha(Color.popups.text, 0.62)
  readonly property color onScrimFaint: Util.alpha(Color.popups.text, 0.38)
  readonly property color onScrimUrgent: Color.urgent
  readonly property color accent: Color.accent
  readonly property color markedColor: Color.accent
  readonly property color cardBg: Color.popups.background
  readonly property color cardBorder: Color.popups.border
  readonly property color rowHover: Color.menu.selectedBackground
  readonly property color rowHoverText: Color.menu.selectedText
  readonly property color scrimColor: Color.menu.scrim
  readonly property color softFill: Util.alpha(Color.popups.text, 0.08)
  readonly property color insetFill: Util.alpha(Color.popups.text, 0.045)
  readonly property string fontFamily: Style.font.family

  function playlists() {
    var c = root.engine.config || {}
    return Array.isArray(c.playlists) ? c.playlists : []
  }

  function activePlaylist() {
    var c = root.engine.config || {}
    return c.activePlaylist || ""
  }

  function viewTitle() {
    if (root.view.section === "playlist") return root.view.name
    if (root.view.section === "online")
      return root.view.provider === "moewalls" ? "Live — MoeWalls" : "Wallhaven"
    return "Library"
  }

  function viewSourceTag() {
    if (root.view.section === "playlist") return "playlist:" + root.view.name
    if (root.view.section === "online") return "online:" + root.view.provider + ":" + root.query
    return "lib"
  }

  function filteredItems() {
    var needle = root.filterText.trim().toLowerCase()
    if (needle === "") return root.items
    var out = []
    for (var i = 0; i < root.items.length; i++) {
      var t = String((root.items[i] && root.items[i].title) || "").toLowerCase()
      if (t.indexOf(needle) !== -1) out.push(root.items[i])
    }
    return out
  }

  // Headless diagnostic: omarchy-shell shell call sebas.wallpaper-engine debugState '{}'
  function debugState() {
    var pls = []
    try {
      var arr = root.playlists()
      for (var i = 0; i < arr.length; i++) pls.push(arr[i].name)
    } catch (e) {}
    return JSON.stringify({
      opened: root.opened,
      view: root.view.section + "/" + (root.view.name || root.view.provider),
      items: root.items.length,
      itemsSource: root.itemsSource,
      loading: root.loading,
      busy: root.busyText,
      elapsed: root.busyElapsed,
      notice: root.notice,
      error: root.errorText,
      selected: root.selectedKey,
      marked: root.markedCount,
      playlists: pls,
      geom: {
        screen: [Math.round(keyCatcher.width), Math.round(keyCatcher.height)],
        scale: Number(cardBox.scale.toFixed(3)),
        rowW: Math.round(centerRow.width),
        rowImp: Math.round(centerRow.implicitWidth),
        sideW: Math.round(sidePanel.width),
        centerW: Math.round(centerCol.width),
        centerImp: Math.round(centerCol.implicitWidth),
        propsW: Math.round(propsPanel.width),
        gridW: Math.round(gridFlow.width),
        gridImp: Math.round(gridFlow.implicitWidth)
      }
    })
  }

  function open(payloadJson) {
    console.log("WE-PANEL open() called, already opened=" + root.opened)
    root.opened = true
    root.notice = ""
    root.errorText = ""
    root.selectedKey = ""
    root.selectedItem = null
    root.selectMode = false
    root.marked = ({})
    root.markedCount = 0
    // Boot through config first; the grid kicks off when config arrives
    // (see configProc), so the two requests never race each other.
    var s = root.startBusy("Loading…")
    configProc.command = [root.script, "config-get"]
    configProc.tag = s
    configProc.mode = "get-boot"
    configProc.doneNotice = ""
    configProc.reloadGrid = false
    configProc.running = true
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    console.log("WE-PANEL close() called")
    root.serial += 1
    var procs = [gridProc, searchProc, applyProc, configProc]
    for (var i = 0; i < procs.length; i++) {
      if (procs[i].running) procs[i].running = false
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

  function cancelLoad() {
    root.serial += 1
    var procs = [gridProc, searchProc, applyProc, configProc]
    for (var i = 0; i < procs.length; i++) {
      if (procs[i].running) procs[i].running = false
    }
    root.loading = false
    root.busyText = ""
    root.notice = "Cancelled"
  }

  function setView(section, name, provider) {
    root.view = ({ section: section, name: name || "", provider: provider || "" })
    root.errorText = ""
    root.notice = ""
    root.selectedKey = ""
    root.selectedItem = null
    root.selectMode = false
    root.marked = ({})
    root.markedCount = 0
    root.filterText = ""
    if (section === "online") {
      if (root.itemsSource !== root.viewSourceTag()) runSearch(true)
    } else {
      if (root.itemsSource !== root.viewSourceTag()) runGrid()
    }
  }

  function startBusy(text) {
    var s = ++root.serial
    root.loading = true
    root.busyText = text
    root.errorText = ""
    root.busySince = Math.floor(Date.now() / 1000)
    root.busyElapsed = 0
    return s
  }

  function runGrid() {
    var s = root.startBusy(root.view.section === "playlist"
      ? "Loading playlist…" : "Loading library…")
    var src = root.view.section === "playlist" ? root.view.name : ""
    gridProc.command = [root.script, "grid-local", "150", src]
    gridProc.tag = s
    gridProc.wantSource = root.viewSourceTag()
    gridProc.running = true
  }

  function runSearch(withDefault) {
    var q = root.query.trim()
    if (q === "" && withDefault)
      q = root.view.provider === "moewalls" ? "anime" : "landscape"
    if (q === "") { root.errorText = "Type something to search"; return }
    root.query = q
    var s = root.startBusy("Searching " + root.view.provider + "…")
    root.notice = ""
    searchProc.command = [root.script, "grid-search", root.view.provider, q]
    searchProc.tag = s
    searchProc.wantSource = "online:" + root.view.provider + ":" + q
    searchProc.running = true
  }

  function findItem(key) {
    for (var i = 0; i < root.items.length; i++) {
      if (root.items[i] && root.items[i].key === key) return root.items[i]
    }
    return null
  }

  function cellClicked(item) {
    if (!item) return
    if (root.selectMode) {
      toggleMark(item.key)
      return
    }
    root.selectedKey = item.key
    root.selectedItem = item
  }

  function toggleMark(key) {
    var next = {}
    var n = 0
    for (var k in root.marked) {
      if (k === key) continue
      next[k] = true
      n++
    }
    if (n === root.markedCount) {
      // key was not marked → add it
      for (var k2 in root.marked) next[k2] = true
      next[key] = true
      n = root.markedCount + 1
    }
    root.marked = next
    root.markedCount = n
    if (root.addTarget === "") {
      var pls = root.playlists()
      if (pls.length > 0) root.addTarget = pls[0].name
    }
  }

  function cycleAddTarget() {
    var pls = root.playlists()
    if (pls.length === 0) return
    var idx = -1
    for (var i = 0; i < pls.length; i++) {
      if (pls[i].name === root.addTarget) { idx = i; break }
    }
    root.addTarget = pls[(idx + 1) % pls.length].name
  }

  function markedKeys() {
    var out = []
    for (var k in root.marked) out.push(k)
    return out
  }

  function applySelected() {
    if (!root.selectedItem || root.loading) return
    var s = root.startBusy(root.view.section === "online" || root.itemsSource.indexOf("online:") === 0
      ? "Downloading full quality… (up to a minute for video)"
      : "Applying…")
    root.notice = ""
    if (root.itemsSource.indexOf("online:") === 0)
      applyProc.command = [root.script, "apply-key", root.selectedItem.key]
    else
      applyProc.command = [root.script, "set", root.selectedItem.key]
    applyProc.tag = s
    applyProc.pendingTitle = root.selectedItem.title || "wallpaper"
    applyProc.appliedPath = ""
    applyProc.running = true
  }

  function removeSelected() {
    if (!root.selectedItem || root.view.section !== "playlist" || root.loading) return
    mutate(["playlist-remove", root.view.name, root.selectedItem.key], "Removed from " + root.view.name, true)
  }

  function mutate(args, doneNotice, wantGridReload) {
    var s = root.startBusy("Saving…")
    root.notice = ""
    configProc.command = [root.script].concat(args)
    configProc.tag = s
    configProc.mode = "refresh"
    configProc.doneNotice = doneNotice || ""
    configProc.reloadGrid = wantGridReload === true
    configProc.running = true
  }

  function loadConfig() {
    var s = root.startBusy("Loading…")
    configProc.command = [root.script, "config-get"]
    configProc.tag = s
    configProc.mode = "get"
    configProc.doneNotice = ""
    configProc.running = true
  }

  function loadConfigSilent() {
    var s = ++root.serial
    configProc.command = [root.script, "config-get"]
    configProc.tag = s
    configProc.mode = "silent"
    configProc.doneNotice = ""
    configProc.running = true
  }

  function setGlobal(key, value) {
    var s = root.startBusy("Saving…")
    configProc.command = [root.script, "config-set", key, String(value)]
    configProc.tag = s
    configProc.mode = "refresh"
    configProc.doneNotice = ""
    configProc.running = true
  }

  function viewingPlaylist() {
    if (root.view.section !== "playlist") return null
    var pls = root.playlists()
    for (var i = 0; i < pls.length; i++) {
      if (pls[i].name === root.view.name) return pls[i]
    }
    return null
  }

  function contextInterval() {
    var vp = root.viewingPlaylist()
    if (vp && vp.intervalMinutes) return vp.intervalMinutes
    var c = root.engine.config || {}
    return c.intervalMinutes || 10
  }

  function stepInterval(delta) {
    var cur = parseInt(root.contextInterval(), 10) || 10
    var next = cur + delta
    if (next < 1) next = 1
    if (next > 1440) next = 1440
    var vp = root.viewingPlaylist()
    if (vp) mutate(["playlist-interval", vp.name, String(next)], "")
    else setGlobal("interval", String(next))
  }

  function setMode(mode) {
    var vp = root.viewingPlaylist()
    if (vp) mutate(["playlist-mode", vp.name, mode], "")
    else setGlobal("mode", mode)
  }

  function createPlaylist() {
    var n = root.newPlaylistName.trim()
    if (n === "") { root.errorText = "Name the playlist first"; return }
    root.newPlaylistName = ""
    mutate(["playlist-create", n], "Playlist created: " + n)
  }

  function deleteViewingPlaylist() {
    if (root.view.section !== "playlist") return
    var n = root.view.name
    root.view = ({ section: "lib", name: "", provider: "" })
    root.itemsSource = ""
    mutate(["playlist-delete", n], "Playlist deleted", true)
  }

  function activateViewingPlaylist() {
    if (root.view.section !== "playlist") return
    mutate(["playlist-activate", root.view.name], "Rotating: " + root.view.name)
  }

  function addMarked() {
    if (root.markedCount === 0 || root.addTarget === "" || root.loading) return
    var s = root.startBusy("Adding " + root.markedCount + " to " + root.addTarget + "…")
    configProc.command = [root.script, "playlist-add", root.addTarget].concat(root.markedKeys())
    configProc.tag = s
    configProc.mode = "refresh"
    configProc.doneNotice = "Added " + root.markedCount + " to " + root.addTarget
    configProc.reloadGrid = true
    root.marked = ({})
    root.markedCount = 0
    root.selectMode = false
    configProc.running = true
  }

  function markCurrentFile(path) {
    if (!path) return
    var next = []
    for (var i = 0; i < root.items.length; i++) {
      var it = root.items[i]
      if (it) it.current = (it.key === path)
      next.push(it)
    }
    root.items = next
  }

  function parseItems(text, source) {
    var arr = []
    try { arr = JSON.parse(String(text || "[]")) || [] } catch (e) { arr = [] }
    if (!Array.isArray(arr)) arr = []
    root.items = arr
    root.itemsSource = source
    root.selectedKey = ""
    root.selectedItem = null
    root.marked = ({})
    root.markedCount = 0
    root.selectMode = false
  }

  function applyEngineToStatus(d) {
    if (d && d.config) root.engine = d
    else if (d && d.status) {
      var e = root.engine || {}
      e.status = d.status
      if (d.config) e.config = d.config
      root.engine = e
    }
    // refresh selected preview flags + sidebar counts flow from engine declaratively
    if (root.selectedKey !== "") {
      var it = root.findItem(root.selectedKey)
      root.selectedItem = it
    }
  }

  component ActionButton: Rectangle {
    id: actBtn
    required property string label
    property bool enabled: true
    property bool primary: false
    height: 34
    width: Math.max(58, actLabel.implicitWidth + 20)
    radius: Style.cornerRadius
    color: !actBtn.enabled ? Util.alpha(root.onScrim, 0.06)
      : actBtn.primary ? root.accent : root.softFill
    opacity: !actBtn.enabled ? 0.5 : 1.0
    signal clicked

    Text {
      id: actLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: actBtn.label
      color: actBtn.primary ? root.cardBg : root.onScrim
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

  component Stepper: RowLayout {
    id: stepper
    required property string valueText
    signal stepped(int delta)
    spacing: 6

    ActionButton {
      label: "−"
      onClicked: stepper.stepped(-1)
    }
    Text {
      textFormat: Text.PlainText
      text: stepper.valueText
      color: root.onScrim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      Layout.preferredWidth: 62
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }
    ActionButton {
      label: "+"
      onClicked: stepper.stepped(1)
    }
  }

  Process {
    id: gridProc
    property int tag: 0
    property string wantSource: ""
    property string truncationNote: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (gridProc.tag !== root.serial || !root.opened) return
        root.loading = false
        root.busyText = ""
        var arr = null
        try { arr = JSON.parse(String(text || "")) } catch (e) { arr = null }
        if (Array.isArray(arr)) {
          root.parseItems(text, gridProc.wantSource)
          if (arr.length === 0) root.notice = "Empty — add wallpapers to get started"
          else root.notice = gridProc.truncationNote
        } else {
          root.errorText = "Could not list wallpapers"
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // engine prints "TRUNCATED total=<n> shown=<m>" on stderr (not part
        // of the JSON contract) when the library/playlist is bigger than
        // what got sent to the panel — surface it instead of hiding it.
        var m = /TRUNCATED total=(\d+) shown=(\d+)/.exec(String(text || ""))
        gridProc.truncationNote = m ? ("Showing " + m[2] + " of " + m[1] + " — trim the folder or split into playlists") : ""
        if (gridProc.tag === root.serial && root.opened && gridProc.truncationNote !== "" && root.notice === "")
          root.notice = gridProc.truncationNote
      }
    }
    onExited: function(code) {
      if (gridProc.tag !== root.serial || !root.opened) return
      root.loading = false
      if (code !== 0 && root.errorText === "" && root.itemsSource !== gridProc.wantSource) {
        root.busyText = ""
        root.errorText = "Could not list wallpapers"
      } else {
        root.busyText = ""
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
          root.notice = arr.length + " results — select one, then Apply"
        } else if (Array.isArray(arr)) {
          root.items = []
          root.itemsSource = searchProc.wantSource
          root.notice = ""
          root.errorText = "No results. Try another search."
        } else {
          root.errorText = "Search failed — connection issue or provider changed"
        }
      }
    }
    onExited: function(code) {
      if (searchProc.tag !== root.serial || !root.opened) return
      root.loading = false
      if (code !== 0 && root.errorText === "" && root.itemsSource !== searchProc.wantSource) {
        root.busyText = ""
        root.errorText = "Search failed — connection issue or provider changed"
      } else {
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
        var lines = String(text || "").trim().split("\n").filter(function(l) { return l !== "" })
        applyProc.appliedPath = lines.length > 0 ? lines[lines.length - 1] : ""
      }
    }
    onExited: function(code) {
      if (applyProc.tag !== root.serial || !root.opened) return
      root.loading = false
      root.busyText = ""
      if (code === 0) {
        root.errorText = ""
        root.notice = "Applied: " + applyProc.pendingTitle
        if (applyProc.appliedPath !== "" && root.view.section !== "online")
          root.markCurrentFile(applyProc.appliedPath)
        loadConfigSilent()
      } else {
        root.errorText = "Could not apply wallpaper"
      }
    }
  }

  Process {
    id: configProc
    property int tag: 0
    property string mode: "get" // get | get-boot | silent | refresh
    property string doneNotice: ""
    property bool reloadGrid: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (configProc.tag !== root.serial || !root.opened) return
        if (configProc.mode === "refresh") return
        var d = null
        try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
        if (d) root.applyEngineToStatus(d.status !== undefined || d.config !== undefined ? d : null)
        if (d && (d.status !== undefined || d.config !== undefined)) {
          if (configProc.mode === "get-boot") {
            // Boot continues into the grid for the current view.
            if (root.view.section === "online") {
              if (root.itemsSource !== root.viewSourceTag()) root.runSearch(true)
              else { root.loading = false; root.busyText = "" }
            } else {
              if (root.itemsSource !== root.viewSourceTag()) root.runGrid()
              else { root.loading = false; root.busyText = "" }
            }
            return
          }
          if (configProc.mode === "get") {
            root.loading = false
            root.busyText = ""
          }
        } else if (configProc.mode === "get" || configProc.mode === "get-boot") {
          root.loading = false
          root.busyText = ""
          if (root.errorText === "") root.errorText = "Could not load settings"
        }
      }
    }
    onExited: function(code) {
      if (configProc.tag !== root.serial || !root.opened) return
      if (configProc.mode === "refresh") {
        if (code !== 0) {
          root.loading = false
          root.busyText = ""
          if (root.errorText === "") root.errorText = "Could not save — check the name and retry"
          return
        }
        configProc.mode = "silent"
        configProc.command = [root.script, "config-get"]
        configProc.running = true
        return
      }
      if (configProc.mode === "silent") {
        if (configProc.doneNotice !== "") {
          root.notice = configProc.doneNotice
          configProc.doneNotice = ""
        }
        // keep the "current" marker truthful after rotations
        if (root.engine.status && root.engine.status.file
            && root.itemsSource !== "" && root.view.section !== "online")
          root.markCurrentFile(root.engine.status.file)
        if (configProc.reloadGrid) {
          configProc.reloadGrid = false
          if (root.view.section !== "online" && !root.loading) {
            root.itemsSource = ""
            root.runGrid()
          }
        }
        return
      }
      root.loading = false
      if (code !== 0 && root.errorText === "") {
        root.busyText = ""
        root.errorText = "Could not load settings"
      }
    }
  }

  Timer {
    id: elapsedTicker
    interval: 500
    repeat: true
    running: root.opened && root.loading
    onTriggered: {
      root.busyElapsed = Math.floor(Date.now() / 1000) - root.busySince
    }
  }

  Timer {
    id: watchdog
    interval: 180000
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
      color: root.scrimColor
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
        id: cardBox
        anchors.centerIn: parent
        // Fixed design size, scaled down as a whole on small/scaled screens
        // (e.g. 1280x720 logical) so the card can never overflow the display.
        width: 1040
        height: 660
        scale: Math.min(1,
          (keyCatcher.width - 64) / 1040,
          (keyCatcher.height - 64) / 660)

        MouseArea { anchors.fill: parent; onClicked: {} }

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: root.cardBg
          border.width: 1
          border.color: root.cardBorder

          RowLayout {
            id: centerRow
            anchors.fill: parent
            spacing: 0

            // ============ SIDEBAR ============
            Rectangle {
              id: sidePanel
              Layout.preferredWidth: 200
              Layout.fillHeight: true
              color: root.insetFill
              radius: Style.cornerRadius

              ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 4

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
                  textFormat: Text.PlainText
                  text: "LIBRARY"
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.topMargin: 10
                }

                Repeater {
                  model: [{ label: "All wallpapers", section: "lib", name: "", count: -1 }]

                  Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    height: 36
                    radius: Style.cornerRadius
                    color: root.view.section === modelData.section && root.view.name === ""
                      ? root.rowHover : "transparent"
                    border.width: root.view.section === modelData.section && root.view.name === "" ? 1 : 0
                    border.color: root.accent

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: 10
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: modelData.label
                      color: root.onScrim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setView(modelData.section, "", "")
                    }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  Layout.topMargin: 10
                  spacing: 6

                  Text {
                    textFormat: Text.PlainText
                    text: "PLAYLISTS"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    Layout.fillWidth: true
                  }
                }

                Repeater {
                  model: root.playlists()

                  Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    height: 40
                    radius: Style.cornerRadius
                    color: root.view.section === "playlist" && root.view.name === modelData.name
                      ? root.rowHover : "transparent"
                    border.width: root.view.section === "playlist" && root.view.name === modelData.name ? 1 : 0
                    border.color: root.accent

                    ColumnLayout {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.leftMargin: 10
                      anchors.rightMargin: 8
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 0

                      Text {
                        textFormat: Text.PlainText
                        text: (modelData.name === root.activePlaylist() ? "● " : "") + modelData.name
                        color: modelData.name === root.activePlaylist() ? root.accent : root.onScrim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: modelData.count + " items · " + modelData.intervalMinutes + "m · " + modelData.mode
                        color: root.onScrimFaint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setView("playlist", modelData.name, "")
                    }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6

                  Rectangle {
                    Layout.fillWidth: true
                    height: 34
                    radius: Style.cornerRadius
                    color: root.softFill

                    TextInput {
                      id: newPlaylistInput
                      anchors.fill: parent
                      anchors.leftMargin: 10
                      anchors.rightMargin: 10
                      verticalAlignment: TextInput.AlignVCenter
                      color: root.onScrim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      text: root.newPlaylistName
                      onTextChanged: root.newPlaylistName = text
                      Keys.onReturnPressed: root.createPlaylist()
                      Keys.onEnterPressed: root.createPlaylist()
                    }
                    Text {
                      visible: newPlaylistInput.displayText === ""
                      anchors.left: parent.left
                      anchors.leftMargin: 10
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: "New playlist…"
                      color: root.onScrimFaint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                  ActionButton {
                    label: "+"
                    onClicked: root.createPlaylist()
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: "ONLINE"
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.topMargin: 10
                }

                Repeater {
                  model: [
                    { label: "Wallhaven", provider: "wallhaven" },
                    { label: "Live — MoeWalls", provider: "moewalls" }
                  ]

                  Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    height: 36
                    radius: Style.cornerRadius
                    color: root.view.section === "online" && root.view.provider === modelData.provider
                      ? root.rowHover : "transparent"
                    border.width: root.view.section === "online" && root.view.provider === modelData.provider ? 1 : 0
                    border.color: root.accent

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: 10
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: modelData.label
                      color: root.onScrim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setView("online", "", modelData.provider)
                    }
                  }
                }

                Item { Layout.fillHeight: true }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: {
                    var st = (root.engine && root.engine.status) || {}
                    if (!st.file) return "Nothing applied yet"
                    var base = String(st.file).split("/").pop().replace(/\.[^/.]+$/, "")
                    var src = st.playlist && st.playlist !== "" ? st.playlist : "Library"
                    if (st.paused) return "Paused • " + base + "\n" + src
                    var mins = Math.floor((st.nextInSec || 0) / 60)
                    var secs = (st.nextInSec || 0) % 60
                    return base + "\nnext in " + mins + "m " + secs + "s • " + src
                  }
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6
                  ActionButton { label: "Next"; onClicked: root.mutate(["next"], "") }
                  ActionButton {
                    label: {
                      var st = (root.engine && root.engine.status) || {}
                      return st.paused ? "Resume" : "Pause"
                    }
                    onClicked: root.mutate(["toggle"], "")
                  }
                }
              }
            }

            // ============ CENTER ============
            ColumnLayout {
              id: centerCol
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.leftMargin: 18
              Layout.rightMargin: 6
              Layout.topMargin: 16
              Layout.bottomMargin: 16
              spacing: 10

              RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                  textFormat: Text.PlainText
                  text: root.viewTitle().toUpperCase()
                  color: root.onScrim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }

                Text {
                  visible: root.view.section !== "online"
                  textFormat: Text.PlainText
                  text: root.filteredItems().length + " items"
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                ActionButton {
                  visible: root.view.section === "playlist"
                  label: root.activePlaylist() === root.view.name ? "Active ✓" : "Set active"
                  enabled: root.activePlaylist() !== root.view.name && !root.loading
                  onClicked: root.activateViewingPlaylist()
                }
                ActionButton {
                  visible: root.view.section === "playlist"
                  label: "Delete"
                  enabled: !root.loading
                  onClicked: root.deleteViewingPlaylist()
                }
                ActionButton {
                  visible: root.view.section !== "online"
                  label: root.selectMode ? "Done" : "Select"
                  onClicked: {
                    root.selectMode = !root.selectMode
                    root.marked = ({})
                    root.markedCount = 0
                  }
                }
              }

              // search (online) / filter (local) row
              RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                  Layout.fillWidth: true
                  height: 38
                  radius: Style.cornerRadius
                  color: root.softFill
                  border.width: centerInput.activeFocus ? 1 : 0
                  border.color: root.accent

                  TextInput {
                    id: centerInput
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.onScrim
                    selectionColor: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    text: root.view.section === "online" ? root.query : root.filterText
                    onTextChanged: {
                      if (root.view.section === "online") root.query = text
                      else root.filterText = text
                    }
                    Keys.onReturnPressed: {
                      if (root.view.section === "online") root.runSearch(false)
                    }
                    Keys.onEnterPressed: {
                      if (root.view.section === "online") root.runSearch(false)
                    }
                    Keys.onEscapePressed: root.dismiss()
                  }

                  Text {
                    visible: centerInput.displayText === ""
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.view.section === "online"
                      ? (root.view.provider === "moewalls" ? "Search live wallpapers… (e.g. frieren)" : "Search wallpapers… (e.g. mountains)")
                      : "Filter…"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                ActionButton {
                  visible: root.view.section === "online"
                  label: "Search"
                  primary: true
                  enabled: !root.loading
                  onClicked: root.runSearch(false)
                }
                ActionButton {
                  visible: root.view.section !== "online"
                  label: "Refresh"
                  enabled: !root.loading
                  onClicked: {
                    root.itemsSource = ""
                    root.runGrid()
                  }
                }
              }

              // selection action bar
              RowLayout {
                visible: root.selectMode
                Layout.fillWidth: true
                spacing: 8

                Text {
                  textFormat: Text.PlainText
                  text: root.markedCount + " selected"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  Layout.fillWidth: true
                }
                ActionButton {
                  label: "→ " + (root.addTarget !== "" ? root.addTarget : "playlist")
                  enabled: root.markedCount > 0 && root.playlists().length > 0 && !root.loading
                  onClicked: root.cycleAddTarget()
                }
                ActionButton {
                  label: "Add"
                  primary: true
                  enabled: root.markedCount > 0 && root.addTarget !== "" && !root.loading
                  onClicked: root.addMarked()
                }
              }

              // progress bar (the visible feedback while busy)
              ColumnLayout {
                visible: root.loading
                Layout.fillWidth: true
                spacing: 6

                Rectangle {
                  Layout.fillWidth: true
                  height: 6
                  radius: Style.cornerRadius
                  color: root.softFill

                  Rectangle {
                    id: progressSlide
                    width: 120
                    height: parent.height
                    radius: Style.cornerRadius
                    color: root.accent
                  }

                  SequentialAnimation on x {
                    running: root.loading
                    loops: Animation.Infinite
                    NumberAnimation {
                      from: 0
                      to: progressTrack.width - progressSlide.width
                      duration: 1100
                      easing.type: Easing.InOutSine
                    }
                    NumberAnimation {
                      from: progressTrack.width - progressSlide.width
                      to: 0
                      duration: 1100
                      easing.type: Easing.InOutSine
                    }
                  }

                  // anchor target for the animation math
                  Item { id: progressTrack; anchors.fill: parent }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: 8

                  Text {
                    textFormat: Text.PlainText
                    text: root.busyText + "  " + root.busyElapsed + "s"
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                  }
                  ActionButton {
                    label: "Cancel"
                    onClicked: root.cancelLoad()
                  }
                }
              }

              Flickable {
                id: gridScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: gridFlow.implicitHeight
                clip: true

                Grid {
                  id: gridFlow
                  width: parent.width
                  readonly property int cols: width > 560 ? 3 : 2
                  columns: gridFlow.cols
                  spacing: 12

                  Repeater {
                    model: root.filteredItems()

                    Item {
                    required property var modelData
                    required property int index
                    width: (gridFlow.width - (gridFlow.cols - 1) * gridFlow.spacing) / gridFlow.cols
                    height: width * 9 / 16 + 32

                      Rectangle {
                        anchors.fill: parent
                        radius: Style.cornerRadius
                        color: root.selectedKey === modelData.key
                          ? Util.alpha(root.accent, 0.22) : root.softFill
                        border.width: (root.selectedKey === modelData.key || modelData.current || root.marked[modelData.key]) ? 2 : 0
                        border.color: root.marked[modelData.key] ? root.markedColor : root.accent

                        Image {
                          anchors.top: parent.top
                          anchors.left: parent.left
                          anchors.right: parent.right
                          height: parent.height - 32
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
                          radius: Style.cornerRadius
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

                        Rectangle {
                          visible: root.marked[modelData.key] === true
                          anchors.top: parent.top
                          anchors.left: parent.left
                          anchors.margins: 6
                          width: 22
                          height: 22
                          radius: Style.cornerRadius
                          color: root.markedColor

                          Text {
                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: "✓"
                            color: root.cardBg
                            font.family: root.fontFamily
                            font.pixelSize: 13
                            font.bold: true
                          }
                        }

                        Rectangle {
                          visible: root.view.section === "playlist"
                          anchors.top: parent.top
                          anchors.left: parent.left
                          anchors.margins: 6
                          width: 22
                          height: 22
                          radius: Style.cornerRadius
                          color: Qt.rgba(0, 0, 0, 0.65)

                          Text {
                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: "×"
                            color: "white"
                            font.family: root.fontFamily
                            font.pixelSize: 14
                            font.bold: true
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: function(mouse) {
                              mouse.accepted = true
                              root.selectedKey = modelData.key
                              root.selectedItem = modelData
                              root.removeSelected()
                            }
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
                          onClicked: root.cellClicked(modelData)
                          onDoubleClicked: {
                            root.cellClicked(modelData)
                            root.applySelected()
                          }
                        }
                      }
                    }
                  }
                }
              }

              Text {
                visible: !root.loading && root.filteredItems().length === 0 && root.errorText === ""
                Layout.fillWidth: true
                Layout.fillHeight: true
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: root.view.section === "online"
                  ? "Search to browse. Results download on Apply."
                  : (root.view.section === "playlist"
                    ? "Empty playlist — use Select in Library to add some."
                    : "No wallpapers here yet.")
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
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

            // ============ PROPERTIES ============
            Rectangle {
              id: propsPanel
              Layout.preferredWidth: 240
              Layout.fillHeight: true
              color: root.insetFill

              Flickable {
                anchors.fill: parent
                anchors.margins: 14
                contentWidth: width
                contentHeight: propsCol.implicitHeight
                clip: true

                ColumnLayout {
                  id: propsCol
                  width: parent.width
                  spacing: 10

                  Text {
                    textFormat: Text.PlainText
                    text: "PREVIEW"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 150
                    radius: Style.cornerRadius
                    color: root.softFill

                    Image {
                      anchors.fill: parent
                      source: root.selectedItem && root.selectedItem.thumb ? "file://" + root.selectedItem.thumb : ""
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                      smooth: true
                    }
                    Text {
                      visible: !root.selectedItem
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: "Select a wallpaper"
                      color: root.onScrimFaint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    text: root.selectedItem ? (root.selectedItem.title || "") : ""
                    visible: root.selectedItem !== null
                    color: root.onScrim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.selectedItem
                      ? ((root.selectedItem.kind === "video" ? "Live video" : "Image")
                        + (root.view.section === "online" ? " • remote — downloads on Apply" : " • local"))
                      : "Click a wallpaper to preview it here.\nDouble-click (or Apply) to set it."
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  ActionButton {
                    label: "Apply wallpaper"
                    primary: true
                    enabled: root.selectedItem !== null && !root.loading
                    Layout.fillWidth: true
                    onClicked: root.applySelected()
                  }

                  Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: root.softFill
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "ROTATION"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    text: {
                      var vp = root.viewingPlaylist()
                      return vp ? ("Playlist: " + vp.name) : "Source: Library (all)"
                    }
                    color: root.onScrimDim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Stepper {
                    valueText: root.contextInterval() + " min"
                    onStepped: function(delta) { root.stepInterval(delta) }
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "per wallpaper"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    ActionButton {
                      label: "Shuffle"
                      primary: {
                        var vp = root.viewingPlaylist()
                        var m = vp ? vp.mode : ((root.engine.config || {}).mode || "shuffle")
                        return m !== "sequential"
                      }
                      onClicked: root.setMode("shuffle")
                    }
                    ActionButton {
                      label: "Order"
                      primary: {
                        var vp2 = root.viewingPlaylist()
                        var m2 = vp2 ? vp2.mode : ((root.engine.config || {}).mode || "shuffle")
                        return m2 === "sequential"
                      }
                      onClicked: root.setMode("sequential")
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    ActionButton { label: "Prev"; onClicked: root.mutate(["prev"], "") }
                    ActionButton { label: "Next"; primary: true; onClicked: root.mutate(["next"], "") }
                    ActionButton {
                      label: {
                        var st = (root.engine && root.engine.status) || {}
                        return st.paused ? "Resume" : "Pause"
                      }
                      onClicked: root.mutate(["toggle"], "")
                    }
                  }

                  Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: root.softFill
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    text: "Tip: fixed times go in ~/.config/omarchy/wallpaper-engine.json under \"schedules\"."
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  ActionButton {
                    label: "Close"
                    Layout.fillWidth: true
                    onClicked: root.dismiss()
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
