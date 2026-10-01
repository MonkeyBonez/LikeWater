#!/bin/sh
# Install both apps on the phone and sideload the tiled metros into each app's
# Application Support/Cities (there is no public bundle server yet). Phone must be unlocked.
set -e
DEV=${DEV:-ECD3EF26-97FB-5D2F-8379-9516C6A8BBE9}
cd "$(dirname "$0")"
P=$(ls -d ~/Library/Developer/Xcode/DerivedData/LikeWater-*/Build/Products/Debug-iphoneos | head -1)
for app in SunMap LikeWater; do xcrun devicectl device install app --device $DEV "$P/$app.app" | grep -E "installed|App installed" || true; done
for id in ${METROS:-seattle nyc la}; do
  for bid in com.likewater.sunmap com.likewater.app; do
    echo "== $id -> $bid"
    xcrun devicectl device copy to --device $DEV --domain-type appDataContainer --domain-identifier $bid \
      --source "Server/$id" --destination "Library/Application Support/Cities/$id" --quiet
  done
done
xcrun devicectl device process launch --device $DEV com.likewater.sunmap | grep Launched || true
