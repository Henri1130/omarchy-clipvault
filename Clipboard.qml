import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
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
  property string historyPath: home + "/.local/state/omarchy/clipboard-history.json"
  // Shares the [menu] surface tokens — themes that style the menu also
  // style the clipboard. Selected-row colors composed in the
  // singleton so consumers drop them straight into Rectangle bindings.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
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

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
    root.history = ClipboardHistory.parseHistory(raw)
    if (root.opened) root.rebuildDisplay()
  }

  function lockHistoryPermissions() {
    Quickshell.execDetached(["chmod", "600", root.historyPath])
    Quickshell.execDetached(["chmod", "700", root.home + "/.local/state/omarchy/clipboard-images"])
  }

  function saveHistory() {
    historyFile.setText(JSON.stringify(root.history.slice(0, root.historyLimit), null, 2) + "\n")
    root.lockHistoryPermissions()
  }

  function addClipboardEntry(entry) {
    var normalized = ClipboardHistory.normalizeEntry(entry)
    if (!normalized) return

    root.history = ClipboardHistory.addEntry(root.history, normalized, root.historyLimit)
    root.saveHistory()
    if (root.opened) root.rebuildDisplay()
  }

  function addClipboardJson(line) {
    root.addClipboardEntry(ClipboardHistory.parseEntryJson(line))
  }

  function requestClearHistory() {
    if (!ClipboardHistory.hasUnpinned(root.history)) return
    clearConfirm.selectedIndex = 1
    root.clearConfirmOpen = true
  }

  function cancelClearHistory() {
    root.clearConfirmOpen = false
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmClearHistory() {
    root.history = ClipboardHistory.clearUnpinned(root.history)
    root.saveHistory()
    root.selectedIndex = 0
    root.cursorActive = false
    root.disarmPointer()
    root.clearConfirmOpen = false
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function removeDisplayIndex(index) {
    if (index < 0 || index >= displayModel.count) return

    var row = displayModel.get(index)
    root.history = ClipboardHistory.removeEntryAt(root.history, row.historyIndex)
    root.saveHistory()

    if (displayModel.count <= 1) {
      root.selectedIndex = 0
      root.cursorActive = false
    } else if (root.selectedIndex >= displayModel.count - 1) {
      root.selectedIndex = displayModel.count - 2
    }

    root.disarmPointer()
    root.rebuildDisplay()
  }

  function togglePinHistory(historyIndex) {
    root.history = ClipboardHistory.togglePinAt(root.history, historyIndex)
    root.saveHistory()
    if (root.opened) root.rebuildDisplay(historyIndex)
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
    var rows = ClipboardHistory.displayRows(root.history, root.filterText, 50)
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

  function applySelected(row) {
    if (!row) return
    root.opened = false
    if (row.entryType === "image") {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-paste-file", row.mime, row.path])
    } else if (row.fullText) {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-paste-text", "--shift-insert", "--history-index", String(row.historyIndex)])
    }
  }

  function copySelected(row) {
    if (!row) return
    root.opened = false
    if (row.entryType === "image") {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-paste-file", "--copy-only", row.mime, row.path])
    } else if (row.fullText) {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-paste-text", "--copy-only", "--history-index", String(row.historyIndex)])
    }
  }

  function openSelected(row) {
    if (!row) return
    root.opened = false
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-open", "--history-index", String(row.historyIndex)])
  }

  function startWatchers() {
    if (root.watchersStarted || !root.captureScript) return
    root.watchersStarted = true
    initProc.running = true
  }

  Component.onCompleted: root.startWatchers()
  onPluginDirChanged: root.startWatchers()

  ListModel { id: displayModel }

  IpcHandler {
    target: "henri.clipvault"
    function togglePin() {
      root.togglePin()
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.lockHistoryPermissions()
      root.loadHistory(text())
    }
    onLoadFailed: root.loadHistory("[]")
    onFileChanged: reload()
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
      onStreamFinished: root.addClipboardJson(text)
    }
  }

  Process {
    id: textWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "text", "--watch", root.captureScript, "text"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  Process {
    id: imageWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "image/png", "--watch", root.captureScript, "image/png"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
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
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.clearConfirmOpen) {
            if (clearConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (event.modifiers & Qt.ShiftModifier) root.requestClearHistory()
            else root.removeDisplayIndex(root.selectedIndex)
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
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(displayModel.count - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive && (event.modifiers & Qt.AltModifier)) root.openIndex(root.selectedIndex)
            else if (root.cursorActive && (event.modifiers & Qt.ShiftModifier)) root.copyIndex(root.selectedIndex)
            else if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.key === Qt.Key_P && (event.modifiers & Qt.AltModifier)) {
            root.togglePin()
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

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

          Text {
            anchors.left: parent.left
            anchors.right: clearAllBtn.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search clipboard…"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
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

                  MouseArea {
                    id: rowClick
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    z: 0
                    onPositionChanged: function(mouse) {
                      root.selectFromPointer(row.index, row, mouse)
                    }
                    onClicked: {
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      root.activateIndex(row.index)
                    }
                  }

                  Row {
                    id: rowContent
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(8)
                    anchors.topMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(8)
                    spacing: Style.space(10)
                    z: 1

                    Image {
                      visible: row.hasPreview
                      width: visible ? parent.height : 0
                      height: parent.height
                      source: row.previewImage
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      smooth: true
                    }

                    Text {
                      width: Math.max(0, parent.width - (row.hasPreview ? parent.height + parent.spacing : 0) - root.actionButtonSize * 2 - parent.spacing * 2)
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

                    Item {
                      id: pinBtn
                      width: root.actionButtonSize
                      height: root.actionButtonSize
                      anchors.verticalCenter: parent.verticalCenter

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
                        onPressed: (mouse) => { mouse.accepted = true }
                        onClicked: (mouse) => {
                          mouse.accepted = true
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
                      anchors.verticalCenter: parent.verticalCenter

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
                        onPressed: (mouse) => { mouse.accepted = true }
                        onClicked: (mouse) => {
                          mouse.accepted = true
                          root.removeDisplayIndex(row.index)
                        }
                      }
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
                source: parent.activeRow ? parent.activeRow.previewImage : ""
                fillMode: Image.PreserveAspectFit
                verticalAlignment: Image.AlignTop
                asynchronous: true
                smooth: true
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
