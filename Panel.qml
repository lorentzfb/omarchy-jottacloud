import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "lorentzfb.jottacloud"
  ipcTarget: "lorentzfb.jottacloud"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property Item rowColumn: panel.loadedContent ? panel.loadedContent.rowColumn : null

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var status: jotta.status
  readonly property string state: jotta.state
  readonly property bool alarming: Model.isAlarming(state)

  // Rows the cursor walks: every backup folder, then the sync folder.
  readonly property var rows: {
    var list = status.backups.slice()
    if (status.sync) list.push(status.sync)
    return list
  }
  readonly property double totalBytes: {
    var sum = 0
    for (var i = 0; i < rows.length; i++) sum += rows[i].bytes
    return sum
  }

  property bool cursorActive: false
  property string focusSection: "rows"   // "header" | "rows"
  property int rowIndex: 0

  function t(key) { return strings.t(key) }
  function fmt(v, d) { return Commons.I18n.formatNumber(v, d) }
  function ago(ms) { return Model.relativeTime(ms, jotta.now, strings.t, strings.tn, fmt) }
  function bytes(v) { return Model.formatBytes(v, fmt) }
  function clock(ms) { return new Date(ms).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm") }

  // Each folder gets its own shade of the theme accent, used both in the
  // storage bar and as the folder's glyph colour, so the bar reads as a legend.
  function segmentColor(index) {
    var steps = [1.0, 1.9, 0.6, 1.4, 2.6, 0.8]
    var f = steps[index % steps.length]
    return f >= 1 ? Qt.darker(accent, f) : Qt.lighter(accent, 1 / f)
  }

  function stateLine() {
    switch (state) {
    case "offline": return t("state.offline")
    case "loggedOut": return t("state.loggedOut")
    case "error": return strings.tn("state.errors", status.totalErrors).arg(fmt(status.totalErrors))
    case "paused": return status.resumeAtMs > 0 ? t("state.pausedUntil").arg(clock(status.resumeAtMs)) : t("state.paused")
    case "uploading": return strings.tn("state.uploading", status.uploads.count).arg(fmt(status.uploads.count))
    case "scanning": return t("state.scanning")
    case "stale": return t("state.stale")
    default: return t("state.ok")
    }
  }

  function detailLine() {
    if (!status.reachable) return jotta.installed ? t("detail.startDaemon") : t("detail.install")
    var parts = []
    if (status.lastBackupMs > 0) parts.push(t("detail.last").arg(ago(status.lastBackupMs)))
    if (status.nextBackupMs > 0 && !status.paused) parts.push(t("detail.next").arg(ago(status.nextBackupMs)))
    return parts.join(" · ")
  }

  function rowMeta(row) {
    var parts = [strings.tn("row.files", row.files).arg(fmt(row.files)), bytes(row.bytes)]
    if (row.remoteFiles !== undefined && row.remoteFiles !== row.files)
      parts.push(t("row.remote").arg(fmt(row.remoteFiles)))
    if (row.nextBackupMs > 0 && !status.paused) parts.push(t("detail.next").arg(ago(row.nextBackupMs)))
    return parts.join(" · ")
  }

  // Folder path with $HOME shortened to "~".
  function displayPath(path) {
    var home = Quickshell.env("HOME")
    if (home && path && (path === home || path.indexOf(home + "/") === 0))
      return "~" + path.slice(home.length)
    return path || ""
  }

  // Freshness: 1 right after a backup, draining to 0 at the stale threshold.
  function freshness(row) {
    if (!row.lastBackupMs) return 0
    var span = jotta.staleHours * 3600 * 1000
    return Math.max(0, Math.min(1, 1 - (jotta.now - row.lastBackupMs) / span))
  }

  function moveCursor(dy) {
    if (focusSection === "header") {
      if (dy > 0 && rows.length > 0) { focusSection = "rows"; rowIndex = 0 }
      return
    }
    if (dy < 0 && rowIndex === 0) { focusSection = "header"; return }
    rowIndex = Math.max(0, Math.min(rows.length - 1, rowIndex + dy))
    scrollRowIntoView()
  }

  function activateCursor() {
    if (focusSection === "header") jotta.togglePause()
    else if (rows.length > 0) jotta.openFolder(rows[Math.min(rowIndex, rows.length - 1)].path)
  }

  function scrollRowIntoView() {
    if (!panelFlick || !rowColumn || rowIndex >= rowColumn.children.length) return
    var item = rowColumn.children[rowIndex]
    Qt.callLater(function() {
      var y = item.mapToItem(panelFlick.contentItem, 0, 0).y
      if (y < panelFlick.contentY) panelFlick.contentY = Math.max(0, y - Style.space(6))
      else if (y + item.height > panelFlick.contentY + panelFlick.height)
        panelFlick.contentY = y + item.height + Style.space(6) - panelFlick.height
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = "rows"
    rowIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    jotta.refresh()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  Service {
    id: jotta
    settings: root.settings
    panelOpen: root.opened
    tr: strings.t
    tn: strings.tn
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { jotta.refresh(); return "ok" }
    function scan(): string { jotta.scan(); return "ok" }
    function status(): string { return root.state }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.stateGlyph(root.state)
    active: root.alarming
    dimmed: root.state === "paused"
    tooltipText: root.opened ? "" : (root.stateLine() + (root.detailLine() !== "" ? "\n" + root.detailLine() : ""))
    onPressed: function(b) {
      if (b === Qt.RightButton) jotta.scan()
      else if (b === Qt.MiddleButton) jotta.togglePause()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(600))

    content: PanelKeyCatcher {
      property alias panelFlick: panelFlick
      property alias rowColumn: rowColumn
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(k) {
        var key = String(k).toLowerCase()
        if (key === "r") jotta.refresh()
        else if (key === "s") jotta.scan()
        else if (key === "p") jotta.togglePause()
        else if (key === "w") jotta.openWeb()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Jottacloud"
            meta: root.stateLine()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.state === "paused" ? 0.5 : 1.0
            iconComponent: Component {
              JottacloudIcon {
                iconSize: Style.font.display
                color: root.alarming ? root.urgent : root.foreground
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: pauseSwitch
                visible: root.status.reachable && root.status.loggedIn
                checked: !root.status.paused
                busy: jotta.busy
                hasCursor: root.cursorActive && root.focusSection === "header"
                foreground: root.foreground
                onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "header" } }
                onToggled: jotta.togglePause()
                PanelToolTip {
                  visible: pauseSwitch.containsMouse
                  text: root.status.paused ? root.t("action.resume") : root.t("action.pause").arg(jotta.pauseDuration)
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          PlainText {
            visible: text !== ""
            width: parent.width
            text: root.detailLine()
            color: root.dim
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PlainText {
            visible: jotta.lastError !== ""
            width: parent.width
            text: jotta.lastError
            color: root.urgent
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Storage: total in the cloud, then how the backed-up bytes split
          // across folders.
          Column {
            visible: root.status.reachable
            width: parent.width
            spacing: Style.space(6)

            RowLayout {
              width: parent.width
              PlainText { text: root.t("storage.stored"); color: root.dim; font.pixelSize: Style.font.bodySmall }
              Item { Layout.fillWidth: true }
              PlainText {
                font.pixelSize: Style.font.bodySmall
                text: root.status.capacityBytes > 0
                  ? root.t("storage.ofCapacity").arg(root.bytes(root.status.usageBytes)).arg(root.bytes(root.status.capacityBytes))
                  : root.t("storage.unlimited").arg(root.bytes(root.status.usageBytes))
              }
            }

            Meter {
              visible: root.status.capacityBytes > 0
              width: parent.width
              fraction: Math.max(0, Model.usageFraction(root.status))
              fill: Model.usageFraction(root.status) > 0.9 ? root.urgent : root.accent
            }

            Row {
              id: splitBar
              visible: root.totalBytes > 0
              width: parent.width
              height: Style.space(8)
              spacing: 2
              Repeater {
                model: root.rows
                Rectangle {
                  required property var modelData
                  required property int index
                  width: Math.max(2, (splitBar.width - splitBar.spacing * (root.rows.length - 1)) * modelData.bytes / root.totalBytes)
                  height: splitBar.height
                  radius: height / 2
                  color: root.segmentColor(index)
                }
              }
            }
          }

          PanelSeparator { visible: root.rows.length > 0; foreground: root.foreground }

          PanelSectionHeader {
            visible: root.rows.length > 0
            text: root.t("section.folders")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            id: rowColumn
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.rows
              FolderRow {
                required property var modelData
                required property int index
                width: rowColumn.width
                row: modelData
                rowIndex: index
              }
            }
          }

          PlainText {
            visible: root.status.reachable && root.rows.length === 0
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.t("section.empty")
            color: root.dim
          }

          PanelSeparator { foreground: root.foreground }

          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            PlainText {
              Layout.fillWidth: true
              text: root.status.email !== "" ? root.status.email + (root.status.hostname !== "" ? " · " + root.status.hostname : "") : ""
              color: root.dim
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            PanelActionButton {
              iconText: Model.GLYPH.scan
              tooltipText: root.t("action.scan")
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.status.reachable && !jotta.busy
              onClicked: jotta.scan()
            }
            PanelActionButton {
              iconText: Model.GLYPH.web
              tooltipText: root.t("action.web")
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: jotta.openWeb()
            }
          }
        }
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  component Meter: Item {
    property real fraction: 0
    property color fill: root.accent
    height: Style.space(4)
    Rectangle { anchors.fill: parent; radius: height / 2; color: root.track }
    Rectangle {
      width: parent.width * Math.max(0, Math.min(1, parent.fraction))
      height: parent.height
      radius: height / 2
      color: parent.fill
      Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
    }
  }

  component FolderRow: CursorSurface {
    id: folderRow
    property var row: null
    property int rowIndex: 0
    readonly property bool isSync: !!row && row.remoteFiles !== undefined
    readonly property real progress: row && row.uploads ? Model.progressFraction(row.uploads) : -1
    readonly property bool uploading: !!(row && row.uploads && row.uploads.count > 0)

    hasCursor: root.cursorActive && root.focusSection === "rows" && root.rowIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.focusSection = "rows"; root.rowIndex = folderRow.rowIndex }
      onClicked: jotta.openFolder(folderRow.row.path)
    }

    ColumnLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(4)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        PlainText {
          text: folderRow.isSync ? Model.GLYPH.sync : Model.GLYPH.folder
          color: root.segmentColor(folderRow.rowIndex)
          font.pixelSize: Style.font.icon
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          RowLayout {
            Layout.fillWidth: true
            PlainText {
              Layout.fillWidth: true
              text: folderRow.isSync ? root.t("row.sync") : (folderRow.row ? folderRow.row.name : "")
              elide: Text.ElideRight
            }
            PlainText {
              font.pixelSize: Style.font.bodySmall
              color: folderRow.row && folderRow.row.errors > 0 ? root.urgent : root.dim
              text: !folderRow.row ? ""
                : folderRow.row.errors > 0 ? strings.tn("state.errors", folderRow.row.errors).arg(root.fmt(folderRow.row.errors))
                : folderRow.uploading ? (folderRow.progress >= 0 ? root.t("row.uploadingPct").arg(root.fmt(Math.round(folderRow.progress * 100))) : root.t("row.uploading"))
                : root.ago(folderRow.row.lastBackupMs)
            }
          }

          PlainText {
            Layout.fillWidth: true
            visible: !!folderRow.row && !!folderRow.row.path
            text: folderRow.row ? root.displayPath(folderRow.row.path) : ""
            color: root.dim
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          PlainText {
            Layout.fillWidth: true
            text: folderRow.row ? root.rowMeta(folderRow.row) : ""
            color: root.dim
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // Upload progress while transferring; otherwise how fresh the last
      // backup is, draining toward the stale threshold.
      Meter {
        Layout.fillWidth: true
        Layout.leftMargin: Style.font.icon + Style.space(8)
        fraction: folderRow.uploading ? Math.max(0.03, folderRow.progress) : root.freshness(folderRow.row || {})
        fill: folderRow.uploading ? root.accent
          : (folderRow.row && folderRow.row.errors > 0) || fraction < 0.15 ? root.urgent
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
      }
    }
  }
}
