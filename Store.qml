import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Persistence for the journal: one JSON file, read through a validated
// descriptor, written atomically, watched for outside edits.
//
// There is deliberately no FileView here. FileView opens the path it is given
// directly, inside the long-lived shell process, and both of this plugin's
// paths are predictable. A same-user process that gets there first can leave a
// FIFO (the open blocks and takes the whole shell with it), a symlink (the read
// is redirected), or a very large file (the read exhausts memory). Atomic
// writes never addressed any of that — they protect the write path, and this is
// the read path.
//
// So every open goes through `dd iflag=nofollow,nonblock`:
//   nofollow  — a symlink fails to open rather than redirecting us
//   nonblock  — a FIFO returns immediately instead of blocking forever
//   count/bs  — the read is bounded no matter what the file claims to be
// The stat and -f/-L tests before it are a cheap early bail, not the guarantee;
// they race by construction. The open flags are the guarantee.
Item {
  id: store

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")

  property string overridePath: ""
  readonly property string resolvedPath: {
    var raw = String(overridePath || "").trim()
    if (!raw) return stateHome + "/omarchy/bujo/tasks.json"
    if (raw.charAt(0) === "~") return home + raw.slice(1)
    return raw
  }
  readonly property string resolvedDir: resolvedPath.replace(/\/[^\/]*$/, "")
  readonly property string resolvedName: resolvedPath.replace(/^.*\//, "")

  // A journal of this size is already far past any plausible use — a task is a
  // couple of hundred bytes — so anything larger is a malformed or hostile file
  // rather than someone's very long week.
  readonly property int maxBytes: 4 * 1024 * 1024

  property var journal: Model.emptyStore()
  property bool ready: false
  property string lastError: ""

  // Identity of this machine: four random hex bytes, generated once and kept
  // OUTSIDE the journal — at a fixed local path rather than beside it, because
  // the point of statePath is that the journal travels and this must not.
  readonly property string devicePath: stateHome + "/omarchy/bujo/device"
  property string deviceId: ""

  readonly property int deletedRetentionDays: 30

  signal changed()

  // The exact text last written. Every save comes back as a watch event, so
  // comparing against this is what stops a save from reloading the panel.
  property string lastWritten: ""

  property bool savePending: false
  property bool writing: false

  property int loadCount: 0
  property int changeCount: 0
  property int writeCount: 0

  function nowIso() { return new Date().toISOString() }

  function commit(next) {
    if (!next) return
    store.journal = next
    store.changed()
    saveTimer.restart()
  }

  function reloadNow() {
    if (readProc.running) return
    readProc.running = true
  }

  function applyText(text) {
    if (text === store.lastWritten) { store.ready = true; return }

    var incoming = Model.normalizeStore(text)

    // Merge unconditionally, including on the first read of the session. An IPC
    // add can land before the read finishes and adopting would discard it, and
    // a file that arrives already holding a duplicated lineage gets collapsed
    // here rather than only on the next sync. Merging an empty journal against
    // the file yields the file, so the ordinary case is unchanged.
    var merged = Model.mergeStores(store.journal, incoming)
    store.journal = merged
    store.ready = true
    store.changed()

    // If the merge produced anything the file did not contain, write it back so
    // the other device learns our side. Comparing canonical serialisations
    // rather than raw text keeps a whitespace difference from starting a
    // write ping-pong.
    if (Model.serialize(merged) !== Model.serialize(incoming)) saveTimer.restart()
  }

  function flush() {
    if (!store.ready) return
    if (store.writing) { store.savePending = true; return }
    var pruned = Model.pruneDeleted(store.journal, store.nowIso(), store.deletedRetentionDays)
    if (pruned !== store.journal) store.journal = pruned
    var text = Model.serialize(pruned)
    if (text === store.lastWritten) return
    store.writing = true
    writeProc.pending = text
    // Remembered separately from `pending`, which is cleared the moment stdin
    // is fed. On success `lastWritten` must become the text this write actually
    // put on disk — re-serialising the journal at exit records whatever it has
    // become since, and a task added mid-write is then treated as already
    // saved and silently never written at all.
    writeProc.inflight = text
    writeProc.running = true
  }

  Component.onCompleted: {
    deviceProc.running = true
    readProc.running = true
  }
  Component.onDestruction: saveTimer.stop()

  // Coalesces a burst of toggles into one write.
  Timer {
    id: saveTimer
    interval: 300
    repeat: false
    onTriggered: store.flush()
  }

  // --- validated read -------------------------------------------------------

  Process {
    id: readProc
    running: false
    command: ["bash", "-c",
      'p="$1"; max="$2"; ' +
      '[ -e "$p" ] || exit 10; ' +               // absent: the ordinary first run
      '[ -L "$p" ] && exit 11; ' +               // symlink
      '[ -f "$p" ] || exit 12; ' +               // FIFO, directory, device node
      'sz=$(stat -c %s -- "$p" 2>/dev/null || echo 0); ' +
      '[ "$sz" -le "$max" ] || exit 13; ' +      // oversized
      'exec dd if="$p" iflag=nofollow,nonblock bs=65536 ' +
      'count=$(( max / 65536 + 1 )) status=none',
      "_", store.resolvedPath, String(store.maxBytes)]

    stdout: StdioCollector { waitForEnd: true }

    onExited: function (code) {
      store.loadCount++
      if (code === 0) {
        store.lastError = ""
        store.applyText(stdout.text)
        return
      }
      // No file yet is the normal first run, not a failure.
      if (code === 10) {
        store.lastError = ""
        store.ready = true
        store.changed()
        return
      }
      // Anything else means the path is not a plain file we are willing to
      // read. Refuse it and keep whatever is in memory rather than guessing.
      store.ready = true
      store.lastError = code === 11 ? "Refused: " + store.resolvedPath + " is a symlink"
                     : code === 12 ? "Refused: " + store.resolvedPath + " is not a regular file"
                     : code === 13 ? "Refused: " + store.resolvedPath + " is larger than 4 MiB"
                     : "Could not read " + store.resolvedPath
      console.warn("bujo: " + store.lastError)
      store.changed()
    }
  }

  // --- validated atomic write -----------------------------------------------

  Process {
    id: writeProc
    running: false
    property string pending: ""
    property string inflight: ""
    stdinEnabled: true

    command: ["bash", "-c",
      'p="$1"; max="$2"; d="${p%/*}"; ' +
      'mkdir -p -- "$d" || exit 20; ' +
      '[ -L "$p" ] && exit 11; ' +               // never publish through a symlink
      'tmp="$d/.bujo.tmp.$$"; ' +
      'rm -f -- "$tmp"; ' +
      '( set -C; : > "$tmp" ) || exit 21; ' +    // O_EXCL: refuse a planted temp
      'chmod 600 -- "$tmp" || exit 22; ' +
      'head -c "$max" > "$tmp" || { rm -f -- "$tmp"; exit 23; }; ' +
      // -T so a symlink at the destination is replaced, never followed.
      'mv -T -- "$tmp" "$p" || { rm -f -- "$tmp"; exit 24; }',
      "_", store.resolvedPath, String(store.maxBytes)]

    onStarted: {
      write(writeProc.pending)
      writeProc.pending = ""
      stdinEnabled = false
    }

    onExited: function (code) {
      store.writing = false
      if (code === 0) {
        store.writeCount++
        store.lastWritten = writeProc.inflight
        store.lastError = ""
        // The journal may have moved on while this write was in flight.
        if (Model.serialize(store.journal) !== store.lastWritten) store.savePending = true
      } else {
        store.lastError = code === 11
          ? "Refused to write: " + store.resolvedPath + " is a symlink"
          : "Could not write " + store.resolvedPath + " (" + code + ")"
        console.warn("bujo: " + store.lastError)
      }
      if (store.savePending) { store.savePending = false; saveTimer.restart() }
    }
  }

  // --- watch for outside edits ----------------------------------------------
  //
  // The directory, not the file: an atomic write replaces the file by rename,
  // which a watch on the old inode would stop seeing after the first save.
  Process {
    id: watchProc
    running: true
    command: ["bash", "-c",
      'd="$1"; ' +
      'while true; do ' +
      '  if [ -d "$d" ]; then ' +
      '    inotifywait -m -q -e close_write,create,moved_to,delete ' +
      '      --format "%f" -- "$d" 2>/dev/null; ' +
      '  fi; ' +
      '  sleep 2; ' +                            // directory absent, or watcher died
      'done',
      "_", store.resolvedDir]

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (String(line).trim() !== store.resolvedName) return
        store.changeCount++
        store.reloadNow()
      }
    }
  }

  // --- device identity ------------------------------------------------------
  //
  // Created exclusively: the file is written to a private temp and published
  // with a hard link, which fails if anything already occupies the path. So we
  // either create it ourselves or read what was already there — never write
  // through something another process put in the way.
  Process {
    id: deviceProc
    running: false
    command: ["bash", "-c",
      'p="$1"; d="${p%/*}"; ' +
      'mkdir -p -- "$d" || exit 20; ' +
      'if [ ! -e "$p" ]; then ' +
      '  tmp="$d/.device.tmp.$$"; ' +
      '  rm -f -- "$tmp"; ' +
      '  ( set -C; : > "$tmp" ) || exit 21; ' +
      '  chmod 600 -- "$tmp"; ' +
      '  od -An -N4 -tx1 /dev/urandom | tr -d " \\n" > "$tmp" || { rm -f -- "$tmp"; exit 23; }; ' +
      '  ln -- "$tmp" "$p" 2>/dev/null; ' +      // exclusive publish; losing a race is fine
      '  rm -f -- "$tmp"; ' +
      'fi; ' +
      '[ -L "$p" ] && exit 11; ' +
      '[ -f "$p" ] || exit 12; ' +
      'sz=$(stat -c %s -- "$p" 2>/dev/null || echo 0); ' +
      '[ "$sz" -le 64 ] || exit 13; ' +
      'exec dd if="$p" iflag=nofollow,nonblock bs=64 count=1 status=none',
      "_", store.devicePath]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var id = String(text).trim()
        if (/^[0-9a-f]{1,16}$/.test(id)) store.deviceId = id
      }
    }

    onExited: {
      // Anything that leaves us without an id — an occupied path, no
      // /dev/urandom, a read-only state directory — falls back rather than
      // staying empty. A queued task that never lands is worse than an id
      // derived from the clock, and it stays distinct per install.
      if (!store.deviceId) {
        store.lastError = "Could not read " + store.devicePath
        store.deviceId = "t" + Math.floor(Date.now()).toString(36).slice(-7)
      }
    }
  }
}
