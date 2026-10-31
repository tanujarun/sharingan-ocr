# Shared by the installers.
need() {
  local missing=()
  for tool in "$@"; do command -v "$tool" >/dev/null || missing+=("$tool"); done
  if ((${#missing[@]})); then
    echo "Missing required tools: ${missing[*]}" >&2
    exit 1
  fi
}
