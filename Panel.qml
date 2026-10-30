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
  readonly property var enText: ({"Notificações": "Notifications", "LIMPAR TUDO": "CLEAR ALL", "Nenhuma notificação": "No notifications", "MOSTRAR MENOS": "SHOW LESS", "MOSTRAR TODAS": "SHOW ALL", "LIMPAR": "CLEAR", "Não perturbe": "Do not disturb",
    "LIGADO": "ON", "DESLIGADO": "OFF", "Os avisos aparecem na tela.": "Alerts show on screen.", "Os avisos não aparecem na tela; ficam guardados aqui.": "Alerts stay off the screen and are kept here."})
  function tr(text) { return portuguese || enText[text] === undefined ? text : enText[text] }
  manageIpc: false

  property var anchorItem: null
  // Do Not Disturb, through the notifications service's IPC. Read at start,
  // on every open and whenever its settings file changes (a shortcut may
  // switch it too), so the bell on the bar always tells (red, slashed).
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
  Process {
    id: dndWatch
    running: true
    command: ["bash", "-c", "mkdir -p \"$1\"; exec inotifywait -m -q -e close_write,moved_to --include 'notifications\\.json$' \"$1\"", "--", root.home + "/.local/state/omarchy"]
    stdout: SplitParser { onRead: dndSoon.restart() }
    onExited: dndWatchRetry.restart()
  }
  Timer { id: dndWatchRetry; interval: 5000; onTriggered: dndWatch.running = true }
  Timer { id: dndSoon; interval: 150; onTriggered: if (!dndProc.running) dndProc.running = true }

  // Clearing rings the bell on the bar (clearSerial) and the cards leave one
  // after the other before their files go.
  property int clearSerial: 0
  property bool clearingAll: false
  // the panel's height follows its content smoothly while open
  property real panelHeight: column.implicitHeight
  Behavior on panelHeight { enabled: root.opened; NumberAnimation { duration: 280; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
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
    if (clearingAll || entries.length === 0) return
    clearingAll = true
    clearSerial++
    clearAllTimer.interval = Math.min(groups.length, 8) * 45 + 300
    clearAllTimer.restart()
  }
  Timer {
    id: clearAllTimer
    onTriggered: {
      root.entries = []
      root.clearingAll = false
      Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "clear"])
    }
  }
  function selectEntry(e) { selectedFile = selectedFile === e.file ? "" : e.file }
  // Clipboard writes go through wl-copy's stdin: an argument would show the
  // text to any account that can read process command lines.
  property string clipboardText: ""
  function copyText(text) {
    clipboardText = String(text || "")
    clipboardProc.stdinEnabled = true
    clipboardProc.running = true
  }
  Process {
    id: clipboardProc
    command: ["wl-copy"]
    onStarted: { write(root.clipboardText); stdinEnabled = false; root.clipboardText = "" }
  }
  function copyEntry(e) {
    var text = [plain(e.summary), plain(e.body)].filter(function(t) { return t !== "" }).join("\n")
    copyText(text)
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
  Component.onCompleted: { refresh(); dndProc.running = true }

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
    contentHeight: panel.fittedContentHeight(root.panelHeight)

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
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.tr("Notificações")
              color: Anatomy.strong
              font.family: Anatomy.sans
              font.pixelSize: 15
              font.weight: Font.DemiBold
            }
            Pill {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              opacity: root.entries.length > 0 && !root.clearingAll ? 1 : 0
              visible: opacity > 0
              Behavior on opacity { NumberAnimation { duration: Anatomy.fast; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
              label: root.tr("LIMPAR TUDO")
              onActivated: root.clearAll()
            }
          }

          DndRow { width: parent.width }

          // nothing yet (fades in once the last card has gone)
          Column {
            visible: root.entries.length === 0
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
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
              textFormat: Text.PlainText
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

  // Do Not Disturb, said in words: what it is, whether it is on and what it
  // does right now. The whole row switches it; on, it turns red and the bell
  // gets its slash (here and on the bar).
  component DndRow: Rectangle {
    id: dndRow
    readonly property bool on: root.dnd
    height: Style.space(50)
    radius: Anatomy.cardRadius + 4
    color: on ? Qt.rgba(Anatomy.red.r, Anatomy.red.g, Anatomy.red.b, dndArea.containsMouse ? 0.13 : 0.09)
      : dndArea.containsMouse ? Qt.rgba(1, 1, 1, 0.065) : Qt.rgba(1, 1, 1, 0.035)
    border.width: Anatomy.hairline
    border.color: on ? Qt.rgba(Anatomy.red.r, Anatomy.red.g, Anatomy.red.b, 0.4) : Anatomy.rim
    Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
    Behavior on border.color { ColorAnimation { duration: 260; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }

    MouseArea {
      id: dndArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.setDnd(!root.dnd)
    }

    // the bell; on, it goes red and a slash draws across it from the top
    Item {
      id: dndIcon
      x: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: 20
      height: 20
      AnatomyIcon {
        anchors.fill: parent
        size: 20
        path: Anatomy.icons.bell
        color: dndRow.on ? Anatomy.red : Anatomy.muted
        Behavior on color { ColorAnimation { duration: 260 } }
      }
      AnatomyIcon {
        anchors.fill: parent
        size: 20
        path: "M4 4l16 16"
        color: Anatomy.red
        transformOrigin: Item.TopLeft
        scale: dndRow.on ? 1 : 0.2
        opacity: dndRow.on ? 1 : 0
        Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
        Behavior on opacity { NumberAnimation { duration: 200 } }
      }
      // a small swing as it switches
      transform: Rotation { id: dndSwing; origin.x: 10; origin.y: 2; angle: 0 }
      SequentialAnimation {
        id: dndRing
        NumberAnimation { target: dndSwing; property: "angle"; to: -14; duration: 90; easing.type: Easing.OutCubic }
        NumberAnimation { target: dndSwing; property: "angle"; to: 10; duration: 140; easing.type: Easing.InOutSine }
        NumberAnimation { target: dndSwing; property: "angle"; to: -5; duration: 130; easing.type: Easing.InOutSine }
        NumberAnimation { target: dndSwing; property: "angle"; to: 0; duration: 170; easing.type: Easing.OutCubic }
      }
      Connections { target: root; function onDndChanged() { dndRing.restart() } }
    }

    Column {
      anchors.left: dndIcon.right
      anchors.leftMargin: Style.space(11)
      anchors.right: dndSwitch.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2
      Row {
        spacing: Style.space(7)
        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: root.tr("Não perturbe")
          color: Anatomy.strong
          font.family: Anatomy.sans
          font.pixelSize: 13
          font.weight: Font.DemiBold
        }
        // the state, written (not only the colour)
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: stateText.implicitWidth + Style.space(10)
          height: Style.space(16)
          radius: height / 2
          color: dndRow.on ? Qt.rgba(Anatomy.red.r, Anatomy.red.g, Anatomy.red.b, 0.16) : Qt.rgba(1, 1, 1, 0.06)
          Behavior on color { ColorAnimation { duration: 260 } }
          Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
          Text {
            id: stateText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: root.tr(dndRow.on ? "LIGADO" : "DESLIGADO")
            color: dndRow.on ? Anatomy.red : Anatomy.muted
            font.family: Anatomy.mono
            font.pixelSize: 9
            font.weight: Font.Medium
            font.letterSpacing: 0.6
            Behavior on color { ColorAnimation { duration: 260 } }
          }
        }
      }
      // what it does now; the two sentences cross-fade
      Item {
        width: parent.width
        height: offText.implicitHeight
        Text {
          id: offText
          textFormat: Text.PlainText
          width: parent.width
          text: root.tr("Os avisos aparecem na tela.")
          color: Anatomy.muted
          font.family: Anatomy.sans
          font.pixelSize: 11
          elide: Text.ElideRight
          opacity: dndRow.on ? 0 : 1
          Behavior on opacity { NumberAnimation { duration: 220 } }
        }
        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.tr("Os avisos não aparecem na tela; ficam guardados aqui.")
          color: Anatomy.text
          font.family: Anatomy.sans
          font.pixelSize: 11
          elide: Text.ElideRight
          opacity: dndRow.on ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 220 } }
        }
      }
    }

    // the switch (the kit's knob is always blue; this one goes red)
    Rectangle {
      id: dndSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      width: 26
      height: 15
      radius: height / 2
      color: dndRow.on ? Qt.rgba(Anatomy.red.r, Anatomy.red.g, Anatomy.red.b, 0.3) : Anatomy.faint
      Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
      Rectangle {
        width: 11
        height: 11
        radius: height / 2
        anchors.verticalCenter: parent.verticalCenter
        x: dndRow.on ? parent.width - width - 2 : 2
        color: dndRow.on ? Anatomy.red : dndArea.containsMouse ? Anatomy.hi : Anatomy.mid
        Behavior on x { NumberAnimation { duration: 350; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
        Behavior on color { ColorAnimation { duration: 260 } }
      }
    }
  }

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
      textFormat: Text.PlainText
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
      textFormat: Text.PlainText
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
  // the panel opens; when cleared it slides aside, fades and folds away.
  component Entering: Item {
    id: enter
    property int order: 0
    property bool leaving: false
    property real shown: 0
    readonly property real fullHeight: childrenRect.height
    height: fullHeight * (leaving ? 0 : 1)
    opacity: leaving ? 0 : shown
    clip: leaving
    transform: Translate {
      x: enter.leaving ? Style.space(36) : 0
      y: (1 - enter.shown) * Style.space(8)
      Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
    }
    Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
    Behavior on opacity { enabled: enter.leaving; NumberAnimation { duration: 200; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
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
      if (leaving) return
      leaving = true
      root.clearSerial++
      clearTimer.start()
    }
    Timer { id: clearTimer; interval: 260; onTriggered: root.clearGroup(groupView.group) }
    // LIMPAR TUDO: every group leaves, one after the other from the top
    Timer { id: leaveTimer; interval: Math.min(groupView.order, 8) * 45 + 1; onTriggered: groupView.leaving = true }
    Connections {
      target: root
      function onClearingAllChanged() { if (root.clearingAll) leaveTimer.restart() }
    }

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
          textFormat: Text.PlainText
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
          owner: groupView
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
            owner: groupView
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

    // the group it belongs to: the last one of an app takes the whole group
    property var owner: null
    function remove() {
      if (leaving) return
      if (owner && owner.count === 1) { owner.clear(); return }
      leaving = true
      root.clearSerial++
      removeTimer.start()
    }
    Timer { id: removeTimer; interval: 250; onTriggered: { if (card.selected) root.selectedFile = ""; root.removeEntry(card.entry) } }

    width: column.width
    readonly property real naturalHeight: Math.max(cardIcon.height, textCol.implicitHeight) + Style.space(22)
    height: leaving ? 0 : naturalHeight
    opacity: leaving ? 0 : 1
    clip: true
    transform: Translate {
      x: card.leaving ? Style.space(36) : 0
      Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
    }
    radius: Anatomy.cardRadius + 4
    color: selected ? Qt.rgba(1, 1, 1, 0.075) : cardArea.containsMouse ? Qt.rgba(1, 1, 1, 0.065) : Qt.rgba(1, 1, 1, 0.045)
    border.width: Anatomy.hairline
    border.color: selected ? Qt.rgba(1, 1, 1, 0.16) : Anatomy.rim
    Behavior on color { ColorAnimation { duration: Anatomy.fast } }
    Behavior on border.color { ColorAnimation { duration: Anatomy.fast } }
    Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
    Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }

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
          textFormat: Text.PlainText
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
          textFormat: Text.PlainText
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
        textFormat: Text.PlainText
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
