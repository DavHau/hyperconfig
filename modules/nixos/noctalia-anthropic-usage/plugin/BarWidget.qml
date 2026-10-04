// Anthropic Weekly Usage — bar widget.
//
// One thin horizontal gauge per Anthropic account, stacked vertically.
// Each gauge overlays two fills on the same track:
//   weekly usage, all models → Color.mPrimary
//   weekly Fable usage       → Color.mTertiary
// The wider fill is drawn underneath so both stay visible. A fill at
// ≥ 80% turns Color.mError (about to hit the cap); stale data (poller
// could not reach the API) dims both fills.
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

  function pct(p) {
    return (p === null || p === undefined) ? "?" : Math.round(p) + "%";
  }

  function when(iso) {
    return iso ? " (resets " + new Date(iso).toLocaleString(Qt.locale(), "ddd hh:mm") + ")" : "";
  }

  function tooltipText() {
    return root.accounts.map(a => {
      const stale = a.stale ? " — stale" : "";
      return a.email + stale
        + "\n  Weekly: " + pct(a.weekly) + when(a.weeklyResetsAt)
        + "\n  Fable: " + pct(a.fable) + when(a.fableResetsAt);
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

        function fraction(p) {
          return (p === null || p === undefined) ? 0 : Math.min(1, Math.max(0, p / 100));
        }
        function fillColor(p, base) {
          return (p !== null && p !== undefined && p >= 80) ? Color.mError : base;
        }

        readonly property real weeklyUsed: fraction(modelData.weekly)
        readonly property real fableUsed: fraction(modelData.fable)

        Layout.preferredWidth: root.gaugeWidth
        Layout.preferredHeight: root.gaugeThickness
        radius: height / 2
        color: Color.mSurfaceVariant

        // index 0 = weekly, 1 = Fable. The wider fill sits at z 0,
        // beneath the narrower one, so both stay visible.
        Repeater {
          model: 2

          delegate: Rectangle {
            id: fill
            required property int index

            readonly property bool isWeekly: index === 0
            readonly property real used: isWeekly ? track.weeklyUsed : track.fableUsed
            readonly property real otherUsed: isWeekly ? track.fableUsed : track.weeklyUsed

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(fill.used * track.width)
            height: track.height
            radius: track.radius
            color: fill.isWeekly
              ? track.fillColor(track.modelData.weekly, Color.mPrimary)
              : track.fillColor(track.modelData.fable, Color.mTertiary)
            opacity: track.modelData.stale ? 0.4 : 1.0
            z: fill.used > fill.otherUsed ? 0 : 1

            Behavior on width {
              NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
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
