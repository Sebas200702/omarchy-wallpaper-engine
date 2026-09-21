import QtQuick
import QtQuick.Layouts
import QtMultimedia
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
  property int searchPage: 1
  property bool searchHasMore: true
  property int searchTotal: -1 // provider result total, -1 when unknown
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
  property string newScheduleTime: ""
  property string newSchedulePick: ""
  // key of the item whose Delete button is armed (second click within
  // confirmDeleteTimer's window actually deletes) — a lightweight inline
  // confirm instead of a modal, so one misclick can't delete a file.
  property string confirmDeleteKey: ""
  // ---- per-monitor pins (engine `monitors` JSON) ----
  property var monitors: ({ outputs: [], stale: [], imageFit: "crop", globalFile: null })
  // ---- live download progress (`download-status` JSON) ----
  property bool applyingOnline: false
  property var download: ({ active: false, downloaded: 0, total: null, percent: null })
  // ---- MoeWalls hover preview ----
  property string hoverKey: ""
  property string previewKey: ""
  property string previewPath: ""
  property var previewCache: ({})

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
    if (root.view.section === "favorites") return "Favorites"
    if (root.view.section === "online")
      return root.view.provider === "moewalls" ? "Live — MoeWalls" : "Wallhaven"
    return "Library"
  }

  function viewSourceTag() {
    if (root.view.section === "playlist") return "playlist:" + root.view.name
    if (root.view.section === "favorites") return "favorites"
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
  // panelRev lets us verify from the CLI which revision of this file the
  // running shell actually loaded (bump on every Panel.qml change).
  readonly property string panelRev: "2026-09-21-p23-uifix2"
  function debugState() {
    var pls = []
    try {
      var arr = root.playlists()
      for (var i = 0; i < arr.length; i++) pls.push(arr[i].name)
    } catch (e) {}
    return JSON.stringify({
      rev: root.panelRev,
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
    // Monitor pins load silently alongside (sidebar block fills in).
    var s = root.startBusy("Loading…")
    configProc.command = [root.script, "config-get"]
    configProc.tag = s
    configProc.mode = "get-boot"
    configProc.doneNotice = ""
    configProc.reloadGrid = false
    configProc.running = true
    root.loadMonitors()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    console.log("WE-PANEL close() called")
    root.serial += 1
    hoverTimer.stop()
    var procs = [gridProc, searchProc, applyProc, configProc, downloadProc, previewProc, monitorsProc, monitorActProc]
    for (var i = 0; i < procs.length; i++) {
      if (procs[i].running) procs[i].running = false
    }
    root.opened = false
    root.loading = false
    root.busyText = ""
    root.applyingOnline = false
    root.hoverKey = ""
    root.previewKey = ""
    root.previewPath = ""
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
    else close()
  }

  function cancelLoad() {
    root.serial += 1
    hoverTimer.stop()
    var procs = [gridProc, searchProc, applyProc, configProc, downloadProc, previewProc, monitorsProc, monitorActProc]
    for (var i = 0; i < procs.length; i++) {
      if (procs[i].running) procs[i].running = false
    }
    root.loading = false
    root.busyText = ""
    root.applyingOnline = false
    root.hoverKey = ""
    root.previewKey = ""
    root.previewPath = ""
    root.notice = "Cancelled"
  }

  function setView(section, name, provider) {
    // Switching source always starts from a clean slate: kill anything
    // in flight (its serial-guarded callbacks become no-ops), clear the
    // query + results, and never fire a default search — the grid stays
    // on its empty-state hint until the user types something.
    root.serial += 1
    hoverTimer.stop()
    var procs = [gridProc, searchProc, applyProc, downloadProc, previewProc, monitorActProc]
    for (var i = 0; i < procs.length; i++) {
      if (procs[i].running) procs[i].running = false
    }
    if (configProc.running) configProc.tag = root.serial
    root.loading = false
    root.busyText = ""
    root.applyingOnline = false
    root.hoverKey = ""
    root.previewKey = ""
    root.previewPath = ""
    root.view = ({ section: section, name: name || "", provider: provider || "" })
    root.errorText = ""
    root.notice = ""
    root.selectedKey = ""
    root.selectedItem = null
    root.selectMode = false
    root.marked = ({})
    root.markedCount = 0
    root.filterText = ""
    root.query = ""
    root.confirmDeleteKey = ""
    root.items = []
    root.itemsSource = ""
    root.searchPage = 1
    root.searchHasMore = true
    root.searchTotal = -1
    if (section !== "online") runGrid()
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
      ? "Loading playlist…" : root.view.section === "favorites"
      ? "Loading favorites…" : "Loading library…")
    var src = root.view.section === "playlist" ? root.view.name
      : root.view.section === "favorites" ? "__favorites__" : ""
    gridProc.command = [root.script, "grid-local", "150", src]
    gridProc.tag = s
    gridProc.wantSource = root.viewSourceTag()
    gridProc.running = true
  }

  // Online search never invents a query: an empty box clears the results
  // (back to the empty-state hint) instead of searching a default.
  function runSearch() {
    var q = root.query.trim()
    if (q === "") {
      root.serial += 1
      if (searchProc.running) searchProc.running = false
      root.loading = false
      root.busyText = ""
      root.items = []
      root.itemsSource = ""
      root.searchPage = 1
      root.searchHasMore = true
      root.searchTotal = -1
      root.notice = ""
      root.errorText = ""
      return
    }
    root.query = q
    root.searchPage = 1
    root.searchHasMore = true
    root.searchTotal = -1
    // Kill a still-running search before starting the new one so rapid
    // successive searches (debounce typing, page flips) can't pile up
    // background curl/ffprobe work — the serial tag already discards the
    // stale result, this also stops its network/CPU cost.
    if (searchProc.running) searchProc.running = false
    var s = root.startBusy("Searching " + root.view.provider + "…")
    root.notice = ""
    searchProc.command = [root.script, "grid-search", root.view.provider, q]
    searchProc.tag = s
    searchProc.wantSource = "online:" + root.view.provider + ":" + q
    searchProc.append = false
    searchProc.running = true
  }

  function loadMoreSearch() {
    if (root.loading || root.view.section !== "online" || !root.searchHasMore) return
    var q = root.query.trim()
    if (q === "") return
    var nextPage = root.searchPage + 1
    var s = root.startBusy("Loading more…")
    root.notice = ""
    searchProc.command = [root.script, "grid-search", root.view.provider, "--page=" + nextPage, q]
    searchProc.tag = s
    searchProc.wantSource = "online:" + root.view.provider + ":" + q
    searchProc.append = true
    searchProc.pendingPage = nextPage
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
    if (root.confirmDeleteKey !== "" && root.confirmDeleteKey !== item.key)
      root.confirmDeleteKey = ""
    root.selectedKey = item.key
    root.selectedItem = item
  }

  // Keyboard grid navigation: arrows move the selection (Up/Down by a full
  // row, using gridFlow's own column count so it stays correct whether the
  // window is showing 2 or 3 columns), Return/Enter applies it — the same
  // selection state a mouse click sets, so this is a thin wrapper around
  // cellClicked/applySelected rather than a second notion of "focus".
  function moveSelection(dx, dy) {
    if (root.selectMode || root.loading) return
    var items = root.filteredItems()
    if (items.length === 0) return
    var idx = -1
    if (root.selectedKey !== "") {
      for (var i = 0; i < items.length; i++) {
        if (items[i].key === root.selectedKey) { idx = i; break }
      }
    }
    if (idx === -1) {
      idx = 0
    } else if (dy !== 0) {
      idx += dy * Math.max(1, gridFlow.cols)
    } else {
      idx += dx
    }
    if (idx < 0) idx = 0
    if (idx > items.length - 1) idx = items.length - 1
    root.cellClicked(items[idx])
    root.scrollSelectionIntoView(idx)
  }

  function scrollSelectionIntoView(idx) {
    // Mirrors the grid cell sizing in the Grid delegate below (width/cols,
    // height: width * 9/16 + 32) to compute where row `idx` lands, since a
    // plain Grid+Flickable (not a GridView) has no positionViewAtIndex.
    var cols = Math.max(1, gridFlow.cols)
    if (gridFlow.width <= 0) return
    var cellW = (gridFlow.width - (cols - 1) * gridFlow.spacing) / cols
    var cellH = cellW * 9 / 16 + 32
    var row = Math.floor(idx / cols)
    var top = row * (cellH + gridFlow.spacing)
    var bottom = top + cellH
    if (top < gridScroll.contentY) gridScroll.contentY = Math.max(0, top)
    else if (bottom > gridScroll.contentY + gridScroll.height) gridScroll.contentY = bottom - gridScroll.height
  }

  function activateSelection() {
    if (root.selectMode || root.loading) return
    if (!root.selectedItem) {
      var items = root.filteredItems()
      if (items.length > 0) root.cellClicked(items[0])
      return
    }
    root.applySelected()
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
    var online = root.view.section === "online" || root.itemsSource.indexOf("online:") === 0
    var s = root.startBusy(online
      ? "Downloading full quality… (up to a minute for video)"
      : "Applying…")
    root.notice = ""
    root.applyingOnline = online
    root.download = ({ active: false, downloaded: 0, total: null, percent: null })
    if (online)
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

  // Delete permanently removes the file from disk — arm on first click
  // (button relabels to "Confirm delete?" for a few seconds), actually
  // delete on the second. Only offered for on-disk items (never "online"
  // search results, which aren't files yet).
  function requestDelete() {
    if (!root.selectedItem || root.loading || root.view.section === "online") return
    var key = root.selectedItem.key
    if (root.confirmDeleteKey === key) {
      confirmDeleteTimer.stop()
      root.confirmDeleteKey = ""
      root.selectedKey = ""
      root.selectedItem = null
      mutate(["delete-file", key], "Deleted", true)
    } else {
      root.confirmDeleteKey = key
      confirmDeleteTimer.restart()
    }
  }

  function toggleFavorite(item) {
    if (!item || root.loading || root.view.section === "online") return
    mutate(["favorite-toggle", item.key], "", true)
  }

  function shortBase(p) {
    if (!p) return ""
    var base = String(p).split("/").pop().replace(/\.[^/.]+$/, "")
    return base.length > 22 ? base.substring(0, 21) + "…" : base
  }

  function formatBytes(n) {
    if (n === null || n === undefined || !isFinite(Number(n))) return "?"
    n = Number(n)
    if (n < 1024) return Math.floor(n) + " B"
    if (n < 1048576) return (n / 1024).toFixed(1) + " KB"
    if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB"
    return (n / 1073741824).toFixed(2) + " GB"
  }

  function downloadText() {
    var d = root.download || {}
    var base = root.formatBytes(d.downloaded || 0)
    if (d.total) base += " / " + root.formatBytes(d.total)
    if (d.percent !== null && d.percent !== undefined) base += " · " + d.percent + "%"
    return base + " · " + root.busyElapsed + "s"
  }

  function cycleFitName(f) {
    if (f === "crop") return "fit"
    if (f === "fit") return "stretch"
    return "crop"
  }

  // ---- per-monitor pins ----
  function loadMonitors() {
    var s = ++root.serial
    monitorsProc.tag = s
    monitorsProc.command = [root.script, "monitors"]
    monitorsProc.running = true
  }

  function monitorAction(args, silent) {
    var s = silent ? ++root.serial : root.startBusy("Saving…")
    monitorActProc.tag = s
    monitorActProc.command = [root.script].concat(args)
    monitorActProc.running = true
  }

  // ---- live download progress ----
  function pollDownload() {
    if (!downloadProc.running) downloadProc.running = true
  }

  // ---- MoeWalls hover preview ----
  function requestPreview(key) {
    root.hoverKey = key || ""
    if (!root.hoverKey) {
      root.previewKey = ""
      root.previewPath = ""
      return
    }
    if (root.previewCache[root.hoverKey]) {
      root.previewKey = root.hoverKey
      root.previewPath = root.previewCache[root.hoverKey]
      return
    }
    root.previewKey = ""
    root.previewPath = ""
    if (previewProc.running) previewProc.running = false
    previewProc.wantKey = root.hoverKey
    previewProc.command = [root.script, "preview-fetch", root.hoverKey]
    previewProc.running = true
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

  // ---- Playback settings (config-backed, wallpaper-engine.sh validates) ----
  // Defaults mirror Service.qml initial properties: battery=false (videos
  // keep playing unplugged), idle=true + 120s, videos muted.
  function playbackCfg() {
    var c = root.engine.config || {}
    return {
      pauseOnBattery: c.pauseOnBattery === true,
      pauseWhenIdle: c.pauseWhenIdle !== false,
      idleSecs: (c.idlePauseSeconds >= 10) ? c.idlePauseSeconds : 120,
      muted: c.muteVideos !== false
    }
  }

  function togglePauseOnBattery() {
    root.setGlobal("pauseOnBattery", String(!root.playbackCfg().pauseOnBattery))
  }

  function togglePauseWhenIdle() {
    root.setGlobal("pauseWhenIdle", String(!root.playbackCfg().pauseWhenIdle))
  }

  function stepIdleSeconds(delta) {
    var cur = parseInt(root.playbackCfg().idleSecs, 10) || 120
    var next = cur + delta * 30
    if (next < 10) next = 10
    if (next > 3600) next = 3600
    root.setGlobal("idlePauseSeconds", String(next))
  }

  function toggleMute() {
    root.setGlobal("muteVideos", String(!root.playbackCfg().muted))
  }

  // ---- Wallhaven filters (config-backed, wallpaper-engine.sh validates) ----
  function wallhavenCfg() {
    var c = root.engine.config || {}
    return c.wallhaven || {}
  }

  function cycleWallhavenSorting() {
    var order = ["random", "toplist", "date_added", "relevance", "views", "favorites"]
    var idx = order.indexOf(root.wallhavenCfg().sorting || "random")
    root.setGlobal("wallhaven.sorting", order[(idx + 1) % order.length])
  }

  function cycleWallhavenPurity() {
    var order = ["100", "110", "111"]
    var idx = order.indexOf(root.wallhavenCfg().purity || "100")
    if (idx === -1) idx = 0
    root.setGlobal("wallhaven.purity", order[(idx + 1) % order.length])
  }

  function cycleWallhavenResolution() {
    var order = ["", "1920x1080", "2560x1440", "3840x2160"]
    var idx = order.indexOf(root.wallhavenCfg().atleast || "")
    if (idx === -1) idx = 0
    root.setGlobal("wallhaven.atleast", order[(idx + 1) % order.length])
  }

  function toggleWallhavenCategory(pos) {
    var cats = root.wallhavenCfg().categories || "111"
    if (cats.length !== 3) cats = "111"
    var arr = cats.split("")
    arr[pos] = arr[pos] === "1" ? "0" : "1"
    var next = arr.join("")
    if (next === "000") return // Wallhaven requires at least one category
    root.setGlobal("wallhaven.categories", next)
  }

  function wallhavenPurityLabel() {
    var p = root.wallhavenCfg().purity || "100"
    if (p === "100") return "Purity: SFW"
    if (p === "110") return "Purity: SFW+Sketchy"
    return "Purity: All"
  }

  function wallhavenSortingLabel() {
    var s = root.wallhavenCfg().sorting || "random"
    var names = { date_added: "Newest", relevance: "Relevance", random: "Random", views: "Views", favorites: "Favorites", toplist: "Top" }
    return "Sort: " + (names[s] || s)
  }

  function wallhavenResolutionLabel() {
    var a = root.wallhavenCfg().atleast || ""
    return a === "" ? "Any resolution" : ("≥ " + a)
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

  function createSchedule() {
    var t = root.newScheduleTime.trim()
    var p = root.newSchedulePick.trim()
    if (t === "" || p === "") { root.errorText = "Enter a time (HH:MM) and a filename"; return }
    root.newScheduleTime = ""
    root.newSchedulePick = ""
    mutate(["schedule-add", t, p], "Schedule added: " + t)
  }

  function removeSchedule(time, pick) {
    mutate(["schedule-remove", time, pick], "Schedule removed")
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
    property bool danger: false
    // dense: sidebar rows where three fixed-width buttons share ~208px —
    // normal padding would overflow the column (measured 270px in 256px).
    property bool dense: false
    height: actBtn.dense ? 30 : 34
    width: Math.max(actBtn.dense ? 44 : 58, actLabel.implicitWidth + (actBtn.dense ? 12 : 20))
    radius: Style.cornerRadius
    color: !actBtn.enabled ? Util.alpha(root.onScrim, 0.06)
      : actBtn.danger ? root.onScrimUrgent
      : actBtn.primary ? root.accent : root.softFill
    opacity: !actBtn.enabled ? 0.5 : 1.0
    signal clicked

    Text {
      id: actLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: actBtn.label
      color: (actBtn.primary || actBtn.danger) ? root.cardBg : root.onScrim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: actBtn.primary || actBtn.danger
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
    property bool append: false
    property int pendingPage: 1
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (searchProc.tag !== root.serial || !root.opened) return
        root.loading = false
        root.busyText = ""
        var payload = null
        try { payload = JSON.parse(String(text || "")) } catch (e) { payload = null }
        // Backend envelope: {items, total, page, pageSize, hasMore}. A bare
        // array is still accepted (older backend / fallback path).
        var arr = null
        var metaTotal = -1
        var metaHasMore = null
        if (Array.isArray(payload)) {
          arr = payload
        } else if (payload && Array.isArray(payload.items)) {
          arr = payload.items
          if (typeof payload.total === "number" && payload.total >= 0) metaTotal = payload.total
          if (typeof payload.hasMore === "boolean") metaHasMore = payload.hasMore
        }
        if (arr !== null && arr.length > 0) {
          if (searchProc.append && root.itemsSource === searchProc.wantSource) {
            var seen = {}
            var i
            for (i = 0; i < root.items.length; i++) seen[root.items[i].key] = true
            var merged = root.items.slice()
            var added = 0
            for (i = 0; i < arr.length; i++) {
              if (!seen[arr[i].key]) { merged.push(arr[i]); added++ }
            }
            root.items = merged
            root.searchPage = searchProc.pendingPage
            if (added === 0) root.searchHasMore = false
            else if (metaHasMore !== null) root.searchHasMore = metaHasMore
            if (metaTotal >= 0) {
              root.searchTotal = metaTotal
              root.notice = merged.length + " of " + metaTotal + " shown — select one, then Apply"
            } else {
              root.searchTotal = -1
              root.notice = merged.length + " results — select one, then Apply"
            }
          } else {
            root.parseItems(JSON.stringify(arr), searchProc.wantSource)
            root.searchPage = 1
            if (metaHasMore !== null) root.searchHasMore = metaHasMore
            else root.searchHasMore = true
            if (metaTotal >= 0) {
              root.searchTotal = metaTotal
              root.notice = arr.length + " of " + metaTotal + " — select one, then Apply"
            } else {
              root.searchTotal = -1
              root.notice = arr.length + " results — select one, then Apply"
            }
          }
        } else if (arr !== null) {
          if (searchProc.append) {
            root.searchHasMore = false
            root.notice = root.items.length + " shown — no more"
          } else {
            root.items = []
            root.itemsSource = searchProc.wantSource
            root.searchHasMore = false
            root.searchTotal = metaTotal
            root.notice = ""
            root.errorText = "No results. Try another search."
          }
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
      root.applyingOnline = false
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

  // Live download progress: polled from the engine while apply-key runs.
  Process {
    id: downloadProc
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.opened || !root.applyingOnline) return
        var d = null
        try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
        if (d && typeof d === "object") root.download = d
      }
    }
  }

  // MoeWalls hover preview: resolves a cached/streamable preview webm.
  Process {
    id: previewProc
    property string wantKey: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.opened || previewProc.wantKey === "" || previewProc.wantKey !== root.hoverKey) return
        var p = String(text || "").trim()
        if (p !== "" && p.charAt(0) === "/" && p.indexOf("\n") === -1) {
          var next = {}
          for (var k in root.previewCache) next[k] = root.previewCache[k]
          next[previewProc.wantKey] = p
          root.previewCache = next
          if (root.hoverKey === previewProc.wantKey) {
            root.previewKey = previewProc.wantKey
            root.previewPath = p
          }
        }
      }
    }
  }

  // Per-monitor pins + global fit mode.
  Process {
    id: monitorsProc
    property int tag: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (monitorsProc.tag !== root.serial || !root.opened) return
        var d = null
        try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
        if (d && Array.isArray(d.outputs)) root.monitors = d
      }
    }
  }

  Process {
    id: monitorActProc
    property int tag: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (monitorActProc.tag !== root.serial || !root.opened) return
        var d = null
        try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
        // monitor-set/clear/fit answer with fresh monitors JSON; config-set
        // (imageFit) answers with config-get instead → just reload pins.
        if (d && Array.isArray(d.outputs)) root.monitors = d
        else root.loadMonitors()
      }
    }
    onExited: function(code) {
      if (monitorActProc.tag !== root.serial || !root.opened) return
      root.loading = false
      root.busyText = ""
      if (code === 0) {
        root.errorText = ""
        loadConfigSilent()
      } else if (root.errorText === "") {
        root.errorText = "Monitor action failed"
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
            // Boot continues into the grid for the current view — except
            // online views, which deliberately start empty (no default
            // search) until the user types something.
            if (root.view.section === "online") {
              root.loading = false
              root.busyText = ""
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

  // Live download progress while an online Apply is in flight.
  Timer {
    id: downloadPoller
    interval: 500
    repeat: true
    running: root.opened && root.applyingOnline && applyProc.running
    onTriggered: root.pollDownload()
  }

  // Hover preview debounce: wait until the cursor settles on a cell.
  Timer {
    id: hoverTimer
    interval: 350
    repeat: false
    property string wantKey: ""
    onTriggered: {
      if (root.opened) root.requestPreview(hoverTimer.wantKey)
    }
  }

  Timer {
    id: watchdog
    interval: 180000
    repeat: false
    running: root.opened && root.loading
    onTriggered: {
      gridProc.running = false
      searchProc.running = false
      applyProc.running = false
      root.serial += 1
      root.loading = false
      root.busyText = ""
      if (root.errorText === "") root.errorText = "Timed out — check your connection and retry"
    }
  }

  Timer {
    id: confirmDeleteTimer
    interval: 4000
    repeat: false
    onTriggered: root.confirmDeleteKey = ""
  }

  // Live online search: typing pauses 700ms before searching, so results
  // feel dynamic without firing one network search per keystroke. Clearing
  // the box clears the results (runSearch's empty path); the itemsSource
  // guard makes the post-search echo of root.query (see centerInput) a
  // no-op instead of a second search.
  Timer {
    id: searchDebounce
    interval: 700
    repeat: false
    onTriggered: {
      if (!root.opened || root.view.section !== "online") return
      var q = root.query.trim()
      if (q === "") { root.runSearch(); return }
      if (q.length < 2) return
      if (root.itemsSource === "online:" + root.view.provider + ":" + q) return
      root.runSearch()
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
      Keys.onLeftPressed: root.moveSelection(-1, 0)
      Keys.onRightPressed: root.moveSelection(1, 0)
      Keys.onUpPressed: root.moveSelection(0, -1)
      Keys.onDownPressed: root.moveSelection(0, 1)
      Keys.onReturnPressed: root.activateSelection()
      Keys.onEnterPressed: root.activateSelection()

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
            // 236 logical px: the monitors block needs ~200 for its
            // [Use current][fit][x] row (fixed-width buttons don't shrink),
            // center keeps 604 (grid stays 3-col). clip contains any future
            // fixed-width row instead of painting over the center column.
            Rectangle {
              id: sidePanel
              Layout.preferredWidth: 236
              Layout.fillHeight: true
              color: root.insetFill
              radius: Style.cornerRadius
              clip: true

              ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 3

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
                  model: [
                    { label: "All wallpapers", section: "lib", name: "", count: -1 },
                    { label: "★ Favorites", section: "favorites", name: "", count: -1 }
                  ]

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
                  text: "SCHEDULES"
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.topMargin: 10
                }

                Repeater {
                  model: (root.engine.config && root.engine.config.schedules) || []

                  RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 4

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.time
                      color: root.onScrim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.pick
                      color: root.onScrimFaint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    ActionButton {
                      label: "×"
                      enabled: !root.loading
                      onClicked: root.removeSchedule(modelData.time, modelData.pick)
                    }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: 4

                  Rectangle {
                    Layout.preferredWidth: 56
                    height: 30
                    radius: Style.cornerRadius
                    color: root.softFill

                    TextInput {
                      id: newScheduleTimeInput
                      anchors.fill: parent
                      anchors.leftMargin: 8
                      verticalAlignment: TextInput.AlignVCenter
                      color: root.onScrim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      text: root.newScheduleTime
                      onTextChanged: root.newScheduleTime = text
                      Keys.onReturnPressed: root.createSchedule()
                      Keys.onEnterPressed: root.createSchedule()
                    }
                    Text {
                      visible: newScheduleTimeInput.displayText === ""
                      anchors.left: parent.left
                      anchors.leftMargin: 8
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: "HH:MM"
                      color: root.onScrimFaint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                  Rectangle {
                    Layout.fillWidth: true
                    height: 30
                    radius: Style.cornerRadius
                    color: root.softFill

                    TextInput {
                      id: newSchedulePickInput
                      anchors.fill: parent
                      anchors.leftMargin: 8
                      anchors.rightMargin: 8
                      verticalAlignment: TextInput.AlignVCenter
                      color: root.onScrim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      text: root.newSchedulePick
                      onTextChanged: root.newSchedulePick = text
                      Keys.onReturnPressed: root.createSchedule()
                      Keys.onEnterPressed: root.createSchedule()
                    }
                    Text {
                      visible: newSchedulePickInput.displayText === ""
                      anchors.left: parent.left
                      anchors.leftMargin: 8
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: "filename…"
                      color: root.onScrimFaint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                  ActionButton {
                    label: "+"
                    enabled: !root.loading
                    onClicked: root.createSchedule()
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

                Text {
                  textFormat: Text.PlainText
                  text: "MONITORS"
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.topMargin: 10
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: "Pin one wallpaper per output — sticky over rotation."
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Repeater {
                  model: (root.monitors && root.monitors.outputs) || []

                  ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: 6

                      Text {
                        textFormat: Text.PlainText
                        text: modelData.name + (modelData.connected === false ? " (off)" : "")
                        color: root.onScrim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: (modelData.width || 0) + "×" + (modelData.height || 0)
                        color: root.onScrimFaint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: modelData.file ? root.shortBase(modelData.file) : "Follows global"
                      color: root.onScrimFaint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: 4

                      ActionButton {
                        label: "Use current"
                        dense: true
                        enabled: !root.loading && !!(root.monitors && root.monitors.globalFile)
                        onClicked: root.monitorAction(["monitor-set", modelData.name, root.monitors.globalFile])
                      }
                      ActionButton {
                        label: modelData.fit || (root.monitors && root.monitors.imageFit) || "crop"
                        dense: true
                        enabled: !root.loading && !!modelData.file
                        onClicked: root.monitorAction(["monitor-fit", modelData.name, root.cycleFitName(modelData.fit || (root.monitors && root.monitors.imageFit) || "crop")])
                      }
                      ActionButton {
                        label: "✕"
                        dense: true
                        enabled: !root.loading && !!modelData.file
                        onClicked: root.monitorAction(["monitor-clear", modelData.name])
                      }
                    }
                  }
                }

                Repeater {
                  model: (root.monitors && root.monitors.stale) || []

                  RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 6

                    Text {
                      textFormat: Text.PlainText
                      text: "○ " + modelData.name + ": " + root.shortBase(modelData.file)
                      color: root.onScrimFaint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      Layout.fillWidth: true
                      elide: Text.ElideRight
                    }
                    ActionButton {
                      label: "✕"
                      enabled: !root.loading
                      onClicked: root.monitorAction(["monitor-clear", modelData.name])
                    }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6

                  Text {
                    textFormat: Text.PlainText
                    text: "Default fit"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    Layout.fillWidth: true
                  }
                  ActionButton {
                    label: (root.monitors && root.monitors.imageFit) || "crop"
                    dense: true
                    enabled: !root.loading
                    onClicked: root.monitorAction(["config-set", "imageFit", root.cycleFitName((root.monitors && root.monitors.imageFit) || "crop")])
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
                      if (root.view.section === "online") {
                        root.query = text
                        searchDebounce.restart()
                      } else root.filterText = text
                    }
                    Keys.onReturnPressed: {
                      if (root.view.section === "online") root.runSearch()
                    }
                    Keys.onEnterPressed: {
                      if (root.view.section === "online") root.runSearch()
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
                  onClicked: root.runSearch()
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

              // Wallhaven filters — config-backed (wallpaper-engine.sh
              // validates every value), takes effect on the next search.
              RowLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: root.view.section === "online" && root.view.provider === "wallhaven"

                ActionButton {
                  label: root.wallhavenPurityLabel()
                  enabled: !root.loading
                  onClicked: root.cycleWallhavenPurity()
                }
                ActionButton {
                  label: root.wallhavenSortingLabel()
                  enabled: !root.loading
                  onClicked: root.cycleWallhavenSorting()
                }
                ActionButton {
                  label: root.wallhavenResolutionLabel()
                  enabled: !root.loading
                  onClicked: root.cycleWallhavenResolution()
                }
                Item { Layout.fillWidth: true }
                ActionButton {
                  label: "General"
                  primary: (root.wallhavenCfg().categories || "111").charAt(0) === "1"
                  enabled: !root.loading
                  onClicked: root.toggleWallhavenCategory(0)
                }
                ActionButton {
                  label: "Anime"
                  primary: (root.wallhavenCfg().categories || "111").charAt(1) === "1"
                  enabled: !root.loading
                  onClicked: root.toggleWallhavenCategory(1)
                }
                ActionButton {
                  label: "People"
                  primary: (root.wallhavenCfg().categories || "111").charAt(2) === "1"
                  enabled: !root.loading
                  onClicked: root.toggleWallhavenCategory(2)
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
                    text: root.applyingOnline && applyProc.running ? root.busyText : root.busyText + "  " + root.busyElapsed + "s"
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

                // Determinate download progress while an online Apply runs
                // (percent from `download-status`; unknown totals show an
                // indeterminate bar with live MB instead of a fake number).
                ColumnLayout {
                  visible: root.applyingOnline && applyProc.running
                  Layout.fillWidth: true
                  spacing: 4

                  Rectangle {
                    Layout.fillWidth: true
                    height: 6
                    radius: 3
                    color: root.softFill

                    Rectangle {
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      anchors.left: parent.left
                      width: {
                        var d = root.download || {}
                        if (d.percent === null || d.percent === undefined) return parent.width
                        var f = Number(d.percent) / 100
                        if (!isFinite(f) || f < 0) f = 0
                        if (f > 1) f = 1
                        return parent.width * f
                      }
                      opacity: {
                        var d2 = root.download || {}
                        return (d2.percent === null || d2.percent === undefined) ? 0.35 : 1
                      }
                      radius: 3
                      color: root.accent
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.downloadText()
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    Layout.fillWidth: true
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

                        // MoeWalls hover preview: settling the cursor on a
                        // LIVE cell fetches the small preview webm
                        // (cached) and plays it over the thumbnail —
                        // nothing downloads until Apply.
                        MediaPlayer {
                          id: cellPreviewPlayer
                          autoPlay: true
                          loops: MediaPlayer.Infinite
                          videoOutput: cellPreviewOut
                          audioOutput: AudioOutput { muted: true }
                          source: (root.previewKey === modelData.key && root.previewPath !== "")
                            ? "file://" + root.previewPath : ""
                        }

                        VideoOutput {
                          id: cellPreviewOut
                          anchors.top: parent.top
                          anchors.left: parent.left
                          anchors.right: parent.right
                          height: parent.height - 32
                          fillMode: VideoOutput.PreserveAspectCrop
                          visible: root.previewKey === modelData.key && root.previewPath !== ""
                        }

                        HoverHandler {
                          id: cellHover
                          onHoveredChanged: {
                            if (!cellHover.hovered) {
                              if (hoverTimer.running && hoverTimer.wantKey === modelData.key) hoverTimer.stop()
                              if (root.hoverKey === modelData.key) root.requestPreview("")
                            } else if (modelData.preview) {
                              hoverTimer.wantKey = modelData.key
                              hoverTimer.restart()
                            }
                          }
                        }

                        Rectangle {
                          id: liveBadge
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
                          visible: root.view.section !== "online"
                          anchors.top: parent.top
                          anchors.right: liveBadge.visible ? liveBadge.left : parent.right
                          anchors.topMargin: 6
                          anchors.rightMargin: 6
                          width: 22
                          height: 22
                          radius: Style.cornerRadius
                          color: Qt.rgba(0, 0, 0, 0.65)

                          Text {
                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: modelData.favorite ? "★" : "☆"
                            color: modelData.favorite ? "#ffd54a" : "white"
                            font.family: root.fontFamily
                            font.pixelSize: 13
                            font.bold: true
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: function(mouse) {
                              mouse.accepted = true
                              root.toggleFavorite(modelData)
                            }
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

              ActionButton {
                visible: root.view.section === "online" && root.items.length > 0 && root.searchHasMore
                label: root.searchTotal >= 0
                  ? ("More (" + root.items.length + " of " + root.searchTotal + ")")
                  : "Load more"
                enabled: !root.loading
                Layout.alignment: Qt.AlignHCenter
                onClicked: root.loadMoreSearch()
              }

              Text {
                visible: !root.loading && root.filteredItems().length === 0 && root.errorText === ""
                Layout.fillWidth: true
                Layout.fillHeight: true
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: root.view.section === "online"
                  ? (root.view.provider === "moewalls"
                    ? "Search to browse. Hover a LIVE result to preview — Apply downloads."
                    : "Search to browse. Results download on Apply.")
                  : (root.view.section === "playlist"
                    ? "Empty playlist — use Select in Library to add some."
                    : root.view.section === "favorites"
                    ? "No favorites yet — click the star on a wallpaper to add it here."
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
                id: propsFlick
                anchors.fill: parent
                anchors.margins: 14
                contentWidth: width
                contentHeight: propsCol.implicitHeight
                clip: true

                // Wheel scroll for desktop: Flickable drag-scrolls by
                // default, but a 660px card with a long inspector needs
                // the wheel too, or the bottom is silently unreachable.
                WheelHandler {
                  onWheel: function(e) {
                    var maxY = Math.max(0, propsFlick.contentHeight - propsFlick.height)
                    var ny = propsFlick.contentY - e.angleDelta.y
                    propsFlick.contentY = Math.max(0, Math.min(maxY, ny))
                    e.accepted = true
                  }
                }

                ColumnLayout {
                  id: propsCol
                  width: parent.width
                  spacing: 8

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
                    Layout.preferredHeight: 132
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
                    wrapMode: Text.Wrap
                    text: root.selectedItem
                      ? ((root.selectedItem.kind === "video" ? "Live video" : "Image")
                        + (root.view.section === "online" ? " • remote — downloads on Apply" : " • local"))
                      : "Click a wallpaper to preview it here.\nDouble-click (or Apply) to set it."
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    visible: !!(root.selectedItem && root.selectedItem.attribution)
                    text: {
                      var a = root.selectedItem && root.selectedItem.attribution
                      if (!a) return ""
                      var src = a.provider === "moewalls" ? "MoeWalls" : a.provider === "wallhaven" ? "Wallhaven" : a.provider
                      return "From " + src + (a.sourceUrl ? "\n" + a.sourceUrl : "")
                    }
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  ActionButton {
                    label: "Apply wallpaper"
                    primary: true
                    enabled: root.selectedItem !== null && !root.loading
                    Layout.fillWidth: true
                    onClicked: root.applySelected()
                  }

                  ActionButton {
                    visible: root.selectedItem !== null && root.view.section !== "online"
                    label: (root.selectedItem && root.selectedItem.favorite) ? "★ Unfavorite" : "☆ Favorite"
                    primary: !!(root.selectedItem && root.selectedItem.favorite)
                    enabled: !root.loading
                    Layout.fillWidth: true
                    onClicked: root.toggleFavorite(root.selectedItem)
                  }

                  ActionButton {
                    visible: root.selectedItem !== null && root.view.section !== "online"
                    label: root.confirmDeleteKey === (root.selectedItem ? root.selectedItem.key : "") ? "Confirm delete?" : "Delete from disk"
                    danger: root.confirmDeleteKey === (root.selectedItem ? root.selectedItem.key : "")
                    enabled: !root.loading
                    Layout.fillWidth: true
                    onClicked: root.requestDelete()
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
                    textFormat: Text.PlainText
                    text: "PLAYBACK"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    text: "Video pauses without stopping rotation."
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  ActionButton {
                    label: (root.playbackCfg().pauseOnBattery ? "✓ " : "") + "Pause on battery"
                    primary: root.playbackCfg().pauseOnBattery
                    enabled: !root.loading
                    Layout.fillWidth: true
                    onClicked: root.togglePauseOnBattery()
                  }

                  ActionButton {
                    label: (root.playbackCfg().pauseWhenIdle ? "✓ " : "") + "Pause when idle"
                    primary: root.playbackCfg().pauseWhenIdle
                    enabled: !root.loading
                    Layout.fillWidth: true
                    onClicked: root.togglePauseWhenIdle()
                  }

                  Stepper {
                    valueText: "idle " + root.playbackCfg().idleSecs + "s"
                    onStepped: function(delta) { root.stepIdleSeconds(delta) }
                  }

                  ActionButton {
                    label: (root.playbackCfg().muted ? "✓ " : "") + "Mute videos"
                    primary: root.playbackCfg().muted
                    enabled: !root.loading
                    Layout.fillWidth: true
                    onClicked: root.toggleMute()
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
