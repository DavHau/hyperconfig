// Anthropic Fable Usage — bar widget.
//
// One thin horizontal gauge per Anthropic account, stacked vertically:
// the filled fraction is the weekly Fable allowance already used.
//   < 80% used → Color.mPrimary
//   ≥ 80% used → Color.mError   (about to hit the cap)
//   stale data → dimmed fill    (poller could not reach the API)
// Hovering shows account emails, exact percentages and reset times.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Services.UI

Item {
  id: root

  // Set by the plugin host / BarWidgetLoader.
  property var pluginApi: null
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  // Declared so the bar's loader can assign them (it sets these on every
  // widget); we don't use per-instance bar settings ourselves.
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property var svc: pluginApi ? pluginApi.mainInstance : null
  readonly property var accounts: svc ? svc.accounts : []

  readonly property string screenName: screen ? screen.name : ""
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)

  readonly property int gaugeWidth: Math.round(capsuleHeight * 1.6)
  readonly property int gaugeThickness: Math.max(3, Math.round(capsuleHeight * 0.24))

  readonly property bool hasAccounts: accounts.length > 0

  implicitWidth: hasAccounts ? root.gaugeWidth : 0
  implicitHeight: capsuleHeight
  visible: hasAccounts

  function tooltipText() {
    return root.accounts.map(a => {
      const pct = (a.percent === null || a.percent === undefined) ? "?" : Math.round(a.percent) + "%";
      const when = a.resetsAt ? ", resets " + new Date(a.resetsAt).toLocaleString(Qt.locale(), "ddd hh:mm") : "";
      const stale = a.stale ? " (stale)" : "";
      return a.email + ": Fable " + pct + " used" + when + stale;
    }).join("\n");
  }

  ColumnLayout {
    id: column
    anchors.centerIn: parent
    spacing: Math.max(2, Math.round(root.capsuleHeight * 0.12))

    Repeater {
      model: root.accounts

      delegate: Rectangle {
        id: track
        required property var modelData

        readonly property real used: {
          const p = modelData.percent;
          return (p === null || p === undefined) ? 0 : Math.min(1, Math.max(0, p / 100));
        }
        readonly property color fillColor: (modelData.percent !== null && modelData.percent >= 80) ? Color.mError : Color.mPrimary

        Layout.preferredWidth: root.gaugeWidth
        Layout.preferredHeight: root.gaugeThickness
        radius: height / 2
        color: Color.mSurfaceVariant

        Rectangle {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.round(track.used * track.width)
          height: track.height
          radius: track.radius
          color: track.fillColor
          opacity: track.modelData.stale ? 0.4 : 1.0

          Behavior on width {
            NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
          }
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onEntered: TooltipService.show(root, root.tooltipText(), BarService.getTooltipDirection(root.screen?.name))
    onExited: TooltipService.hide()
  }
}
