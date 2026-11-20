#!/bin/bash
# End to end, the way a real update goes: two development builds of Tidewall (90.0.0 and 90.0.1), a feed signed with a
# throwaway key and served from this Mac, and the old copy updating itself. Every copy runs isolated (its own settings,
# caches and log, windows behind your wallpaper), so it never touches your Tidewall.
#
#   tools/update-test.sh [--quick] [<output dir>]      (--quick: skips the rollback case, which waits out 3 minutes)
#
#   full       the whole release downloaded, checked and swapped in; the new copy comes up and records it
#   patch      only the files that changed, laid over a clone of the old copy, must give exactly the release
#   admin      an administrator's install, walked without a password: the script through AppleScript's quoting,
#              the new app copied to a private folder and its code-signature hash checked there
#   tampered   a release whose zip changed after signing is refused, and the old copy stays
#   unsigned   a feed signed with a key the app doesn't trust is refused
#   rollback   a release that never comes up is swapped back out after 3 minutes, and not retried at once
set -uo pipefail
cd "$(dirname "$0")/.."
quick=0; out=""
for a in "$@"; do case "$a" in --quick) quick=1;; *) out="$a";; esac; done
out="${out:-${TMPDIR:-/tmp}/tidewall-update-test-$(date +%Y%m%d-%H%M%S)}"; mkdir -p "$out"; out=$(cd "$out" && pwd)
LOG="$HOME/Library/Logs/Tidewall-isolated-test.log"; CACHE="$HOME/Library/Caches/app.tidewall.isolated-test"
PB=/usr/libexec/PlistBuddy; INST="$out/inst/Tidewall.app"; SRV="$out/srv"; mkdir -p "$SRV"
bad=0

