#!/bin/bash
set -e
xcodebuild -project OverlayOpus.xcodeproj -scheme OverlayOpus -configuration Release -derivedDataPath build
echo "Built: build/Build/Products/Release/OverlayOpus.app"
echo "Install: cp -r build/Build/Products/Release/OverlayOpus.app /Applications/"
