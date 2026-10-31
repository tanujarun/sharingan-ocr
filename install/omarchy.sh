#!/bin/bash
# Installs Sharingan on Omarchy 4+ (Hyprland with Lua config): copies the plugin, installs the OCR engine, enables the
# plugin in shell.json and binds SUPER+ALT+C. Safe to rerun. Backs up what it edits. Stops if the key is already taken.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/install/lib.sh"
need omarchy hyprctl jq grim wl-copy python3

config=${XDG_CONFIG_HOME:-$HOME/.config}
plugin=$config/omarchy/plugins/tanuj.sharingan
shell_json=$config/omarchy/shell.json
bindings=$config/hypr/bindings.lua
stamp=$(date +%s)

if ! grep -q 'tanuj\.sharingan' "$bindings" 2>/dev/null &&
  hyprctl binds -j | jq -e '.[] | select(.modmask == 72 and (.key | ascii_upcase) == "C")' >/dev/null; then
  echo "SUPER+ALT+C is already bound. Free it or pick another key in $bindings, then rerun." >&2
  exit 1
fi

mkdir -p "$plugin"
cp -r "$repo/plugin/." "$plugin/"
"$plugin/tools/setup.sh"

if ! jq -e '.plugins[]? | select(.id == "tanuj.sharingan")' "$shell_json" >/dev/null; then
  cp "$shell_json" "$shell_json.bak.$stamp"
  jq '.plugins += [{"id": "tanuj.sharingan"}]' "$shell_json.bak.$stamp" >"$shell_json"
fi

if ! grep -q 'tanuj\.sharingan' "$bindings" 2>/dev/null; then
  cp "$bindings" "$bindings.bak.$stamp"
  cat >>"$bindings" <<'LUA'

-- Sharingan: freeze the screen, draw a box, select and copy the words in it
o.bind("SUPER + ALT + C", "Sharingan", "omarchy-shell shell toggle tanuj.sharingan")
hl.layer_rule({ match = { namespace = "tanuj-sharingan" }, no_anim = true, animation = "none" })
LUA
fi

hyprctl reload >/dev/null
hyprctl configerrors
omarchy restart shell
echo "Installed. Press SUPER+ALT+C."
