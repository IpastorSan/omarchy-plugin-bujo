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

  function commit(next) {
    if (!next) return
    store.journal = next
    store.changed()
    saveTimer.restart()
  }

  function reloadNow() {
    file.reload()
  }

  function applyText(text) {
    store.journal = Model.normalizeStore(text)
    store.ready = true
    store.changed()
  }

  function flush() {
    if (!store.ready) return
    var text = Model.serialize(store.journal)
    if (text === store.lastWritten) return
    if (!store.dirReady) {
      store.savePending = true
      return
    }
    store.lastWritten = text
    store.writeCount++
    file.setText(text)
  }

  Component.onCompleted: mkdirProc.running = true
  Component.onDestruction: {
    // A pending debounce would otherwise be lost when the shell reloads the
    // plugin, which happens on every file save during development.
    saveTimer.stop()
    flush()
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
      store.applyText(text)
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
