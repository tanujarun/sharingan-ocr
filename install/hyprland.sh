#!/bin/bash
# Installs Sharingan on Hyprland without Omarchy: assembles a Quickshell config in ~/.config/quickshell/sharingan and
# installs the OCR engine. Hyprland configs differ, so this prints the lines to add rather than editing yours.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/install/lib.sh"
need quickshell hyprctl grim wl-copy python3

target=${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/sharingan
mkdir -p "$target/plugin"
cp -r "$repo/standalone/." "$target/"
cp -r "$repo/plugin/." "$target/plugin/"
"$target/plugin/tools/setup.sh"

cat <<'NEXT'
Installed. Add these to your Hyprland config, then reload it:

  exec-once = quickshell -c sharingan
  bindd = SUPER ALT, C, Sharingan, exec, quickshell ipc -c sharingan call sharingan toggle
  layerrule = noanim, tanuj-sharingan

Lua config (hyprland.lua):

  hl.exec_once("quickshell -c sharingan")
  hl.bind("SUPER + ALT + C", hl.dsp.exec_cmd("quickshell ipc -c sharingan call sharingan toggle"))
  hl.layer_rule({ match = { namespace = "tanuj-sharingan" }, no_anim = true, animation = "none" })
NEXT
