import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "../io.github.hugorolimf.kit/ui"

// Notification history, like macOS's Notification Center: grouped by app,
// newest first. A group shows its latest notification as a stack; a click
// spreads it out. A click on a notification opens its app; × deletes it,
// LIMPAR clears a group, LIMPAR TUDO the whole history. The history is
// the notifications service's (one JSON file per notification), watched with
// inotifywait so the panel and the badge follow it live. "Unseen" counts what
// arrived after the panel was last opened (kept in a state file, so every
// monitor's bell agrees).
Panel {
  id: root
  moduleName: "io.github.hugorolimf.inbox"
  // Portuguese, or English for every other locale.
  readonly property bool portuguese: Qt.locale().name.indexOf("pt") === 0
  readonly property var enText: ({"Notificações": "Notifications", "LIMPAR TUDO": "CLEAR ALL", "Nenhuma notificação": "No notifications", "MOSTRAR MENOS": "SHOW LESS", "MOSTRAR TODAS": "SHOW ALL", "LIMPAR": "CLEAR", "Não perturbe": "Do not disturb"})
  function tr(text) { return portuguese || enText[text] === undefined ? text : enText[text] }
  manageIpc: false

  property var anchorItem: null
  // Do Not Disturb (was a bar indicator), through the notifications
  // service's IPC; read again on every open.
  property bool dnd: false
  onOpenedChanged: if (opened) dndProc.running = true
  function setDnd(on) {
    dnd = on
    Quickshell.execDetached(["omarchy-shell", "notifications", "setDnd", on ? "on" : "off"])
  }
  Process {
    id: dndProc
    command: ["omarchy-shell", "notifications", "isDnd"]
    stdout: StdioCollector {
      onStreamFinished: root.dnd = text.trim() === "on"
    }
  }
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME")
  readonly property string historyDir: home + "/.local/state/omarchy/notifications/history"
  readonly property string imagesDir: home + "/.local/state/omarchy/notifications/images"
  readonly property string stateDir: home + "/.local/state/omarchy/io.github.hugorolimf.inbox"
  readonly property string iphoneIconDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/island-iphone/icons/"

  property var entries: []
  property var expanded: ({})
  // the one notification spread out with its buttons (its file name)
  property string selectedFile: ""
  // bumped each time the panel opens: the cards come in again
  property int openSerial: 0
  property real now: Date.now()

  readonly property int unseen: {
    var n = 0, seen = seenFile.lastSeen
    for (var i = 0; i < entries.length; i++) if (entries[i].timestamp > seen) n++
    return n
  }

  function open() {
    refresh()
    now = Date.now()
    selectedFile = ""
    openSerial++
    root.controller.show()
    seenFile.lastSeen = Date.now()
  }
  function openFromHotkey() { open() }
  function close() {
    root.controller.hide()
    expanded = ({})
    selectedFile = ""
  }
  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() { if (!listProc.running) listProc.running = true }

  // ---- reading and grouping
  readonly property string claudeIcon: home + "/.local/share/icons/hicolor/256x256/apps/claude-code.png"

  function appName(e) {
    var a = String(e.app || "")
    if (a === "" || a === "notify-send" || a === "omarchy-action") return "Omarchy"
    if (a === "Claude Code") return "Claude"
    if (String(e.appIcon || "").indexOf("iphone:") === 0) return a
    void DesktopEntries.applications.values
    var entry = DesktopEntries.heuristicLookup(a)
    if (entry && entry.name && entry.name.toLowerCase() === a.toLowerCase()) return entry.name
    return /[A-Z]/.test(a) ? a : a.charAt(0).toUpperCase() + a.slice(1)
  }

  function iconFor(e) {
    var icon = String(e.appIcon || "")
    // Claude Code's hook (claude-notch-notify), older entries had no icon
    if (e.app === "Claude" || e.app === "Claude Code") return "file://" + claudeIcon
    if (icon.indexOf("iphone:") === 0)
      return "file://" + iphoneIconDir + encodeURIComponent(icon.slice(7).replace(/\//g, "_")) + ".png"
    var image = String(e.image || "")
    if (image.charAt(0) === "/") return "file://" + image
    if (image.indexOf("file://") === 0) return image
    if (icon.charAt(0) === "/") return "file://" + icon
    if (icon.indexOf("file://") === 0) return icon
    if (icon !== "") {
      var themed = Quickshell.iconPath(icon, true)
      if (themed) return themed
    }
    void DesktopEntries.applications.values
    var entry = DesktopEntries.heuristicLookup(String(e.app || ""))
    if (entry && entry.icon) return Quickshell.iconPath(entry.icon, true) || ""
    return ""
  }

  readonly property var groups: {
    var by = ({}), order = []
    var sorted = entries.slice().sort(function(a, b) { return b.timestamp - a.timestamp })
    for (var i = 0; i < sorted.length; i++) {
      var e = sorted[i]
      var name = appName(e)
      if (!by[name]) { by[name] = { name: name, icon: iconFor(e), items: [] }; order.push(name) }
      by[name].items.push(e)
    }
    return order.map(function(n) { return by[n] })
  }

  function when(ts) {
    var d = new Date(ts), n = new Date(now)
    var mins = Math.floor((now - ts) / 60000)
    if (mins < 1) return portuguese ? "agora" : "now"
    if (mins < 60) return portuguese ? "há " + mins + " min" : mins + " min ago"
    var hm = Qt.formatTime(d, "HH:mm")
    if (d.toDateString() === n.toDateString()) return hm
    var y = new Date(n.getFullYear(), n.getMonth(), n.getDate() - 1)
    if (d.toDateString() === y.toDateString()) return (portuguese ? "ontem " : "yesterday ") + hm
    return Qt.formatDate(d, portuguese ? "dd/MM" : "MM/dd") + " " + hm
  }

  function plain(text) {
    return String(text || "").replace(/<[^>]*>/g, "").replace(/&amp;/g, "&").replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/\s+/g, " ").trim()
  }

  // ---- actions
  function removeFiles(list) {
    if (!list.length) return
    var gone = ({})
    for (var i = 0; i < list.length; i++) gone[list[i]] = true
    entries = entries.filter(function(e) { return !gone[e.file] })
    Quickshell.execDetached(["bash", "-c",
      "h=\"$1\" i=\"$2\"; shift 2; cd \"$h\" && for f in \"$@\"; do rm -f -- \"$f\" \"$i/${f%.json}\"-*; done",
      "--", historyDir, imagesDir].concat(list))
  }
  function removeEntry(e) { removeFiles([e.file]) }
  function clearGroup(g) { removeFiles(g.items.map(function(e) { return e.file })) }
  function clearAll() {
    entries = []
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "clear"])
  }
  function selectEntry(e) { selectedFile = selectedFile === e.file ? "" : e.file }
  function copyEntry(e) {
    var text = [plain(e.summary), plain(e.body)].filter(function(t) { return t !== "" }).join("\n")
    Quickshell.execDetached(["wl-copy", "--", text])
  }
  function toggleGroup(name) {
    var next = Object.assign({}, expanded)
    next[name] = !next[name]
    expanded = next
  }
  function openEntry(e) {
    close()
    // a way back sent along with it (Omarchy's exec hint; Claude's points
    // at its terminal and tmux pane)
    var argv = null
    try { argv = JSON.parse(String(e.execArgv || "")) } catch (err) { argv = null }
    // Through ~/.local/bin/hugo-present-after when it exists (the window it
    // lands on arrives animated), else straight.
    var present = ["sh", "-c", 'p="$HOME/.local/bin/hugo-present-after"; if [ -x "$p" ]; then exec "$p" "$@"; else exec "$@"; fi', "sh"]
    if (Array.isArray(argv) && argv.length && typeof argv[0] === "string" && argv[0].charAt(0) !== "-") {
      Quickshell.execDetached(present.concat(argv))
      return
    }
    // iPhone ones have nothing to open here (the phone keeps them)
    if (String(e.appIcon || "").indexOf("iphone:") === 0) return
    var app = String(e.app || "")
    if (!app || app === "notify-send" || app === "omarchy-action") return
    Quickshell.execDetached(present.concat([Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-hyprland-focus-app", app]))
  }

  // ---- data
  Process {
    id: listProc
    command: ["bash", "-c", "mkdir -p \"$1\"; cd \"$1\" && ls *.json >/dev/null 2>&1 && jq -c '. + {file: input_filename}' *.json 2>/dev/null", "--", root.historyDir]
    stdout: StdioCollector {
      onStreamFinished: {
        var out = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i]) continue
          try {
            var e = JSON.parse(lines[i])
            e.timestamp = Number(e.timestamp) || 0
            out.push(e)
          } catch (err) {}
        }
        root.entries = out
      }
    }
  }
  Component.onCompleted: refresh()

  // live: a file written, moved in or removed in the history folder
  Process {
    id: watchProc
    running: true
    command: ["bash", "-c", "mkdir -p \"$1\"; exec inotifywait -m -q -e create,delete,moved_to,close_write \"$1\"", "--", root.historyDir]
    stdout: SplitParser { onRead: reloadSoon.restart() }
    onExited: watchRetry.restart()
  }
  Timer { id: watchRetry; interval: 5000; onTriggered: watchProc.running = true }
  Timer { id: reloadSoon; interval: 400; onTriggered: root.refresh() }
  // relative times ("há 3 min") while open
  Timer { interval: 30000; repeat: true; running: root.opened; onTriggered: root.now = Date.now() }

  FileView {
    id: seenView
    path: root.stateDir + "/seen.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onAdapterUpdated: writeAdapter()
    onLoadFailed: function(error) {
      if (error !== FileViewError.FileNotFound) return
      Quickshell.execDetached(["mkdir", "-p", root.stateDir])
      writeAdapter()
    }
    JsonAdapter {
      id: seenFile
      property real lastSeen: 0
    }
  }

  // ---- view
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            height: Style.space(28)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.tr("Notificações")
              color: Anatomy.strong
              font.family: Anatomy.sans
              font.pixelSize: 15
              font.weight: Font.DemiBold
            }
            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)
              // silences the toasts; the history keeps filling
              ToggleSwitch {
                id: dndSwitch
                anchors.verticalCenter: parent.verticalCenter
                checked: root.dnd
                foreground: root.bar ? root.bar.foreground : Anatomy.strong
                onToggled: root.setDnd(!checked)
                PanelToolTip {
                  visible: dndSwitch.containsMouse
                  text: root.tr("Não perturbe")
                  fontFamily: Anatomy.sans
                }
              }
              Pill {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.entries.length > 0
                label: root.tr("LIMPAR TUDO")
                onActivated: root.clearAll()
              }
            }
          }

          // nothing yet
          Column {
            visible: root.entries.length === 0
            width: parent.width
            topPadding: Style.space(18)
            bottomPadding: Style.space(22)
            spacing: Style.space(10)
            AnatomyIcon {
              anchors.horizontalCenter: parent.horizontalCenter
              size: 26
              color: Anatomy.muted
              path: Anatomy.icons.bell
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.tr("Nenhuma notificação")
              color: Anatomy.muted
              font.family: Anatomy.sans
              font.pixelSize: 12
            }
          }

          Repeater {
            model: root.groups
            delegate: Group { required property var modelData; required property int index; group: modelData; order: index }
          }
        }
      }
    }
  }

  // ---- pieces

  component Pill: Rectangle {
    id: pill
    property string label: ""
    property bool accent: false
    signal activated()
    width: pillText.implicitWidth + Style.space(16)
    height: Style.space(22)
    radius: height / 2
    color: pillArea.containsMouse ? Anatomy.pressed : (accent ? Anatomy.hover : "transparent")
    border.width: Anatomy.hairline
    border.color: accent ? Qt.rgba(1, 1, 1, 0.22) : Anatomy.controlRim
    Behavior on color { ColorAnimation { duration: Anatomy.fast } }
    Text {
      id: pillText
      anchors.centerIn: parent
      text: pill.label
      color: pill.accent ? Anatomy.strong : Anatomy.text
      font.family: Anatomy.mono
      font.pixelSize: 9
      font.weight: Font.Medium
      font.letterSpacing: 0.6
    }
    MouseArea {
      id: pillArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.activated()
    }
  }

  // App icon in a rounded tile; the app's initial when it has none.
  component AppIcon: Rectangle {
    id: tile
    property string source: ""
    property string name: ""
    property real size: 30
    width: size
    height: size
    radius: Math.round(size * 0.24)
    color: img.status === Image.Ready ? "transparent" : Anatomy.face
    clip: true
    Image {
      id: img
      anchors.fill: parent
      source: tile.source
      visible: status === Image.Ready
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      smooth: true
      mipmap: true
      sourceSize.width: 96
      sourceSize.height: 96
    }
    Text {
      anchors.centerIn: parent
      visible: img.status !== Image.Ready
      text: tile.name.charAt(0).toUpperCase()
      color: Anatomy.hi
      font.family: Anatomy.sans
      font.pixelSize: Math.round(tile.size * 0.45)
      font.weight: Font.DemiBold
    }
  }

  // Comes in (fades and rises a few px), staggered by `order`, each time
  // the panel opens; folds away (fades, shrinks) when cleared.
  component Entering: Item {
    id: enter
    property int order: 0
    property bool leaving: false
    property real shown: 0
    readonly property real fullHeight: childrenRect.height
    height: fullHeight * (leaving ? 0 : 1)
    opacity: leaving ? 0 : shown
    clip: leaving
    transform: Translate { y: (1 - enter.shown) * Style.space(8) }
    Behavior on height { NumberAnimation { duration: 170; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
    Behavior on opacity { enabled: enter.leaving; NumberAnimation { duration: 140 } }
    function play() {
      shown = 0
      inAnim.restart()
    }
    SequentialAnimation {
      id: inAnim
      PauseAnimation { duration: Math.min(enter.order, 6) * 18 }
      NumberAnimation { target: enter; property: "shown"; to: 1; duration: 200; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease }
    }
    Component.onCompleted: play()
    Connections {
      target: root
      function onOpenSerialChanged() { enter.play() }
    }
  }

  // One app: header, then its newest notification stacked over the rest,
  // or all of them once spread out.
  component Group: Entering {
    id: groupView
    property var group: ({ name: "", icon: "", items: [] })
    readonly property bool open: !!root.expanded[group.name]
    readonly property int count: group.items.length
    width: column.width

    function clear() {
      leaving = true
      clearTimer.start()
    }
    Timer { id: clearTimer; interval: 180; onTriggered: root.clearGroup(groupView.group) }

    Column {
      width: parent.width
      spacing: Style.space(6)

      Item {
        width: parent.width
        height: Style.space(22)
        AppIcon {
          id: headIcon
          anchors.verticalCenter: parent.verticalCenter
          size: 16
          source: groupView.group.icon
          name: groupView.group.name
        }
        Text {
          anchors.left: headIcon.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: groupView.group.name + (groupView.count > 1 ? "  ·  " + groupView.count : "")
          color: Anatomy.text
          font.family: Anatomy.sans
          font.pixelSize: 12
          font.weight: Font.DemiBold
        }
        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
          Pill {
            visible: groupView.count > 1
            label: root.tr(groupView.open ? "MOSTRAR MENOS" : "MOSTRAR TODAS")
            onActivated: root.toggleGroup(groupView.group.name)
          }
          Pill {
            label: root.tr("LIMPAR")
            onActivated: groupView.clear()
          }
        }
      }

      // stacked (closed): the newest card with two edges peeking under it
      Item {
        visible: !groupView.open
        width: parent.width
        height: topCard.height + (groupView.count > 1 ? Style.space(groupView.count > 2 ? 10 : 5) : 0)
        Rectangle {
          visible: groupView.count > 2
          x: Style.space(16); width: parent.width - 2 * x
          y: topCard.height
          height: Style.space(10)
          radius: Anatomy.cardRadius
          color: Qt.rgba(1, 1, 1, 0.025)
          border.width: Anatomy.hairline
          border.color: Anatomy.rule
        }
        Rectangle {
          visible: groupView.count > 1
          x: Style.space(8); width: parent.width - 2 * x
          y: topCard.height - Style.space(5)
          height: Style.space(10)
          radius: Anatomy.cardRadius
          color: Qt.rgba(1, 1, 1, 0.04)
          border.width: Anatomy.hairline
          border.color: Anatomy.rule
        }
        Card {
          id: topCard
          entry: groupView.group.items[0] || ({})
          icon: groupView.group.icon
          appName: groupView.group.name
          // a stack spreads out first; a lone notification opens its buttons
          onPicked: groupView.count > 1 ? root.toggleGroup(groupView.group.name) : root.selectEntry(entry)
        }
      }

      // spread (open): every one of them, coming in one after the other
      Repeater {
        model: groupView.open ? groupView.group.items.slice(0, 30) : []
        delegate: Entering {
          required property var modelData
          required property int index
          order: index
          width: groupView.width
          Card {
            entry: modelData
            icon: groupView.group.icon
            appName: groupView.group.name
            onPicked: root.selectEntry(entry)
          }
        }
      }
    }
  }

  // A notification. A click spreads it out: the whole text and its buttons
  // (ABRIR, COPIAR, APAGAR); × on hover deletes it at once. Height changes
  // ease; a deleted card folds away before its file goes.
  component Card: Rectangle {
    id: card
    property var entry: ({})
    property string icon: ""
    property string appName: ""
    readonly property bool selected: root.selectedFile !== "" && root.selectedFile === entry.file
    property bool leaving: false
    signal picked()

    function remove() {
      leaving = true
      removeTimer.start()
    }
    Timer { id: removeTimer; interval: 170; onTriggered: { if (card.selected) root.selectedFile = ""; root.removeEntry(card.entry) } }

    width: column.width
    readonly property real naturalHeight: Math.max(cardIcon.height, textCol.implicitHeight) + Style.space(22)
    height: leaving ? 0 : naturalHeight
    opacity: leaving ? 0 : 1
    clip: true
    radius: Anatomy.cardRadius + 4
    color: selected ? Qt.rgba(1, 1, 1, 0.075) : cardArea.containsMouse ? Qt.rgba(1, 1, 1, 0.065) : Qt.rgba(1, 1, 1, 0.045)
    border.width: Anatomy.hairline
    border.color: selected ? Qt.rgba(1, 1, 1, 0.16) : Anatomy.rim
    Behavior on color { ColorAnimation { duration: Anatomy.fast } }
    Behavior on border.color { ColorAnimation { duration: Anatomy.fast } }
    Behavior on height { NumberAnimation { duration: 170; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
    Behavior on opacity { NumberAnimation { duration: 140 } }

    MouseArea {
      id: cardArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: card.picked()
    }

    AppIcon {
      id: cardIcon
      x: Style.space(11)
      y: Style.space(11)
      size: 30
      source: card.icon
      name: card.appName
    }

    Column {
      id: textCol
      anchors.left: cardIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      y: Style.space(10)
      spacing: 2
      Item {
        width: parent.width
        height: titleText.implicitHeight
        Text {
          id: titleText
          width: parent.width - timeText.implicitWidth - Style.space(8)
          text: root.plain(card.entry.summary) || card.appName
          color: Anatomy.strong
          font.family: Anatomy.sans
          font.pixelSize: 13
          font.weight: Font.DemiBold
          elide: Text.ElideRight
        }
        Text {
          id: timeText
          anchors.right: parent.right
          anchors.baseline: titleText.baseline
          opacity: closeArea.containsMouse || cardArea.containsMouse ? 0 : 1
          Behavior on opacity { NumberAnimation { duration: Anatomy.fast } }
          text: root.when(card.entry.timestamp)
          color: Anatomy.muted
          font.family: Anatomy.mono
          font.pixelSize: 10
        }
      }
      Text {
        width: parent.width
        visible: text !== ""
        text: root.plain(card.entry.body)
        color: Anatomy.text
        font.family: Anatomy.sans
        font.pixelSize: 12
        lineHeight: 1.1
        wrapMode: Text.Wrap
        maximumLineCount: card.selected ? 14 : 2
        elide: Text.ElideRight
      }
      // the buttons, when spread out
      Item {
        width: parent.width
        height: card.selected ? actions.height + Style.space(10) : 0
        opacity: card.selected ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Row {
          id: actions
          y: Style.space(10)
          spacing: Style.space(6)
          Pill {
            label: "ABRIR"
            accent: true
            visible: String(card.entry.appIcon || "").indexOf("iphone:") !== 0
            onActivated: root.openEntry(card.entry)
          }
          Pill { label: "COPIAR"; onActivated: root.copyEntry(card.entry) }
          Pill { label: "APAGAR"; onActivated: card.remove() }
        }
      }
    }

    // delete this one (on hover, where the time was)
    Rectangle {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      y: Style.space(8)
      width: Style.space(20)
      height: width
      radius: width / 2
      opacity: cardArea.containsMouse || closeArea.containsMouse ? 1 : 0
      visible: opacity > 0
      Behavior on opacity { NumberAnimation { duration: Anatomy.fast } }
      color: closeArea.containsMouse ? Anatomy.hover : "transparent"
      AnatomyIcon {
        anchors.centerIn: parent
        size: 11
        path: "M7 7l10 10M17 7L7 17"
        color: closeArea.containsMouse ? Anatomy.red : Anatomy.muted
      }
      MouseArea {
        id: closeArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: card.remove()
      }
    }
  }
}