echo "building (development build)…"
./build.sh > "$out/build.log" 2>&1 || { echo "✗ the build failed (see $out/build.log)"; exit 1; }
# <version> <dir> [never-alive]: a copy of the build as that version, isolated, ad-hoc signed
copyas() {
  mkdir -p "$2"; rm -rf "$2/Tidewall.app"; cp -R build/Tidewall.app "$2/"
  $PB -c "Set :CFBundleShortVersionString $1" -c "Add :TidewallIsolatedTest bool true" "$2/Tidewall.app/Contents/Info.plist"
  [ "${3:-}" = never-alive ] && $PB -c "Add :TidewallTestNeverAlive bool true" "$2/Tidewall.app/Contents/Info.plist"
  codesign --force --deep --sign - "$2/Tidewall.app" 2>/dev/null
}
cdhash() { codesign -dv --verbose=4 --arch arm64 "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
copyas 90.0.0 "$out/a"; copyas 90.0.1 "$out/b"; copyas 90.0.1 "$out/broken" never-alive
(cd "$out/b" && ditto -c -k --keepParent Tidewall.app "$SRV/full.zip")
(cd "$out/broken" && ditto -c -k --keepParent Tidewall.app "$SRV/broken.zip")
python3 tools/make-patch.py "$out/a/Tidewall.app" "$out/b/Tidewall.app" "$SRV/patch.zip" > "$out/patch.log" 2>&1 \
  || { echo "✗ make-patch.py couldn't make a patch from 90.0.0 to 90.0.1 (see $out/patch.log)"; exit 1; }
cp "$SRV/full.zip" "$SRV/tampered.zip"
python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[len(b)//2]^=1; open(p,"wb").write(b)' "$SRV/tampered.zip"

keys() { swift tools/update-sign.swift keygen | awk '/private/ {print $NF} /public/ {print $NF}'; }
read -r PRIV PUB <<< "$(keys | tr '\n' ' ')"; read -r OTHER _ <<< "$(keys | tr '\n' ' ')"
PORT=$((20000 + RANDOM % 20000)); URL="http://127.0.0.1:$PORT"
echo "release notes" > "$out/notes.txt"
sign() {   # <feed name> <key> <zip signed> <zip served> <cdhash> [patch]
  local extra=(); [ "${6:-}" = patch ] && extra=("$SRV/patch.zip" 90.0.0 "$URL/patch.zip")
  TIDEWALL_UPDATE_KEY="$2" swift tools/update-sign.swift sign "$SRV/$3" 90.0.1 "$URL/$4" "$out/notes.txt" "$5" ${extra[@]+"${extra[@]}"} > "$SRV/$1.json"
}
B=$(cdhash "$out/b/Tidewall.app"); BROKEN=$(cdhash "$out/broken/Tidewall.app")
sign full "$PRIV" full.zip full.zip "$B"; sign patch "$PRIV" full.zip full.zip "$B" patch
sign broken "$PRIV" broken.zip broken.zip "$BROKEN"
sign tampered "$PRIV" full.zip tampered.zip "$B"   # signed over the real zip, served the tampered one
sign unsigned "$OTHER" full.zip full.zip "$B"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SRV" > "$out/server.log" 2>&1 & server=$!
stopall() { pkill -f "$out/inst/Tidewall.app/Contents/MacOS/Tidewall" 2>/dev/null; sleep 1; }
trap 'stopall; kill $server 2>/dev/null' EXIT

since=0
fresh() {   # the old copy installed, nothing left from the last case
  stopall; rm -rf "$out/inst" "$CACHE"; mkdir -p "$out/inst"; cp -R "$out/a/Tidewall.app" "$out/inst/"
  defaults delete tidewall.isolated-test update.failed 2>/dev/null; defaults write tidewall.isolated-test welcomed -bool true
  touch "$LOG"; since=$(($(wc -l < "$LOG") + 1))
}
launch() {   # <feed> [VAR=value…]: the old copy, told about the feed, installing the moment it's ready
  env TIDEWALL_UPDATE_FEED="$URL/$1.json" TIDEWALL_UPDATE_TESTKEY="$PUB" TIDEWALL_UPDATE_INSTALL_NOW=1 "${@:2}" \
    "$INST/Contents/MacOS/Tidewall" --background > /dev/null 2>&1 &
}
logged() { tail -n +$since "$LOG" | grep -qF "$1"; }
waitfor() {   # <text> <seconds>
  for _ in $(seq 1 "$2"); do logged "$1" && return 0; sleep 1; done; return 1
}
# what the swap helper recorded for the next launch (ok, failed, rolledback, rollbackfailed)
outcome() { for _ in $(seq 1 "$1"); do [ -s "$CACHE/update-result" ] && break; sleep 1; done; cat "$CACHE/update-result" 2>/dev/null; }
version() { $PB -c "Print :CFBundleShortVersionString" "$INST/Contents/Info.plist" 2>/dev/null; }
check() {   # <case> <condition…>: every condition must hold
  local name="$1" why=""; shift
  for c in "$@"; do eval "$c" || why="$why; $c"; done
  if [ -z "$why" ]; then echo "✓ $name"; else bad=$((bad + 1)); echo "✗ $name:${why#;}"; tail -n +$since "$LOG" | grep "\[update\]" | tail -6 | sed 's/^/    /'; fi
}

fresh; launch full
waitfor "[update] updated from 90.0.0 to 90.0.1" 90
check full 'logged "[update] 90.0.1 is ready to install"' '[ "$(version)" = 90.0.1 ]' '[ "$(outcome 20)" = "ok 90.0.1" ]' \
  '[ ! -e "$out/inst/.tidewall-update-$(id -u)/previous.app" ]'

fresh; launch patch
waitfor "[update] updated from 90.0.0 to 90.0.1" 90
check patch 'logged "is ready to install (patched)"' '[ "$(version)" = 90.0.1 ]' '[ "$(outcome 20)" = "ok 90.0.1" ]'

before=$(ls -d /private/var/tmp/tidewall-update.* 2>/dev/null | wc -l)
fresh; launch full TIDEWALL_UPDATE_ADMIN_DRYRUN=1
waitfor "[update] updated from 90.0.0 to 90.0.1" 90
check admin 'logged "survives AppleScript"' '[ "$(version)" = 90.0.1 ]' '[ "$(outcome 20)" = "ok 90.0.1" ]' \
  '[ "$(ls -d /private/var/tmp/tidewall-update.* 2>/dev/null | wc -l)" -eq "$before" ]'

fresh; launch tampered
waitfor "rejected" 60
check tampered 'logged "[update] 90.0.1 rejected: checksum mismatch"' '[ "$(version)" = 90.0.0 ]'

fresh; launch unsigned
waitfor "signature is invalid" 40; sleep 2
check unsigned 'logged "signature is invalid"' '! logged "downloading"' '[ "$(version)" = 90.0.0 ]'

if [ $quick = 0 ]; then
  echo "   (rollback: waiting out the 3 minutes a new copy gets to come up)"
  fresh; launch broken
  waitfor "didn't work (" 260
  check rollback 'logged "[update] installing 90.0.1 didn'"'"'t work (rolledback); keeping 90.0.0"' '[ "$(version)" = 90.0.0 ]' \
    '! pgrep -f "$out/inst/Tidewall.app.failed" > /dev/null' '[ ! -e "$out/inst/Tidewall.app.failed" ]'
fi

stopall
[ $bad -eq 0 ] && { echo "✓ updates: every case behaved (logs: $out, and $LOG)"; exit 0; }
echo "✗ updates: $bad case(s) misbehaved (logs: $out, and $LOG)"; exit 1
