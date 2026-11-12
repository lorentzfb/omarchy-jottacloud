import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// The Jottacloud mark (the two rounded leaves from the official logo),
// drawn as vector paths in a single colour so it follows the shell theme.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground

  // Artwork is authored on a 38x38 grid.
  readonly property real unit: iconSize / 38

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    Leaf { path: "M37.5923 0V25.3333C37.5923 28.6933 36.2718 31.9139 33.9223 34.2902C31.5727 36.6652 28.3854 38 25.0614 38H20.0488V12.6667C20.0488 9.30669 21.3693 6.0861 23.7188 3.70979C26.0697 1.33479 29.2557 0 32.5797 0H37.5923Z" }
    Leaf { path: "M0 20.2666H5.0126C8.33655 20.2666 11.5226 21.6014 13.8734 23.9764C16.223 26.3514 17.5434 29.5733 17.5434 32.9333V38H12.5308C9.20689 38 6.02084 36.6654 3.67001 34.2904C1.32047 31.9141 0 28.6922 0 25.3335V20.2666Z" }
  }

  component Leaf: ShapePath {
    property alias path: svg.path
    fillColor: root.color
    strokeWidth: 0
    strokeColor: "transparent"
    scale: Qt.size(root.unit, root.unit)
    PathSvg { id: svg }
  }
}
