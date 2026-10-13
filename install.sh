#!/bin/bash
# Usage Wall installer (macOS 14+): builds the app from this checkout, installs it to ~/Applications, asks which
# display to use, and starts it at login. Re-run any time to update; your settings are kept.
#
#   ./install.sh                     interactive: pick the display from a list
#   ./install.sh --display NAME      NAME as shown by `usage-wall display list`, or auto, or window
#   ./install.sh --use-signin        also read usage with your Claude Code sign-in (unofficial endpoint, opt-in)
#   ./install.sh --no-statusline     do not set Claude Code's status line (the default data source)
#   ./install.sh --no-login          do not start at login (open the app yourself)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Usage Wall"
LABEL="io.github.porgeeratad.usagewall"
APP="$HOME/Applications/$NAME.app"
EXE="$APP/Contents/MacOS/UsageWall"
BIN="$HOME/.local/bin"
DISPLAY_CHOICE="" STATUSLINE=1 LOGIN=1 SIGNIN=""

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --display) [ $# -ge 2 ] || die "--display needs a value"; DISPLAY_CHOICE="$2"; shift 2 ;;
    --display=*) DISPLAY_CHOICE="${1#*=}"; shift ;;
    --no-statusline) STATUSLINE=0; shift ;;
    --use-signin) SIGNIN=on; shift ;;
    --no-signin) SIGNIN=off; shift ;;
    --no-login) LOGIN=0; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# --- requirements -------------------------------------------------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "Usage Wall is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "macOS 14 (Sonoma) or newer is needed; this Mac has $(sw_vers -productVersion)."
xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null \
  || die "the Xcode Command Line Tools are needed to build the app: run  xcode-select --install  then this script again."
/usr/bin/python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null \
  || die "/usr/bin/python3 (3.9+) is needed; it comes with the Command Line Tools."
# only checks that the item exists (no secret is read, no dialog): plan limits need a Pro/Max sign-in either way
if ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  warn "no Claude Code sign-in found in your login Keychain. Run  claude  and sign in with a Pro or Max plan;"
  warn "the wall shows plan limits only for a Pro/Max sign-in."
fi

# --- build and install --------------------------------------------------------------------------------------------
say "Building $NAME"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"$ROOT/app/build.sh" "$TMP" >/dev/null

if [ -d "$APP" ]; then
  say "Replacing the installed copy"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  osascript -e "tell application id \"$LABEL\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq UsageWall || break; sleep 0.5; done
  rm -rf "$APP"
fi
mkdir -p "$HOME/Applications" "$BIN"
mv "$TMP/$NAME.app" "$APP"
cp "$ROOT/bin/usage-wall" "$BIN/usage-wall"
cp "$ROOT/bin/usage-wall-statusline" "$BIN/usage-wall-statusline"
chmod +x "$BIN/usage-wall" "$BIN/usage-wall-statusline"
say "Installed $APP"

# --- which display ------------------------------------------------------------------------------------------------
if [ -z "$DISPLAY_CHOICE" ]; then
  current="$("$EXE" --config 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.loads(sys.stdin.read().split("\nfile:")[0]).get("display",""))' 2>/dev/null || true)"
  if [ -t 0 ]; then
    names=()
    while IFS=$'\t' read -r n size how; do names+=("$n"); done < <("$EXE" --list-displays)
    echo
    echo "Where should Usage Wall show?"
    echo "  w) Floating window   (default)"
    echo "  a) Automatic - full screen on the smallest extra display, else a window"
    i=1
    while IFS=$'\t' read -r n size how; do printf '  %d) %s  %s  - %s\n' "$i" "$n" "$size" "$how"; i=$((i + 1)); done < <("$EXE" --list-displays)
    [ -n "$current" ] && echo "  (now: $current - press Enter to keep it)"
    printf 'Choice: '; read -r pick || pick=""
    case "$pick" in
      "") DISPLAY_CHOICE="${current:-window}" ;;
      a|A) DISPLAY_CHOICE=auto ;;
      w|W) DISPLAY_CHOICE=window ;;
      *[!0-9]*) die "not a choice: $pick" ;;
      *) [ "$pick" -ge 1 ] && [ "$pick" -le ${#names[@]} ] || die "not a choice: $pick"; DISPLAY_CHOICE="${names[$((pick - 1))]}" ;;
    esac
  else
    DISPLAY_CHOICE="${current:-window}"
  fi
fi
"$EXE" --set-display "$DISPLAY_CHOICE" >/dev/null
say "Display: $DISPLAY_CHOICE  (change it any time from the menu bar icon, or: usage-wall display set NAME)"

# --- where the numbers come from ----------------------------------------------------------------------------------
if [ -n "$SIGNIN" ]; then "$EXE" --signin "$SIGNIN" >/dev/null; fi
signin_on="$("$EXE" --config 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.loads(sys.stdin.read().split("\nfile:")[0]).get("useSignIn", False))' 2>/dev/null || echo False)"
if [ "$signin_on" = True ]; then
  say "Data: Claude Code's status line + your Claude sign-in (unofficial endpoint; usage-wall signin off to stop)"
  # the server reads the token with /usr/bin/security; macOS may ask once - do it now, while you are here
  if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
    say "Checking Keychain access - if macOS asks about \"Claude Code-credentials\", choose Always Allow"
    security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1 \
      || warn "Keychain access was not allowed; sign-in mode cannot read your usage until it is (README > Privacy)."
  fi
else
  say "Data: Claude Code's status line (updates while you use Claude Code; ./install.sh --use-signin for more)"
fi

# --- optional Claude Code status line ------------------------------------------------------------------------------
SETTINGS="$HOME/.claude/settings.json"
if [ "$STATUSLINE" = 1 ]; then
  /usr/bin/python3 - "$SETTINGS" "$BIN/usage-wall-statusline" <<'PY'
import json, os, shutil, sys
path, script = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
cur = data.get("statusLine")
want = {"type": "command", "command": script}
if cur == want:
    sys.exit(0)
if cur and "usage-wall-statusline" not in json.dumps(cur):
    print("==> You already have a Claude Code status line, so it was left alone. To feed the wall from it,")
    print(f"    add this to that script:  printf '%s' \"$input\" | {script} >/dev/null   (README > Status line)")
    sys.exit(0)
if os.path.exists(path):
    shutil.copy2(path, path + ".bak-usage-wall")
data["statusLine"] = want
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(f"==> Claude Code status line set ({path}; backup: settings.json.bak-usage-wall)")
PY
fi

# --- start --------------------------------------------------------------------------------------------------------
if [ "$LOGIN" = 1 ]; then
  "$EXE" --install-agent >/dev/null && say "Started, and it will start at login (menu bar: gauge icon)"
else
  open "$APP" && say "Started (not at login - toggle \"Start at Login\" in its menu)"
fi
case ":$PATH:" in *":$BIN:"*) ;; *) warn "$BIN is not on your PATH; add it to use the usage-wall command." ;; esac
echo
echo "  usage-wall display list        displays and how each would be used"
echo "  usage-wall display set NAME    NAME | auto | window"
echo "  usage-wall status              current usage as the wall sees it"
echo "  ./uninstall.sh                 remove everything"
