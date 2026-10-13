#!/bin/bash
# Remove Usage Wall: the login agent, the app, the usage-wall commands, and (unless --keep-settings) its settings,
# state and log. Claude Code's status line is only touched if it points at usage-wall, and only after you say yes.
#   ./uninstall.sh [--keep-settings] [--yes]
set -euo pipefail
LABEL="io.github.porgeeratad.usagewall"
APP="$HOME/Applications/Usage Wall.app"
SUPPORT="$HOME/Library/Application Support/UsageWall"
KEEP=0 YES=0
for a in "$@"; do
  case "$a" in
    --keep-settings) KEEP=1 ;;
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && say "Stopped the login agent" || true
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true      # clear a "disabled" mark left by the menu toggle
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
osascript -e "tell application id \"$LABEL\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq UsageWall || break; sleep 0.5; done
[ -d "$APP" ] && rm -rf "$APP" && say "Removed $APP"
for f in usage-wall usage-wall-statusline; do
  p="$HOME/.local/bin/$f"
  [ -f "$p" ] && grep -q "Usage Wall\|usage-wall" "$p" && rm -f "$p" && say "Removed $p"
done

SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q "usage-wall-statusline" "$SETTINGS"; then
  ans=y
  if [ "$YES" != 1 ] && [ -t 0 ]; then printf 'Remove the usage-wall status line from %s? [y/N] ' "$SETTINGS"; read -r ans || ans=n; fi
  case "$ans" in
    y|Y) /usr/bin/python3 - "$SETTINGS" <<'PY'
import json, shutil, sys
p = sys.argv[1]
d = json.load(open(p))
if "usage-wall-statusline" in json.dumps(d.get("statusLine", "")):
    shutil.copy2(p, p + ".bak-usage-wall-uninstall")
    d.pop("statusLine", None)
    json.dump(d, open(p, "w"), indent=2)
    print("==> Removed the status line (backup: settings.json.bak-usage-wall-uninstall)")
PY
    ;;
    *) say "Kept the status line in $SETTINGS (it will stop updating the wall; remove it any time)" ;;
  esac
fi

if [ "$KEEP" = 1 ]; then
  say "Kept settings in $SUPPORT"
else
  rm -rf "$SUPPORT" "$HOME/Library/Logs/UsageWall.log"
  say "Removed settings, state and log"
fi
say "Usage Wall is uninstalled"
