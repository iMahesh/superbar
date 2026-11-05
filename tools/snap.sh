#!/bin/zsh
# Snapshots of every page in light and dark, with seed data, on a fresh test store.
# Usage: tools/snap.sh            all pages
#        APP_SNAPSHOT_PAGES=all,settings tools/snap.sh
#        tools/snap.sh --own      launch Superbar on its own (through Launch Services), so
#                                 macOS checks Superbar's own Screen Recording grant instead of
#                                 the terminal's. Grant it after the last rebuild: ad hoc builds
#                                 lose the grant.
# Messages also go to /tmp/Superbar-shots/snapshot.log.
set -u
bundle=~/Applications/Superbar.app
app=$bundle/Contents/MacOS/Superbar
store=/tmp/Superbar-test.store
shots=/tmp/Superbar-shots
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/com.maheshporeddy.superbar.savedState
# Seed data only fills an empty store, so start from nothing.
rm -f $store $store-shm $store-wal
rm -rf $shots
if [[ ${1:-} == --own ]]; then
  # -n: a new instance next to a running Superbar. -W: wait until it quits.
  env=(--env APP_STORE=$store --env APP_SEED=1 --env APP_SNAPSHOT=$shots)
  [[ -n ${APP_SNAPSHOT_PAGES:-} ]] && env+=(--env APP_SNAPSHOT_PAGES=$APP_SNAPSHOT_PAGES)
  open -n -W $env $bundle
  cat $shots/snapshot.log 2>/dev/null
else
  APP_STORE=$store APP_SEED=1 APP_SNAPSHOT=$shots $app
fi
