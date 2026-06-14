#!/usr/bin/env bash
#
#  install.sh — Claude + Codex usage widget for the macOS menu bar
#  ---------------------------------------------------------------
#  One command does everything: build, install, enable auto-start at login,
#  and launch. Nothing else to set up.
#
#      ./install.sh             build + install + auto-start + launch
#      ./install.sh uninstall   stop, disable auto-start, and remove it
#
#  Requirements: macOS 12+ and the Xcode Command Line Tools (for `swiftc`).
#  `ccusage` is optional — only the daily $ cost / token figures need it; the
#  5h / weekly quota percentages work without it.
#
set -euo pipefail

# ----------------------------------------------------------------- config ----
APP_NAME="ClaudeUsageWidget"
BUNDLE_ID="com.hugo.claudeusagewidget"        # must match the cache dir used in the code
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Applications"
APP="$INSTALL_DIR/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
UID_NUM="$(id -u)"

# ----------------------------------------------------------------- output ----
say()  { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# -------------------------------------------------------------- uninstall ----
uninstall() {
  say "Removing the widget…"
  launchctl bootout "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null \
    || launchctl unload "$AGENT" 2>/dev/null || true
  rm -f "$AGENT"
  pkill -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true
  rm -rf "$APP"
  ok "Uninstalled. Auto-start disabled and the app removed from ~/Applications."
  echo "  (Cached data, if any, stays in ~/Library/Caches/$BUNDLE_ID — harmless to delete.)"
  exit 0
}
if [ "${1:-}" = "uninstall" ] || [ "${1:-}" = "--uninstall" ]; then uninstall; fi

# ----------------------------------------------------------- prerequisites ---
[ "$(uname)" = "Darwin" ] || die "This widget is macOS-only."
command -v swiftc >/dev/null 2>&1 \
  || die "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install"

if ! command -v ccusage >/dev/null 2>&1 \
   && [ ! -x /opt/homebrew/bin/ccusage ] && [ ! -x /usr/local/bin/ccusage ]; then
  warn "ccusage not found — quota percentages will still work, but the daily cost / token figures will be hidden."
  warn "To enable them later:  npm install -g ccusage   (or:  bun install -g ccusage)"
fi

# ------------------------------------------------------------------- build ---
say "Building $APP_NAME…"
STAGE="$(mktemp -d)/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$SRC_DIR/Info.plist" "$STAGE/Contents/Info.plist"
[ -f "$SRC_DIR/AppIcon.icns" ] && cp "$SRC_DIR/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

swiftc -O -swift-version 5 \
    "$SRC_DIR/ClaudeUsage.swift" \
    -o "$STAGE/Contents/MacOS/$APP_NAME" \
    -framework Cocoa \
    -framework UserNotifications

# Ad-hoc signature: enough for a local build, avoids Gatekeeper hassle at launch.
codesign --force --sign - "$STAGE" 2>/dev/null || true

# Install into ~/Applications (so it keeps working even if you move/delete this repo).
mkdir -p "$INSTALL_DIR"
pkill -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true
rm -rf "$APP"
mv "$STAGE" "$APP"
rm -rf "$(dirname "$STAGE")"
ok "Installed → $APP"

# ----------------------------------------------------- auto-start at login ---
say "Enabling auto-start at login…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <!-- Launch through LaunchServices (\`open\`) rather than the binary directly:
         this is what lets macOS grant notification permission. \`open\` exits at
         once; the app keeps running on its own (KeepAlive=false). -->
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

# (Re)load cleanly. Bootstrapping with RunAtLoad also launches it right now.
launchctl bootout "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$AGENT" 2>/dev/null || launchctl load "$AGENT" 2>/dev/null || true
launchctl enable "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true
ok "It will start automatically at every login."

# ------------------------------------------------------------------ launch ---
open "$APP" 2>/dev/null || true
echo
ok "Done. Look for the ⌛ / 🗓 icons in your menu bar (top-right)."
echo "  Click them for the detail: Claude + Codex quotas, daily cost and projection."
echo "  Uninstall anytime:  ./install.sh uninstall"
