import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import qs.Ui

// Bar entry point. The widget (or the panel it opens) is drawn with Island
// Kit, imported by path, so without the Kit it cannot load and the plugin
// would just vanish from the bar, or show a button that opens nothing. This file imports nothing from the Kit: it
// checks the Kit is there, loads the real widget, and otherwise shows a small
// "Install Island Kit" button that installs it and restarts the shell.
BarWidget {
  id: root

  // The real widget, next to this file.
  readonly property string widgetFile: "BarWidget.qml"
  readonly property string kitId: "io.github.hugorolimf.kit"
  readonly property string kitUrl: "https://github.com/hugorolimf/omarchy-island-kit"

  // The loaded widget. Island Bar reads the widget's own state through it.
  readonly property var inner: widgetLoader.item

  // Can the Kit be imported the way the widget imports it? A missing import
  // directory is no error by itself, only the first type from it is, so the
  // probe names the Kit's Panel (compiled, never created). Checked once:
  // installing the Kit restarts the shell anyway.
  readonly property bool kitPresent: {
    try {
      var probe = Qt.createQmlObject('import QtQuick\nimport "../' + kitId + '/ui"\n'
        + 'QtObject { property Component probe: Component { Panel {} } }',
        root, Qt.resolvedUrl("KitProbe.qml"))
      probe.destroy()
      return true
    } catch (e) {
      return false
    }
  }
  // Kit missing, or there but the widget still failed (a Kit too old for it).
  readonly property bool needsKit: !kitPresent || widgetLoader.status === Loader.Error
  readonly property bool portuguese: Qt.locale().name.indexOf("pt") === 0
  property string kitState: "idle"  // "idle" | "busy" | "failed"

  // Shape contract for shell.summon/hide/toggle (Bar.findPanelWidget) and the
  // popout coordinator, for bars that only see this item. `opened` stays
  // undefined without the widget, so the fallback is not taken for a panel.
  readonly property var opened: inner ? inner.opened === true : undefined
  readonly property bool popoutSwitchClosing: inner ? inner.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: inner && inner.openPanelIndicatorWidth > 0 ? inner.openPanelIndicatorWidth : 0
  readonly property real openPanelIndicatorHeight: inner && inner.openPanelIndicatorHeight > 0 ? inner.openPanelIndicatorHeight : 0
  function open() { if (inner && typeof inner.open === "function") inner.open() }
  function close() { if (inner && typeof inner.close === "function") inner.close() }
  function toggle() { if (inner && typeof inner.toggle === "function") inner.toggle() }
  function closeForPopoutSwitch() {
    if (inner && typeof inner.closeForPopoutSwitch === "function") inner.closeForPopoutSwitch()
    else close()
  }

  // Island Bar presses a module through triggerPress; only the fallback
  // button takes it, the widget keeps its own buttons.
  readonly property bool pressable: needsKit
  function triggerPress(button) { if (needsKit) installKit() }

  // The widget hides itself (no battery, no location yet) through its own
  // `visible`. Reading that back into this item's `visible` would loop (an
  // item reads invisible while its parent is), so this item stays visible and
  // takes no room instead.
  implicitWidth: inner ? (inner.visible ? inner.implicitWidth : 0) : (needsKit ? fallback.implicitWidth : 0)
  implicitHeight: inner ? (inner.visible ? inner.implicitHeight : 0) : (needsKit ? fallback.implicitHeight : 0)

  // What the bar injects here goes on to the widget. Only once the bar has
  // injected something, so the defaults never overwrite a value the bar
  // gave the widget directly.
  function injectInner() {
    var target = inner
    if (!target || !root.bar) return
    if ("bar" in target) target.bar = root.bar
    if ("moduleName" in target && root.moduleName !== "") target.moduleName = root.moduleName
    if ("settings" in target) target.settings = root.settings
  }
  onBarChanged: injectInner()
  onModuleNameChanged: injectInner()
  onSettingsChanged: injectInner()

  Loader {
    id: widgetLoader
    anchors.fill: parent
    // Only once the bar is here: widgets read root.bar while they build.
    active: root.kitPresent && !!root.bar
    source: Qt.resolvedUrl(root.widgetFile)
    onLoaded: root.injectInner()
  }

  // Kit missing: add it; Kit there but the widget failed: update it. Then a
  // shell restart loads the widget for real (a failed import stays cached).
  function installKit() {
    if (kitState === "busy") return
    kitState = "busy"
    kitProc.command = root.kitPresent
      ? ["omarchy", "plugin", "update", root.kitId, "--yes"]
      : ["omarchy", "plugin", "add", root.kitUrl, "--yes"]
    kitProc.running = true
  }

  Process {
    id: kitProc
    stderr: StdioCollector { id: kitErr }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        Quickshell.execDetached(["omarchy-restart-shell"])
      } else {
        console.warn(root.moduleName + ": installing Island Kit failed: " + kitErr.text)
        root.kitState = "failed"
      }
    }
  }

  Rectangle {
    id: fallback
    visible: root.needsKit
    anchors.centerIn: parent
    readonly property color ink: root.bar && root.bar.barForeground ? root.bar.barForeground : Commons.Color.foreground
    readonly property string label: {
      if (root.vertical) return "Kit"
      if (root.kitState === "busy") return root.portuguese ? "Instalando o Island Kit…" : "Installing Island Kit…"
      if (root.kitState === "failed") return root.portuguese ? "Falhou · tentar de novo" : "Failed · try again"
      if (root.kitPresent) return root.portuguese ? "Atualize o Island Kit" : "Update Island Kit"
      return root.portuguese ? "Instale o Island Kit" : "Install Island Kit"
    }
    implicitWidth: fallbackText.implicitWidth + 16
    implicitHeight: Math.max(fallbackText.implicitHeight + 6, 20)
    radius: height / 2
    color: Qt.rgba(ink.r, ink.g, ink.b, mouse.containsMouse ? 0.18 : 0.10)
    border.width: 1
    border.color: Qt.rgba(ink.r, ink.g, ink.b, 0.35)
    opacity: root.kitState === "busy" ? 0.6 : 1

    Text {
      id: fallbackText
      anchors.centerIn: parent
      text: fallback.label
      color: fallback.ink
      font.family: Commons.Style.font.family
      font.pixelSize: Commons.Style.font.bodySmall
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.installKit()
    }
  }
}
