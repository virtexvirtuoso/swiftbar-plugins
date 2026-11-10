#!/bin/bash
# SwiftBar launcher for Pearcleaner (app uninstaller).
# Pearcleaner 5.x dropped its own menu-bar mode, so this puts it back as a launcher.
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#
# Read-only by design: every item only OPENS Pearcleaner, which shows the files it would
# remove and waits for you to confirm. Nothing here deletes anything. In particular there
# is no "remove orphaned files" item: the CLI's orphan scan flags files of apps that are
# still installed (it listed CodexBar's folder on 2026-11-10), so it must be reviewed by eye.

APP="/Applications/Pearcleaner.app"
CLI="/opt/homebrew/bin/pearcleaner"

echo "🍐 | size=13"
echo "---"

if [ ! -d "$APP" ]; then
  echo "Pearcleaner is not installed | color=red"
  echo "Install with: brew install --cask pearcleaner | size=11"
  exit 0
fi

echo "Open Pearcleaner | bash=/usr/bin/open param1=-a param2=Pearcleaner terminal=false"
echo "Uninstall an app…"

# One submenu per first letter keeps ~150 apps navigable.
last=""
while IFS= read -r path; do
  name=$(basename "$path" .app)
  letter=$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')
  case "$letter" in [A-Z]) ;; *) letter="#";; esac
  if [ "$letter" != "$last" ]; then
    echo "-- $letter"
    last="$letter"
  fi
  # Pipe would end the title in SwiftBar's syntax; no installed app uses one, but be safe.
  title=${name//|/-}
  echo "---- $title | bash=/usr/bin/open param1=-a param2=Pearcleaner param3=\"$path\" terminal=false"
done < <(find /Applications "$HOME/Applications" -maxdepth 1 -name '*.app' 2>/dev/null \
          | awk -F/ '{print toupper(substr($NF,1,1)) "\t" $0}' | LC_ALL=C sort -f | cut -f2-)

echo "---"
if [ -x "$CLI" ]; then
  echo "List leftover files (read-only) | bash=$CLI param1=list-orphaned terminal=true"
fi
echo "Refresh app list | refresh=true size=11"
