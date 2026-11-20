#!/bin/zsh
# usage: scene.sh <scene> <welcome 0|1>
D=~/Developer/ToolboxProMax/build/appstore
P=~/Library/Containers/io.github.corvinus2003.toolbox/Data/Library/Preferences/io.github.corvinus2003.toolbox.plist
APP="$D/Toolbox Studio.xcarchive/Products/Applications/Toolbox Studio.app"
osascript -e 'quit app "Toolbox Studio"' 2>/dev/null; while pgrep -x "Toolbox Studio" >/dev/null; do sleep 0.3; done
SEL=$(python3 "$D/scenes.py" "$1")
defaults write "$P" "NSWindow Frame main" "120 100 1440 900 0 0 2048 1122 "
defaults delete "$P" viewport 2>/dev/null
if [[ "$2" == 1 ]]; then defaults delete "$P" welcomeSeen 2>/dev/null; else defaults write "$P" welcomeSeen -bool YES; fi
open --env TPM_SELECT=$SEL "$APP"
sleep 3; osascript -e 'tell application id "io.github.corvinus2003.toolbox" to activate'; sleep 2
swift "$D/winid.swift" "Toolbox Studio"
