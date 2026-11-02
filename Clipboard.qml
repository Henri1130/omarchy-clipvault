import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ClipboardHistory.js" as ClipboardHistory

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var manifest: null
  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool clearConfirmOpen: false
  property var history: []
  property bool watchersStarted: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: (manifest && manifest.__sourceDir)
    ? String(manifest.__sourceDir)
    : (home + "/.config/omarchy/plugins/henri.clipvault")
  readonly property string captureScript: pluginDir + "/capture.sh"
  readonly property string saveScript: pluginDir + "/save-history.sh"
  readonly property string pruneScript: pluginDir + "/prune-images.sh"
  readonly property string pasteScript: pluginDir + "/paste.sh"
  readonly property string stateDir: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    return (xdg && xdg.length > 0) ? (xdg + "/omarchy") : (home + "/.local/state/omarchy")
  }
  property string historyPath: stateDir + "/clipboard-history.json"
  property string pendingHistory: ""
  property bool saveQueued: false
  property bool saving: false
  property bool suppressCapture: false
  // Shares the [menu] surface tokens — themes that style the menu also
  // style the clipboard. Selected-row colors composed in the
  // singleton so consumers drop them straight into Rectangle bindings.
  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(875), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int historyLimit: 300
  readonly property int actionButtonSize: Math.round(rowHeight * 0.6)
  // Must stay in lockstep with capture.sh JSON_MAX. Collectors abort above this
  // so a huge clipboard payload cannot accumulate in the shell.
  readonly property int captureJsonLimit: 2097152
  property bool ignoreNextHistoryReload: false
  // Window that had focus when the overlay opened; paste.sh refocuses it so a
  // mouse click cannot paste into whatever window sits under the pointer.
  property string targetWindow: ""
  property string lastWindow: ""
  property string pendingPasteText: ""
  // Raw text of the last history load; identical reloads are ignored.
  property string lastLoadedRaw: ""

  function currentWindowAddress() {
    var toplevel = Hyprland.activeToplevel
    var address = ClipboardHistory.normalizeWindowAddress(toplevel ? toplevel.address : "")
    return address || root.lastWindow
  }

  function open(payloadJson) {
    root.targetWindow = root.currentWindowAddress()
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
    Qt.callLater(function() { root.focusSearch() })
  }

  // Keyboard focus lives in the header search box so its caret and mouse text
  // selection work; typing on open still filters because it is focused then.
  function focusSearch() {
    if (root.opened) searchInput.forceActiveFocus()
  }

  onFilterTextChanged: {
    if (searchInput.text !== root.filterText) searchInput.text = root.filterText
  }

  // Shared by the search box (fromInput) and the fallback key catcher. Text
  // editing keys are left to the TextInput; list keys behave as before.
  function handleKey(event, fromInput) {
    if (root.clearConfirmOpen) {
      clearConfirm.handleKey(event)
      event.accepted = true
      return
    }

    var shift = event.modifiers & Qt.ShiftModifier
    if (event.key === Qt.Key_Escape) {
      if (root.filterText) root.setFilter("")
      else root.close()
      event.accepted = true
    } else if (event.key === Qt.Key_U && event.modifiers === Qt.ControlModifier) {
      root.setFilter("")
      event.accepted = true
    } else if (!fromInput && Util.editsFilter(event, root.filterText)) {
      root.setFilter(Util.editedFilter(event, root.filterText))
      event.accepted = true
    } else if (event.key === Qt.Key_Delete) {
      if (shift) {
        root.requestClearHistory()
      } else if (fromInput && (searchInput.selectedText.length > 0 || searchInput.cursorPosition < searchInput.text.length)) {
        return
      } else {
        root.removeDisplayIndex(root.selectedIndex)
      }
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      root.select(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      root.select(1)
      event.accepted = true
    } else if (event.key === Qt.Key_PageUp) {
      root.select(-6)
      event.accepted = true
    } else if (event.key === Qt.Key_PageDown) {
      root.select(6)
      event.accepted = true
    } else if (event.key === Qt.Key_Home && !shift) {
      root.selectAbsolute(0)
      event.accepted = true
    } else if (event.key === Qt.Key_End && !shift) {
      root.selectAbsolute(displayModel.count - 1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (root.cursorActive && (event.modifiers & Qt.AltModifier)) root.openIndex(root.selectedIndex)
      else if (root.cursorActive && shift) root.copyIndex(root.selectedIndex)
      else if (root.cursorActive) root.activateIndex(root.selectedIndex)
      else if (displayModel.count > 0) root.cursorActive = true
      event.accepted = true
    } else if (event.key === Qt.Key_P && (event.modifiers & Qt.AltModifier)) {
      root.togglePin()
      event.accepted = true
    } else if (!fromInput && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
      root.setFilter(root.filterText + event.text)
      event.accepted = true
    }
  }

  function close() {
    root.cancelClearHistory()
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function loadHistory(raw) {
    var text = String(raw || "")
    if (text === root.lastLoadedRaw) return
    root.lastLoadedRaw = text
    var parsed = ClipboardHistory.parseHistory(raw)
    var limited = ClipboardHistory.limitHistory(parsed, root.historyLimit)
    root.pruneOrphanImages(parsed, limited)
    root.history = limited
    if (root.opened) root.rebuildDisplay()
  }

  function pruneOrphanImages(previous, next) {
    var names = ClipboardHistory.orphanedManagedImageNames(previous, next)
    if (!names || names.length === 0) return
    var cmd = [root.pruneScript, "--remove"]
    for (var i = 0; i < names.length; i++) cmd.push(String(names[i]))
    Quickshell.execDetached(cmd)
  }

  function lockHistoryPermissions() {
    Quickshell.execDetached(["chmod", "600", root.historyPath])
    Quickshell.execDetached(["chmod", "700", root.stateDir + "/clipboard-images"])
  }

  function saveHistory(previous) {
    var before = previous === undefined ? root.history : previous
    root.history = ClipboardHistory.limitHistory(root.history, root.historyLimit)
    root.pruneOrphanImages(before, root.history)
    root.pendingHistory = JSON.stringify(root.history, null, 2) + "\n"
    root.lastLoadedRaw = root.pendingHistory
    root.ignoreNextHistoryReload = true
    if (saveProc.running) {
      root.saveQueued = true
      return
    }
    root.saving = true
    saveProc.stdinEnabled = true
    saveProc.running = true
  }

  function addClipboardEntry(entry) {
    var normalized = ClipboardHistory.normalizeEntry(entry)
    if (!normalized) return

    var previous = root.history
    root.history = ClipboardHistory.addEntry(previous, normalized, root.historyLimit)
    root.saveHistory(previous)
    if (root.opened) root.rebuildDisplay()
  }

  function addClipboardJson(line) {
    if (root.suppressCapture)
      return
    var raw = String(line || "")
    if (!raw || raw.length > root.captureJsonLimit)
      return
    root.addClipboardEntry(ClipboardHistory.parseEntryJson(raw))
  }

  function acceptCaptureChunk(data) {
    var raw = String(data || "")
    if (!raw || raw.length > root.captureJsonLimit)
      return
    root.addClipboardJson(raw)
  }

  function requestClearHistory() {
    if (!ClipboardHistory.hasUnpinned(root.history)) return
    clearConfirm.selectedIndex = 1
    root.clearConfirmOpen = true
  }

  function cancelClearHistory() {
    root.clearConfirmOpen = false
    root.disarmPointer()
    Qt.callLater(function() { root.focusSearch() })
  }

  function confirmClearHistory() {
    var previous = root.history
    root.history = ClipboardHistory.clearUnpinned(previous)
    root.saveHistory(previous)
    root.selectedIndex = 0
    root.cursorActive = false
    root.disarmPointer()
    root.clearConfirmOpen = false
    root.rebuildDisplay()
    Qt.callLater(function() { root.focusSearch() })
  }

  function removeDisplayIndex(index) {
    if (index < 0 || index >= displayModel.count) return

    var removed = displayModel.get(index).historyIndex
    var previous = root.history
    root.history = ClipboardHistory.removeEntryAt(previous, removed)
    root.saveHistory(previous)

    // Update rows in place: a full rebuild resets the view and shifts rows
    // under the pointer, so the next click lands on a different item.
    displayModel.remove(index)
    for (var i = 0; i < displayModel.count; i++) {
      var current = displayModel.get(i).historyIndex
      var next = ClipboardHistory.historyIndexAfterRemoval(current, removed)
      if (next !== current) displayModel.setProperty(i, "historyIndex", next)
    }

    if (displayModel.count === 0) {
      root.selectedIndex = 0
      root.cursorActive = false
    } else if (root.selectedIndex >= displayModel.count) {
      root.selectedIndex = displayModel.count - 1
    }

    root.disarmPointer()
    root.focusSearch()
  }

  function togglePinHistory(historyIndex) {
    root.history = ClipboardHistory.togglePinAt(root.history, historyIndex)
    root.saveHistory()
    if (!root.opened) return

    // Flip the pin in place and keep the row where it is while the popup is
    // open; pinned items move to the top on the next open or search.
    var entry = root.history[historyIndex]
    for (var i = 0; i < displayModel.count; i++) {
      if (displayModel.get(i).historyIndex === historyIndex) {
        displayModel.setProperty(i, "pinned", !!(entry && entry.pinned))
        break
      }
    }
  }

  function togglePinAt(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.togglePinHistory(row.historyIndex)
  }

  // IPC + in-popup Alt+P. No-op when the popup is closed.
  function togglePin() {
    if (!root.opened) return
    root.togglePinAt(root.selectedIndex)
  }

  function rebuildDisplay(keepHistoryIndex) {
    var rows = ClipboardHistory.displayRows(root.history, root.filterText, 50, root.stateDir + "/clipboard-images")
    var keep = keepHistoryIndex === undefined ? -1 : Number(keepHistoryIndex)

    displayModel.clear()
    var keptIndex = -1
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      displayModel.append({
        entryType: row.entryType,
        fullText: row.fullText,
        previewText: row.previewText,
        previewImage: row.previewImage ? Util.fileUrl(row.previewImage) : "",
        path: row.path,
        mime: row.mime,
        historyIndex: row.index,
        pinned: row.pinned
      })
      if (keep >= 0 && row.index === keep) keptIndex = i
    }

    if (displayModel.count === 0) {
      selectedIndex = 0
    } else if (keptIndex >= 0) {
      selectedIndex = keptIndex
      cursorActive = true
    } else if (selectedIndex >= displayModel.count) {
      selectedIndex = displayModel.count - 1
    } else if (selectedIndex < 0) {
      selectedIndex = 0
    }

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    if (root.cursorActive && root.selectedIndex === index) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.applySelected(row)
  }

  function copyIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.copySelected(row)
  }

  function openIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.openSelected(row)
  }

  function beginPaste() {
    root.suppressCapture = true
    captureResumeTimer.restart()
    root.close()
  }

  // The exact entry comes from in-memory history (the list was built from it),
  // never from the capped display row or a history-file lookup by index.
  function runPaste(row, copyOnly) {
    if (!row) return
    var request = ClipboardHistory.pasteRequest(root.history, row.historyIndex)
    var window = root.targetWindow
    root.beginPaste()
    if (!request) return

    var cmd = [root.pasteScript]
    if (copyOnly) cmd.push("--copy-only")
    else if (window) cmd.push("--window", window)

    Qt.callLater(function() {
      if (request.kind === "image") {
        Quickshell.execDetached(cmd.concat(["--file", request.mime, request.path]))
        return
      }
      if (pasteProc.running) return
      root.pendingPasteText = request.text
      pasteProc.command = cmd.concat(["--text"])
      pasteProc.stdinEnabled = true
      pasteProc.running = true
    })
  }

  function applySelected(row) {
    root.runPaste(row, false)
  }

  function copySelected(row) {
    root.runPaste(row, true)
  }

  function openSelected(row) {
    if (!row) return
    var historyIndex = String(row.historyIndex)
    root.beginPaste()
    Qt.callLater(function() {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-open", "--history-index", historyIndex])
    })
  }

  function startWatchers() {
    if (root.watchersStarted || !root.captureScript) return
    root.watchersStarted = true
    initProc.running = true
  }

  Component.onCompleted: {
    root.lockHistoryPermissions()
    root.startWatchers()
    // Seed Hyprland.activeToplevel so the first open after a reload already
    // knows which window to paste back into.
    Hyprland.refreshToplevels()
  }
  onPluginDirChanged: root.startWatchers()

  ListModel { id: displayModel }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      if (root.opened) return
      var toplevel = Hyprland.activeToplevel
      var address = ClipboardHistory.normalizeWindowAddress(toplevel ? toplevel.address : "")
      if (address) root.lastWindow = address
    }
  }

  Process {
    id: pasteProc
    stdinEnabled: true
    onStarted: {
      pasteProc.write(root.pendingPasteText)
      root.pendingPasteText = ""
      pasteProc.stdinEnabled = false
    }
  }

  IpcHandler {
    target: "henri.clipvault"
    function togglePin() {
      root.togglePin()
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
    threshold: 3
  }

  Process {
    id: saveProc
    command: [root.saveScript]
    stdinEnabled: true
    onStarted: {
      saveProc.write(root.pendingHistory)
      saveProc.stdinEnabled = false
    }
    onExited: function() {
      root.saving = false
      historyQuietTimer.restart()
      if (root.saveQueued) {
        root.saveQueued = false
        Qt.callLater(root.saveHistory)
      }
    }
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: false
    printErrors: false
    // Never change permissions from these handlers: that raises an inotify ATTRIB event,
    // which fires onFileChanged again, an endless reload loop (hundreds per
    // second) that rebuilt the open list and snapped it back to the top.
    // Permissions are locked once at startup; the scripts write 600 anyway.
    onLoaded: {
      if (root.saving || root.ignoreNextHistoryReload || historyQuietTimer.running) return
      root.loadHistory(text())
    }
    onLoadFailed: root.loadHistory("[]")
    onFileChanged: {
      if (root.saving || root.ignoreNextHistoryReload || historyQuietTimer.running) {
        root.ignoreNextHistoryReload = false
        return
      }
      reload()
    }
  }

  // Reap leftover stock and ClipVault watchers from a previous shell instance.
  // pdeathsig then kills ours whenever the shell exits.
  Process {
    id: initProc
    command: ["bash", "-c", "pkill -f -- 'wl-paste .*--watch .*/(clipboard|clipvault)/capture\\.sh' >/dev/null 2>&1 || true"]
    onExited: {
      currentProc.running = true
      textWatchProc.running = true
      imageWatchProc.running = true
    }
  }

  Process {
    id: currentProc
    command: [root.captureScript]
    stdout: StdioCollector {
      waitForEnd: true
      onDataChanged: {
        if (text.length > root.captureJsonLimit)
          currentProc.running = false
      }
      onStreamFinished: {
        if (text.length > root.captureJsonLimit)
          return
        root.addClipboardJson(text)
      }
    }
  }

  Process {
    id: textWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "text", "--watch", root.captureScript, "text"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.acceptCaptureChunk(data) }
    }
  }

  Process {
    id: imageWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "image/png", "--watch", root.captureScript, "image/png"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.acceptCaptureChunk(data) }
    }
  }

  // A watcher that dies takes clipboard history with it, silently: copying still
  // works, the picker still opens, and the old entries are all still there, so
  // nothing recorded until the next shell reload. Bring it back instead.
  Timer {
    id: watchRestartTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (!textWatchProc.running) textWatchProc.running = true
      if (!imageWatchProc.running) imageWatchProc.running = true
    }
  }

  Timer {
    id: captureResumeTimer
    interval: 700
    repeat: false
    onTriggered: root.suppressCapture = false
  }

  Timer {
    id: historyQuietTimer
    interval: 250
    repeat: false
    onTriggered: root.ignoreNextHistoryReload = false
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-clipvault"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.clearConfirmOpen ? 20 : 0

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.handleKey(event, false) }

        ConfirmDialog {
          id: clearConfirm

          anchors.fill: parent
          opened: root.clearConfirmOpen
          z: 10
          message: "Delete all unpinned items? Pinned items are kept."
          confirmText: "Delete"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelClearHistory()
          onConfirmed: root.confirmClearHistory()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Item {
            id: searchBox
            anchors.left: parent.left
            anchors.right: clearAllBtn.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height

            // Clicks beside the text line still focus the box (caret at end).
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.IBeamCursor
              onClicked: {
                searchInput.forceActiveFocus()
                searchInput.cursorPosition = searchInput.text.length
              }
            }

            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: searchInput.text.length === 0
              text: "Search clipboard…"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.58
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }

            TextInput {
              id: searchInput
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              color: root.foreground
              selectionColor: root.selectedBackground
              selectedTextColor: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              selectByMouse: true
              activeFocusOnPress: true
              clip: true
              focus: true
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) { root.handleKey(event, true) }
              onTextChanged: {
                if (text !== root.filterText) root.setFilter(text)
              }
            }
          }

          Item {
            id: clearAllBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height
            width: Style.space(116)
            z: 3

            Text {
              anchors.centerIn: parent
              text: "🗑 Clear all"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              opacity: 0.8
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.requestClearHistory()
            }
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          Row {
            anchors.fill: parent
            spacing: 0

            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: displayModel
                clip: true
                spacing: Style.space(4)
                pixelAligned: true
                boundsBehavior: Flickable.StopAtBounds
                delegate: Rectangle {
                  id: row
                  required property int index
                  required property string entryType
                  required property string previewText
                  required property string fullText
                  required property string previewImage
                  required property bool pinned

                  readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
                  readonly property bool hasPreview: previewImage.length > 0

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: hasCursor ? root.selectedBackground : "transparent"

                  Row {
                    id: rowContent
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(8) + root.actionButtonSize * 2 + Style.space(10)
                    anchors.topMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(8)
                    spacing: Style.space(10)

                    // previewImage is only ever a sanitized managed copy
                    // (see ClipboardHistory.imagePreviewPath); never the
                    // copied file itself.
                    Image {
                      visible: row.hasPreview
                      width: visible ? parent.height : 0
                      height: parent.height
                      source: row.previewImage
                      sourceSize.width: Math.max(1, height)
                      sourceSize.height: Math.max(1, height)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      cache: true
                      smooth: true
                    }

                    Text {
                      width: Math.max(0, parent.width - (row.hasPreview ? parent.height + parent.spacing : 0))
                      height: parent.height
                      text: row.previewText
                      textFormat: Text.PlainText
                      color: row.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      opacity: row.entryType === "image" || row.entryType === "file" ? 0.72 : 1.0
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      verticalAlignment: Text.AlignVCenter
                    }
                  }

                  Row {
                    id: actionButtons
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)
                    z: 2

                    Item {
                      id: pinBtn
                      width: root.actionButtonSize
                      height: root.actionButtonSize

                      Text {
                        anchors.centerIn: parent
                        text: "📌"
                        textFormat: Text.PlainText
                        color: row.hasCursor ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        opacity: row.pinned ? 1 : 0.3
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        preventStealing: true
                        onPositionChanged: function(mouse) {
                          root.selectFromPointer(row.index, pinBtn, mouse)
                        }
                        onClicked: {
                          root.cursorActive = true
                          root.selectedIndex = row.index
                          root.togglePinAt(row.index)
                        }
                      }
                    }

                    Item {
                      id: delBtn
                      width: root.actionButtonSize
                      height: root.actionButtonSize

                      Text {
                        anchors.centerIn: parent
                        text: "✕"
                        textFormat: Text.PlainText
                        color: row.hasCursor ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        opacity: 0.8
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        preventStealing: true
                        onPositionChanged: function(mouse) {
                          root.selectFromPointer(row.index, delBtn, mouse)
                        }
                        onClicked: root.removeDisplayIndex(row.index)
                      }
                    }
                  }

                  MouseArea {
                    id: rowClick
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.right: actionButtons.left
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    preventStealing: true
                    onPositionChanged: function(mouse) {
                      root.selectFromPointer(row.index, row, mouse)
                    }
                    onClicked: {
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      root.activateIndex(row.index)
                    }
                  }
                }
              }
            }

            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              property var activeRow: displayModel.count > 0 && root.selectedIndex >= 0 && root.selectedIndex < displayModel.count ? displayModel.get(root.selectedIndex) : null

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.28)
              }

              Text {
                visible: parent.activeRow && !parent.activeRow.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.rightMargin: 0
                anchors.topMargin: 0
                anchors.bottomMargin: 0
                text: parent.activeRow ? parent.activeRow.fullText : ""
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                verticalAlignment: Text.AlignTop
              }

              Image {
                visible: parent.activeRow && parent.activeRow.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.rightMargin: 0
                anchors.topMargin: 0
                anchors.bottomMargin: 0
                // Sanitized managed copy only; decode is bounded to the pane.
                source: parent.activeRow ? parent.activeRow.previewImage : ""
                sourceSize.width: Math.max(1, width)
                sourceSize.height: Math.max(1, height)
                fillMode: Image.PreserveAspectFit
                verticalAlignment: Image.AlignTop
                asynchronous: true
                cache: true
                smooth: true
              }

              MouseArea {
                anchors.fill: parent
                enabled: !!parent.activeRow
                cursorShape: Qt.PointingHandCursor
                onClicked: root.activateIndex(root.selectedIndex)
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              text: "󰅌"
              textFormat: Text.PlainText
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: root.history.length === 0 ? "Clipboard is empty" : "No matches for “" + root.filterText + "”"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
