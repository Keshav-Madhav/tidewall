import Foundation

/// The helper that swaps an update in once this process has exited. If the new copy never writes `alive`, it puts the
/// old one back; either way it leaves the outcome in `result` for the next launch.
///
/// Run as root (an administrator's install), it must not trust anything this account can still change. It copies the
/// new app into a folder of its own and checks its code-signature hash there before using it, parks the old copy in
/// that same folder, and touches this account's caches (the result, alive and pid files) only as this user, so a link
/// planted there can't turn a root write into a write anywhere.
struct InstallScript {
  let new: URL
  let previous: String
  let alive: URL
  let result: URL
  let pidFile: URL
  let version: String
  /// The staged copy's code-directory hash, as it was checked when staged ("CDHash=…").
  let hash: String
  /// Copy and re-check the new app in a private folder first: always as root, and testable without.
  let privateCopy: Bool

  var text: String {
    let q = shQuote
    return """
    APP=\(q(Bundle.main.bundleURL.path)); NEW=\(q(new.path)); PREV=\(q(previous)); OK=\(q(alive.path)); RES=\(q(result.path))
    PIDF=\(q(pidFile.path)); V=\(q(version)); HASH=\(q(hash)); PRIVATE=\(privateCopy ? 1 : 0); ME=\(q(NSUserName())); MYUID=\(getuid())
    EXE="$APP/Contents/MacOS/Tidewall"; T=""
    asme() { if [ "$(id -u)" = 0 ]; then /usr/bin/sudo -u "$ME" "$@"; else "$@"; fi; }
    open_app() { if [ "$(id -u)" = 0 ]; then /bin/launchctl asuser $MYUID /usr/bin/sudo -u "$ME" /usr/bin/open "$@"; else /usr/bin/open "$@"; fi; }
    launch() { \(viaLogin)open_app "$APP" --args --background --updated-from \(q(Cfg.version)); }
    # the outcome, for the next launch; then the private folder goes, unless the previous copy is still parked in it
    report() { asme /bin/sh -c 'echo "$1" > "$2"' sh "$1" "$RES"; [ -n "$T" ] && [ ! -e "$PREV" ] && rm -rf "$T"; }
    # stop every Tidewall running from $APP: the pid it wrote, and any other whose executable is exactly $EXE
    stop() { for sig in TERM TERM TERM KILL; do
        ps=""; p=$(cat "$PIDF" 2>/dev/null); [ -n "$p" ] && [ "$(ps -o comm= -p "$p" 2>/dev/null)" = "$EXE" ] && ps="$p"
        for q in $(pgrep -x Tidewall); do [ "$(ps -o comm= -p "$q" 2>/dev/null)" = "$EXE" ] && ps="$ps $q"; done
        [ -z "$ps" ] && return 0
        kill -$sig $ps 2>/dev/null; sleep 1; done; }
    while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
    if [ "$PRIVATE" = 1 ]; then
      T=$(/usr/bin/mktemp -d /private/var/tmp/tidewall-update.XXXXXX) || { report "failed $V"; launch; exit 0; }
      PREV="$T/previous.app"
      if ! /bin/cp -cR "$NEW" "$T/new.app" 2>/dev/null && ! /usr/bin/ditto "$NEW" "$T/new.app"; then report "failed $V"; launch; exit 0; fi
      [ "$(id -u)" = 0 ] && /usr/sbin/chown -R root:wheel "$T/new.app"
      if ! /usr/bin/codesign --verify --deep --strict "$T/new.app" 2>/dev/null \\
        || [ "$(/usr/bin/codesign -dv --verbose=4 --arch arm64 "$T/new.app" 2>&1 | grep '^CDHash=')" != "$HASH" ]; then
        report "failed $V"; launch; exit 0; fi
      NEW="$T/new.app"
    fi
    rm -rf "$PREV"; asme /bin/rm -f "$OK" "$PIDF"
    if ! mv "$APP" "$PREV"; then report "failed $V"; launch; exit 0; fi
    if ! mv "$NEW" "$APP"; then mv "$PREV" "$APP"; report "failed $V"; launch; exit 0; fi
    launch
    i=0; while [ $i -lt 900 ]; do
      if [ "$(cat "$OK" 2>/dev/null)" = "$V" ]; then rm -rf "$PREV"; report "ok $V"; exit 0; fi
      sleep 0.2; i=$((i+1)); done
    # it didn't come up within 3 minutes (a slow Mac's first look at a new app can take a while): put the previous copy back
    stop
    outcome="rollbackfailed"
    if mv "$APP" "$APP.failed"; then
      if mv "$PREV" "$APP"; then rm -rf "$APP.failed"; outcome="rolledback"; else mv "$APP.failed" "$APP"; fi
    fi
    report "$outcome $V"; launch
    """
  }

  /// With the login item on, relaunch through it so launchd keeps restarting Tidewall if it ever crashes; only if
  /// launchd's loaded copy of the job runs exactly this app (it keeps the definition it read at login).
  private var viaLogin: String {
    let job = "gui/\(getuid())/\(LoginItem.label)"
    return LoginItem.enabled
      ? "[ \"$(launchctl print \(job) 2>/dev/null | awk '/^\\tprogram = /{print substr($0, index($0, \"= \") + 2); exit}')\" = \"$EXE\" ] && launchctl kickstart \(job) >/dev/null 2>&1 || " : ""
  }
}
