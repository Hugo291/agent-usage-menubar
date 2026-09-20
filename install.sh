#!/usr/bin/env bash
#
#  install.sh — Claude + Codex usage widget for the macOS menu bar
#  ---------------------------------------------------------------
#  One command does everything: download (if needed), build, install, enable
#  auto-start at login, and launch. Nothing else to set up.
#
#  One-line install (nothing to clone):
#      curl -fsSL https://raw.githubusercontent.com/Hugo291/agent-usage-menubar/main/install.sh | bash
#
#  From a checkout:
#      ./install.sh             build + install + auto-start + launch
#      ./install.sh uninstall   stop, disable auto-start, and remove it
#
#  Requirements: macOS 12+ and the Xcode Command Line Tools (for `swiftc`, and
#  `git` when installing via the one-liner). `ccusage` is optional — only the
#  daily $ cost / token figures need it; the quota percentages work without it.
#
set -euo pipefail

# ----------------------------------------------------------------- config ----
APP_NAME="ClaudeUsageWidget"
BUNDLE_ID="com.hugo.claudeusagewidget"        # must match the cache dir used in the code
WIDGET_NAME="AgentUsageWidget"
WIDGET_ID="$BUNDLE_ID.widget"                 # must match WidgetFeed.extensionBundleID
REPO="https://github.com/Hugo291/agent-usage-menubar.git"
SRC_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
INSTALL_DIR="$HOME/Applications"
APP="$INSTALL_DIR/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
UID_NUM="$(id -u)"
CLONED=""

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
  # Deregister the embedded widget before deleting, so it leaves the gallery.
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$LSREG" ] && "$LSREG" -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
  rm -rf "$HOME/Library/Containers/$WIDGET_ID"
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

# --------------------------------------------------------- source bootstrap ---
# Run standalone (e.g. `curl … | bash`, so the source isn't next to us)?
# Fetch it into a temp dir and build from there; clean it up at the end.
if [ -z "${SRC_DIR:-}" ] || [ ! -f "$SRC_DIR/ClaudeUsage.swift" ]; then
  command -v git >/dev/null 2>&1 \
    || die "git not found — needed to download the source. Install the Xcode Command Line Tools:  xcode-select --install"
  say "Downloading the widget source…"
  CLONED="$(mktemp -d)"
  git clone --depth 1 "$REPO" "$CLONED" >/dev/null 2>&1 || die "Couldn't download from $REPO"
  SRC_DIR="$CLONED"
fi

# ------------------------------------------------------------------- build ---
# Braces are load-bearing: macOS ships bash 3.2, where `set -u` plus a UTF-8
# locale swallows the following multibyte character into the variable name
# ("APP_NAME…: unbound variable") and aborts the install.
say "Building ${APP_NAME}…"
STAGE="$(mktemp -d)/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$SRC_DIR/Info.plist" "$STAGE/Contents/Info.plist"
[ -f "$SRC_DIR/AppIcon.icns" ] && cp "$SRC_DIR/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

swiftc -O -swift-version 5 \
    "$SRC_DIR/ClaudeUsage.swift" \
    -o "$STAGE/Contents/MacOS/$APP_NAME" \
    -framework Cocoa \
    -framework Network \
    -framework UserNotifications \
    -framework WidgetKit

# ------------------------------------------- Notification Centre / desk widget ---
# Optional extra: a WidgetKit extension embedded in the app. It is sandboxed, so it
# never fetches anything itself — the menu-bar app drops a snapshot into the
# extension's own container and asks the system to redraw. That container is also
# why no App Group (and therefore no paid Apple Team ID) is needed.
if [ -f "$SRC_DIR/AgentUsageWidget.swift" ]; then
  say "Building the Notification Centre widget…"
  SDK_VER="$(xcrun --show-sdk-version 2>/dev/null || sw_vers -productVersion | cut -d. -f1-2)"
  BUILD_VER="$(date +%Y%m%d%H%M)"
  AX="$STAGE/Contents/PlugIns/$WIDGET_NAME.appex"
  mkdir -p "$AX/Contents/MacOS"
  cat > "$AX/Contents/Info.plist" <<AXPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$WIDGET_NAME</string>
    <key>CFBundleIdentifier</key><string>$WIDGET_ID</string>
    <key>CFBundleName</key><string>$WIDGET_NAME</string>
    <key>CFBundleDisplayName</key><string>Agent Usage</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <!-- Build timestamp, not a constant: chronod caches each extension's widget
         descriptors and only re-queries when the bundle looks new. With a fixed
         version, adding or renaming a widget silently keeps the OLD list in the
         gallery until the cache happens to expire. -->
    <key>CFBundleVersion</key><string>$BUILD_VER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <!-- Keys Xcode would normally stamp. chronod (the daemon that fills the widget
         gallery) filters on the platform, so a hand-rolled bundle that omits them
         registers with pluginkit yet never reaches the gallery. -->
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>DTPlatformName</key><string>macosx</string>
    <key>DTSDKName</key><string>macosx$SDK_VER</string>
    <key>DTPlatformVersion</key><string>$SDK_VER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
AXPLIST
  # A widget extension must be sandboxed; that is exactly why it is fed a snapshot.
  ENT="$(mktemp)"
  cat > "$ENT" <<'ENTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
</dict>
</plist>
ENTPLIST
  # `-e _NSExtensionMain` is what makes this an app extension rather than a program.
  # Xcode passes it for every extension target; without it the Swift `@main` entry
  # point runs instead, boots down the ExtensionKit path, returns, and the process
  # simply exits — so chronod's `getAllDescriptors` dies on an invalidated connection
  # and the widget never appears, even though pluginkit lists it as registered.
  if swiftc -O -swift-version 5 -parse-as-library \
        "$SRC_DIR/AgentUsageWidget.swift" \
        -o "$AX/Contents/MacOS/$WIDGET_NAME" \
        -framework WidgetKit -framework SwiftUI \
        -Xlinker -e -Xlinker _NSExtensionMain 2>/dev/null; then
    codesign --force --sign - --entitlements "$ENT" "$AX" 2>/dev/null || true
    ok "Widget built — add it from the widget gallery."
  else
    warn "Couldn't build the widget extension — the menu-bar app is unaffected."
    rm -rf "$STAGE/Contents/PlugIns"
  fi
  rm -f "$ENT"
fi

# Ad-hoc signature: enough for a local build, avoids Gatekeeper hassle at launch.
# Signed last so the embedded extension is sealed into the app's signature.
codesign --force --sign - "$STAGE" 2>/dev/null || true

# Install into ~/Applications (so it keeps working even if you move/delete this repo).
mkdir -p "$INSTALL_DIR"
pkill -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true
rm -rf "$APP"
mv "$STAGE" "$APP"
rm -rf "$(dirname "$STAGE")"
ok "Installed → $APP"

# Tell LaunchServices about the app (and the widget inside it), otherwise the
# extension never shows up in the widget gallery.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP" 2>/dev/null || true

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
[ -n "$CLONED" ] && rm -rf "$CLONED" 2>/dev/null || true   # tidy the temp checkout
echo
ok "Done. Look for the ⌛ / 🗓 icons in your menu bar (top-right)."
echo "  Click them for the detail: Claude + Codex quotas, daily cost and projection."
echo "  Uninstall:  curl -fsSL https://raw.githubusercontent.com/Hugo291/agent-usage-menubar/main/install.sh | bash -s uninstall"
