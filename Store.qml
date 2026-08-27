import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Persistence for the journal: one JSON file, read once, written back debounced.
//
// The shape on disk is Model's store shape verbatim, so this file is only
// plumbing — parsing, writing, and the two hazards that come with watching a
// file you also write to.
Item {
  id: store

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")

  // Override from settings; "" means the default location. A leading ~ is
  // expanded here because the settings field is hand-typed and Qt will not.
  property string overridePath: ""
  readonly property string resolvedPath: {
    var raw = String(overridePath || "").trim()
    if (!raw) return stateHome + "/omarchy/bujo/tasks.json"
    if (raw.charAt(0) === "~") return home + raw.slice(1)
    return raw
  }
  readonly property string resolvedDir: resolvedPath.replace(/\/[^\/]*$/, "")

  property var journal: Model.emptyStore()
  property bool ready: false
  property string lastError: ""

  // Identity of this machine: four random hex bytes, generated once and kept
  // OUTSIDE the journal — deliberately at a fixed local path rather than beside
  // it, because the whole point of statePath is that the journal is the thing
  // that travels and this must not.
  //
  // It exists so an id minted here can never collide with one minted on another
  // machine in the same millisecond, which under a merge would fuse two
  // unrelated tasks into one.
  readonly property string devicePath: stateHome + "/omarchy/bujo/device"
  property string deviceId: ""

  // How long a deletion marker is kept before pruning. Long enough that a
  // device offline for a month still learns about the delete rather than
  // resurrecting the task.
  readonly property int deletedRetentionDays: 30

  signal changed()

  // The exact text we last wrote. FileView watches the file we are writing to,
  // so every save comes back as a change notification; comparing against this
  // is what stops a save from reloading and re-rendering the whole panel.
  property string lastWritten: ""

  // True once mkdir has finished. FileView will not create the directory, and a
  // write into a missing one fails silently, so the first save has to wait.
  property bool dirReady: false
  property bool savePending: false

  // Diagnostics, surfaced through the IPC status so the file-watch path can be
  // verified without relying on console output.
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
    file.reload()
  }

  function flush() {
    if (!store.ready) return
    var pruned = Model.pruneDeleted(store.journal, store.nowIso(), store.deletedRetentionDays)
    if (pruned !== store.journal) store.journal = pruned
    var text = Model.serialize(pruned)
    if (text === store.lastWritten) return
    if (!store.dirReady) {
      store.savePending = true
      return
    }
    store.lastWritten = text
    store.writeCount++
    file.setText(text)
  }

  Component.onCompleted: {
    mkdirProc.running = true
    deviceProc.running = true
  }
  Component.onDestruction: {
    // A pending debounce would otherwise be lost when the shell reloads the
    // plugin, which happens on every file save during development.
    saveTimer.stop()
    flush()
  }

  // Read the device id, creating it on first run. A Process rather than a
  // FileView because the file has to be generated when absent, and absent is
  // the normal first-run case rather than an error.
  Process {
    id: deviceProc
    command: ["bash", "-c",
      'd="$1"; mkdir -p "$(dirname "$d")"; ' +
      '[ -s "$d" ] || od -An -N4 -tx1 /dev/urandom | tr -d " \n" > "$d"; ' +
      'cat "$d"',
      "_", store.devicePath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: store.deviceId = String(text).trim()
    }
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", store.resolvedDir]
    onExited: function (code) {
      store.dirReady = code === 0
      if (code !== 0) store.lastError = "Could not create " + store.resolvedDir
      else if (store.savePending) { store.savePending = false; store.flush() }
    }
  }

  // Coalesces a burst of toggles into one write. Ticking through a list of ten
  // should touch the disk once, not ten times.
  Timer {
    id: saveTimer
    interval: 300
    repeat: false
    onTriggered: store.flush()
  }

  FileView {
    id: file
    path: store.resolvedPath
    watchChanges: true
    atomicWrites: true
    printErrors: false

    onLoaded: {
      var text = file.text()
      store.loadCount++
      // Our own write coming back around. Reloading here would replace `journal`
      // with an equal-but-different object and re-run every binding in the
      // panel mid-interaction.
      if (text === store.lastWritten) { store.ready = true; return }

      var incoming = Model.normalizeStore(text)

      // First read of the session: there is nothing of ours to preserve yet, so
      // adopt the file whole.
      if (!store.ready) {
        store.journal = incoming
        store.ready = true
        store.changed()
        return
      }

      // Somebody else wrote this — another machine through a sync folder, or a
      // text editor. Ours is not automatically right and neither is theirs, so
      // combine them.
      var merged = Model.mergeStores(store.journal, incoming)
      store.journal = merged
      store.changed()

      // If the merge produced anything the file did not already contain, write
      // it back so the other device learns our side too. Comparing canonical
      // serialisations rather than raw text keeps a whitespace difference from
      // starting a write ping-pong.
      if (Model.serialize(merged) !== Model.serialize(incoming)) saveTimer.restart()
    }

    // No file yet is the normal first run, not an error worth surfacing.
    onLoadFailed: {
      store.loadCount++
      store.journal = Model.emptyStore()
      store.ready = true
      store.changed()
    }

    onFileChanged: { store.changeCount++; file.reload() }
  }
}
