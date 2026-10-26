import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "icons/paths.js" as IconPaths

// WallHub gallery: top bar with menus (playlists, settings), center grid
// with search feedback, bottom action bar and a full-card preview.
// Summoned with: omarchy-shell shell summon io.github.sebas200702.wallhub
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  // view: {section: "lib" | "playlist" | "online", name: playlistName, provider: wallhaven|moewalls|steam}
  property var view: ({ section: "lib", name: "", provider: "" })
  property var items: []
  property string itemsSource: "" // lib | playlist:<name> | online:<provider>:<query>
  property string query: ""
  property string filterText: ""
  property string kindFilter: "all" // all | video | image | fav
  property string layoutMode: "grid" // grid | list
  property bool previewOpen: false   // full-card preview overlay
  property bool propsOpen: false     // scene properties drawer inside the preview
  property var sceneProps: []        // workshop-properties result for propsId
  property string propsId: ""
  property bool propsLoading: false
  property var doctorRows: []        // doctor --json, loaded with the Ajustes menu
  // Top-bar dropdown currently open: "" | "playlists" | "settings".
  // Configuration lives in these menus; there are no side panels.
  property string openMenu: ""
  onOpenMenuChanged: {
    if (root.openMenu === "settings" && root.opened) { root.loadMonitors(); root.loadDoctor() }
    if (root.openMenu === "") keyCatcher.forceActiveFocus()
  }
  // Wallhaven filter row starts expanded (discoverable) but collapses to
  // a single toggle so the search box + grid reclaim the center column.
  property bool filtersOpen: true
  property int searchPage: 1
  property bool searchHasMore: true
  property int searchTotal: -1 // provider result total, -1 when unknown
  // Steam sign-in (one-time panel form): hides itself once the engine has
  // a cached steamUser; the login child gets creds via env, never argv.
  property bool steamBusy: false
  readonly property bool steamSignedIn: !!(root.engine.config && root.engine.config.steamUser)
  property bool loading: false
  property string busyText: ""
  property int busySince: 0
  property int busyElapsed: 0
  property string notice: ""
  property string errorText: ""
  property var engine: ({ status: ({}), config: ({ intervalMinutes: 10, mode: "shuffle", playlists: [] }) })
  property int serial: 0
  // Background generation counter for silent side-loads (monitor pins,
  // silent config refreshes). These must NEVER bump `serial`: they share
  // no loading state with the foreground grid/search/apply flow, and
  // bumping the shared counter discards the in-flight foreground reply
  // (boot config-get, grid list), stranding `loading=true` forever.
  property int bgSerial: 0
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

  readonly property string pluginId: (manifest && manifest.id) || "io.github.sebas200702.wallhub"
  readonly property string script: decodeURIComponent(String(Qt.resolvedUrl("wallpaper-engine.sh")).replace(/^file:\/\//, ""))
  // AniDev palette (Design System 01 · Color): near-black tonal surfaces,
  // one brand-blue signal. Text pairs follow its contrast audit: body text
  // never sits on brand-600; filled buttons use brand-700, accent text
  // uses brand-300. Only the scrim still follows the Omarchy theme.
  readonly property color onScrim: "#f6f6f6"        // on-surface
  readonly property color onScrimDim: "#b0b0b0"     // on-surface-muted
  readonly property color onScrimFaint: "#888888"   // on-surface-subtle
  readonly property color onScrimUrgent: "#cd4631"  // danger
  readonly property color accent: "#1d6cff"         // brand-600: lines, rings, selection
  readonly property color accentText: "#a1c2ff"     // brand-300: accent as text
  readonly property color accentFill: "#1858cf"     // brand-700: filled buttons
  readonly property color accentFillHover: "#103c8d" // brand-800
  readonly property color markedColor: "#1d6cff"
  readonly property color cardBg: "#121212"         // surface
  readonly property color raisedBg: "#1c1c1c"       // surface-raised
  readonly property color overlayBg: "#242424"      // surface-overlay
  readonly property color cardBorder: "#3d3d3d"
  readonly property color rowHover: "#242424"
  readonly property color rowHoverText: "#f6f6f6"
  readonly property color scrimColor: Color.menu.scrim
  readonly property color softFill: "#1c1c1c"
  readonly property color insetFill: "#161616"
  readonly property color hoverFill: "#242424"
  readonly property color hairline: "#2c2c2c"
  readonly property color strongLine: "#454545"     // border
  // Two voices: Kode Mono (bundled, OFL) shouts — display, titles, badges;
  // the Omarchy mono labels everything else.
  readonly property string fontFamily: Style.font.family
  readonly property string displayFamily: kodeBold.status === FontLoader.Ready ? kodeBold.name : Style.font.family

  FontLoader { id: kodeRegular; source: Qt.resolvedUrl("fonts/KodeMono-Regular.ttf") }
  FontLoader { id: kodeMedium; source: Qt.resolvedUrl("fonts/KodeMono-Medium.ttf") }
  FontLoader { id: kodeBold; source: Qt.resolvedUrl("fonts/KodeMono-Bold.ttf") }

  // Lucide-shaped icons from icons/paths.js (AnimateIcons set), drawn by
  // AnimIcon with a hover animation per icon.
  readonly property var icons: ({
    search: "search", star: "star", starOff: "star", play: "play",
    pause: "pause", eye: "eye", close: "x", monitor: "monitor",
    rotate: "rotate-cw", refresh: "refresh-cw", chevronDown: "chevron-down", grid: "layout-grid",
    list: "list", check: "check", select: "square-check", sliders: "sliders-horizontal"
  })
  // Default hover motion per icon (see AnimIcon).
  readonly property var iconMotion: ({
    "play": "nudge", "eye": "blink", "star": "pop", "settings": "spin", "refresh-cw": "spin",
    "rotate-cw": "spin", "shuffle": "wiggle", "list-ordered": "nudge", "timer": "wiggle",
    "pause": "pop", "skip-forward": "nudge", "skip-back": "nudgeBack", "battery-charging": "pulse",
    "volume-x": "wiggle", "moon": "wiggle", "pin": "drop", "pin-off": "wiggle", "trash-2": "wiggle",
    "x": "spinQuarter", "sliders-horizontal": "nudge", "check": "pop", "search": "wiggle",
    "list": "nudge", "layout-grid": "pop", "square-check": "pop", "maximize": "pop", "crop": "pop",
    "expand": "pop", "scan": "pop", "chevron-down": "drop", "chevron-left": "nudgeBack",
    "chevron-right": "nudge", "monitor": "pop", "info": "pop", "clock": "spin",
    "sparkles": "pop", "globe": "spin", "lock": "wiggle", "circle-check": "pop", "circle-x": "wiggle",
    "triangle-alert": "wiggle", "stethoscope": "wiggle", "gauge": "spinQuarter", "rotate-ccw": "spin"
  })


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
    if (root.view.section === "workshop") return "Steam Workshop"
    if (root.view.section === "online") {
      if (root.view.provider === "moewalls") return "Live — MoeWalls"
      if (root.view.provider === "steam") return "Live — Steam"
      return "Wallhaven"
    }
    return "Library"
  }

  function viewSourceTag() {
    if (root.view.section === "playlist") return "playlist:" + root.view.name
    if (root.view.section === "favorites") return "favorites"
    if (root.view.section === "workshop") return "workshop"
    if (root.view.section === "online") return "online:" + root.view.provider + ":" + root.query
    return "lib"
  }

  function filteredItems() {
    var needle = root.filterText.trim().toLowerCase()
    var out = []
    for (var i = 0; i < root.items.length; i++) {
      var item = root.items[i]
      if (!item) continue
      if (root.kindFilter === "fav") { if (!item.favorite) continue }
      else if (root.kindFilter === "scene") { if (item.kind !== "scene" && item.kind !== "web") continue }
      else if (root.kindFilter !== "all" && item.kind !== root.kindFilter) continue
      var t = (root.displayName(item) + " " + root.sourceLabel(item)).toLowerCase()
      if (needle === "" || t.indexOf(needle) !== -1) out.push(item)
    }
    return out
  }

  // Chip counters run over the unfiltered list.
  function countWhere(kind) {
    var n = 0
    for (var i = 0; i < root.items.length; i++) {
      var it = root.items[i]
      if (!it) continue
      if (kind === "fav" ? it.favorite
          : kind === "scene" ? (it.kind === "scene" || it.kind === "web")
          : it.kind === kind) n++
    }
    return n
  }

  function titleCase(s) {
    return String(s).toLowerCase().replace(/(^|\s)(\S)/g, function(m, sp, c) { return sp + c.toUpperCase() })
  }

  // Human title for a card. Engine titles are often just the provider tag
  // ("moe") and filenames carry slugs + random suffixes
  // (moe-moe-anime-girl-cozy-rain-…-211-13153.mp4), so prefer the
  // attribution sidecar title, then a cleaned filename, then "Provider #id".
  function displayName(item) {
    if (!item) return ""
    var junk = /\s*[-–|]\s*(moewalls|wallhaven|steam( workshop)?|wallpaper engine)\s*$/i
    var a = item.attribution && item.attribution.title ? String(item.attribution.title) : ""
    a = a.replace(junk, "").replace(/\s+live wallpaper\s*$/i, "").trim()
    if (a !== "") return a
    var t = String(item.title || "").trim()
    if (t !== "" && !/^(moe|stm|steam|wallhaven|wh|moewalls)$/i.test(t) && !/^\d+$/.test(t)
        && t.indexOf("/") === -1) return t.replace(junk, "").replace(/\s+live wallpaper\s*$/i, "")
    var base = String(item.key || "").split("/").pop().replace(/\.[^.]+$/, "")
    var slug = base.replace(/^((moe|stm|wh)-)+/i, "")
      .replace(/(-\d+)+$/, "")
      .replace(/-?(live-wallpaper|moewalls|wallpaper)(?=-|$)/gi, "")
      .replace(/^\d+-/, "")
      .replace(/[-_]+/g, " ").trim()
    if (slug !== "" && !/^\d+$/.test(slug)) return root.titleCase(slug)
    var id = (base.match(/\d+/) || [""])[0]
    return root.sourceLabel(item) + (id ? " #" + id : "")
  }

  function providerOf(item) {
    if (!item) return ""
    if (item.attribution && item.attribution.provider) return item.attribution.provider
    if (item.provider) return item.provider
    var base = String(item.key || "").split("/").pop()
    if (/^moe-/i.test(base)) return "moewalls"
    if (/^stm-/i.test(base)) return "steam"
    if (/^wh-/i.test(base)) return "wallhaven"
    if (root.view.section === "online") return root.view.provider
    return ""
  }

  function sourceLabel(item) {
    var p = root.providerOf(item)
    return p === "moewalls" ? "MoeWalls" : p === "steam" ? "Steam" : p === "wallhaven" ? "Wallhaven"
      : p === "workshop" ? "Workshop" : "Local"
  }

  function pad2(n) { return n < 9 ? "0" + (n + 1) : String(n + 1) }

  function selectedIndex() {
    var arr = root.filteredItems()
    for (var i = 0; i < arr.length; i++) if (arr[i] && arr[i].key === root.selectedKey) return i
    return -1
  }

  function primaryOutput() {
    var outs = (root.monitors && root.monitors.outputs) || []
    for (var i = 0; i < outs.length; i++) if (outs[i].connected !== false) return outs[i]
    return outs.length > 0 ? outs[0] : null
  }

  // Center column width derived from the card (not from the layout being
  // arranged — binding children to centerCol.width loops the layout).
  readonly property real centerW: cardBox.width - 64
  readonly property bool wideHero: root.centerW >= 1250
  readonly property bool compactBar: root.centerW < 1000

  function kindLabel(item) {
    if (!item) return ""
    return item.kind === "video" ? "Animado" : item.kind === "scene" ? "Escena"
      : item.kind === "web" ? "Web" : item.kind === "other" ? "App" : "Estático"
  }

  function itemMeta(item) {
    if (!item) return ""
    return root.kindLabel(item) + "   ·   " + root.sourceLabel(item)
      + (root.view.section === "online" ? "   ·   se descarga al aplicar" : "")
      + (item.playable === false ? "   ·   " + root.blockedReason(item) : "")
  }

  // Why a Workshop item can't be applied (shown on cards and in the bar).
  function blockedReason(item) {
    if (!item || item.playable !== false) return ""
    return item.reason === "needs-lwe" ? "requiere linux-wallpaperengine" : "tipo no soportado"
  }

  readonly property bool isWorkshop: root.view.section === "workshop"
  // Actions that only make sense for wallpaper files on disk.
  readonly property bool fileActions: root.view.section !== "online" && !root.isWorkshop

  function isPinnedHere(item) {
    var o = root.primaryOutput()
    return !!(item && o && o.file && o.file === item.key)
  }

  // Pin / unpin the selected local wallpaper on the primary output.
  function togglePin(item) {
    var o = root.primaryOutput()
    if (!item || !o || !root.fileActions) return
    if (root.isPinnedHere(item)) root.monitorAction(["monitor-clear", o.name])
    else root.monitorAction(["monitor-set", o.name, item.key])
  }

  function openPreview() {
    if (!root.selectedItem) return
    root.openMenu = ""
    root.propsOpen = false
    root.previewOpen = true
    // Online live results stream their cached preview clip.
    if (root.view.section === "online" && root.selectedItem.preview) root.requestPreview(root.selectedItem.key)
  }

  function doctorStatus(id) {
    for (var i = 0; i < root.doctorRows.length; i++) if (root.doctorRows[i].id === id) return root.doctorRows[i].status
    return ""
  }

  function loadDoctor() {
    if (!doctorProc.running) doctorProc.running = true
  }

  function openProps() {
    if (!root.selectedItem || root.selectedItem.kind !== "scene") return
    root.propsId = String(root.selectedItem.workshopId)
    root.sceneProps = []
    root.propsLoading = true
    root.propsOpen = true
    propsProc.command = [root.script, "workshop-properties", root.propsId]
    propsProc.running = true
  }

  // Saves one override; the service restarts the scene if it is showing.
  function setSceneProp(name, value) {
    if (root.propsId === "" || value === undefined || value === null || String(value) === "") return
    var v = String(value)
    var next = []
    for (var i = 0; i < root.sceneProps.length; i++) {
      var p = root.sceneProps[i]
      if (p.name === name) p = Object.assign({}, p, { override: v })
      next.push(p)
    }
    root.sceneProps = next
    Quickshell.execDetached([root.script, "scene-prop-set", root.propsId, name, v])
  }

  function resetSceneProps() {
    if (root.propsId === "") return
    Quickshell.execDetached([root.script, "scene-prop-reset", root.propsId])
    var next = []
    for (var i = 0; i < root.sceneProps.length; i++) next.push(Object.assign({}, root.sceneProps[i], { override: null }))
    root.sceneProps = next
  }

  function propValue(p) {
    return p.override !== null && p.override !== undefined ? String(p.override) : String(p.value === null ? "" : p.value)
  }

  // "R: 0.14 G: 0.23 B: 0.4 A: 1" → Qt color.
  function propColor(p) {
    var m = /R:\s*([0-9.]+)\s*G:\s*([0-9.]+)\s*B:\s*([0-9.]+)/.exec(String(p.color || ""))
    return m ? Qt.rgba(parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3]), 1) : "transparent"
  }

  // Preview browsing: move the selection and keep the clip in sync.
  function previewStep(d) {
    root.propsOpen = false
    root.moveSelection(d, 0)
    if (root.view.section === "online" && root.selectedItem && root.selectedItem.preview)
      root.requestPreview(root.selectedItem.key)
  }

  function closeOverlays() {
    if (root.propsOpen) { root.propsOpen = false; return true }
    if (root.previewOpen) { root.previewOpen = false; return true }
    if (root.openMenu !== "") { root.openMenu = ""; return true }
    return false
  }

  function clearSelection() {
    root.selectedKey = ""
    root.selectedItem = null
  }

  // Headless diagnostic: omarchy-shell shell call io.github.sebas200702.wallhub debugState '{}'
  // panelRev lets us verify from the CLI which revision of this file the
  // running shell actually loaded (bump on every Panel.qml change).
  readonly property string panelRev: "2026-10-26-anidev-redesign"
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
        centerW: Math.round(centerCol.width),
        centerImp: Math.round(centerCol.implicitWidth),
        gridW: Math.round(gridFlow.width),
        gridImp: Math.round(gridFlow.implicitWidth)
      }
    })
  }

  // Headless UI toggles for screenshot checks:
  // omarchy-shell shell call io.github.sebas200702.wallhub debugUi '{"layout":"list","details":true}'
  function debugUi(json) {
    var o = {}
    try { o = JSON.parse(String(json || "{}")) || {} } catch (e) {}
    if (o.online) root.setView("online", "", String(o.online))
    if (typeof o.select === "number") {
      var arr = root.filteredItems()
      if (o.select >= 0 && o.select < arr.length) root.highlightCell(arr[o.select])
    }
    if (o.layout === "grid" || o.layout === "list") root.layoutMode = o.layout
    if (typeof o.menu === "string") root.openMenu = o.menu
    if (typeof o.preview === "boolean") { if (o.preview) root.openPreview(); else root.previewOpen = false }
    return root.debugState()
  }

  function open(payloadJson) {
    console.log("WE-PANEL open() called, already opened=" + root.opened)
    root.opened = true
    root.notice = ""
    root.errorText = ""
    root.selectedKey = ""
    root.selectedItem = null
    root.selectMode = false
    root.openMenu = ""
    root.kindFilter = "all"
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
    root.previewOpen = false
    root.openMenu = ""
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
    root.bgSerial += 1
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
    root.kindFilter = "all"
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
      ? "Loading favorites…" : root.isWorkshop ? "Leyendo Steam Workshop…" : "Loading library…")
    var src = root.view.section === "playlist" ? root.view.name
      : root.view.section === "favorites" ? "__favorites__" : ""
    gridProc.command = root.isWorkshop ? [root.script, "workshop-list"] : [root.script, "grid-local", "150", src]
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

  // Selection without side effects: mouse clicks in selectMode toggle the
  // mark AND move the highlight here; keyboard arrows move it via
  // moveSelection without toggling (Space toggles, Enter confirms).
  function highlightCell(item) {
    if (!item) return
    if (root.confirmDeleteKey !== "" && root.confirmDeleteKey !== item.key)
      root.confirmDeleteKey = ""
    root.selectedKey = item.key
    root.selectedItem = item
  }

  function cellClicked(item) {
    if (!item) return
    if (root.selectMode) toggleMark(item.key)
    root.highlightCell(item)
  }

  // Keyboard grid navigation: arrows move the selection (Up/Down by a full
  // row, using gridFlow's own column count so it stays correct whether the
  // window is showing 2 or 3 columns), Return/Enter applies it — the same
  // selection state a mouse click sets, so this is a thin wrapper around
  // cellClicked/applySelected rather than a second notion of "focus".
  function moveSelection(dx, dy) {
    if (root.loading) return
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
    // In selectMode arrows only move the highlight — toggling is Space's
    // job, otherwise every arrow press would (un)mark a wallpaper.
    if (root.selectMode) root.highlightCell(items[idx])
    else root.cellClicked(items[idx])
    root.scrollSelectionIntoView(idx)
  }

  function scrollSelectionIntoView(idx) {
    if (idx >= 0 && idx < gridFlow.count)
      gridFlow.positionViewAtIndex(idx, GridView.Contain)
  }

  function activateSelection() {
    if (root.loading) return
    // In selectMode Enter confirms the batch (or marks the highlighted
    // cell when nothing is marked yet) instead of applying the wallpaper.
    if (root.selectMode) {
      if (root.markedCount > 0) { root.addMarked(); return }
      if (root.selectedKey !== "") { root.toggleMark(root.selectedKey); return }
      var firstItems = root.filteredItems()
      if (firstItems.length > 0) root.highlightCell(firstItems[0])
      return
    }
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
    if (root.selectedItem.playable === false) {
      root.errorText = "No se puede aplicar: " + root.blockedReason(root.selectedItem) + " (ver Ajustes → Diagnóstico)"
      return
    }
    var online = root.view.section === "online" || root.itemsSource.indexOf("online:") === 0
    var s = root.startBusy(online
      ? "Downloading full quality… (up to a minute for video)"
      : "Applying…")
    root.notice = ""
    root.applyingOnline = online
    root.download = ({ active: false, downloaded: 0, total: null, percent: null })
    if (online)
      applyProc.command = [root.script, "apply-key", root.selectedItem.key]
    else if (root.isWorkshop)
      applyProc.command = [root.script, "workshop-apply", String(root.selectedItem.workshopId)]
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
    if (!root.selectedItem || root.loading || !root.fileActions) return
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
    if (!item || root.loading || !root.fileActions) return
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
  // Background fetch: tagged in the bgSerial domain so it can neither
  // invalidate nor be invalidated by the foreground loading flow.
  function loadMonitors() {
    var s = ++root.bgSerial
    monitorsProc.tag = s
    monitorsProc.command = [root.script, "monitors"]
    monitorsProc.running = true
  }

  function monitorAction(args, silent) {
    if (silent) {
      monitorActProc.isBackground = true
      monitorActProc.tag = ++root.bgSerial
      monitorActProc.command = [root.script].concat(args)
      monitorActProc.running = true
      return
    }
    monitorActProc.isBackground = false
    var s = root.startBusy("Saving…")
    monitorActProc.tag = s
    monitorActProc.command = [root.script].concat(args)
    monitorActProc.running = true
  }

  // ---- live download progress ----
  function pollDownload() {
    if (!downloadProc.running) downloadProc.running = true
  }

  // Connected outputs currently showing a pinned wallpaper instead of the
  // global one — surfaced after Apply so a stale pin never looks like a
  // broken set again (single-monitor setups hit this hardest: the pin wins
  // on the only screen, every global apply "does nothing").
  function pinnedOutputsText() {
    var outs = (root.monitors && root.monitors.outputs) || []
    var names = []
    for (var i = 0; i < outs.length; i++) {
      if (outs[i] && outs[i].connected !== false && outs[i].file) names.push(outs[i].name)
    }
    return names.join(", ")
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
    // Background refresh (post-apply/post-monitor): bgSerial domain, never
    // touches `loading`, so it can't strand or prematurely clear a
    // foreground spinner.
    configProc.command = [root.script, "config-get"]
    configProc.tag = ++root.bgSerial
    configProc.mode = "silent"
    configProc.clearBusy = false
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

  // Panel-side Steam sign-in: password + optional Guard code travel in the
  // child's environment (owner-only under /proc — argv would be world-
  // readable in ps), and steam_login feeds them to steamcmd's prompts.
  function steamSignIn() {
    if (root.steamBusy) return
    if (steamUserInput.text.trim() === "" || steamPassInput.text === "") return
    root.errorText = ""
    root.notice = ""
    root.steamBusy = true
    steamLoginProc.failMsg = ""
    steamLoginProc.environment = ({
      WE_STEAM_PASS: steamPassInput.text,
      WE_STEAM_CODE: steamGuardInput.text
    })
    steamLoginProc.command = [root.script, "steam-login", steamUserInput.text.trim()]
    steamLoginProc.running = true
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
    root.setContextInterval(cur + delta)
  }

  // Absolute set (presets row): one click instead of ~50 stepper taps to
  // go from 10 to 60 minutes.
  function setContextInterval(v) {
    var next = parseInt(v, 10) || 10
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
    // Same two-step arm as file delete: a whole curated list deserves at
    // least the protection a single file gets (previously instant).
    var armKey = "playlist:" + n
    if (root.confirmDeleteKey !== armKey) {
      root.confirmDeleteKey = armKey
      confirmDeleteTimer.restart()
      return
    }
    confirmDeleteTimer.stop()
    root.confirmDeleteKey = ""
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

  function markCurrentWorkshop(key) {
    var next = []
    for (var i = 0; i < root.items.length; i++) {
      var it = root.items[i]
      if (it) it.current = (it.key === key)
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

  // Lucide stroke icon (24-unit viewBox, 2px round strokes) that plays a
  // short motion on each hover-in, reimplementing AnimateIcons' motion.dev
  // variants with QML animations.
  component AnimIcon: Item {
    id: animIcon
    required property string name
    property color color: root.onScrim
    property real size: 20
    property bool hovered: false
    property bool filled: false
    property string motion: root.iconMotion[animIcon.name] || "pop"
    implicitWidth: animIcon.size
    implicitHeight: animIcon.size

    function play() {
      if (animIcon.motion === "spin") spinAnim.restart()
      else if (animIcon.motion === "spinQuarter") quarterAnim.restart()
      else if (animIcon.motion === "blink") blinkAnim.restart()
      else if (animIcon.motion === "nudge" || animIcon.motion === "nudgeBack") nudgeAnim.restart()
      else if (animIcon.motion === "wiggle") wiggleAnim.restart()
      else if (animIcon.motion === "drop") dropAnim.restart()
      else if (animIcon.motion === "pulse") pulseAnim.restart()
      else popAnim.restart()
    }
    onHoveredChanged: if (animIcon.hovered) animIcon.play()

    Item {
      id: motionLayer
      anchors.centerIn: parent
      width: animIcon.size
      height: animIcon.size
      transform: Scale { id: blinkScale; origin.x: animIcon.size / 2; origin.y: animIcon.size / 2 }

      Shape {
        anchors.centerIn: parent
        width: 24
        height: 24
        scale: animIcon.size / 24
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeColor: animIcon.color
          strokeWidth: 2
          fillColor: animIcon.filled ? animIcon.color : "transparent"
          capStyle: ShapePath.RoundCap
          joinStyle: ShapePath.RoundJoin
          PathSvg { path: IconPaths.paths[animIcon.name] || "" }
        }
      }
    }

    NumberAnimation { id: spinAnim; target: motionLayer; property: "rotation"; from: 0; to: 360; duration: 700; easing.type: Easing.InOutCubic }
    NumberAnimation { id: quarterAnim; target: motionLayer; property: "rotation"; from: 0; to: 90; duration: 320; easing.type: Easing.OutBack }
    SequentialAnimation {
      id: blinkAnim
      NumberAnimation { target: blinkScale; property: "yScale"; to: 0.15; duration: 140; easing.type: Easing.InQuad }
      NumberAnimation { target: blinkScale; property: "yScale"; to: 1; duration: 220; easing.type: Easing.OutQuad }
    }
    SequentialAnimation {
      id: nudgeAnim
      NumberAnimation { target: motionLayer; property: "x"; to: (animIcon.motion === "nudgeBack" ? -3 : 3) * animIcon.size / 24; duration: 140; easing.type: Easing.OutQuad }
      NumberAnimation { target: motionLayer; property: "x"; to: 0; duration: 260; easing.type: Easing.OutBack }
    }
    SequentialAnimation {
      id: wiggleAnim
      NumberAnimation { target: motionLayer; property: "rotation"; to: -14; duration: 90 }
      NumberAnimation { target: motionLayer; property: "rotation"; to: 12; duration: 120 }
      NumberAnimation { target: motionLayer; property: "rotation"; to: -6; duration: 100 }
      NumberAnimation { target: motionLayer; property: "rotation"; to: 0; duration: 120; easing.type: Easing.OutQuad }
    }
    SequentialAnimation {
      id: popAnim
      NumberAnimation { target: motionLayer; property: "scale"; to: 1.22; duration: 130; easing.type: Easing.OutQuad }
      NumberAnimation { target: motionLayer; property: "scale"; to: 1; duration: 260; easing.type: Easing.OutBack }
    }
    SequentialAnimation {
      id: dropAnim
      NumberAnimation { target: motionLayer; property: "y"; to: -3 * animIcon.size / 24; duration: 140; easing.type: Easing.OutQuad }
      NumberAnimation { target: motionLayer; property: "y"; to: 0; duration: 320; easing.type: Easing.OutBounce }
    }
    SequentialAnimation {
      id: pulseAnim
      NumberAnimation { target: motionLayer; property: "opacity"; to: 0.35; duration: 160 }
      NumberAnimation { target: motionLayer; property: "opacity"; to: 1; duration: 160 }
      NumberAnimation { target: motionLayer; property: "opacity"; to: 0.35; duration: 160 }
      NumberAnimation { target: motionLayer; property: "opacity"; to: 1; duration: 160 }
    }
  }

  // Hover label for icon-only controls.
  component Tip: Rectangle {
    id: tip
    required property string text
    property bool shown: false
    property bool below: false
    visible: tip.shown && tip.text !== ""
    opacity: tip.visible ? 1 : 0
    z: 1000
    anchors.horizontalCenter: parent.horizontalCenter
    y: tip.below ? parent.height + 8 : -height - 8
    width: tipText.implicitWidth + 18
    height: 26
    color: root.overlayBg
    border.width: 1
    border.color: root.strongLine
    Text {
      id: tipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tip.text
      color: root.onScrim
      font.family: root.fontFamily
      font.pixelSize: 11
    }
  }

  // Dropdown frame for top-bar menus: anchored under its trigger, scrolls
  // when taller than the card, closes on Esc / outside click (menuCatcher).
  component DropMenu: Rectangle {
    id: dropMenu
    required property string menuId
    property Item anchorItem: null
    property bool alignRight: false
    default property alias content: menuCol.data
    readonly property bool shown: root.openMenu === dropMenu.menuId
    visible: opacity > 0
    opacity: dropMenu.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }
    z: 50
    x: {
      root.openMenu
      if (!dropMenu.anchorItem || !dropMenu.parent) return 0
      var p = dropMenu.anchorItem.mapToItem(dropMenu.parent, 0, 0)
      var want = dropMenu.alignRight ? p.x + dropMenu.anchorItem.width - dropMenu.width : p.x
      return Math.max(16, Math.min(dropMenu.parent.width - dropMenu.width - 16, want))
    }
    y: {
      root.openMenu
      if (!dropMenu.anchorItem || !dropMenu.parent) return 0
      return dropMenu.anchorItem.mapToItem(dropMenu.parent, 0, dropMenu.anchorItem.height).y + 4
    }
    height: Math.min(menuCol.implicitHeight + 32, dropMenu.parent ? dropMenu.parent.height - dropMenu.y - 16 : 600)
    color: root.raisedBg
    border.width: 1
    border.color: root.strongLine
    clip: true
    MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }
    Rectangle { anchors.top: parent.top; width: parent.width; height: 2; color: root.accent }
    Flickable {
      id: menuFlick
      anchors.fill: parent
      anchors.margins: 16
      contentWidth: width
      contentHeight: menuCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      WheelHandler {
        onWheel: function(e) {
          var maxY = Math.max(0, menuFlick.contentHeight - menuFlick.height)
          menuFlick.contentY = Math.max(0, Math.min(maxY, menuFlick.contentY - e.angleDelta.y))
          e.accepted = true
        }
      }
      ColumnLayout {
        id: menuCol
        width: menuFlick.width
        spacing: 6
      }
    }
  }

  // Section heading inside a menu.
  component MenuHeading: Text {
    textFormat: Text.PlainText
    color: root.onScrimFaint
    font.family: root.fontFamily
    font.pixelSize: 11
    font.letterSpacing: 2.2
    Layout.topMargin: 10
    Layout.bottomMargin: 2
  }

  // Icon + label row with an on/off switch; the whole row toggles.
  component MenuToggle: Rectangle {
    id: menuToggle
    required property string icon
    required property string label
    property bool checked: false
    property bool enabled: true
    signal toggled
    Layout.fillWidth: true
    implicitHeight: 40
    color: toggleHover.hovered ? root.hoverFill : "transparent"
    opacity: menuToggle.enabled ? 1 : 0.45
    HoverHandler { id: toggleHover }
    AnimIcon {
      id: toggleIcon
      anchors.left: parent.left
      anchors.leftMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      name: menuToggle.icon
      size: 18
      color: menuToggle.checked ? root.accentText : root.onScrimDim
      hovered: toggleHover.hovered
    }
    Text {
      anchors.left: toggleIcon.right
      anchors.leftMargin: 12
      anchors.right: track.left
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: menuToggle.label
      color: root.onScrim
      font.family: root.fontFamily
      font.pixelSize: 13
      elide: Text.ElideRight
    }
    Rectangle {
      id: track
      anchors.right: parent.right
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      width: 34
      height: 18
      color: menuToggle.checked ? root.accentFill : root.insetFill
      border.width: menuToggle.checked ? 0 : 1
      border.color: root.strongLine
      Behavior on color { ColorAnimation { duration: 120 } }
      Rectangle {
        width: 12
        height: 12
        anchors.verticalCenter: parent.verticalCenter
        x: menuToggle.checked ? parent.width - width - 3 : 3
        color: menuToggle.checked ? root.onScrim : root.onScrimDim
        Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      }
    }
    MouseArea {
      anchors.fill: parent
      enabled: menuToggle.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: menuToggle.toggled()
    }
  }

  // Minimal drag slider for scene properties; emits committed(value) on
  // release so a drag doesn't rewrite the config on every pixel.
  component ValueSlider: Item {
    id: vslider
    property real from: 0
    property real to: 1
    property real stepSize: 0.1
    property real value: 0
    signal committed(real value)
    implicitHeight: 28
    readonly property real ratio: vslider.to > vslider.from ? (vslider.value - vslider.from) / (vslider.to - vslider.from) : 0
    function valueAt(x) {
      var r = Math.max(0, Math.min(1, x / Math.max(1, vslider.width)))
      var v = vslider.from + r * (vslider.to - vslider.from)
      if (vslider.stepSize > 0) v = Math.round((v - vslider.from) / vslider.stepSize) * vslider.stepSize + vslider.from
      return Math.max(vslider.from, Math.min(vslider.to, Number(v.toFixed(4))))
    }
    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 2; color: root.cardBorder }
    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width * vslider.ratio; height: 2; color: root.accent }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: Math.max(0, Math.min(parent.width - width, parent.width * vslider.ratio - width / 2))
      width: 12
      height: 12
      color: sliderArea.pressed ? root.accentText : root.onScrim
    }
    MouseArea {
      id: sliderArea
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onPressed: function(m) { vslider.value = vslider.valueAt(m.x) }
      onPositionChanged: function(m) { if (pressed) vslider.value = vslider.valueAt(m.x) }
      onReleased: vslider.committed(vslider.value)
    }
  }

  // Row of mutually exclusive small options (interval presets, fit modes).
  component Segmented: Row {
    id: seg
    required property var options      // [{ value, label?, icon?, tip? }]
    property var current
    property bool enabled: true
    property int cellSize: 34
    signal picked(var value)
    spacing: 0
    opacity: seg.enabled ? 1 : 0.45
    Repeater {
      model: seg.options
      Rectangle {
        id: segCell
        required property var modelData
        readonly property bool on: seg.current === segCell.modelData.value
        width: segCell.modelData.icon ? seg.cellSize + 6 : segLabel.implicitWidth + 22
        height: seg.cellSize
        color: segCell.on ? root.accentFill : segHover.hovered ? root.hoverFill : "transparent"
        border.width: segCell.on ? 0 : 1
        border.color: root.cardBorder
        HoverHandler { id: segHover }
        Text {
          id: segLabel
          visible: !segCell.modelData.icon
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: segCell.modelData.label || ""
          color: segCell.on ? root.onScrim : root.onScrimDim
          font.family: root.fontFamily
          font.pixelSize: 12
        }
        AnimIcon {
          visible: !!segCell.modelData.icon
          anchors.centerIn: parent
          name: segCell.modelData.icon || "check"
          size: Math.round(seg.cellSize * 0.47)
          color: segCell.on ? root.onScrim : root.onScrimDim
          hovered: segHover.hovered
        }
        Tip { text: segCell.modelData.tip || ""; shown: segHover.hovered }
        MouseArea {
          anchors.fill: parent
          enabled: seg.enabled
          cursorShape: Qt.PointingHandCursor
          onClicked: seg.picked(segCell.modelData.value)
        }
      }
    }
  }

  component ActionButton: Rectangle {
    id: actBtn
    required property string label
    property string icon: ""
    property bool enabled: true
    property bool primary: false
    property bool danger: false
    // dense: sidebar rows where three fixed-width buttons share ~208px —
    // normal padding would overflow the column (measured 270px in 256px).
    property bool dense: false
    property bool large: false
    // implicit (not width/height): layouts size from implicit sizes, and an
    // explicit width goes stale when the label changes (compact bar).
    implicitHeight: actBtn.large ? 56 : actBtn.dense ? 30 : 36
    implicitWidth: Math.max(actBtn.dense ? 44 : 58, actRow.implicitWidth + (actBtn.large ? 56 : actBtn.dense ? 14 : 24))
    radius: 0
    color: !actBtn.enabled ? root.insetFill
      : actBtn.danger ? root.onScrimUrgent
      : actBtn.primary ? (actionHover.hovered ? root.accentFillHover : root.accentFill)
      : actionHover.hovered ? root.hoverFill : root.softFill
    opacity: !actBtn.enabled ? 0.5 : 1.0
    // Keyboard-operable: Tab reaches every button, Return/Enter/Space
    // activates it, and the accent ring shows where focus is. Previously
    // the whole panel chrome was pointer-only (Rectangle+MouseArea).
    focusPolicy: Qt.StrongFocus
    border.width: actBtn.activeFocus ? 2 : (actBtn.primary || actBtn.danger ? 0 : 1)
    border.color: actBtn.activeFocus ? root.accentText : actionHover.hovered ? root.strongLine : root.hairline
    Behavior on color { ColorAnimation { duration: 120 } }
    HoverHandler { id: actionHover }
    signal clicked
    Keys.onReturnPressed: function(e) { if (actBtn.enabled) { actBtn.clicked(); e.accepted = true } }
    Keys.onEnterPressed: function(e) { if (actBtn.enabled) { actBtn.clicked(); e.accepted = true } }
    Keys.onSpacePressed: function(e) { if (actBtn.enabled) { actBtn.clicked(); e.accepted = true } }

    Row {
      id: actRow
      anchors.centerIn: parent
      spacing: actBtn.label === "" ? 0 : actBtn.large ? 14 : 8
      AnimIcon {
        visible: actBtn.icon !== ""
        anchors.verticalCenter: parent.verticalCenter
        name: actBtn.icon
        color: actLabel.color
        filled: actBtn.icon === "play"
        size: actBtn.large ? 18 : 14
        hovered: actionHover.hovered
      }
      Text {
        id: actLabel
        visible: actBtn.label !== ""
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: actBtn.label
        color: root.onScrim
        font.family: actBtn.large ? root.displayFamily : root.fontFamily
        font.pixelSize: actBtn.large ? 15 : Style.font.body
        font.weight: actBtn.large ? Font.Medium : (actBtn.primary || actBtn.danger ? Font.DemiBold : Font.Normal)
        font.letterSpacing: actBtn.large ? 2.4 : 0
      }
    }
    MouseArea {
      anchors.fill: parent
      enabled: actBtn.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        actBtn.forceActiveFocus()
        actBtn.clicked()
      }
    }
  }

  // Square glyph button (close, view toggles, refresh, favorite).
  component IconButton: Rectangle {
    id: iconBtn
    required property string icon
    property bool active: false
    property bool enabled: true
    property bool flat: false
    property color glyphColor: iconBtn.active ? root.onScrim : root.onScrimDim
    property int size: 36
    property bool filled: false
    property bool tipBelow: false
    property string tip: ""
    signal clicked
    width: iconBtn.size
    height: iconBtn.size
    radius: 0
    opacity: iconBtn.enabled ? 1 : 0.4
    color: iconBtn.active ? root.accentFill
      : iconHover.hovered ? root.hoverFill : (iconBtn.flat ? "transparent" : root.softFill)
    border.width: iconBtn.activeFocus ? 2 : (iconBtn.flat || iconBtn.active ? 0 : 1)
    border.color: iconBtn.activeFocus ? root.accentText : iconHover.hovered ? root.strongLine : root.hairline
    focusPolicy: Qt.StrongFocus
    Behavior on color { ColorAnimation { duration: 120 } }
    HoverHandler { id: iconHover }
    Keys.onReturnPressed: function(e) { if (iconBtn.enabled) { iconBtn.clicked(); e.accepted = true } }
    Keys.onEnterPressed: function(e) { if (iconBtn.enabled) { iconBtn.clicked(); e.accepted = true } }
    Keys.onSpacePressed: function(e) { if (iconBtn.enabled) { iconBtn.clicked(); e.accepted = true } }
    AnimIcon {
      anchors.centerIn: parent
      name: iconBtn.icon
      color: iconBtn.glyphColor
      filled: iconBtn.filled
      size: Math.round(iconBtn.size * 0.46)
      hovered: iconHover.hovered
    }
    Tip { text: iconBtn.tip; shown: iconHover.hovered; below: iconBtn.tipBelow }
    MouseArea {
      anchors.fill: parent
      enabled: iconBtn.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        mouse.accepted = true
        iconBtn.clicked()
      }
    }
  }

  // Filter chip: "Animados · 18". Selected fills with brand-700.
  component Chip: Rectangle {
    id: chip
    required property string label
    property int count: -1
    property bool selected: false
    signal clicked
    implicitHeight: 40
    implicitWidth: chipRow.implicitWidth + 38
    radius: 0
    color: chip.selected ? root.accentFill : chipHover.hovered ? root.hoverFill : "transparent"
    border.width: chip.activeFocus ? 2 : (chip.selected ? 0 : 1)
    border.color: chip.activeFocus ? root.accentText : chipHover.hovered ? root.strongLine : root.cardBorder
    focusPolicy: Qt.StrongFocus
    Behavior on color { ColorAnimation { duration: 120 } }
    HoverHandler { id: chipHover }
    Keys.onReturnPressed: function(e) { chip.clicked(); e.accepted = true }
    Keys.onSpacePressed: function(e) { chip.clicked(); e.accepted = true }
    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: 0
      Text {
        textFormat: Text.PlainText
        text: chip.label
        color: chip.selected ? root.onScrim : root.onScrimDim
        font.family: root.fontFamily
        font.pixelSize: 13
      }
      Text {
        visible: chip.count >= 0
        textFormat: Text.PlainText
        text: "  ·  " + chip.count
        color: chip.selected ? root.onScrim : root.onScrimFaint
        font.family: root.fontFamily
        font.pixelSize: 13
      }
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: { chip.forceActiveFocus(); chip.clicked() }
    }
  }

  component NavButton: Item {
    id: navButton
    required property string label
    property bool selected: false
    property bool menu: false
    property bool menuOpen: false
    signal clicked
    implicitWidth: navText.implicitWidth + (navButton.menu ? 46 : 28)
    implicitHeight: 58
    focusPolicy: Qt.StrongFocus
    HoverHandler { id: navHover }

    AnimIcon {
      visible: navButton.menu
      anchors.left: navText.right
      anchors.leftMargin: 8
      anchors.verticalCenter: navText.verticalCenter
      name: "chevron-down"
      size: 12
      color: navText.color
      hovered: navHover.hovered
      rotation: navButton.menuOpen ? 180 : 0
      Behavior on rotation { NumberAnimation { duration: 160 } }
    }
    Text {
      id: navText
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: navButton.menu ? -9 : 0
      text: navButton.label
      color: navButton.selected || navHover.hovered ? root.onScrim : root.onScrimDim
      font.family: root.fontFamily
      font.pixelSize: 13
      font.weight: navButton.selected ? Font.DemiBold : Font.Normal
      font.letterSpacing: 1.8
    }
    Rectangle {
      anchors.left: navText.left
      anchors.right: navText.right
      anchors.top: navText.bottom
      anchors.topMargin: 6
      height: 2
      color: root.accent
      visible: navButton.selected
    }
    Rectangle {
      anchors.fill: parent
      color: "transparent"
      border.width: navButton.activeFocus ? 1 : 0
      border.color: root.accent
    }
    Keys.onReturnPressed: function(e) { navButton.clicked(); e.accepted = true }
    Keys.onEnterPressed: function(e) { navButton.clicked(); e.accepted = true }
    Keys.onSpacePressed: function(e) { navButton.clicked(); e.accepted = true }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: { navButton.forceActiveFocus(); navButton.clicked() }
    }
  }

  component Stepper: RowLayout {
    id: stepper
    required property string valueText
    // Ungated steppers used to fire config writes mid-busy, piling commands
    // onto the single shared configProc.
    property bool enabled: true
    signal stepped(int delta)
    spacing: 6

    ActionButton {
      label: "−"
      enabled: stepper.enabled
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
      enabled: stepper.enabled
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
        var shadow = root.pinnedOutputsText()
        if (shadow !== "") root.notice += " — " + shadow + " keeps its pinned wallpaper (clear the pin in MONITORS to see this one)"
        if (root.isWorkshop) root.markCurrentWorkshop(root.selectedKey)
        else if (applyProc.appliedPath !== "" && root.view.section !== "online")
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

  // Per-monitor pins + global fit mode (background domain).
  Process {
    id: monitorsProc
    property int tag: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.opened || monitorsProc.tag !== root.bgSerial) return
        var d = null
        try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
        if (d && Array.isArray(d.outputs)) root.monitors = d
      }
    }
  }

  Process {
    id: monitorActProc
    property int tag: 0
    property bool isBackground: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.opened) return
        if (monitorActProc.isBackground ? monitorActProc.tag !== root.bgSerial : monitorActProc.tag !== root.serial) return
        var d = null
        try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
        // monitor-set/clear/fit answer with fresh monitors JSON; config-set
        // (imageFit) answers with config-get instead → just reload pins.
        if (d && Array.isArray(d.outputs)) root.monitors = d
        else root.loadMonitors()
      }
    }
    onExited: function(code) {
      if (!root.opened) return
      if (monitorActProc.isBackground ? monitorActProc.tag !== root.bgSerial : monitorActProc.tag !== root.serial) return
      // Background actions never own the spinner: refresh state, leave
      // `loading` alone so a concurrent foreground load keeps its feedback.
      if (monitorActProc.isBackground) {
        if (code === 0) loadConfigSilent()
        else if (root.errorText === "") root.errorText = "Monitor action failed"
        return
      }
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

  // One-time Steam sign-in from the panel form (see steamSignIn above).
  Process {
    id: steamLoginProc
    property string failMsg: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text || "").trim().split("\n").filter(function(l) { return l !== "" })
        steamLoginProc.failMsg = m.length > 0 ? m[m.length - 1] : ""
      }
    }
    onExited: function(code) {
      root.steamBusy = false
      if (!root.opened) return
      if (code === 0) {
        root.errorText = ""
        root.notice = "Signed in to Steam — downloads enabled"
        steamPassInput.text = ""
        steamGuardInput.text = ""
        loadConfigSilent()
      } else {
        root.errorText = steamLoginProc.failMsg !== "" ? steamLoginProc.failMsg : "Steam login failed"
      }
    }
  }

  Process {
    id: configProc
    property int tag: 0
    property string mode: "get" // get | get-boot | silent | refresh
    property string doneNotice: ""
    property bool reloadGrid: false
    // True when this silent run closes a foreground mutate: only then may
    // it clear `loading`. Standalone background refreshes leave it alone.
    property bool clearBusy: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Foreground modes (get/get-boot/refresh) live in the `serial`
        // domain; silent background refreshes live in `bgSerial`. A stale
        // reply in either domain is a no-op.
        if (!root.opened) return
        if (configProc.mode === "silent" ? configProc.tag !== root.bgSerial : configProc.tag !== root.serial) return
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
      if (!root.opened) return
      if (configProc.mode === "silent" ? configProc.tag !== root.bgSerial : configProc.tag !== root.serial) return
      if (configProc.mode === "refresh") {
        if (code !== 0) {
          root.loading = false
          root.busyText = ""
          if (root.errorText === "") root.errorText = "Could not save — check the name and retry"
          return
        }
        // Chain into a silent re-read in the background domain. The silent
        // completion below owns clearing `loading`, so the spinner survives
        // across the two sequential runs instead of stranding on.
        configProc.mode = "silent"
        configProc.clearBusy = true
        configProc.tag = ++root.bgSerial
        configProc.command = [root.script, "config-get"]
        configProc.running = true
        return
      }
      if (configProc.mode === "silent") {
        // Every foreground mutate funnels through here: this is the ONLY
        // place that can clear its spinner, so it must always do so —
        // previously it never did, stranding "Saving…" forever.
        // Standalone background refreshes (clearBusy=false) leave a
        // concurrent foreground spinner alone.
        if (configProc.clearBusy) {
          root.loading = false
          root.busyText = ""
        }
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
          if (root.view.section !== "online") {
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

  Process {
    id: doctorProc
    command: [root.script, "doctor", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        var d = []
        try { d = JSON.parse(String(text || "[]")) } catch (e) { d = [] }
        root.doctorRows = Array.isArray(d) ? d : []
      }
    }
  }

  Process {
    id: propsProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.propsLoading = false
        var d = []
        try { d = JSON.parse(String(text || "[]")) } catch (e) { d = [] }
        root.sceneProps = Array.isArray(d) ? d : []
      }
    }
    onExited: function(code) { root.propsLoading = false }
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

  // Backstop: no single panel operation (grid list, search page, apply,
  // save) should ever own the spinner for longer than this. Kills the same
  // full proc list as close()/cancelLoad() — a partial kill used to leave
  // config/monitors procs running while orphaning their replies.
  Timer {
    id: watchdog
    interval: 60000
    repeat: false
    running: root.opened && root.loading
    onTriggered: {
      gridProc.running = false
      searchProc.running = false
      applyProc.running = false
      configProc.running = false
      downloadProc.running = false
      previewProc.running = false
      monitorsProc.running = false
      monitorActProc.running = false
      root.serial += 1
      root.bgSerial += 1
      root.loading = false
      root.busyText = ""
      root.applyingOnline = false
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
    WlrLayershell.namespace: "wallhub-panel"
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
      Keys.onEscapePressed: { if (!root.closeOverlays()) root.dismiss() }
      Keys.onLeftPressed: root.previewOpen ? root.previewStep(-1) : root.moveSelection(-1, 0)
      Keys.onRightPressed: root.previewOpen ? root.previewStep(1) : root.moveSelection(1, 0)
      Keys.onUpPressed: if (!root.previewOpen) root.moveSelection(0, -1)
      Keys.onDownPressed: if (!root.previewOpen) root.moveSelection(0, 1)
      Keys.onReturnPressed: root.activateSelection()
      Keys.onEnterPressed: root.activateSelection()
      // Select mode is fully keyboard-driven: arrows move, Space toggles,
      // Enter confirms the batch (see activateSelection).
      Keys.onSpacePressed: {
        if (root.selectMode && root.selectedKey !== "") root.toggleMark(root.selectedKey)
        else if (root.previewOpen) root.previewOpen = false
        else root.openPreview()
      }
      // "/" jumps to search, as hinted inside the search box.
      Keys.onPressed: function(e) {
        if (e.key === Qt.Key_Slash) {
          centerInput.forceActiveFocus()
          e.accepted = true
        }
      }

      Item {
        id: cardBox
        anchors.centerIn: parent
        width: Math.min(1660, Math.max(640, keyCatcher.width - 32))
        height: Math.min(940, Math.max(520, keyCatcher.height - 32))

        MouseArea { anchors.fill: parent; onClicked: {} }

        Rectangle {
          anchors.fill: parent
          radius: 0
          color: root.cardBg
          border.width: 1
          border.color: root.cardBorder
          clip: true

          ColumnLayout {
            anchors.fill: parent
            spacing: 0

              // ---- top bar: brand · sections · output · rotation · close ----
              RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 32
                Layout.rightMargin: 24
                Layout.preferredHeight: 58
                spacing: 0

                // WallHub mark: two stacked frames (the collection) — a
                // brand-blue card behind, a framed landscape in front.
                Item {
                  id: brandMark
                  Layout.preferredWidth: 30
                  Layout.preferredHeight: 30
                  HoverHandler { id: brandHover }
                  Rectangle {
                    x: brandHover.hovered ? 11 : 9
                    y: 0
                    width: 21
                    height: 21
                    color: root.accent
                    Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                  }
                  Rectangle {
                    id: brandFront
                    x: 0
                    y: 9
                    width: 21
                    height: 21
                    color: root.cardBg
                    border.width: 2
                    border.color: root.onScrim
                    clip: true
                    // sun
                    Rectangle { x: 12; y: 4; width: 4; height: 4; color: root.accentText }
                    // ridge line
                    Shape {
                      anchors.fill: parent
                      preferredRendererType: Shape.CurveRenderer
                      ShapePath {
                        strokeColor: root.onScrim
                        strokeWidth: 2
                        fillColor: "transparent"
                        joinStyle: ShapePath.MiterJoin
                        capStyle: ShapePath.FlatCap
                        PathSvg { path: "M2 17 L8 10 L12 14 L14.5 11.5 L19 17" }
                      }
                    }
                  }
                }
                Text {
                  Layout.leftMargin: 14
                  textFormat: Text.StyledText
                  text: "WALL<font color=\"" + root.accentText + "\">HUB</font>"
                  color: root.onScrim
                  font.family: root.displayFamily
                  font.pixelSize: 21
                  font.weight: Font.Bold
                  font.letterSpacing: 1.6
                }
                Rectangle { Layout.leftMargin: 24; Layout.rightMargin: 10; width: 1; height: 26; color: root.cardBorder }
                NavButton {
                  label: "BIBLIOTECA"
                  selected: root.view.section === "lib" || root.isWorkshop
                  onClicked: { root.openMenu = ""; root.setView("lib") }
                }
                NavButton {
                  label: "FAVORITOS"
                  selected: root.view.section === "favorites"
                  onClicked: { root.openMenu = ""; root.setView("favorites") }
                }
                NavButton {
                  label: "PLAYLISTS"
                  id: playlistsNav
                  selected: root.view.section === "playlist" || root.openMenu === "playlists"
                  menu: true
                  menuOpen: root.openMenu === "playlists"
                  onClicked: root.openMenu = root.openMenu === "playlists" ? "" : "playlists"
                }
                NavButton {
                  label: "ONLINE"
                  selected: root.view.section === "online"
                  onClicked: { root.openMenu = ""; root.setView("online", "", root.view.provider || "wallhaven") }
                }
                NavButton {
                  label: "AJUSTES"
                  id: settingsNav
                  selected: root.openMenu === "settings"
                  menu: true
                  menuOpen: root.openMenu === "settings"
                  onClicked: root.openMenu = root.openMenu === "settings" ? "" : "settings"
                }
                Item { Layout.fillWidth: true }

                // Active output (first connected) with its mode.
                Row {
                  visible: root.primaryOutput() !== null && cardBox.width > 1450
                  spacing: 12
                  AnimIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.icons.monitor
                    color: root.onScrim
                    size: 19
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: {
                      var o = root.primaryOutput()
                      if (!o) return ""
                      return o.name + "   " + (o.width || 0) + "×" + (o.height || 0)
                    }
                    color: root.accentText
                    font.family: root.fontFamily
                    font.pixelSize: 12
                    font.letterSpacing: 0.6
                  }
                }
                Rectangle {
                  visible: root.primaryOutput() !== null && cardBox.width > 1450
                  Layout.leftMargin: 24; Layout.rightMargin: 12
                  width: 1; height: 26; color: root.cardBorder
                }

                // Rotation source; opens Ajustes (interval, mode, playback).
                Rectangle {
                  id: rotPill
                  Layout.preferredHeight: 36
                  Layout.preferredWidth: rotRow.implicitWidth + 24
                  color: rotHover.hovered || root.openMenu === "settings" ? root.hoverFill : "transparent"
                  HoverHandler { id: rotHover }
                  Row {
                    id: rotRow
                    anchors.centerIn: parent
                    spacing: 10
                    AnimIcon {
                      anchors.verticalCenter: parent.verticalCenter
                      name: ((root.engine && root.engine.status) || {}).paused ? root.icons.pause : root.icons.rotate
                    hovered: rotHover.hovered
                      color: root.onScrim
                      size: 16
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: {
                        var st = (root.engine && root.engine.status) || {}
                        if (st.paused) return "Rotación: En pausa"
                        var ap = root.activePlaylist()
                        return "Rotación: " + (ap !== "" ? ap : "Global")
                      }
                      color: root.onScrimDim
                      font.family: root.fontFamily
                      font.pixelSize: 12
                    }
                    AnimIcon {
                      anchors.verticalCenter: parent.verticalCenter
                      name: root.icons.chevronDown
                      color: root.onScrimDim
                      size: 10
                    }
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openMenu = root.openMenu === "settings" ? "" : "settings"
                  }
                }
                Rectangle { Layout.leftMargin: 12; Layout.rightMargin: 12; width: 1; height: 26; color: root.cardBorder }
                IconButton {
                  icon: root.icons.close
                  flat: true
                  size: 36
                  glyphColor: root.onScrim
                  onClicked: root.dismiss()
                }
              }

              Rectangle {
                Layout.fillWidth: true
                height: 1
                color: root.hairline
              }

          RowLayout {
            id: centerRow
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ============ CENTER ============
            ColumnLayout {
              id: centerCol
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.leftMargin: 32
              Layout.rightMargin: 32
              Layout.topMargin: 10
              Layout.bottomMargin: 20
              spacing: 14

              // ---- hero: eyebrow + display title (left) · search + chips (right) ----
              GridLayout {
                Layout.fillWidth: true
                Layout.topMargin: root.wideHero ? 14 : 4
                columns: root.wideHero ? 2 : 1
                columnSpacing: 48
                rowSpacing: 14

                ColumnLayout {
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignTop
                  spacing: root.wideHero ? 6 : 2
                  Text {
                    text: root.view.section === "online" ? "DESCUBRE"
                      : root.view.section === "playlist" ? "PLAYLIST" : "EXPLORA"
                    color: root.onScrimDim
                    font.family: root.fontFamily
                    font.pixelSize: 11
                    font.letterSpacing: 2.4
                  }
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.StyledText
                    text: {
                      var t = root.view.section === "lib" ? "TU ESCRITORIO, A TU MANERA"
                        : root.view.section === "favorites" ? "TUS FAVORITOS"
                        : root.view.section === "online" ? "DESCUBRE NUEVOS FONDOS"
                        : String(root.viewTitle()).toUpperCase()
                      t = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
                      return t + "<font color=\"" + root.accent + "\">.</font>"
                    }
                    color: root.onScrim
                    font.family: root.displayFamily
                    font.pixelSize: root.wideHero ? 60 : 38
                    font.weight: Font.Bold
                    font.letterSpacing: -0.5
                    fontSizeMode: Text.HorizontalFit
                    minimumPixelSize: 26
                    maximumLineCount: 1
                  }
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: 18
                    Text {
                      text: root.filteredItems().length + (root.filteredItems().length === 1 ? " FONDO" : " FONDOS")
                      color: root.accentText
                      font.family: root.displayFamily
                      font.pixelSize: 15
                      font.weight: Font.Bold
                      font.letterSpacing: 2.4
                    }
                    // Share of the library the current filter shows.
                    Item {
                      Layout.fillWidth: true
                      height: 3
                      Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; height: 1; color: root.cardBorder }
                      Rectangle {
                        height: 3
                        color: root.accent
                        width: {
                          var total = Math.max(1, root.items.length)
                          return Math.max(24, parent.width * Math.min(1, root.filteredItems().length / total) * 0.25)
                        }
                        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                      }
                    }
                  }
                }

                // Wide: search above chips. Narrow: one toolbar row.
                GridLayout {
                  Layout.preferredWidth: root.wideHero ? Math.min(730, root.centerW * 0.45) : root.centerW
                  Layout.fillWidth: !root.wideHero
                  Layout.alignment: Qt.AlignTop
                  Layout.topMargin: root.wideHero ? 8 : 0
                  columns: root.wideHero ? 1 : 2
                  rowSpacing: 18
                  columnSpacing: 14

                  // search (online) / filter (local)
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                      Layout.fillWidth: true
                      height: 42
                      radius: 0
                      color: root.insetFill
                      border.width: 1
                      border.color: centerInput.activeFocus ? root.accent : root.cardBorder

                      AnimIcon {
                        id: searchGlyph
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.icons.search
                        color: centerInput.activeFocus ? root.onScrim : root.onScrimDim
                        hovered: centerInput.activeFocus
                        size: 16
                      }

                      TextInput {
                        id: centerInput
                        anchors.left: searchGlyph.right
                        anchors.right: slashHint.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 12
                        anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter
                        color: root.onScrim
                        selectionColor: root.accentFill
                        font.family: root.fontFamily
                        font.pixelSize: 13
                        clip: true
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
                        // Two-stage Esc: first press returns focus to the grid
                        // (arrows/Enter work again), second press dismisses.
                        Keys.onEscapePressed: keyCatcher.forceActiveFocus()
                      }

                      Text {
                        visible: centerInput.displayText === ""
                        anchors.left: centerInput.left
                        anchors.right: centerInput.right
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.view.section === "online"
                          ? (root.view.provider === "wallhaven"
                            ? "Buscar en Wallhaven… (ej. montañas)"
                            : root.view.provider === "steam"
                            ? "Buscar en Steam Workshop… (ej. cyberpunk)"
                            : "Buscar fondos animados… (ej. frieren)")
                          : "Buscar fondos, fuentes, nombres…"
                        color: root.onScrimFaint
                        font.family: root.fontFamily
                        font.pixelSize: 13
                      }

                      // "/" focuses search (see keyCatcher).
                      Rectangle {
                        id: slashHint
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22
                        height: 22
                        color: "transparent"
                        border.width: 1
                        border.color: root.strongLine
                        Text {
                          anchors.centerIn: parent
                          text: "/"
                          color: root.onScrimDim
                          font.family: root.fontFamily
                          font.pixelSize: 11
                        }
                      }
                    }

                    IconButton {
                      visible: root.view.section === "online"
                      icon: root.icons.search
                      size: 42
                      active: true
                      glyphColor: root.onScrim
                      enabled: !root.loading
                      onClicked: root.runSearch()
                    }
                    IconButton {
                      visible: root.view.section !== "online"
                      icon: root.icons.refresh
                      size: 42
                      enabled: !root.loading
                      onClicked: {
                        root.itemsSource = ""
                        root.runGrid()
                      }
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: root.wideHero
                    spacing: 10

                    Chip {
                      visible: root.view.section !== "online"
                      label: "Todos"
                      count: root.items.length
                      selected: root.kindFilter === "all"
                      onClicked: root.kindFilter = "all"
                    }
                    Chip {
                      visible: root.view.section !== "online"
                      label: "Animados"
                      count: root.countWhere("video")
                      selected: root.kindFilter === "video"
                      onClicked: root.kindFilter = "video"
                    }
                    Chip {
                      visible: root.view.section !== "online" && !root.isWorkshop
                      label: "Estáticos"
                      count: root.countWhere("image")
                      selected: root.kindFilter === "image"
                      onClicked: root.kindFilter = "image"
                    }
                    Chip {
                      visible: root.isWorkshop
                      label: "Escenas"
                      count: root.countWhere("scene")
                      selected: root.kindFilter === "scene"
                      onClicked: root.kindFilter = "scene"
                    }
                    Chip {
                      visible: root.view.section !== "online" && root.view.section !== "favorites"
                        && !root.isWorkshop && root.centerW > 1180
                      label: "Favoritos"
                      count: root.countWhere("fav")
                      selected: root.kindFilter === "fav"
                      onClicked: root.kindFilter = "fav"
                    }
                    // Local Steam Workshop library (no login needed).
                    Chip {
                      visible: root.view.section === "lib" || root.isWorkshop
                      label: "Workshop"
                      selected: root.isWorkshop
                      onClicked: root.setView(root.isWorkshop ? "lib" : "workshop", "", "")
                    }
                    Chip {
                      visible: root.view.section === "online"
                      label: "Wallhaven"
                      selected: root.view.provider === "wallhaven"
                      onClicked: root.setView("online", "", "wallhaven")
                    }
                    Chip {
                      visible: root.view.section === "online"
                      label: "MoeWalls"
                      selected: root.view.provider === "moewalls"
                      onClicked: root.setView("online", "", "moewalls")
                    }
                    Chip {
                      visible: root.view.section === "online"
                      label: "Steam"
                      selected: root.view.provider === "steam"
                      onClicked: root.setView("online", "", "steam")
                    }
                    Item { Layout.fillWidth: true; visible: root.wideHero }
                    IconButton {
                      visible: root.fileActions
                      icon: root.icons.select
                      size: 40
                      active: root.selectMode
                      onClicked: {
                        root.selectMode = !root.selectMode
                        root.marked = ({})
                        root.markedCount = 0
                      }
                    }
                    Row {
                      spacing: 0
                      IconButton {
                        icon: root.icons.grid
                        size: 40
                        active: root.layoutMode === "grid"
                        onClicked: root.layoutMode = "grid"
                      }
                      IconButton {
                        icon: root.icons.list
                        size: 40
                        active: root.layoutMode === "list"
                        onClicked: root.layoutMode = "list"
                      }
                    }
                  }
                }
              }

              // playlist actions (only while viewing a playlist)
              RowLayout {
                visible: root.view.section === "playlist"
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                ActionButton {
                  label: root.activePlaylist() === root.view.name ? "Activa ✓" : "Activar rotación"
                  enabled: root.activePlaylist() !== root.view.name && !root.loading
                  onClicked: root.activateViewingPlaylist()
                }
                ActionButton {
                  label: root.confirmDeleteKey === "playlist:" + root.view.name ? "¿Confirmar borrado?" : "Borrar playlist"
                  danger: root.confirmDeleteKey === "playlist:" + root.view.name
                  enabled: !root.loading
                  onClicked: root.deleteViewingPlaylist()
                }
              }

              // Steam sign-in — one-time; steamcmd caches the credentials
              // so downloads work afterwards. Hidden once signed in.
              RowLayout {
                visible: root.view.section === "online" && root.view.provider === "steam"
                  && !root.steamSignedIn
                Layout.fillWidth: true
                spacing: 6

                Rectangle {
                  Layout.fillWidth: true
                  height: 34
                  radius: Style.cornerRadius
                  color: root.softFill
                  border.width: steamUserInput.activeFocus ? 1 : 0
                  border.color: root.accent

                  TextInput {
                    id: steamUserInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.onScrim
                    selectionColor: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    text: (root.engine.config && root.engine.config.steamUser) || ""
                    Keys.onReturnPressed: root.steamSignIn()
                    Keys.onEnterPressed: root.steamSignIn()
                  }
                  Text {
                    visible: steamUserInput.displayText === ""
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Steam user"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                Rectangle {
                  Layout.fillWidth: true
                  height: 34
                  radius: Style.cornerRadius
                  color: root.softFill
                  border.width: steamPassInput.activeFocus ? 1 : 0
                  border.color: root.accent

                  TextInput {
                    id: steamPassInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.onScrim
                    selectionColor: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    echoMode: TextInput.Password
                    Keys.onReturnPressed: root.steamSignIn()
                    Keys.onEnterPressed: root.steamSignIn()
                  }
                  Text {
                    visible: steamPassInput.displayText === ""
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Password"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                Rectangle {
                  Layout.preferredWidth: 92
                  Layout.fillWidth: false
                  height: 34
                  radius: Style.cornerRadius
                  color: root.softFill
                  border.width: steamGuardInput.activeFocus ? 1 : 0
                  border.color: root.accent

                  TextInput {
                    id: steamGuardInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.onScrim
                    selectionColor: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    Keys.onReturnPressed: root.steamSignIn()
                    Keys.onEnterPressed: root.steamSignIn()
                  }
                  Text {
                    visible: steamGuardInput.displayText === ""
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Guard code"
                    color: root.onScrimFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                ActionButton {
                  label: root.steamBusy ? "Signing in…" : "Sign in"
                  primary: true
                  enabled: !root.steamBusy && steamUserInput.displayText !== "" && steamPassInput.text !== ""
                  onClicked: root.steamSignIn()
                }
              }

              Text {
                visible: root.view.section === "online" && root.view.provider === "steam"
                  && !root.steamSignedIn
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "One-time sign-in — your Steam account must own Wallpaper Engine. Guard code: Steam app or email."
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              // Wallhaven filters — config-backed (wallpaper-engine.sh
              // validates every value), takes effect on the next search.
              // Collapsible: six buttons always visible crowd out the grid.
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: root.view.section === "online" && root.view.provider === "wallhaven"

                ActionButton {
                  label: root.filtersOpen ? "Filters ▾" : "Filters ▸"
                  enabled: !root.loading
                  onClicked: root.filtersOpen = !root.filtersOpen
                }

                RowLayout {
                  visible: root.filtersOpen
                  Layout.fillWidth: true
                  spacing: 6

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
                  clip: true

                  Rectangle {
                    id: progressSlide
                    width: Math.min(120, progressTrack.width)
                    height: parent.height
                    radius: Style.cornerRadius
                    color: root.accent

                    // NOTE: this animation must live on the SLIDE (it used
                    // to sit on the track rect, sliding the whole bar —
                    // track included — past the column into the next panel).
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

              // Gallery. Each cell carries the 20px gutter on its right/bottom;
              // the view overhangs the column by that gutter so the last
              // column lines up with the header's right edge.
              GridView {
                id: gridFlow
                visible: root.filteredItems().length > 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.rightMargin: -gridFlow.gutter
                clip: true
                readonly property int gutter: 18
                readonly property bool listMode: root.layoutMode === "list"
                readonly property int footerH: 42
                readonly property int cols: listMode ? 1 : (width > 1300 ? 4 : width > 860 ? 3 : 2)
                cellWidth: width / cols
                cellHeight: listMode ? 84 + gutter / 2 : Math.round((cellWidth - gutter) * 0.40) + footerH + gutter
                cacheBuffer: cellHeight
                reuseItems: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.filteredItems()

                delegate: Item {
                  id: cell
                  required property var modelData
                  required property int index
                  readonly property bool isSel: root.selectedKey === modelData.key
                  readonly property bool isMarked: root.marked[modelData.key] === true
                  readonly property bool listMode: gridFlow.listMode
                  width: gridFlow.cellWidth - gridFlow.gutter
                  height: gridFlow.cellHeight - (listMode ? gridFlow.gutter / 2 : gridFlow.gutter)

                  Rectangle {
                    anchors.fill: parent
                    radius: 0
                    color: cell.isSel ? root.overlayBg : root.raisedBg
                    clip: true

                    // ---- media ----
                    Item {
                      id: media
                      x: 0
                      y: 0
                      width: cell.listMode ? Math.round(parent.height * 16 / 9) : parent.width
                      height: cell.listMode ? parent.height : parent.height - gridFlow.footerH
                      clip: true

                      Rectangle { anchors.fill: parent; color: root.insetFill }

                      Image {
                        anchors.fill: parent
                        source: modelData.thumb ? "file://" + modelData.thumb : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        smooth: true
                        sourceSize.width: 640
                        opacity: modelData.playable === false ? 0.45 : 1
                        scale: cellHover.hovered && !cell.listMode ? 1.03 : 1.0
                        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                      }

                      // MoeWalls hover preview: settling the cursor on a
                      // LIVE cell fetches the small preview webm
                      // (cached) and plays it over the thumbnail —
                      // nothing downloads until Apply.
                      Loader {
                        id: previewLoader
                        anchors.fill: parent
                        active: root.previewKey === modelData.key && root.previewPath !== ""
                        sourceComponent: Item {
                          MediaPlayer {
                            autoPlay: true
                            loops: MediaPlayer.Infinite
                            videoOutput: previewOutput
                            audioOutput: AudioOutput { muted: true }
                            source: "file://" + root.previewPath
                          }
                          VideoOutput {
                            id: previewOutput
                            anchors.fill: parent
                            fillMode: VideoOutput.PreserveAspectCrop
                          }
                        }
                      }

                      Rectangle {
                        id: liveBadge
                        visible: (modelData.kind === "video" || modelData.kind === "scene" || modelData.kind === "web")
                          && !cell.listMode
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 10
                        width: liveRow.implicitWidth + 18
                        height: 26
                        color: Qt.rgba(0.07, 0.07, 0.07, 0.82)
                        Row {
                          id: liveRow
                          anchors.centerIn: parent
                          spacing: 8
                          AnimIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: modelData.kind === "scene" ? "sparkles" : modelData.kind === "web" ? "globe" : root.icons.play
                            color: root.onScrim
                            filled: modelData.kind === "video"
                            size: 11
                            hovered: cellHover.hovered
                          }
                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: modelData.kind === "scene" ? "ESCENA" : modelData.kind === "web" ? "WEB" : "LIVE"
                            color: root.onScrim
                            font.family: root.displayFamily
                            font.pixelSize: 12
                            font.weight: Font.Bold
                            font.letterSpacing: 1.4
                          }
                        }
                      }

                      // Workshop item this machine can't render yet.
                      Rectangle {
                        visible: modelData.playable === false && !cell.listMode
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: 10
                        width: blockedRow.implicitWidth + 16
                        height: 26
                        color: Qt.rgba(0.07, 0.07, 0.07, 0.86)
                        border.width: 1
                        border.color: "#f4d35e"
                        Row {
                          id: blockedRow
                          anchors.centerIn: parent
                          spacing: 6
                          AnimIcon { anchors.verticalCenter: parent.verticalCenter; name: "lock"; size: 12; color: "#f4d35e"; hovered: cellHover.hovered }
                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: modelData.reason === "needs-lwe" ? "REQUIERE LWE" : "NO SOPORTADO"
                            color: "#f4d35e"
                            font.family: root.displayFamily
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            font.letterSpacing: 1.2
                          }
                        }
                      }

                      // Currently applied wallpaper.
                      Rectangle {
                        visible: modelData.current === true && !cell.isMarked && root.view.section !== "playlist"
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: 10
                        width: inUseText.implicitWidth + 16
                        height: 24
                        color: root.accentFill
                        Text {
                          id: inUseText
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: "EN USO"
                          color: root.onScrim
                          font.family: root.displayFamily
                          font.pixelSize: 11
                          font.weight: Font.Bold
                          font.letterSpacing: 1.4
                        }
                      }

                      Rectangle {
                        visible: cell.isMarked
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: 10
                        width: 28
                        height: 28
                        color: root.accentFill
                        AnimIcon {
                          anchors.centerIn: parent
                          name: root.icons.check
                          color: root.onScrim
                          size: 14
                        }
                      }

                      IconButton {
                        visible: root.view.section === "playlist"
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.topMargin: 10
                        anchors.leftMargin: cell.isMarked ? 44 : 10
                        icon: root.icons.close
                        size: 28
                        flat: true
                        color: Qt.rgba(0.07, 0.07, 0.07, 0.82)
                        glyphColor: root.onScrim
                        onClicked: {
                          root.selectedKey = modelData.key
                          root.selectedItem = modelData
                          root.removeSelected()
                        }
                      }
                    }

                    // ---- footer: index · title · source · favorite ----
                    Item {
                      id: footer
                      x: cell.listMode ? media.width : 0
                      y: cell.listMode ? 0 : media.height
                      width: parent.width - x
                      height: cell.listMode ? parent.height : gridFlow.footerH

                      Rectangle {
                        visible: !cell.listMode
                        anchors.top: parent.top
                        width: parent.width
                        height: 1
                        color: root.hairline
                      }

                      Item {
                        id: idxCell
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: cell.listMode ? 64 : 42
                        Text {
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: root.pad2(cell.index)
                          color: cell.isSel ? root.accentText : root.onScrim
                          font.family: root.displayFamily
                          font.pixelSize: cell.listMode ? 15 : 13
                          font.weight: Font.Bold
                        }
                        Rectangle {
                          anchors.right: parent.right
                          anchors.top: parent.top
                          anchors.bottom: parent.bottom
                          width: 1
                          color: root.hairline
                        }
                      }

                      Row {
                        anchors.left: idxCell.right
                        anchors.leftMargin: 14
                        anchors.right: favBtn.visible ? favBtn.left : parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 12
                        clip: true

                        Text {
                          id: cellTitle
                          anchors.verticalCenter: parent.verticalCenter
                          width: Math.min(implicitWidth, parent.width - srcSep.width - srcText.implicitWidth - 24)
                          textFormat: Text.PlainText
                          text: root.displayName(modelData)
                          color: root.onScrim
                          font.family: root.fontFamily
                          font.pixelSize: cell.listMode ? 14 : 13
                          font.weight: cell.isSel ? Font.DemiBold : Font.Normal
                          elide: Text.ElideRight
                        }
                        Rectangle {
                          id: srcSep
                          anchors.verticalCenter: parent.verticalCenter
                          width: 1
                          height: 14
                          color: root.strongLine
                        }
                        Text {
                          id: srcText
                          anchors.verticalCenter: parent.verticalCenter
                          textFormat: Text.PlainText
                          text: cell.listMode
                            ? root.sourceLabel(modelData) + "  ·  " + (modelData.kind === "video" ? "Animado" : "Estático")
                            : root.sourceLabel(modelData)
                          color: root.onScrimFaint
                          font.family: root.fontFamily
                          font.pixelSize: 12
                        }
                      }

                      IconButton {
                        id: favBtn
                        visible: root.fileActions
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        icon: "star"
                        filled: modelData.favorite === true
                        tip: modelData.favorite ? "Quitar de favoritos" : "Añadir a favoritos"
                        size: 34
                        flat: true
                        glyphColor: modelData.favorite ? root.accentText : root.onScrimDim
                        onClicked: root.toggleFavorite(modelData)
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      z: -1
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.cellClicked(modelData)
                      onDoubleClicked: {
                        root.cellClicked(modelData)
                        root.applySelected()
                      }
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
                  }

                  // Outline drawn above the media so selection reads on bright thumbs.
                  Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.width: cell.isSel || cell.isMarked ? 2 : 1
                    border.color: cell.isSel || cell.isMarked ? root.accent
                      : cellHover.hovered ? root.strongLine : root.hairline
                  }
                }
              }

              ActionButton {
                visible: root.view.section === "online" && root.items.length > 0 && root.searchHasMore
                label: root.searchTotal >= 0
                  ? ("Cargar más (" + root.items.length + " de " + root.searchTotal + ")")
                  : "Cargar más"
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
                    : root.view.provider === "steam"
                    ? (root.steamSignedIn
                      ? "Search to browse — Apply downloads via steamcmd."
                      : "Search to browse. Sign in above once — Apply downloads via steamcmd.")
                    : "Search to browse. Results download on Apply.")
                  : (root.filterText.trim() !== ""
                    ? "No wallpapers match this filter."
                    : root.view.section === "playlist"
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

              // Errors used to be dead ends (recovery = guessing which
              // button to re-click). Retry re-runs the loader for the
              // current view; for a failed Apply, re-press Apply.
              ActionButton {
                visible: !root.loading && root.errorText !== ""
                label: "Retry"
                Layout.alignment: Qt.AlignHCenter
                onClicked: {
                  root.errorText = ""
                  if (root.view.section === "online") root.runSearch()
                  else {
                    root.itemsSource = ""
                    root.runGrid()
                  }
                }
              }

              // ---- action bar for the selected wallpaper ----
              // One labelled primary (Aplicar); every other action is an
              // icon with a hover label.
              Rectangle {
                visible: root.selectedItem !== null && !root.selectMode
                Layout.fillWidth: true
                Layout.preferredHeight: 92
                color: root.raisedBg
                border.width: 1
                border.color: root.cardBorder
                radius: 0

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: 12
                  anchors.rightMargin: 20
                  anchors.topMargin: 10
                  anchors.bottomMargin: 10
                  spacing: 0

                  Rectangle {
                    visible: root.centerW > 760
                    Layout.preferredWidth: Math.round(72 * 16 / 9)
                    Layout.preferredHeight: 72
                    color: root.insetFill
                    clip: true
                    Image {
                      anchors.fill: parent
                      source: root.selectedItem && root.selectedItem.thumb ? "file://" + root.selectedItem.thumb : ""
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      sourceSize.width: 320
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openPreview()
                    }
                  }

                  ColumnLayout {
                    Layout.leftMargin: 20
                    Layout.fillWidth: true
                    Layout.minimumWidth: 120
                    spacing: 2
                    Text {
                      textFormat: Text.PlainText
                      text: root.selectedIndex() >= 0 ? root.pad2(root.selectedIndex()) : ""
                      color: root.accentText
                      font.family: root.fontFamily
                      font.pixelSize: 12
                      font.letterSpacing: 1
                    }
                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: root.displayName(root.selectedItem)
                      color: root.onScrim
                      font.family: root.displayFamily
                      font.pixelSize: 19
                      font.weight: Font.Medium
                      elide: Text.ElideRight
                    }
                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: root.itemMeta(root.selectedItem)
                      color: root.onScrimFaint
                      font.family: root.fontFamily
                      font.pixelSize: 12
                      elide: Text.ElideRight
                    }
                  }

                  Rectangle {
                    Layout.leftMargin: 20
                    Layout.rightMargin: 28
                    width: 1; height: 44; color: root.cardBorder
                  }

                  ActionButton {
                    label: root.view.section === "online" && !root.compactBar ? "DESCARGAR Y APLICAR" : "APLICAR"
                    icon: "play"
                    primary: true
                    large: true
                    enabled: !root.loading
                    onClicked: root.applySelected()
                  }
                  IconButton {
                    Layout.leftMargin: 12
                    icon: "eye"
                    size: 56
                    tip: "Vista previa  ·  Espacio"
                    onClicked: root.openPreview()
                  }
                  IconButton {
                    Layout.leftMargin: 8
                    visible: root.fileActions
                    icon: "star"
                    filled: !!(root.selectedItem && root.selectedItem.favorite)
                    size: 56
                    glyphColor: root.selectedItem && root.selectedItem.favorite ? root.accentText : root.onScrimDim
                    tip: root.selectedItem && root.selectedItem.favorite ? "Quitar de favoritos" : "Añadir a favoritos"
                    enabled: !root.loading
                    onClicked: root.toggleFavorite(root.selectedItem)
                  }
                  IconButton {
                    Layout.leftMargin: 8
                    visible: root.fileActions && root.primaryOutput() !== null
                    icon: root.isPinnedHere(root.selectedItem) ? "pin-off" : "pin"
                    active: root.isPinnedHere(root.selectedItem)
                    size: 56
                    tip: root.isPinnedHere(root.selectedItem)
                      ? "Soltar de " + (root.primaryOutput() || {}).name
                      : "Fijar en " + (root.primaryOutput() || {}).name
                    enabled: !root.loading
                    onClicked: root.togglePin(root.selectedItem)
                  }
                  IconButton {
                    Layout.leftMargin: 8
                    visible: root.fileActions && root.view.section !== "playlist"
                    icon: "trash-2"
                    size: 56
                    readonly property bool armed: root.confirmDeleteKey === (root.selectedItem ? root.selectedItem.key : "")
                    color: armed ? root.onScrimUrgent : "transparent"
                    glyphColor: armed ? root.onScrim : root.onScrimDim
                    tip: armed ? "Pulsa otra vez para borrar del disco" : "Borrar del disco"
                    enabled: !root.loading
                    onClicked: root.requestDelete()
                  }

                  Rectangle {
                    visible: root.centerW > 1240
                    Layout.leftMargin: 28; Layout.rightMargin: 12
                    width: 1; height: 44; color: root.cardBorder
                  }
                  IconButton {
                    Layout.leftMargin: root.centerW > 1240 ? 0 : 12
                    icon: "x"
                    flat: true
                    size: 40
                    glyphColor: root.onScrim
                    tip: "Deseleccionar"
                    onClicked: root.clearSelection()
                  }
                }
              }
            }

          }
          }
        }

        // ============ MENUS ============
        // Outside-click catcher for any open top-bar menu.
        MouseArea {
          anchors.fill: parent
          z: 40
          visible: root.openMenu !== ""
          onClicked: root.openMenu = ""
        }

        // ---- Playlists ----
        DropMenu {
          menuId: "playlists"
          anchorItem: playlistsNav
          width: 360

          MenuHeading { text: "PLAYLISTS"; Layout.topMargin: 0 }

          Repeater {
            model: root.playlists()
            Rectangle {
              id: plRow
              required property var modelData
              readonly property bool viewing: root.view.section === "playlist" && root.view.name === plRow.modelData.name
              readonly property bool active: root.activePlaylist() === plRow.modelData.name
              Layout.fillWidth: true
              implicitHeight: 48
              color: plRow.viewing ? root.overlayBg : plHover.hovered ? root.hoverFill : "transparent"
              HoverHandler { id: plHover }
              Rectangle { visible: plRow.viewing; width: 2; height: parent.height; color: root.accent }
              AnimIcon {
                id: plIcon
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                name: plRow.active ? "play" : "list"
                filled: plRow.active
                size: 16
                color: plRow.active ? root.accentText : root.onScrimDim
                hovered: plHover.hovered
              }
              Column {
                anchors.left: plIcon.right
                anchors.leftMargin: 12
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: plRow.modelData.name
                  color: root.onScrim
                  font.family: root.fontFamily
                  font.pixelSize: 13
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  text: plRow.modelData.count + " fondos  ·  " + plRow.modelData.intervalMinutes + " min  ·  "
                    + (plRow.modelData.mode === "sequential" ? "en orden" : "aleatorio")
                    + (plRow.active ? "  ·  en rotación" : "")
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: 11
                }
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.openMenu = ""; root.setView("playlist", plRow.modelData.name, "") }
              }
            }
          }

          Text {
            visible: root.playlists().length === 0
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: "Sin playlists todavía. Crea una y añade fondos con el modo selección."
            color: root.onScrimFaint
            font.family: root.fontFamily
            font.pixelSize: 12
          }

          RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 6
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: 36
              color: root.insetFill
              border.width: 1
              border.color: newPlaylistInput.activeFocus ? root.accent : root.cardBorder
              TextInput {
                id: newPlaylistInput
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                color: root.onScrim
                selectionColor: root.accentFill
                font.family: root.fontFamily
                font.pixelSize: 13
                clip: true
                text: root.newPlaylistName
                onTextChanged: root.newPlaylistName = text
                Keys.onReturnPressed: root.createPlaylist()
                Keys.onEnterPressed: root.createPlaylist()
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }
              Text {
                visible: newPlaylistInput.displayText === ""
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Nueva playlist…"
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: 13
              }
            }
            IconButton {
              icon: "check"
              size: 36
              tip: "Crear playlist"
              enabled: root.newPlaylistName.trim() !== "" && !root.loading
              onClicked: root.createPlaylist()
            }
          }
        }

        // ---- Ajustes: rotation, playback, monitors, schedules ----
        DropMenu {
          menuId: "settings"
          anchorItem: rotPill
          alignRight: true
          width: 440

          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            MenuHeading { text: "ROTACIÓN"; Layout.topMargin: 0; Layout.fillWidth: true }
            Text {
              textFormat: Text.PlainText
              text: {
                var vp = root.viewingPlaylist()
                return vp ? "playlist: " + vp.name : (root.activePlaylist() !== "" ? "playlist: " + root.activePlaylist() : "toda la biblioteca")
              }
              color: root.accentText
              font.family: root.fontFamily
              font.pixelSize: 11
            }
          }

          // transport + order
          RowLayout {
            Layout.fillWidth: true
            spacing: 6
            IconButton { icon: "skip-back"; size: 40; tip: "Anterior"; enabled: !root.loading; onClicked: root.mutate(["prev"], "") }
            IconButton {
              readonly property bool paused: !!((root.engine && root.engine.status) || {}).paused
              icon: paused ? "play" : "pause"
              filled: true
              active: !paused
              size: 40
              tip: paused ? "Reanudar rotación" : "Pausar rotación"
              enabled: !root.loading
              onClicked: root.mutate(["toggle"], "")
            }
            IconButton { icon: "skip-forward"; size: 40; tip: "Siguiente"; enabled: !root.loading; onClicked: root.mutate(["next"], "") }
            Item { Layout.fillWidth: true }
            Segmented {
              readonly property string mode: {
                var vp = root.viewingPlaylist()
                return vp ? vp.mode : ((root.engine.config || {}).mode || "shuffle")
              }
              options: [
                { value: "shuffle", icon: "shuffle", tip: "Aleatorio" },
                { value: "sequential", icon: "list-ordered", tip: "En orden" }
              ]
              current: mode === "sequential" ? "sequential" : "shuffle"
              enabled: !root.loading
              onPicked: function(v) { root.setMode(v) }
            }
          }

          // interval
          RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 10
            AnimIcon { name: "timer"; size: 18; color: root.onScrimDim; hovered: intervalHover.hovered }
            HoverHandler { id: intervalHover }
            Segmented {
              options: [{ value: 1, label: "1m" }, { value: 10, label: "10m" }, { value: 30, label: "30m" }, { value: 60, label: "60m" }]
              current: root.contextInterval()
              enabled: !root.loading
              onPicked: function(v) { root.setContextInterval(v) }
            }
            Item { Layout.fillWidth: true }
            IconButton { icon: "chevron-left"; size: 30; flat: true; tip: "−1 min"; enabled: !root.loading; onClicked: root.stepInterval(-1) }
            Text {
              textFormat: Text.PlainText
              text: root.contextInterval() + " min"
              color: root.onScrim
              font.family: root.fontFamily
              font.pixelSize: 13
              Layout.preferredWidth: 52
              horizontalAlignment: Text.AlignHCenter
            }
            IconButton { icon: "chevron-right"; size: 30; flat: true; tip: "+1 min"; enabled: !root.loading; onClicked: root.stepInterval(1) }
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: {
              var st = (root.engine && root.engine.status) || {}
              if (!st.file) return "Nada aplicado todavía"
              if (st.paused) return "En pausa"
              var n = st.nextInSec || 0
              if (n <= 0) return "Rotación activa · cada " + root.contextInterval() + " min"
              return "Siguiente cambio en " + Math.floor(n / 60) + "m " + (n % 60) + "s"
            }
            color: root.onScrimFaint
            font.family: root.fontFamily
            font.pixelSize: 11
          }

          MenuHeading { text: "REPRODUCCIÓN" }
          MenuToggle {
            icon: "battery-charging"
            label: "Pausar video con batería"
            checked: root.playbackCfg().pauseOnBattery
            enabled: !root.loading
            onToggled: root.togglePauseOnBattery()
          }
          MenuToggle {
            icon: "moon"
            label: "Pausar video en inactividad · " + root.playbackCfg().idleSecs + "s"
            checked: root.playbackCfg().pauseWhenIdle
            enabled: !root.loading
            onToggled: root.togglePauseWhenIdle()
          }
          RowLayout {
            visible: root.playbackCfg().pauseWhenIdle
            Layout.fillWidth: true
            Layout.leftMargin: 40
            spacing: 6
            Text {
              textFormat: Text.PlainText
              text: "Espera"
              color: root.onScrimFaint
              font.family: root.fontFamily
              font.pixelSize: 11
              Layout.fillWidth: true
            }
            IconButton { icon: "chevron-left"; size: 28; flat: true; tip: "−30 s"; enabled: !root.loading; onClicked: root.stepIdleSeconds(-1) }
            Text {
              textFormat: Text.PlainText
              text: root.playbackCfg().idleSecs + " s"
              color: root.onScrim
              font.family: root.fontFamily
              font.pixelSize: 12
              Layout.preferredWidth: 48
              horizontalAlignment: Text.AlignHCenter
            }
            IconButton { icon: "chevron-right"; size: 28; flat: true; tip: "+30 s"; enabled: !root.loading; onClicked: root.stepIdleSeconds(1) }
          }
          MenuToggle {
            icon: "volume-x"
            label: "Silenciar videos"
            checked: root.playbackCfg().muted
            enabled: !root.loading
            onToggled: root.toggleMute()
          }
          MenuToggle {
            icon: "maximize"
            label: "Pausar con apps en pantalla completa"
            checked: ((root.engine.config || {}).pauseOnFullscreen) !== false
            enabled: !root.loading
            onToggled: root.setGlobal("pauseOnFullscreen", checked ? "false" : "true")
          }

          MenuHeading { text: "ESCENAS (WALLPAPER ENGINE)" }
          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            AnimIcon {
              name: root.doctorStatus("lwe") === "ok" ? "circle-check" : "triangle-alert"
              size: 16
              color: root.doctorStatus("lwe") === "ok" ? "#7fb069" : "#f4d35e"
            }
            Text {
              Layout.fillWidth: true
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: root.doctorStatus("lwe") === "ok"
                ? "linux-wallpaperengine listo — las escenas y fondos web del Workshop se pueden aplicar."
                : "Instala linux-wallpaperengine (AUR: linux-wallpaperengine-git) para escenas y fondos web. Los videos del Workshop ya funcionan."
              color: root.onScrimDim
              font.family: root.fontFamily
              font.pixelSize: 11
            }
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            AnimIcon { name: "gauge"; size: 18; color: root.onScrimDim; hovered: fpsHover.hovered }
            HoverHandler { id: fpsHover }
            Text {
              textFormat: Text.PlainText
              text: "FPS de escenas"
              color: root.onScrim
              font.family: root.fontFamily
              font.pixelSize: 12
              Layout.fillWidth: true
            }
            Segmented {
              options: [{ value: 15, label: "15" }, { value: 30, label: "30" }, { value: 60, label: "60" }]
              current: parseInt((root.engine.config || {}).sceneFps, 10) || 30
              enabled: !root.loading
              onPicked: function(v) { root.setGlobal("sceneFps", v) }
            }
          }

          MenuHeading { text: "MONITORES" }
          Repeater {
            model: (root.monitors && root.monitors.outputs) || []
            RowLayout {
              id: monRow
              required property var modelData
              readonly property string fit: monRow.modelData.fit || (root.monitors && root.monitors.imageFit) || "crop"
              Layout.fillWidth: true
              spacing: 10
              AnimIcon { name: "monitor"; size: 18; color: monRow.modelData.file ? root.accentText : root.onScrimDim }
              Column {
                Layout.fillWidth: true
                spacing: 1
                Text {
                  textFormat: Text.PlainText
                  text: monRow.modelData.name + "  ·  " + (monRow.modelData.width || 0) + "×" + (monRow.modelData.height || 0)
                    + (monRow.modelData.connected === false ? "  (off)" : "")
                  color: root.onScrim
                  font.family: root.fontFamily
                  font.pixelSize: 12
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: monRow.modelData.file ? "Fijado: " + root.displayName({ key: monRow.modelData.file }) : "Sigue la rotación"
                  color: root.onScrimFaint
                  font.family: root.fontFamily
                  font.pixelSize: 11
                  elide: Text.ElideRight
                }
              }
              Segmented {
                visible: !!monRow.modelData.file
                options: [
                  { value: "crop", icon: "crop", tip: "Recortar" },
                  { value: "fit", icon: "scan", tip: "Encajar" },
                  { value: "stretch", icon: "expand", tip: "Estirar" }
                ]
                current: monRow.fit
                enabled: !root.loading
                onPicked: function(v) { root.monitorAction(["monitor-fit", monRow.modelData.name, v]) }
              }
              IconButton {
                visible: !!monRow.modelData.file
                icon: "pin-off"
                size: 34
                flat: true
                tip: "Soltar"
                enabled: !root.loading
                onClicked: root.monitorAction(["monitor-clear", monRow.modelData.name])
              }
              IconButton {
                visible: !monRow.modelData.file
                icon: "pin"
                size: 34
                flat: true
                tip: "Fijar el fondo actual"
                enabled: !root.loading && !!(root.monitors && root.monitors.globalFile)
                onClicked: root.monitorAction(["monitor-set", monRow.modelData.name, root.monitors.globalFile])
              }
            }
          }
          Repeater {
            model: (root.monitors && root.monitors.stale) || []
            RowLayout {
              id: staleRow
              required property var modelData
              Layout.fillWidth: true
              spacing: 10
              AnimIcon { name: "monitor"; size: 18; color: root.onScrimFaint }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: staleRow.modelData.name + " (desconectado): " + root.displayName({ key: staleRow.modelData.file })
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: 11
                elide: Text.ElideRight
              }
              IconButton { icon: "x"; size: 30; flat: true; tip: "Olvidar"; enabled: !root.loading; onClicked: root.monitorAction(["monitor-clear", staleRow.modelData.name]) }
            }
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
              textFormat: Text.PlainText
              text: "Ajuste por defecto"
              color: root.onScrimDim
              font.family: root.fontFamily
              font.pixelSize: 12
              Layout.fillWidth: true
            }
            Segmented {
              options: [
                { value: "crop", icon: "crop", tip: "Recortar" },
                { value: "fit", icon: "scan", tip: "Encajar" },
                { value: "stretch", icon: "expand", tip: "Estirar" }
              ]
              current: (root.monitors && root.monitors.imageFit) || "crop"
              enabled: !root.loading
              onPicked: function(v) { root.monitorAction(["config-set", "imageFit", v]) }
            }
          }

          MenuHeading { text: "HORARIOS" }
          Repeater {
            model: (root.engine.config && root.engine.config.schedules) || []
            RowLayout {
              id: schedRow
              required property var modelData
              Layout.fillWidth: true
              spacing: 10
              AnimIcon { name: "clock"; size: 16; color: root.onScrimDim }
              Text {
                textFormat: Text.PlainText
                text: schedRow.modelData.time
                color: root.onScrim
                font.family: root.fontFamily
                font.pixelSize: 12
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.displayName({ key: schedRow.modelData.pick })
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: 12
                elide: Text.ElideRight
              }
              IconButton { icon: "trash-2"; size: 30; flat: true; tip: "Quitar"; enabled: !root.loading; onClicked: root.removeSchedule(schedRow.modelData.time, schedRow.modelData.pick) }
            }
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Rectangle {
              Layout.preferredWidth: 64
              implicitHeight: 34
              color: root.insetFill
              border.width: 1
              border.color: newScheduleTimeInput.activeFocus ? root.accent : root.cardBorder
              TextInput {
                id: newScheduleTimeInput
                anchors.fill: parent
                anchors.leftMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                color: root.onScrim
                font.family: root.fontFamily
                font.pixelSize: 12
                text: root.newScheduleTime
                onTextChanged: root.newScheduleTime = text
                Keys.onReturnPressed: root.createSchedule()
                Keys.onEnterPressed: root.createSchedule()
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }
              Text {
                visible: newScheduleTimeInput.displayText === ""
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: "HH:MM"
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: 12
              }
            }
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: 34
              color: root.insetFill
              border.width: 1
              border.color: newSchedulePickInput.activeFocus ? root.accent : root.cardBorder
              TextInput {
                id: newSchedulePickInput
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                color: root.onScrim
                font.family: root.fontFamily
                font.pixelSize: 12
                clip: true
                text: root.newSchedulePick
                onTextChanged: root.newSchedulePick = text
                Keys.onReturnPressed: root.createSchedule()
                Keys.onEnterPressed: root.createSchedule()
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }
              Text {
                visible: newSchedulePickInput.displayText === ""
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "archivo…"
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: 12
                elide: Text.ElideRight
              }
            }
            // Fill the pick with the selected wallpaper (no filename recall).
            IconButton {
              icon: "image"
              size: 34
              tip: "Usar el fondo seleccionado"
              enabled: root.selectedItem !== null && root.view.section !== "online"
              onClicked: {
                var k = String((root.selectedItem && root.selectedItem.key) || "")
                root.newSchedulePick = k.split("/").pop()
              }
            }
            IconButton {
              icon: "check"
              size: 34
              tip: "Añadir horario"
              enabled: !root.loading && root.newScheduleTime.trim() !== "" && root.newSchedulePick.trim() !== ""
              onClicked: root.createSchedule()
            }
          }

          MenuHeading { text: "DIAGNÓSTICO" }
          Repeater {
            model: root.doctorRows
            RowLayout {
              id: docRow
              required property var modelData
              Layout.fillWidth: true
              spacing: 10
              AnimIcon {
                name: docRow.modelData.status === "ok" ? "circle-check"
                  : docRow.modelData.status === "fail" ? "circle-x"
                  : docRow.modelData.status === "warn" ? "triangle-alert" : "info"
                size: 15
                color: docRow.modelData.status === "ok" ? "#7fb069"
                  : docRow.modelData.status === "fail" ? root.onScrimUrgent
                  : docRow.modelData.status === "warn" ? "#f4d35e" : root.onScrimFaint
              }
              Text {
                textFormat: Text.PlainText
                text: docRow.modelData.label
                color: root.onScrim
                font.family: root.fontFamily
                font.pixelSize: 12
                Layout.preferredWidth: 150
                elide: Text.ElideRight
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: docRow.modelData.detail
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: 11
                elide: Text.ElideMiddle
              }
            }
          }
          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.doctorRows.length === 0 ? "Comprobando…" : "También en la terminal: wallpaper-engine.sh doctor"
              color: root.onScrimFaint
              font.family: root.fontFamily
              font.pixelSize: 11
            }
            IconButton { icon: "stethoscope"; size: 32; tip: "Volver a comprobar"; onClicked: root.loadDoctor() }
          }
        }

        // ============ PREVIEW ============
        // Full-card preview: big media, ←/→ browse, Enter applies, Esc closes.
        Rectangle {
          id: previewLayer
          anchors.fill: parent
          z: 60
          visible: opacity > 0
          opacity: root.previewOpen && root.selectedItem !== null ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 160 } }
          color: root.cardBg
          border.width: 1
          border.color: root.cardBorder
          MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }

          readonly property var item: root.selectedItem
          readonly property bool localItem: root.fileActions
          readonly property string videoSource: {
            var it = previewLayer.item
            if (!it || it.kind !== "video" || !root.previewOpen) return ""
            if (root.isWorkshop) return it.file ? "file://" + it.file : ""
            if (previewLayer.localItem) return "file://" + it.key
            return root.previewKey === it.key && root.previewPath !== "" ? "file://" + root.previewPath : ""
          }

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: 28
            anchors.rightMargin: root.propsOpen ? propsDrawer.width + 28 : 28
            spacing: 18

            RowLayout {
              Layout.fillWidth: true
              spacing: 16
              Text {
                textFormat: Text.PlainText
                text: root.selectedIndex() >= 0 ? root.pad2(root.selectedIndex()) + " / " + root.filteredItems().length : ""
                color: root.accentText
                font.family: root.fontFamily
                font.pixelSize: 13
                font.letterSpacing: 1
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.displayName(previewLayer.item)
                color: root.onScrim
                font.family: root.displayFamily
                font.pixelSize: 26
                font.weight: Font.Bold
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                text: root.itemMeta(previewLayer.item)
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: 12
              }
              IconButton { icon: "x"; flat: true; size: 40; glyphColor: root.onScrim; tip: "Cerrar  ·  Esc"; tipBelow: true; onClicked: root.previewOpen = false }
            }

            Item {
              Layout.fillWidth: true
              Layout.fillHeight: true

              Rectangle {
                id: stage
                anchors.centerIn: parent
                // 16:9 stage fitted into the free area.
                width: Math.min(parent.width - 120, parent.height * 16 / 9)
                height: width * 9 / 16
                color: root.insetFill
                clip: true

                Image {
                  anchors.fill: parent
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  source: {
                    var it = previewLayer.item
                    if (!it || !root.previewOpen) return ""
                    if (previewLayer.localItem && it.kind === "image") return "file://" + it.key
                    return it.thumb ? "file://" + it.thumb : ""
                  }
                  sourceSize.width: 1920
                }
                // Scene / web previews ship as GIFs: play them.
                AnimatedImage {
                  anchors.fill: parent
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  visible: previewLayer.videoSource === "" && source !== ""
                  playing: visible && root.previewOpen
                  source: {
                    var it = previewLayer.item
                    if (!it || !root.previewOpen || !it.thumb) return ""
                    return /\.gif$/i.test(String(it.thumb)) ? "file://" + it.thumb : ""
                  }
                }
                Loader {
                  anchors.fill: parent
                  active: previewLayer.videoSource !== ""
                  sourceComponent: Item {
                    MediaPlayer {
                      id: stagePlayer
                      autoPlay: true
                      loops: MediaPlayer.Infinite
                      videoOutput: stageVideo
                      audioOutput: AudioOutput { muted: true }
                      source: previewLayer.videoSource
                      // The Loader stays alive while ←/→ browse, so only
                      // `source` changes — and Qt 6 does not re-run autoPlay
                      // for a new source; the clip sat paused. Restart it.
                      onSourceChanged: if (String(source) !== "") stagePlayer.play()
                      onMediaStatusChanged: {
                        if (mediaStatus === MediaPlayer.LoadedMedia && playbackState !== MediaPlayer.PlayingState)
                          stagePlayer.play()
                      }
                    }
                    VideoOutput {
                      id: stageVideo
                      anchors.fill: parent
                      fillMode: VideoOutput.PreserveAspectCrop
                    }
                  }
                }
                Rectangle {
                  visible: !!previewLayer.item && previewLayer.item.kind !== "image"
                  anchors.top: parent.top
                  anchors.right: parent.right
                  anchors.margins: 14
                  width: stageLive.implicitWidth + 18
                  height: 28
                  color: Qt.rgba(0.07, 0.07, 0.07, 0.82)
                  Text {
                    id: stageLive
                    anchors.centerIn: parent
                    text: {
                      var it = previewLayer.item
                      if (it && it.kind === "scene") return it.playable === false ? "ESCENA · requiere linux-wallpaperengine" : "ESCENA"
                      if (it && it.kind === "web") return it.playable === false ? "WEB · requiere linux-wallpaperengine" : "WEB"
                      return previewLayer.videoSource !== "" ? "LIVE" : "LIVE · sin vista previa"
                    }
                    color: root.onScrim
                    font.family: root.displayFamily
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    font.letterSpacing: 1.4
                  }
                }
              }

              IconButton {
                anchors.right: stage.left
                anchors.rightMargin: 16
                anchors.verticalCenter: stage.verticalCenter
                icon: "chevron-left"
                size: 48
                flat: true
                glyphColor: root.onScrim
                tip: "Anterior  ·  ←"
                onClicked: root.previewStep(-1)
              }
              IconButton {
                anchors.left: stage.right
                anchors.leftMargin: 16
                anchors.verticalCenter: stage.verticalCenter
                icon: "chevron-right"
                size: 48
                flat: true
                glyphColor: root.onScrim
                tip: "Siguiente  ·  →"
                onClicked: root.previewStep(1)
              }
            }

            RowLayout {
              Layout.alignment: Qt.AlignHCenter
              spacing: 10
              ActionButton {
                label: root.view.section === "online" ? "DESCARGAR Y APLICAR" : "APLICAR"
                icon: "play"
                primary: true
                large: true
                enabled: !root.loading && !(previewLayer.item && previewLayer.item.playable === false)
                onClicked: { root.previewOpen = false; root.applySelected() }
              }
              IconButton {
                visible: !!previewLayer.item && previewLayer.item.kind === "scene" && previewLayer.item.playable !== false
                icon: "sliders-horizontal"
                active: root.propsOpen
                size: 56
                tip: "Propiedades de la escena"
                onClicked: root.propsOpen ? (root.propsOpen = false) : root.openProps()
              }
              IconButton {
                visible: previewLayer.localItem
                icon: "star"
                filled: !!(previewLayer.item && previewLayer.item.favorite)
                size: 56
                glyphColor: previewLayer.item && previewLayer.item.favorite ? root.accentText : root.onScrimDim
                tip: previewLayer.item && previewLayer.item.favorite ? "Quitar de favoritos" : "Añadir a favoritos"
                enabled: !root.loading
                onClicked: root.toggleFavorite(previewLayer.item)
              }
              IconButton {
                visible: previewLayer.localItem && root.primaryOutput() !== null
                icon: root.isPinnedHere(previewLayer.item) ? "pin-off" : "pin"
                active: root.isPinnedHere(previewLayer.item)
                size: 56
                tip: (root.isPinnedHere(previewLayer.item) ? "Soltar de " : "Fijar en ") + (root.primaryOutput() || {}).name
                enabled: !root.loading
                onClicked: root.togglePin(previewLayer.item)
              }
              Rectangle { visible: previewLayer.localItem; width: 1; height: 40; color: root.cardBorder; Layout.leftMargin: 6; Layout.rightMargin: 6 }
              Segmented {
                visible: previewLayer.localItem
                cellSize: 56
                options: [
                  { value: "crop", icon: "crop", tip: "Recortar" },
                  { value: "fit", icon: "scan", tip: "Encajar" },
                  { value: "stretch", icon: "expand", tip: "Estirar" }
                ]
                // Fit of the pin when pinned here, else the global default.
                current: {
                  var o = root.primaryOutput()
                  if (o && root.isPinnedHere(previewLayer.item) && o.fit) return o.fit
                  return (root.monitors && root.monitors.imageFit) || "crop"
                }
                enabled: !root.loading
                onPicked: function(v) {
                  var o = root.primaryOutput()
                  if (o && root.isPinnedHere(previewLayer.item)) root.monitorAction(["monitor-fit", o.name, v])
                  else root.monitorAction(["config-set", "imageFit", v])
                }
              }
            }
          }
          // ---- scene properties drawer (linux-wallpaperengine) ----
          Rectangle {
            id: propsDrawer
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            width: Math.min(380, parent.width * 0.36)
            visible: root.propsOpen
            color: root.raisedBg
            border.width: 1
            border.color: root.strongLine
            MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }
            Rectangle { anchors.left: parent.left; width: 2; height: parent.height; color: root.accent }

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: 20
              spacing: 10

              RowLayout {
                Layout.fillWidth: true
                MenuHeading { text: "PROPIEDADES"; Layout.topMargin: 0; Layout.fillWidth: true }
                IconButton { icon: "rotate-ccw"; size: 32; flat: true; tip: "Restablecer"; tipBelow: true; onClicked: root.resetSceneProps() }
                IconButton { icon: "x"; size: 32; flat: true; tip: "Cerrar"; tipBelow: true; onClicked: root.propsOpen = false }
              }
              Text {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: root.propsLoading ? "Leyendo propiedades…"
                  : root.sceneProps.length === 0 ? "Esta escena no expone propiedades."
                  : "Los cambios se aplican al reiniciar la escena (al momento si está activa)."
                color: root.onScrimFaint
                font.family: root.fontFamily
                font.pixelSize: 11
              }

              Flickable {
                id: propsFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: propsCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                WheelHandler {
                  onWheel: function(e) {
                    var maxY = Math.max(0, propsFlick.contentHeight - propsFlick.height)
                    propsFlick.contentY = Math.max(0, Math.min(maxY, propsFlick.contentY - e.angleDelta.y))
                    e.accepted = true
                  }
                }
                ColumnLayout {
                  id: propsCol
                  width: propsFlick.width
                  spacing: 8

                  Repeater {
                    model: root.sceneProps
                    ColumnLayout {
                      id: propRow
                      required property var modelData
                      readonly property string current: root.propValue(propRow.modelData)
                      Layout.fillWidth: true
                      spacing: 4

                      // booleans render as a full toggle row
                      MenuToggle {
                        visible: propRow.modelData.type === "boolean"
                        icon: "sparkles"
                        label: propRow.modelData.label || propRow.modelData.name
                        checked: propRow.current === "1" || propRow.current === "true"
                        onToggled: root.setSceneProp(propRow.modelData.name, checked ? "0" : "1")
                      }

                      RowLayout {
                        visible: propRow.modelData.type !== "boolean"
                        Layout.fillWidth: true
                        Text {
                          Layout.fillWidth: true
                          textFormat: Text.PlainText
                          text: propRow.modelData.label || propRow.modelData.name
                          color: root.onScrim
                          font.family: root.fontFamily
                          font.pixelSize: 12
                          elide: Text.ElideRight
                        }
                        Text {
                          visible: propRow.modelData.type === "slider"
                          textFormat: Text.PlainText
                          text: propRow.current
                          color: root.accentText
                          font.family: root.fontFamily
                          font.pixelSize: 12
                        }
                        Rectangle {
                          visible: propRow.modelData.type === "color"
                          width: 22; height: 22
                          color: root.propColor(propRow.modelData)
                          border.width: 1
                          border.color: root.strongLine
                        }
                      }

                      ValueSlider {
                        visible: propRow.modelData.type === "slider"
                        Layout.fillWidth: true
                        from: propRow.modelData.min !== null ? propRow.modelData.min : 0
                        to: propRow.modelData.max !== null ? propRow.modelData.max : 1
                        stepSize: propRow.modelData.step !== null ? propRow.modelData.step : 0
                        value: parseFloat(propRow.current) || 0
                        onCommitted: function(v) { root.setSceneProp(propRow.modelData.name, String(v)) }
                      }

                      Segmented {
                        visible: propRow.modelData.type === "combolist" && (propRow.modelData.options || []).length <= 5
                        options: (propRow.modelData.options || []).map(function(o) { return { value: String(o.value), label: String(o.label) } })
                        current: propRow.current
                        onPicked: function(v) { root.setSceneProp(propRow.modelData.name, v) }
                      }
                      ActionButton {
                        // long option lists cycle instead of overflowing
                        visible: propRow.modelData.type === "combolist" && (propRow.modelData.options || []).length > 5
                        dense: true
                        label: {
                          var opts = propRow.modelData.options || []
                          for (var i = 0; i < opts.length; i++) if (String(opts[i].value) === propRow.current) return String(opts[i].label)
                          return propRow.current
                        }
                        onClicked: {
                          var opts = propRow.modelData.options || []
                          var idx = 0
                          for (var i = 0; i < opts.length; i++) if (String(opts[i].value) === propRow.current) idx = i
                          root.setSceneProp(propRow.modelData.name, String(opts[(idx + 1) % opts.length].value))
                        }
                      }
                      Rectangle { Layout.fillWidth: true; Layout.topMargin: 4; height: 1; color: root.hairline }
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
}
