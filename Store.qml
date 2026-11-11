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
//
// Writes hold ONE descriptor from creation to publication. Creating a temp
// exclusively and then writing to it by name is not enough: the exclusivity
// ends with the create, and the name can be replaced with a symlink or a FIFO
// before the write reopens it. So the temp is opened once with
// O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK, every byte goes through that same
// descriptor, and before publishing we confirm the name still refers to the
// file we are holding. perl does this rather than the shell because `set -C`
// only guards regular files — a FIFO planted at the temp name opens and blocks
// the whole shell — and because it is an Omarchy dependency already.
//
// Every helper settles through ONE function that runs once per run, called
// from both `exited` and `runningChanged`. Quickshell emits only
// `runningChanged` when a command fails to start, so state settled in
// onExited alone stays stuck: a writer that never launched leaves `writing`
// set and no save ever runs again. A watchdog settles any helper that hangs.
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

  // Far longer than any of these helpers takes on a healthy disk; reaching it
  // means a hung filesystem, and the helper is killed and settled as failed.
  readonly property int helperTimeout: 15000

  function nowIso() { return new Date().toISOString() }

  function commit(next) {
    if (!next) return
    store.journal = next
    store.changed()
    saveTimer.restart()
  }

  function reloadNow() {
    if (readProc.running) return
    store.readSettled = false
    readProc.running = true
    readWatchdog.restart()
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
    // `inflight` is kept separate from `payload`, which is cleared the moment
    // stdin is fed. On success `lastWritten` must become the text this write
    // actually put on disk — re-serialising the journal at exit records
    // whatever it has become since, and a task added mid-write is then treated
    // as already saved and silently never written at all.
    var writer = writerComponent.createObject(store, { payload: text, inflight: text })
    if (!writer) { store.writing = false; store.lastError = "Could not start the writer"; return }
    writer.start()
  }

  Component.onCompleted: {
    deviceProc.running = true
    deviceWatchdog.restart()
    store.reloadNow()
  }
  Component.onDestruction: {
    saveTimer.stop()
    watchRetry.stop()
    readWatchdog.stop()
    readRetry.stop()
    deviceWatchdog.stop()
  }

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

    onExited: function (code) { store.readFinished(code, stdout.text) }
    onRunningChanged: if (!running) store.readFinished(-1, "")
  }

  property bool readSettled: true
  property int readDelay: 2000

  Timer {
    id: readWatchdog
    interval: store.helperTimeout
    onTriggered: {
      if (store.readSettled) return
      readProc.signal(9)
      store.readFinished(-2, "")
    }
  }

  // Retries a read that never ran or never finished. Marking the store ready
  // instead would let the next save write the in-memory journal -- empty, on
  // the first read -- over a file that may be perfectly fine.
  Timer {
    id: readRetry
    interval: 2000
    onTriggered: store.reloadNow()
  }

  // code -1: the helper never started; -2: it hung and was killed.
  function readFinished(code, text) {
    if (store.readSettled) return
    store.readSettled = true
    readWatchdog.stop()
    store.loadCount++
    if (code === -1 || code === -2) {
      store.lastError = (code === -1 ? "Could not start the reader for " : "Timed out reading ")
                      + store.resolvedPath
      console.warn("bujo: " + store.lastError)
      // Interval set before the restart: changing it on a running Timer
      // restarts it with the new value.
      readRetry.interval = store.readDelay
      readRetry.restart()
      store.readDelay = Math.min(store.readDelay * 2, 60000)
      return
    }
    store.readDelay = 2000
    if (code === 0) {
      store.lastError = ""
      store.applyText(text)
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

  // --- validated atomic write -----------------------------------------------

  // A fresh Process per write, created from a Component and destroyed on exit.
  //
  // Not one long-lived Process re-triggered by setting running=true: stdin has
  // to be closed after the payload so the helper sees EOF, and a Process whose
  // stdin has been closed does not start again. Reusing one silently performed
  // exactly one write per session — every later save was dropped with no error,
  // because onExited never fired to report one.
  //
  // The Item around it carries the watchdog and the settle-once flag, which a
  // Process cannot hold as children.
  Component {
    id: writerComponent

    Item {
      id: job
      property string payload: ""
      property string inflight: ""
      property bool settled: false

      function start() {
        writerProc.running = true
        writerWatchdog.restart()
      }

      // code -1: the helper never started; -2: it hung and was killed.
      function finished(code) {
        if (job.settled) return
        job.settled = true
        writerWatchdog.stop()
        store.writing = false
        if (code === 0) {
          store.writeCount++
          store.lastWritten = job.inflight
          store.lastError = ""
          // The journal may have moved on while this write was in flight.
          if (Model.serialize(store.journal) !== store.lastWritten) store.savePending = true
        } else {
          store.lastError = code === 21 ? "Refused to write: the temporary file could not be created exclusively"
                          : code === 25 ? "Refused to publish: the temporary file was replaced mid-write"
                          : code === -1 ? "Could not start the writer for " + store.resolvedPath
                          : code === -2 ? "Timed out writing " + store.resolvedPath
                          : "Could not write " + store.resolvedPath + " (" + code + ")"
          console.warn("bujo: " + store.lastError)
          // Unsaved changes stay in memory; the next commit retries them.
        }
        if (store.savePending) { store.savePending = false; saveTimer.restart() }
      }

      Timer {
        id: writerWatchdog
        interval: store.helperTimeout
        onTriggered: {
          writerProc.signal(9)
          job.finished(-2)
        }
      }

      Process {
        id: writerProc
        stdinEnabled: true

      command: ["perl", "-e",
        [
        'use strict; use warnings;',
        'use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK);',
        'use File::Path qw(make_path);',
        'my ($dest, $max) = @ARGV;',
        'my ($dir) = $dest =~ m{^(.*)/[^/]*$};',
        '$dir = "." unless defined $dir && length $dir;',
        'make_path($dir) unless -d $dir;',
        'my $tmp = sprintf("%s/.bujo.tmp.%d", $dir, $$);',
        // Deliberately NOT unlinked first. Clearing the name before creating it
        // is what makes O_EXCL meaningless: it removes whatever an attacker put
        // there and then creates cleanly every time. If the name is occupied the
        // create must fail, and the sweep below is what keeps that from becoming
        // permanent after a hard kill.

        // Every failure path below unlinks its own temp, so this only sweeps up
        // after a hard kill mid-write. unlink never follows a symlink, so a
        // planted name here removes the link and not whatever it points at.
        'for my $old (glob("$dir/.bujo.tmp.*")) {',
        '  my @o = lstat($old);',
        '  unlink $old if @o && -f _ && time - $o[9] > 3600;',
        '}',
        // One open, with the flags that matter. O_EXCL refuses anything already
        // at the name, O_NOFOLLOW refuses a symlink, O_NONBLOCK means a planted
        // FIFO cannot wedge the shell.
        'sysopen(my $fh, $tmp, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK, 0600) or exit 21;',
        'my ($buf, $n) = ("", 0);',
        'while (my $r = sysread(STDIN, $buf, 65536)) {',
        '  $n += $r;',
        '  if ($n > $max) { close $fh; unlink $tmp; exit 23 }',
        '  my $o = 0;',
        '  while ($o < $r) {',
        '    my $w = syswrite($fh, $buf, $r - $o, $o);',
        '    unless (defined $w) { close $fh; unlink $tmp; exit 23 }',
        '    $o += $w;',
        '  }',
        '}',
        'eval { require IO::Handle; $fh->sync };',
        // Validation before publication: the name must still be the file this
        // descriptor points at, or someone swapped it while we were writing.
        'my @f = stat($fh); my @l = lstat($tmp);',
        'unless (@l && $f[0] == $l[0] && $f[1] == $l[1]) { close $fh; unlink $tmp; exit 25 }',
        'close($fh) or do { unlink $tmp; exit 23 };',
        // rename(2) replaces a symlink at the destination rather than following it.
        'rename($tmp, $dest) or do { unlink $tmp; exit 24 };',
        'exit 0'
        ].join("\n"),
        "--", store.resolvedPath, String(store.maxBytes)]

        onStarted: {
          write(job.payload)
          job.payload = ""
          // Closing stdin is what gives the helper its EOF.
          stdinEnabled = false
        }

        onExited: function (code) { job.finished(code) }
        // Fires after `exited`, and alone when the command never started. The
        // job outlives a killed helper until it has actually gone.
        onRunningChanged: {
          if (running) return
          job.finished(-1)
          job.destroy()
        }
      }
    }
  }

  // --- watch for outside edits ----------------------------------------------
  //
  // The directory, not the file: an atomic write replaces the file by rename,
  // which a watch on the old inode would stop seeing after the first save.
  //
  // inotifywait is the tracked process itself, with no shell around it. A
  // retry loop in bash made it a grandchild, and Quickshell kills only the
  // process it started: disabling or reloading the plugin left the watcher
  // running. The retry lives in QML instead.
  Process {
    id: watchProc
    running: true
    command: ["inotifywait", "-m", "-q", "-e", "close_write,create,moved_to,delete",
              "--format", "%f", "--", store.resolvedDir]

    // Directory absent, inotifywait missing, or the watch died: try again,
    // backing off so a missing binary is not retried every two seconds forever.
    onStarted: watchRetry.interval = 2000
    onRunningChanged: if (!running) watchRetry.restart()

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (String(line).trim() !== store.resolvedName) return
        store.changeCount++
        store.reloadNow()
      }
    }
  }

  Timer {
    id: watchRetry
    interval: 2000
    onTriggered: {
      watchProc.running = true
      watchRetry.interval = Math.min(watchRetry.interval * 2, 60000)
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
    command: ["perl", "-e",
      [
      'use strict; use warnings;',
      'use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK :mode);',
      'use File::Path qw(make_path);',
      'my ($dest) = @ARGV;',
      'my ($dir) = $dest =~ m{^(.*)/[^/]*$};',
      '$dir = "." unless defined $dir && length $dir;',
      'make_path($dir) unless -d $dir;',
      'unless (-e $dest) {',
      '  my $tmp = sprintf("%s/.device.tmp.%d", $dir, $$);',
      // Same single-descriptor discipline as the journal write.
      '  if (sysopen(my $fh, $tmp, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK, 0600)) {',
      '    my $rnd = "";',
      '    if (sysopen(my $u, "/dev/urandom", O_RDONLY)) { sysread($u, $rnd, 4); close $u }',
      '    my $hex = unpack("H*", $rnd);',
      '    if (length($hex) == 8 && defined syswrite($fh, $hex)) {',
      '      eval { require IO::Handle; $fh->sync };',
      '      my @f = stat($fh); my @l = lstat($tmp);',
      '      if (@l && $f[0] == $l[0] && $f[1] == $l[1]) {',
      '        close $fh;',
      // link() publishes exclusively: it fails if anything already holds the
      // name, so a racing creator wins and we simply read theirs.
      '        link($tmp, $dest);',
      '      } else { close $fh }',
      '    } else { close $fh }',
      '    unlink $tmp;',
      '  }',
      '}',
      // Read back through a validated descriptor, same rules as the journal.
      'sysopen(my $rh, $dest, O_RDONLY|O_NOFOLLOW|O_NONBLOCK) or exit 11;',
      'my @st = stat($rh);',
      'unless (@st && S_ISREG($st[2])) { close $rh; exit 12 }',
      'if ($st[7] > 64) { close $rh; exit 13 }',
      'my $out = ""; sysread($rh, $out, 64); close $rh;',
      'print $out; exit 0'
      ].join("\n"),
      "--", store.devicePath]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var id = String(text).trim()
        if (/^[0-9a-f]{1,16}$/.test(id)) store.deviceId = id
      }
    }

    onExited: store.deviceFinished()
    // Alone, without `exited`, when perl never started.
    onRunningChanged: if (!running) store.deviceFinished()
  }

  Timer {
    id: deviceWatchdog
    interval: store.helperTimeout
    onTriggered: {
      deviceProc.signal(9)
      store.deviceFinished()
    }
  }

  property bool deviceSettled: false

  function deviceFinished() {
    if (store.deviceSettled) return
    store.deviceSettled = true
    deviceWatchdog.stop()
    // Anything that leaves us without an id — an occupied path, no
    // /dev/urandom, a read-only state directory, a helper that never started
    // or hung — falls back rather than staying empty. A queued task that never
    // lands is worse than an id derived from the clock, and it stays distinct
    // per install.
    if (!store.deviceId) {
      store.lastError = "Could not read " + store.devicePath
      store.deviceId = "t" + Math.floor(Date.now()).toString(36).slice(-7)
    }
  }
}
