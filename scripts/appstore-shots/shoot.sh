#!/bin/zsh
# usage: shoot.sh <output name>
D=~/Developer/ToolboxProMax/build/appstore
W=$(swift "$D/winid.swift" "Toolbox Studio" | cut -d' ' -f1)
screencapture -x -o -l "$W" "$D/screenshots/raw-$1.png"
swift "$D/flatten.swift" "$D/screenshots/raw-$1.png" "$D/screenshots/$1.png" && rm "$D/screenshots/raw-$1.png"
sips -g pixelWidth -g pixelHeight -g hasAlpha "$D/screenshots/$1.png" | tail -3 | tr '\n' ' '; echo
