import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// The bell on the bar: notification history (the notifications service keeps it as
// one JSON file per notification), grouped by app in Panel.qml. Island Bar
// draws the bell and the badge (unseen = arrived after the panel was last
// opened). `omarchy-shell io.github.hugorolimf.inbox toggle` opens it on the focused
// monitor (Omarchy's history key calls it).
BarWidget {
  id: root
  moduleName: "io.github.hugorolimf.inbox"

  readonly property int unseen: panelLoader.item ? panelLoader.item.unseen : 0

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Shape contract for shell.summon/hide/toggle (Bar.findPanelWidget).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF009A)
    tooltipText: ""
    onPressed: function(b) { if (panelLoader.item) panelLoader.item.toggle() }
  }

  IpcHandler {
    target: "io.github.hugorolimf.inbox"
    function toggle(): void { Quickshell.execDetached(["omarchy-shell", "-q", "io.github.hugorolimf.bar", "click", "io.github.hugorolimf.inbox"]) }
    function refresh(): void { if (panelLoader.item) panelLoader.item.refresh() }
  }
}
