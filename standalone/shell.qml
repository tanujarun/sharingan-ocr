import Quickshell
import Quickshell.Io
import QtQuick

// Runs Sharingan on plain Hyprland, without Omarchy. install/hyprland.sh assembles this folder with plugin/ inside it,
// because Quickshell refuses to load files from outside its config folder.
ShellRoot {
  Loader { id: loader; source: Qt.resolvedUrl("plugin/Sharingan.qml") }
  IpcHandler {
    target: "sharingan"
    function toggle(): void {
      if (loader.item.opened) loader.item.close()
      else loader.item.open()
    }
  }
}
