import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Kamal Deploy — finds config/deploy.yml + config/deploy.<env>.yml files
// under your configured project folders and turns each one into a checklist
// row. Since most Kamal actions are the same shape for any destination,
// checking one or more rows (across one or many projects) reveals a shared
// action bar at the bottom — the actions from the user's own kamal_menu()
// shell function (provision / setup / deploy / accessories / logs / console
// / shell), plus a few more pulled from the Kamal CLI (rollback, details,
// lock, audit, restart) — and clicking one runs it against every checked
// target at once. Each action carries a `icon` glyph (Font Awesome
// codepoints from the Nerd Font's legacy PUA block, verified against the
// font's own cmap before use, not guessed blind).
//
// Every action runs via `omarchy-launch-or-focus-tui`, which opens (or
// refocuses) the system's default terminal running scripts/run.sh — real
// TTY, real colors, real stdin for `kamal app exec -i` and interactive
// SSH/passphrase prompts, without the user ever opening a terminal by hand.
// scripts/discover.sh does the filesystem scan and caches its JSON result so
// run.sh can resolve a clicked target back to a project path without a
// project path (which might contain spaces) ever crossing the launcher's
// word-splitting `eval`.
Panel {
  id: root
  moduleName: "eduard.kamal-deploy"
  ipcTarget: moduleName

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Style.cornerRadius mirrors the system's Hyprland window rounding, which
  // can be as low as 0-2px — too subtle to read as "rounded" on a button.
  // Floor it so every button in this panel stays visibly rounded regardless
  // of that system setting, while still growing with it if the user prefers
  // more rounding overall.
  readonly property int buttonRadius: Math.max(Style.cornerRadius, Style.space(8))
  // Shared between the wizard's tab strip and its content card so the
  // active tab's fill and the card's own fill are the exact same value —
  // that color match, not a border, is what sells the "attached tab"
  // illusion where the active tab's bottom edge visually merges into the
  // card below it.
  readonly property color wizardCardColor: Qt.rgba(0, 0, 0, 0.18)
  readonly property color wizardCardBorder: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/eduard.kamal-deploy"
  readonly property string discoverScript: pluginDir + "/scripts/discover.sh"
  readonly property string runScript: pluginDir + "/scripts/run.sh"
  readonly property string runBackgroundScript: pluginDir + "/scripts/run-background.sh"
  readonly property string checkUpdateScript: pluginDir + "/scripts/check-update.sh"

  readonly property var savedSettings: bar && bar.shell && bar.shell.shellConfig
    && bar.shell.shellConfig["eduard.kamal-deploy"] && typeof bar.shell.shellConfig["eduard.kamal-deploy"] === "object"
    ? bar.shell.shellConfig["eduard.kamal-deploy"] : ({})
  readonly property var searchPaths: Array.isArray(savedSettings.searchPaths) ? savedSettings.searchPaths : []

  readonly property string generateProvisionScript: pluginDir + "/scripts/generate-provision.sh"
  readonly property string generateDeployScript: pluginDir + "/scripts/generate-deploy.sh"
  readonly property string provisionCheckScript: pluginDir + "/scripts/provision-check.sh"
  readonly property string completePathScript: pluginDir + "/scripts/complete-path.sh"

  property var projects: []
  property bool scanning: false
  property string lastScanError: ""

  // ---------------------------------------------------------------- selection
  // Multi-select: every environment across every project is a checkbox, and
  // the same batch of Kamal actions at the bottom of the panel runs against
  // whichever ones are checked — one terminal per selected target per click,
  // since each target needs its own `kamal ... -d <env>` in its own project
  // directory.
  property var selectedTargetIds: ({})

  readonly property var targetIndex: {
    var idx = {}
    for (var i = 0; i < root.projects.length; i++) {
      var p = root.projects[i]
      var envs = p.environments || []
      for (var j = 0; j < envs.length; j++) idx[envs[j].targetId] = { project: p, env: envs[j] }
    }
    return idx
  }

  readonly property var selectedIds: {
    var out = []
    for (var k in root.selectedTargetIds) if (root.selectedTargetIds[k] && root.targetIndex[k]) out.push(k)
    return out
  }
  readonly property int selectedCount: root.selectedIds.length
  readonly property bool selectedHasProvision: root.selectedCount > 0 && root.selectedIds.every(function(id) {
    var e = root.targetIndex[id]
    return e && e.project && e.project.hasProvision
  })
  readonly property var selectedAccessories: {
    var set = {}
    root.selectedIds.forEach(function(id) {
      var e = root.targetIndex[id]
      if (e && e.project && Array.isArray(e.project.accessories)) e.project.accessories.forEach(function(a) { set[a] = true })
    })
    return Object.keys(set)
  }

  function toggleSelected(targetId) {
    var next = {}
    for (var k in root.selectedTargetIds) next[k] = root.selectedTargetIds[k]
    if (next[targetId]) delete next[targetId]
    else next[targetId] = true
    root.selectedTargetIds = next
  }

  function selectAllVisible() {
    var next = {}
    root.projects.forEach(function(p) { (p.environments || []).forEach(function(e) { next[e.targetId] = true }) })
    root.selectedTargetIds = next
  }

  function clearSelection() {
    root.selectedTargetIds = {}
  }

  function pruneSelection() {
    var idx = root.targetIndex
    var next = {}
    for (var k in root.selectedTargetIds) if (idx[k]) next[k] = true
    root.selectedTargetIds = next
  }

  function launchSelected(action, extra, background) {
    root.selectedIds.forEach(function(id) { root.launch(id, action, extra, background) })
  }

  // ---------------------------------------------------------- provision wizard
  property bool wizardOpen: false
  // "deploy" | "provision" — Deploy config and the provisioning script are
  // two independent artifacts this wizard can generate; each gets its own
  // tab so the fields for one never crowd out the other, with Deploy shown
  // first since a fresh project needs deploy.yml before provisioning even
  // makes sense.
  property string wizardActiveTab: "deploy"
  property string wizardTargetMode: "known"   // "known" | "custom"
  property string wizardKnownPath: ""
  property string wizardCustomPath: ""
  readonly property string wizardResolvedPath: (wizardTargetMode === "known" ? wizardKnownPath : wizardCustomPath).trim()
  readonly property bool wizardTargetValid: root.wizardResolvedPath !== "" && root.isUnderHome(root.wizardResolvedPath)
  property var wizardChecks: null
  property bool wizardChecking: false
  property bool wizardGenerating: false
  property string wizardResult: ""
  property bool wizardResultIsError: false

  // deploy.yml generation — a second, independent artifact this same
  // wizard can produce. An empty env targets the base config/deploy.yml
  // (only offered when one doesn't exist yet); a named env always targets
  // a minimal, servers-only config/deploy.<env>.yml override, which is
  // the normal Kamal pattern for adding a destination to an existing app.
  property string wizardDeployEnv: ""
  property bool wizardDeployGenerating: false
  property string wizardDeployResult: ""
  property bool wizardDeployResultIsError: false
  readonly property bool wizardDeployTargetIsBase: root.wizardDeployEnv.trim() === ""
  readonly property bool wizardDeployBlocked: root.wizardDeployTargetIsBase && !!(root.wizardChecks && root.wizardChecks.baseDeployExists)
  readonly property bool wizardDeployFileExists: root.wizardDeployTargetIsBase
    ? !!(root.wizardChecks && root.wizardChecks.baseDeployExists)
    : !!(root.wizardChecks && root.wizardChecks.envDeployExists)
  // A named environment with no base config yet gets one generated
  // alongside it (see generate-deploy.sh) — an override with nothing to
  // override isn't useful on its own. service/image only matter for that
  // base render, so they stay visible whenever one is about to happen,
  // whether this generation targets the base directly or triggers it as
  // a side effect of a named-environment override.
  readonly property bool wizardBaseWillBeCreated: !root.wizardDeployTargetIsBase
    && !(root.wizardChecks && root.wizardChecks.baseDeployExists)
  readonly property string wizardSuggestedService: {
    if (root.wizardResolvedPath === "") return ""
    var parts = root.wizardResolvedPath.split("/").filter(function(s) { return s !== "" })
    return parts.length > 0 ? parts[parts.length - 1] : ""
  }

  onWizardResolvedPathChanged: if (root.wizardOpen) wizardCheckDebounce.restart()
  onWizardDeployEnvChanged: if (root.wizardOpen) wizardCheckDebounce.restart()

  function openWizard() {
    root.wizardActiveTab = "deploy"
    root.wizardResult = ""
    root.wizardResultIsError = false
    root.wizardDeployResult = ""
    root.wizardDeployResultIsError = false
    root.wizardDeployEnv = ""
    root.wizardChecks = null
    root.wizardCustomPath = ""
    if (root.projects.length > 0) {
      root.wizardTargetMode = "known"
      root.wizardKnownPath = root.projects[0].path
    } else {
      root.wizardTargetMode = "custom"
      root.wizardKnownPath = ""
    }
    root.wizardOpen = true
    Qt.callLater(root.runWizardChecks)
  }

  function closeWizard() {
    root.wizardOpen = false
  }

  function runWizardChecks() {
    if (!root.wizardTargetValid) { root.wizardChecks = null; return }
    if (checkProcess.running) return
    root.wizardChecking = true
    checkProcess.command = ["bash", root.provisionCheckScript, root.wizardResolvedPath, root.wizardDeployEnv.trim()]
    checkProcess.running = true
  }

  function parseWizardChecks(raw) {
    try {
      root.wizardChecks = JSON.parse(String(raw || "{}"))
    } catch (e) {
      root.wizardChecks = null
    }
  }

  function generateProvision(options) {
    if (!root.wizardTargetValid || generateProcess.running) return
    root.wizardGenerating = true
    root.wizardResult = ""
    generateProcess.command = ["bash", root.generateProvisionScript, root.wizardResolvedPath, JSON.stringify(options)]
    generateProcess.running = true
  }

  function generateDeploy(options) {
    if (!root.wizardTargetValid || root.wizardDeployBlocked || generateDeployProcess.running) return
    root.wizardDeployGenerating = true
    root.wizardDeployResult = ""
    generateDeployProcess.command = ["bash", root.generateDeployScript, root.wizardResolvedPath, root.wizardDeployEnv.trim(), JSON.stringify(options)]
    generateDeployProcess.running = true
  }

  function saveSearchPaths(paths) {
    if (!bar || !bar.shell || typeof bar.shell.mutateShellConfig !== "function") return
    bar.shell.mutateShellConfig(function(config) {
      if (!config["eduard.kamal-deploy"] || typeof config["eduard.kamal-deploy"] !== "object") config["eduard.kamal-deploy"] = {}
      config["eduard.kamal-deploy"].searchPaths = paths
    })
  }

  // Safety baseline: every folder this plugin touches — search folders here,
  // the Provision Wizard's custom path in wizardTargetValid below — must
  // resolve inside $HOME. Lexically resolves "." / ".." segments (so
  // "~/../../etc" can't pass as home-scoped just because it starts with the
  // right prefix) the same way `realpath -m` does in the bash scripts,
  // which re-check this independently since it's the real safety boundary —
  // this is just for fast, friendly feedback before ever shelling out.
  function resolvePath(p) {
    var value = String(p || "").trim()
    if (value === "") return ""
    if (value === "~") value = root.home
    else if (value.indexOf("~/") === 0) value = root.home + value.slice(1)
    if (value.charAt(0) !== "/") value = root.home + "/" + value
    var parts = value.split("/")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var seg = parts[i]
      if (seg === "" || seg === ".") continue
      if (seg === "..") { if (out.length > 0) out.pop(); continue }
      out.push(seg)
    }
    return "/" + out.join("/")
  }

  function isUnderHome(p) {
    var resolved = root.resolvePath(p)
    return resolved !== "" && (resolved === root.home || resolved.indexOf(root.home + "/") === 0)
  }

  function addSearchPath(p) {
    var trimmed = String(p || "").trim()
    if (trimmed === "" || root.searchPaths.indexOf(trimmed) !== -1) return
    if (!root.isUnderHome(trimmed)) {
      root.lastScanError = "Search folders must be inside your home folder (" + root.home + ")."
      return
    }
    root.lastScanError = ""
    root.saveSearchPaths(root.searchPaths.concat([trimmed]))
    Qt.callLater(root.rescan)
  }

  function removeSearchPath(p) {
    root.saveSearchPaths(root.searchPaths.filter(function(x) { return x !== p }))
    Qt.callLater(root.rescan)
  }

  function detectCommon() {
    if (detectProcess.running) return
    detectProcess.command = ["bash", root.pluginDir + "/scripts/detect-common.sh"]
    detectProcess.running = true
  }

  function rescan() {
    if (scanProcess.running) return
    if (root.searchPaths.length === 0) { root.projects = []; return }
    root.scanning = true
    root.lastScanError = ""
    scanProcess.command = ["bash", root.discoverScript].concat(root.searchPaths)
    scanProcess.running = true
  }

  function parseProjects(raw) {
    try {
      var parsed = JSON.parse(String(raw || "[]"))
      root.projects = Array.isArray(parsed) ? parsed : []
      root.pruneSelection()
    } catch (e) {
      root.lastScanError = "Could not parse scan results."
    }
  }

  function launch(targetId, action, extra, background) {
    if (background) {
      root.runBackgroundJob(targetId, action, extra)
      return
    }
    var appId = "org.omarchy.kamal-deploy." + targetId + "." + action + (extra ? ("." + extra) : "")
    var args = ["omarchy-launch-or-focus-tui", "--app-id=" + appId, "bash", root.runScript, targetId, action]
    if (extra) args.push(extra)
    Quickshell.execDetached(args)
  }

  // ------------------------------------------------------ background jobs
  // Actions that always run to completion on their own (no interactive
  // input, no forever-streaming output — see run-background.sh's own
  // refuse-list for the exact boundary) run here instead of opening a
  // terminal: a spinner while the Process is alive, then its captured
  // output rendered in a console-styled card. Newest job first; each is
  // independently dismissible — dismissing a still-running job kills it
  // (see dismissBackgroundJob).
  property var backgroundJobs: []
  property int backgroundJobSeq: 0
  // jobId -> live Process, so a dismiss can find and terminate one that's
  // still running. Not used in any binding, so plain mutation is fine.
  property var backgroundProcs: ({})

  readonly property var actionLabels: ({
    provision: "Provision", setup: "Setup", deploy: "Deploy", rollback: "Rollback",
    logs: "Tail logs", console: "Rails console", shell: "Bash shell", restart: "Restart",
    details: "Details", audit: "Audit log", lock_status: "Lock status", lock_release: "Release lock",
    accessory_boot: "Boot", accessory_reboot: "Reboot", accessory_stop: "Stop",
    accessory_restart: "Restart", accessory_logs: "Logs", accessory_remove: "Remove"
  })

  function stripAnsi(s) {
    return String(s || "").replace(/\x1b\[[0-9;]*[A-Za-z]/g, "")
  }

  // Job output can be arbitrary bytes from a remote deploy target — never
  // build a shell command by concatenating it in unquoted. Util.shellQuote
  // single-quotes it for bash, same pattern the network panel's own
  // copy-to-clipboard uses.
  function copyBackgroundJobOutput(text) {
    if (!text || text.trim() === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function startBackgroundJob(labelText, args) {
    var jobId = "job" + (root.backgroundJobSeq++)
    var job = { id: jobId, label: labelText, status: "running", output: "", exitCode: null }
    root.backgroundJobs = [job].concat(root.backgroundJobs)
    var proc = backgroundJobComponent.createObject(root, { jobId: jobId, jobLabel: labelText, command: args })
    root.backgroundProcs[jobId] = proc
    proc.running = true
  }

  function runBackgroundJob(targetId, action, extra) {
    var entry = root.targetIndex[targetId]
    if (!entry) return
    var label = (entry.project.name || "project") + " / " + (entry.env.label || "default") + " — "
      + (root.actionLabels[action] || action) + (extra ? (" (" + extra + ")") : "")
    var args = [root.runBackgroundScript, targetId, action]
    if (extra) args.push(extra)
    root.startBackgroundJob(label, ["bash"].concat(args))
  }

  // Deliberately NOT a self-update: an earlier version of this button ran
  // `git fetch` + `git merge --ff-only` against mutable origin/main,
  // which pulls in whatever is on the branch right now regardless of
  // whether the marketplace's own exact-SHA verification has reviewed
  // it — silently replacing the reviewed, listed snapshot with unreviewed
  // code. This just tells the user a newer version exists and how to get
  // it themselves, using the same result-card UI as any other action but
  // with no process ever spawned.
  function showUpdateInstructions() {
    if (!root.updateInfo || !root.updateInfo.updateAvailable) return
    var msg = "A newer version is available: v" + root.updateInfo.latestVersion
      + " (installed: v" + root.updateInfo.currentVersion + ").\n\n"
      + "This plugin doesn't update itself automatically, so you can review "
      + "what changed first. To update:\n\n"
      + "cd " + root.pluginDir + "\n"
      + "git log HEAD..origin/main --oneline   # see what's new\n"
      + "git pull\n"
      + "omarchy restart shell\n"
    var jobId = "job" + (root.backgroundJobSeq++)
    var job = { id: jobId, label: "Kamal Deploy — update available", status: "done", output: msg, exitCode: 0 }
    root.backgroundJobs = [job].concat(root.backgroundJobs)
  }

  function updateBackgroundJob(jobId, patch) {
    root.backgroundJobs = root.backgroundJobs.map(function(j) {
      if (j.id !== jobId) return j
      var next = {}
      for (var k in j) next[k] = j[k]
      for (var k2 in patch) next[k2] = patch[k2]
      return next
    })
  }

  function dismissBackgroundJob(jobId) {
    var proc = root.backgroundProcs[jobId]
    // SIGTERM; onExited still fires (job is already gone from the list by
    // then, so updateBackgroundJob is a harmless no-op) and destroys it.
    if (proc && proc.running) proc.running = false
    root.backgroundJobs = root.backgroundJobs.filter(function(j) { return j.id !== jobId })
  }

  function clearFinishedBackgroundJobs() {
    root.backgroundJobs = root.backgroundJobs.filter(function(j) { return j.status === "running" })
  }

  // A background job runs with no terminal and no panel requirement — the
  // panel might well be closed by the time it finishes. Fire a desktop
  // notification so the user knows to reopen it and check the result card,
  // rather than relying on a spinner that's no longer on screen. notify-send
  // takes plain positional args (no shell involved), so job.label — built
  // from project/env/action names that ultimately come from a deploy.yml
  // the user placed under their own search folders — needs no extra
  // escaping here, same as every other execDetached call in this file.
  function notifyBackgroundJobResult(job) {
    var ok = job.status === "done"
    var args = [
      "notify-send", "--app-name=Kamal Deploy",
      "--icon=" + (ok ? "dialog-information" : "dialog-error")
    ]
    if (!ok) args.push("--urgency=critical")
    args.push(ok ? "Kamal Deploy — done" : "Kamal Deploy — failed")
    args.push(job.label + (ok ? "" : (" (exit " + job.exitCode + ")")) + " — check the panel for output.")
    Quickshell.execDetached(args)
  }

  Component {
    id: backgroundJobComponent
    Process {
      id: bgProc
      property string jobId: ""
      property string jobLabel: ""
      property string capturedOut: ""
      property string capturedErr: ""
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: bgProc.capturedOut = text }
      stderr: StdioCollector { waitForEnd: true; onStreamFinished: bgProc.capturedErr = text }
      onExited: function(exitCode) {
        var combined = bgProc.capturedOut
        if (bgProc.capturedErr.trim() !== "") {
          combined += (combined !== "" && combined.slice(-1) !== "\n" ? "\n" : "") + bgProc.capturedErr
        }
        var status = exitCode === 0 ? "done" : "failed"
        root.updateBackgroundJob(bgProc.jobId, {
          status: status,
          output: root.stripAnsi(combined).trim(),
          exitCode: exitCode
        })
        root.notifyBackgroundJobResult({ label: bgProc.jobLabel, status: status, exitCode: exitCode })
        delete root.backgroundProcs[bgProc.jobId]
        bgProc.destroy()
      }
    }
  }

  // ------------------------------------------------------- update checking
  // Checked once per panel-open (see onOpenedChanged below), against this
  // plugin's own GitHub repo — see scripts/check-update.sh for exactly
  // how (always silent on failure, offline included; never surfaces as an
  // error here, the button just doesn't appear).
  property var updateInfo: null
  property bool updateCheckDone: false

  function checkForUpdate() {
    if (updateCheckProcess.running) return
    updateCheckProcess.command = ["bash", root.checkUpdateScript]
    updateCheckProcess.running = true
  }

  Process {
    id: updateCheckProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.updateCheckDone = true
        try {
          root.updateInfo = JSON.parse(text)
        } catch (e) {
          root.updateInfo = null
        }
      }
    }
  }

  // Fixed, theme-independent brand colors — like GitHub's per-language dots,
  // these stay recognizable regardless of the active Omarchy theme. Icons
  // are Seti-UI glyphs from the Nerd Font (v3 codepoints, confirmed against
  // the installed JetBrainsMono Nerd Font's own charset coverage — not
  // guessed — so none of these render as tofu).
  readonly property var languageBadges: ({
    ruby: { icon: "", color: "#CC342D" },
    go: { icon: "", color: "#00ADD8" },
    typescript: { icon: "", color: "#3178C6" },
    node: { icon: "", color: "#68A063" }
  })

  function languageBadge(lang) {
    return root.languageBadges[lang] || { icon: "", color: root.dim }
  }

  onOpenedChanged: if (opened) {
    if (root.searchPaths.length > 0 && root.projects.length === 0) root.rescan()
    if (!root.updateCheckDone) root.checkForUpdate()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: scanProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseProjects(text)
    }
    onExited: function(exitCode) {
      root.scanning = false
      if (exitCode !== 0 && root.lastScanError === "") root.lastScanError = "Scan exited with status " + exitCode + "."
    }
  }

  Process {
    id: detectProcess
    stdout: SplitParser {
      onRead: function(line) {
        var trimmed = String(line || "").trim()
        if (trimmed !== "") root.addSearchPath(trimmed)
      }
    }
  }

  Timer {
    id: wizardCheckDebounce
    interval: 350
    onTriggered: root.runWizardChecks()
  }

  Process {
    id: checkProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseWizardChecks(text)
    }
    onExited: function(exitCode) { root.wizardChecking = false }
  }

  Process {
    id: generateProcess
    property string capturedOut: ""
    property string capturedErr: ""
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: generateProcess.capturedOut = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: generateProcess.capturedErr = text }
    onExited: function(exitCode) {
      root.wizardGenerating = false
      if (exitCode === 0) {
        root.wizardResultIsError = false
        root.wizardResult = "Created " + generateProcess.capturedOut.trim()
        root.rescan()
        root.runWizardChecks()
      } else {
        root.wizardResultIsError = true
        root.wizardResult = generateProcess.capturedErr.trim() || ("Failed (exit " + exitCode + ")")
      }
    }
  }

  Process {
    id: generateDeployProcess
    property string capturedOut: ""
    property string capturedErr: ""
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: generateDeployProcess.capturedOut = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: generateDeployProcess.capturedErr = text }
    onExited: function(exitCode) {
      root.wizardDeployGenerating = false
      if (exitCode === 0) {
        root.wizardDeployResultIsError = false
        var createdFiles = generateDeployProcess.capturedOut.trim().split("\n").filter(function(s) { return s !== "" })
        root.wizardDeployResult = "Created " + createdFiles.join(" and ")
        root.rescan()
        root.runWizardChecks()
      } else {
        root.wizardDeployResultIsError = true
        root.wizardDeployResult = generateDeployProcess.capturedErr.trim() || ("Failed (exit " + exitCode + ")")
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.iconSlot
    tooltipText: "Kamal Deploy"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(14)

          Column {
          id: mainView
          width: parent.width
          spacing: Style.space(14)
          visible: !root.wizardOpen

          PanelHero {
            width: parent.width
            title: "Kamal Deploy"
            meta: root.scanning
              ? "SCANNING…"
              : (root.projects.length === 0 ? "NO PROJECTS YET" : (root.projects.length + " PROJECT" + (root.projects.length === 1 ? "" : "S")))
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(6)

                PanelActionButton {
                  radius: root.buttonRadius
                  visible: !!(root.updateInfo && root.updateInfo.updateAvailable)
                  iconText: ""
                  fontSize: Style.font.iconLarge
                  tooltipText: root.updateInfo && root.updateInfo.updateAvailable
                    ? ("Update available: v" + root.updateInfo.latestVersion + " (installed v" + root.updateInfo.currentVersion + ") — click for update instructions")
                    : ""
                  foreground: root.foreground
                  hoverColor: Color.accent
                  focusable: true
                  onClicked: root.showUpdateInstructions()
                }

                PanelActionButton {
                  radius: root.buttonRadius
                  iconText: "↻"
                  fontSize: Style.font.iconLarge
                  tooltipText: "Rescan"
                  foreground: root.foreground
                  focusable: true
                  onClicked: root.rescan()
                }
              }
            }
          }

          Button {
            radius: root.buttonRadius
            width: parent.width
            leftAlign: true
            iconText: "+"
            text: "Provision Wizard — set up a new server"
            fontSize: Style.font.bodySmall
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            focusable: true
            onClicked: root.openWizard()
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "SEARCH FOLDERS"; foreground: root.foreground; fontFamily: root.fontFamily }

            Repeater {
              model: root.searchPaths
              Row {
                property string entry: modelData
                width: column.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - removeBtn.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: entry
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideMiddle
                  textFormat: Text.PlainText
                }

                PanelActionButton {
                  radius: root.buttonRadius
                  id: removeBtn
                  iconText: "✕"
                  tooltipText: "Remove"
                  foreground: root.foreground
                  hoverColor: root.urgent
                  focusable: true
                  onClicked: root.removeSearchPath(entry)
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              PathField {
                id: pathField
                width: parent.width
                placeholderText: "~/Code"
                foreground: root.foreground
                onAccepted: { root.addSearchPath(text); text = "" }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  radius: root.buttonRadius
                  id: addBtn
                  text: "Add"
                  fontSize: Style.font.bodySmall
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  focusable: true
                  onClicked: { root.addSearchPath(pathField.text); pathField.text = "" }
                }

                Button {
                  radius: root.buttonRadius
                  id: detectBtn
                  text: "Detect"
                  tooltipText: "Look for common project folders (Code, Projects, dev, …)"
                  fontSize: Style.font.bodySmall
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  focusable: true
                  onClicked: root.detectCommon()
                }
              }
            }

            Text {
              visible: root.lastScanError !== ""
              width: parent.width
              text: root.lastScanError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.foreground }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.projects.length > 0

            Button {
              radius: root.buttonRadius
              text: "Select all"
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              focusable: true
              onClicked: root.selectAllVisible()
            }

            Button {
              radius: root.buttonRadius
              text: "Clear"
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              focusable: true
              enabled: root.selectedCount > 0
              onClicked: root.clearSelection()
            }

            Text {
              text: root.selectedCount + " selected"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(16)
            visible: root.projects.length > 0

            Repeater {
              model: root.projects
              ProjectBlock { width: column.width; project: modelData }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(14)
            visible: root.selectedCount > 0

            PanelSeparator { foreground: root.foreground }

            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader { text: "SELECTED (" + root.selectedCount + ")"; foreground: root.foreground; fontFamily: root.fontFamily }

              Flow {
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: root.selectedIds
                  Button {
                    radius: root.buttonRadius
                    property string tid: modelData
                    readonly property var entry: root.targetIndex[tid]
                    text: (entry ? (entry.project.name + " / " + (entry.env.label || "default")) : tid) + "  ✕"
                    fontSize: Style.font.caption
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    bordered: true
                    focusable: true
                    onClicked: root.toggleSelected(tid)
                  }
                }
              }
            }

            ActionGroup {
              width: parent.width
              heading: "DEPLOY"
              actions: [
                { label: "Provision", action: "provision", icon: "", background: true, enabled: root.selectedHasProvision,
                  disabledReason: "Not every selected target has a provision script — run the Provision Wizard for the ones that don't." },
                { label: "Setup", action: "setup", icon: "", background: true },
                { label: "Deploy", action: "deploy", icon: "", background: true },
                { label: "Rollback", action: "rollback", icon: "" }
              ]
            }

            ActionGroup {
              width: parent.width
              heading: "APPLICATION"
              actions: [
                { label: "Tail logs", action: "logs", icon: "" },
                { label: "Rails console", action: "console", icon: "" },
                { label: "Bash shell", action: "shell", icon: "" },
                { label: "Restart", action: "restart", icon: "", background: true },
                { label: "Details", action: "details", icon: "", background: true }
              ]
            }

            ActionGroup {
              width: parent.width
              heading: "OPERATIONS"
              actions: [
                { label: "Lock status", action: "lock_status", icon: "", background: true },
                { label: "Release lock", action: "lock_release", icon: "", background: true },
                { label: "Audit log", action: "audit", icon: "", background: true }
              ]
            }

            Column {
              id: bulkAccessoryGroup
              width: parent.width
              spacing: Style.space(8)

              readonly property string accessoryValue: bulkAccessoryField.text.trim()
              // A real Kamal accessory name is a plain YAML key (letters,
              // digits, - and _) — enforced as a strict allowlist, not just
              // "no spaces", because this value ends up in a terminal
              // window's --app-id for the Logs action, which
              // omarchy-launch-or-focus-tui/-focus reassembles unquoted and
              // runs through `eval`. A crafted accessory name (e.g. copied
              // from a malicious deploy.yml's "Known:" hint) containing
              // shell metacharacters would otherwise be able to run
              // arbitrary commands the moment Logs is clicked.
              readonly property bool accessoryValid: /^[A-Za-z0-9_-]+$/.test(accessoryValue)

              PanelSectionHeader { text: "ACCESSORIES"; foreground: root.foreground; fontFamily: root.fontFamily }

              Text {
                visible: root.selectedAccessories.length > 0
                width: parent.width
                text: "Known: " + root.selectedAccessories.join(", ")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              TextField {
                id: bulkAccessoryField
                width: parent.width
                placeholderText: root.selectedAccessories.length > 0 ? root.selectedAccessories[0] : "accessory name"
                foreground: root.foreground
              }

              Text {
                visible: bulkAccessoryField.text.trim() !== "" && !bulkAccessoryGroup.accessoryValid
                width: parent.width
                text: "Accessory name must be letters, numbers, - or _ only."
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Flow {
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: [
                    { label: "Boot", action: "accessory_boot", icon: "", background: true },
                    { label: "Reboot", action: "accessory_reboot", icon: "", background: true },
                    { label: "Stop", action: "accessory_stop", icon: "", background: true },
                    { label: "Restart", action: "accessory_restart", icon: "", background: true },
                    { label: "Logs", action: "accessory_logs", icon: "" },
                    { label: "Remove", action: "accessory_remove", icon: "", background: true }
                  ]

                  Button {
                    radius: root.buttonRadius
                    required property var modelData
                    text: modelData.label
                    iconText: modelData.icon
                    fontSize: Style.font.bodySmall
                    foreground: modelData.action === "accessory_remove" ? root.urgent : root.foreground
                    fontFamily: root.fontFamily
                    bordered: true
                    focusable: true
                    enabled: bulkAccessoryGroup.accessoryValid
                    onClicked: root.launchSelected(modelData.action, bulkAccessoryGroup.accessoryValue, modelData.background === true)
                  }
                }
              }
            }
          }

          Text {
            visible: root.projects.length === 0 && root.searchPaths.length === 0
            width: parent.width
            text: "Add a search folder above and Kamal Deploy will find every config/deploy.yml and config/deploy.<env>.yml under it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(16)
            bottomPadding: Style.space(16)
          }

          Text {
            visible: root.projects.length === 0 && root.searchPaths.length > 0 && !root.scanning && root.lastScanError === ""
            width: parent.width
            text: "No Kamal deploy configs found under your search folders."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(16)
            bottomPadding: Style.space(16)
          }
          } // mainView

          Column {
            id: backgroundResults
            width: column.width
            spacing: Style.space(10)
            visible: root.backgroundJobs.length > 0

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              height: Math.max(resultsHeader.implicitHeight, clearFinishedButton.implicitHeight)

              PanelSectionHeader {
                id: resultsHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "RESULTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Button {
                radius: root.buttonRadius
                id: clearFinishedButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.backgroundJobs.some(function(j) { return j.status !== "running" })
                text: "Clear finished"
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                focusable: true
                onClicked: root.clearFinishedBackgroundJobs()
              }
            }

            Repeater {
              model: root.backgroundJobs
              delegate: BackgroundJobCard {
                width: backgroundResults.width
                required property var modelData
                job: modelData
              }
            }
          }

          Loader {
            id: wizardLoader
            width: column.width
            active: root.wizardOpen
            visible: root.wizardOpen
            sourceComponent: Component {
              Column {
                width: wizardLoader.width
                spacing: Style.space(14)

                PanelHero {
                  width: parent.width
                  title: "Provision Wizard"
                  meta: "SET UP A NEW SERVER"
                  foreground: root.foreground
                  fontFamily: root.fontFamily

                  iconComponent: Component {
                    Text {
                      text: "+"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.display
                      font.bold: true
                    }
                  }

                  trailingControl: Component {
                    PanelActionButton {
                      radius: root.buttonRadius
                      iconText: "✕"
                      tooltipText: "Close wizard"
                      foreground: root.foreground
                      focusable: true
                      onClicked: root.closeWizard()
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: "Sets up a new server: the Deploy tab generates config/deploy.yml, the Provision tab generates a tailored `provision` script — the Provision action on any project only runs if that file is there."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                PanelSeparator { foreground: root.foreground }

                // ---------- Target folder ----------
                Column {
                  width: parent.width
                  spacing: Style.space(8)

                  PanelSectionHeader { text: "TARGET FOLDER"; foreground: root.foreground; fontFamily: root.fontFamily }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Button {
                      radius: root.buttonRadius
                      text: "Existing project"
                      fontSize: Style.font.bodySmall
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      bordered: true
                      focusable: true
                      enabled: root.projects.length > 0
                      active: root.wizardTargetMode === "known"
                      onClicked: root.wizardTargetMode = "known"
                    }

                    Button {
                      radius: root.buttonRadius
                      text: "Custom path"
                      fontSize: Style.font.bodySmall
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      bordered: true
                      focusable: true
                      active: root.wizardTargetMode === "custom"
                      onClicked: root.wizardTargetMode = "custom"
                    }
                  }

                  Flow {
                    width: parent.width
                    spacing: Style.space(6)
                    visible: root.wizardTargetMode === "known"

                    Repeater {
                      model: root.projects
                      Button {
                        radius: root.buttonRadius
                        required property var modelData
                        text: modelData.name
                        fontSize: Style.font.bodySmall
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        bordered: true
                        focusable: true
                        active: root.wizardKnownPath === modelData.path
                        onClicked: root.wizardKnownPath = modelData.path
                      }
                    }
                  }

                  PathField {
                    width: parent.width
                    visible: root.wizardTargetMode === "custom"
                    placeholderText: "~/Code/new-app"
                    foreground: root.foreground
                    text: root.wizardCustomPath
                    onTextChanged: root.wizardCustomPath = text
                  }

                  Text {
                    visible: root.wizardResolvedPath !== ""
                    width: parent.width
                    text: root.wizardResolvedPath
                    color: root.wizardTargetValid ? root.dim : root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }

                  Text {
                    visible: root.wizardResolvedPath !== "" && !root.wizardTargetValid
                    width: parent.width
                    text: "Must be inside your home folder (" + root.home + ")."
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                // ---------- Checks ----------
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.wizardTargetValid

                  PanelSectionHeader { text: "CHECKS"; foreground: root.foreground; fontFamily: root.fontFamily }

                  Text {
                    visible: root.wizardChecking
                    text: "Checking…"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(4)
                    visible: !root.wizardChecking && root.wizardChecks !== null && root.wizardChecks.folderExists !== false

                    CheckRow { ok: true; label: "Folder exists" }
                    CheckRow { ok: !!(root.wizardChecks && root.wizardChecks.configFound); label: "config/deploy.yml (or deploy.<env>.yml) found" }
                    CheckRow { ok: !!(root.wizardChecks && root.wizardChecks.hasKamalGem); label: "Gemfile has the kamal gem" }
                    CheckRow { ok: !!(root.wizardChecks && root.wizardChecks.hasNetSshGem); label: "Gemfile has the net-ssh gem" }
                    CheckRow { ok: !!(root.wizardChecks && root.wizardChecks.sshIdentityCount > 0); label: "SSH agent has a loaded key (ssh-add -l)" }
                  }

                  Text {
                    visible: !root.wizardChecking && root.wizardChecks !== null && root.wizardChecks.folderExists === false
                    width: parent.width
                    text: "Folder doesn't exist yet — it will be created when you generate the script."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    visible: !!(root.wizardChecks && root.wizardChecks.provisionExists)
                    width: parent.width
                    text: "A provision file already exists here — generating will overwrite it."
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                }

                PanelSeparator { visible: root.wizardTargetValid; foreground: root.foreground }

                // ---------- Tabs ----------
                Column {
                  width: parent.width
                  spacing: 0
                  visible: root.wizardTargetValid

                  Row {
                    spacing: Style.space(4)

                    WizardTab {
                      label: "Deploy"
                      active: root.wizardActiveTab === "deploy"
                      onClicked: root.wizardActiveTab = "deploy"
                    }

                    WizardTab {
                      label: "Provision"
                      active: root.wizardActiveTab === "provision"
                      onClicked: root.wizardActiveTab = "provision"
                    }
                  }

                  // Same layered-inset technique as WizardTab, mirrored: the
                  // inner fill is flush with the outer's top edge (no top
                  // margin) so no border line ever shows there, whichever
                  // tab is active — only left/right/bottom get a visible
                  // rim, matching the tab that's sitting flush above it.
                  Item {
                    id: tabCard
                    width: parent.width
                    height: tabContent.implicitHeight + Style.space(24)

                    readonly property real bw: Math.max(1, Style.normalBorderWidth)

                    Rectangle {
                      anchors.fill: parent
                      color: root.wizardCardBorder
                      topLeftRadius: 0
                      topRightRadius: 0
                      bottomLeftRadius: root.buttonRadius
                      bottomRightRadius: root.buttonRadius
                    }

                    Rectangle {
                      anchors.fill: parent
                      anchors.topMargin: 0
                      anchors.leftMargin: tabCard.bw
                      anchors.rightMargin: tabCard.bw
                      anchors.bottomMargin: tabCard.bw
                      color: root.wizardCardColor
                      topLeftRadius: 0
                      topRightRadius: 0
                      bottomLeftRadius: Math.max(0, root.buttonRadius - tabCard.bw)
                      bottomRightRadius: Math.max(0, root.buttonRadius - tabCard.bw)
                    }

                    Column {
                      id: tabContent
                      anchors.fill: parent
                      anchors.margins: Style.space(12)
                      spacing: Style.space(14)

                // ---------- Deploy config ----------
                Column {
                  id: deployConfigGroup
                  width: parent.width
                  spacing: Style.space(10)
                  visible: root.wizardActiveTab === "deploy"

                  readonly property var webHosts: (deployWebHostsField.text || "").split(",")
                    .map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
                  readonly property var workersHosts: (deployWorkersHostsField.text || "").split(",")
                    .map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
                  readonly property bool hostsValid: deployConfigGroup.webHosts.length > 0
                    && deployConfigGroup.webHosts.every(function(h) { return !/\s/.test(h) })
                    && deployConfigGroup.workersHosts.every(function(h) { return !/\s/.test(h) })
                  // Becomes part of a filename (config/deploy.<env>.yml) —
                  // a plain identifier only, blank meaning "the base
                  // config". Not exploitable as written today (the fixed
                  // "deploy." prefix forces a nonexistent-directory hop
                  // before any ".." in here could take effect, confirmed
                  // empirically), but that's an accidental property of the
                  // current code, not something to rely on — a later
                  // change adding `mkdir -p "$(dirname "$out_file")")`
                  // for convenience would silently turn this back into a
                  // real path-traversal write outside the project folder.
                  readonly property bool envNameValid: root.wizardDeployEnv.trim() === ""
                    || /^[A-Za-z0-9_-]+$/.test(root.wizardDeployEnv.trim())

                  PanelSectionHeader { text: "DEPLOY CONFIG"; foreground: root.foreground; fontFamily: root.fontFamily }

                  Text {
                    width: parent.width
                    text: "Generates config/deploy.yml (a brand-new project) or config/deploy.<env>.yml (an override for an existing one) — servers plus, for a new base config, the full proxy/registry/env/builder skeleton. A named environment with no base yet gets both, in one click."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(2)
                    Text { text: "ENVIRONMENT (blank = base config/deploy.yml)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    TextField {
                      id: deployEnvField
                      width: parent.width
                      placeholderText: "production, staging, …"
                      foreground: root.foreground
                      onTextChanged: root.wizardDeployEnv = text
                    }
                    Text {
                      visible: !deployConfigGroup.envNameValid
                      width: parent.width
                      text: "Environment must be letters, numbers, - or _ only."
                      color: root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    width: parent.width
                    text: (root.wizardBaseWillBeCreated ? "→ config/deploy.yml + " : "→ ")
                      + "config/deploy" + (root.wizardDeployTargetIsBase ? "" : ("." + root.wizardDeployEnv.trim())) + ".yml"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    visible: root.wizardDeployBlocked
                    width: parent.width
                    text: "config/deploy.yml already exists — edit it directly, or type an environment name above (e.g. staging) to add an override instead."
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    visible: root.wizardBaseWillBeCreated
                    width: parent.width
                    text: "config/deploy.yml doesn't exist yet — it'll be generated too, using Service/Image below plus these servers."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    visible: !root.wizardDeployBlocked && root.wizardDeployFileExists
                    width: parent.width
                    text: "This file already exists — generating will overwrite it."
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(10)
                    visible: !root.wizardDeployBlocked

                    Row {
                      width: parent.width
                      spacing: Style.space(8)
                      visible: root.wizardDeployTargetIsBase || root.wizardBaseWillBeCreated

                      Column {
                        width: (parent.width - parent.spacing) / 2
                        spacing: Style.space(2)
                        Text { text: "SERVICE"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        TextField { id: deployServiceField; width: parent.width; text: root.wizardSuggestedService; placeholderText: "my-app"; foreground: root.foreground }
                      }

                      Column {
                        width: (parent.width - parent.spacing) / 2
                        spacing: Style.space(2)
                        Text { text: "IMAGE"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        TextField { id: deployImageField; width: parent.width; text: root.wizardSuggestedService; placeholderText: "my-user/my-app"; foreground: root.foreground }
                      }
                    }

                    Row {
                      width: parent.width
                      spacing: Style.space(8)

                      Column {
                        width: (parent.width - 2 * parent.spacing) / 3
                        spacing: Style.space(2)
                        Text { text: "ROLE"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        TextField { id: deployWebRoleField; width: parent.width; text: "web"; foreground: root.foreground }
                      }

                      Column {
                        width: (parent.width - 2 * parent.spacing) / 3
                        spacing: Style.space(2)
                        Text { text: "HOSTS"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        TextField { id: deployWebHostsField; width: parent.width; placeholderText: "10.0.1.10, 10.0.1.11"; foreground: root.foreground }
                      }

                      Column {
                        width: (parent.width - 2 * parent.spacing) / 3
                        spacing: Style.space(2)
                        Text { text: "CMD (optional)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        TextField { id: deployWebCmdField; width: parent.width; placeholderText: "bin/rails s -p 3000"; foreground: root.foreground }
                      }
                    }

                    Row {
                      width: parent.width
                      spacing: Style.space(8)

                      Column {
                        width: (parent.width - 2 * parent.spacing) / 3
                        spacing: Style.space(2)
                        Text { text: "ROLE (optional)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        TextField { id: deployWorkersRoleField; width: parent.width; text: "workers"; foreground: root.foreground }
                      }

                      Column {
                        width: (parent.width - 2 * parent.spacing) / 3
                        spacing: Style.space(2)
                        Text { text: "HOSTS (optional)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        TextField { id: deployWorkersHostsField; width: parent.width; placeholderText: "10.0.2.10"; foreground: root.foreground }
                      }

                      Column {
                        width: (parent.width - 2 * parent.spacing) / 3
                        spacing: Style.space(2)
                        Text { text: "CMD (optional)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        TextField { id: deployWorkersCmdField; width: parent.width; placeholderText: "bin/jobs"; foreground: root.foreground }
                      }
                    }

                    Text {
                      visible: deployWebHostsField.text.trim() !== "" && !deployConfigGroup.hostsValid
                      width: parent.width
                      text: "Hosts can't contain spaces — separate multiple hosts with commas."
                      color: root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Button {
                      radius: root.buttonRadius
                      text: root.wizardDeployGenerating ? "Generating…" : (root.wizardBaseWillBeCreated ? "Generate deploy.yml + config" : "Generate deploy.yml")
                      fontSize: Style.font.bodySmall
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      bordered: true
                      focusable: true
                      enabled: deployConfigGroup.hostsValid && deployConfigGroup.envNameValid && !root.wizardDeployGenerating
                      onClicked: {
                        root.generateDeploy({
                          service: deployServiceField.text.trim() || root.wizardSuggestedService || "my-app",
                          image: deployImageField.text.trim() || deployServiceField.text.trim() || "my-app",
                          web_role: deployWebRoleField.text.trim() || "web",
                          web_hosts: deployConfigGroup.webHosts,
                          web_cmd: deployWebCmdField.text.trim(),
                          workers_role: deployWorkersRoleField.text.trim() || "workers",
                          workers_hosts: deployConfigGroup.workersHosts,
                          workers_cmd: deployWorkersCmdField.text.trim()
                        })
                      }
                    }

                    Text {
                      visible: root.wizardDeployResult !== ""
                      width: parent.width
                      text: root.wizardDeployResult
                      color: root.wizardDeployResultIsError ? root.urgent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                  }
                }

                // ---------- Tailor (Provision tab) ----------
                Column {
                  width: parent.width
                  spacing: Style.space(10)
                  visible: root.wizardActiveTab === "provision"

                  PanelSectionHeader { text: "TAILOR"; foreground: root.foreground; fontFamily: root.fontFamily }

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Column {
                      width: (parent.width - parent.spacing) / 2
                      spacing: Style.space(2)
                      Text { text: "SWAP SIZE"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      TextField { id: swapSizeField; width: parent.width; text: "2G"; foreground: root.foreground }
                    }

                    Column {
                      width: (parent.width - parent.spacing) / 2
                      spacing: Style.space(2)
                      Text { text: "STORAGE PATH"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      TextField { id: storagePathField; width: parent.width; text: "/storage"; foreground: root.foreground }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Column {
                      width: (parent.width - parent.spacing) / 2
                      spacing: Style.space(2)
                      Text { text: "STORAGE OWNER (uid:gid)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      TextField { id: storageOwnerField; width: parent.width; text: "1000:1000"; foreground: root.foreground }
                    }

                    Column {
                      width: (parent.width - parent.spacing) / 2
                      spacing: Style.space(2)
                      Text { text: "EXTRA FIREWALL PORTS"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      TextField { id: extraPortsField; width: parent.width; text: "80, 443"; placeholderText: "80, 443"; foreground: root.foreground }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Column {
                      width: (parent.width - 2 * parent.spacing) / 3
                      spacing: Style.space(2)
                      Text { text: "DOCKER LOG SIZE"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      TextField { id: dockerLogSizeField; width: parent.width; text: "50m"; foreground: root.foreground }
                    }

                    Column {
                      width: (parent.width - 2 * parent.spacing) / 3
                      spacing: Style.space(2)
                      Text { text: "LOG FILES KEPT"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      TextField { id: dockerLogFileField; width: parent.width; text: "3"; foreground: root.foreground }
                    }

                    Column {
                      width: (parent.width - 2 * parent.spacing) / 3
                      spacing: Style.space(2)
                      Text { text: "ULIMIT NOFILE"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      TextField { id: dockerUlimitField; width: parent.width; text: "65536"; foreground: root.foreground }
                    }
                  }

                  Toggle {
                    id: ufwToggle
                    width: parent.width
                    checked: true
                    label: "Enable UFW firewall"
                    description: "Defense-in-depth — your cloud provider's security group is the real firewall."
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: checked = !checked
                  }

                  Toggle {
                    id: fail2banToggle
                    width: parent.width
                    checked: true
                    label: "Install fail2ban"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: checked = !checked
                  }

                  Toggle {
                    id: unattendedToggle
                    width: parent.width
                    checked: true
                    label: "Unattended security upgrades"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: checked = !checked
                  }

                  Toggle {
                    id: sshHardenToggle
                    width: parent.width
                    checked: true
                    label: "Harden SSH"
                    description: "Disables password auth — key login only."
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: checked = !checked
                  }

                  PanelSeparator { foreground: root.foreground }

                  Button {
                    radius: root.buttonRadius
                    text: root.wizardGenerating ? "Generating…" : "Generate provision file"
                    fontSize: Style.font.bodySmall
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    bordered: true
                    focusable: true
                    enabled: root.wizardTargetValid && !root.wizardGenerating
                    onClicked: {
                      var ports = extraPortsField.text.split(",")
                        .map(function(s) { return s.trim() })
                        .filter(function(s) { return /^[0-9]+$/.test(s) })
                        .map(function(s) { return parseInt(s, 10) })
                      root.generateProvision({
                        swap_size: swapSizeField.text.trim() || "2G",
                        storage_path: storagePathField.text.trim() || "/storage",
                        storage_owner: storageOwnerField.text.trim() || "1000:1000",
                        docker_log_max_size: dockerLogSizeField.text.trim() || "50m",
                        docker_log_max_file: dockerLogFileField.text.trim() || "3",
                        docker_ulimit_nofile: dockerUlimitField.text.trim() || "65536",
                        enable_fail2ban: fail2banToggle.checked,
                        enable_unattended_upgrades: unattendedToggle.checked,
                        harden_ssh: sshHardenToggle.checked,
                        enable_ufw: ufwToggle.checked,
                        firewall_ports: ports
                      })
                    }
                  }

                  Text {
                    visible: root.wizardResult !== ""
                    width: parent.width
                    text: root.wizardResult
                    color: root.wizardResultIsError ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                }
                    } // tabContent
                  } // content card
                }

                PanelSeparator { foreground: root.foreground }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Button {
                    radius: root.buttonRadius
                    text: "Close"
                    fontSize: Style.font.bodySmall
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    bordered: true
                    focusable: true
                    onClicked: root.closeWizard()
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- blocks

  component ProjectBlock: Column {
    id: block
    property var project: ({})
    readonly property var badge: root.languageBadge(block.project.language)

    spacing: Style.space(8)

    Column {
      width: parent.width
      spacing: Style.space(1)

      Row {
        width: parent.width
        spacing: Style.space(6)

        Rectangle {
          id: langChip
          // badge.color may be a hex string or an existing color value
          // (root.dim, for the generic fallback) — routing it through a
          // `color`-typed property normalizes either into one we can tint.
          property color tint: block.badge.color
          width: Style.space(20)
          height: Style.space(20)
          radius: width / 2
          color: Qt.rgba(tint.r, tint.g, tint.b, 0.18)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: langIcon
            anchors.centerIn: parent
            text: block.badge.icon
            color: block.badge.color
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        PanelSectionHeader {
          anchors.verticalCenter: parent.verticalCenter
          text: String(block.project.name || "project").toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
          textFormat: Text.PlainText
        }
      }

      Text {
        width: parent.width
        text: String(block.project.path || "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
        textFormat: Text.PlainText
      }
    }

    Grid {
      id: envGrid
      width: parent.width
      // A single deploy.yml (one row) still reads best as its own full-width
      // line; only once there's more than one destination does splitting
      // into two columns actually save vertical space worth the tradeoff.
      columns: (block.project.environments || []).length > 1 ? 2 : 1
      columnSpacing: Style.space(12)
      rowSpacing: Style.space(4)

      readonly property real cellWidth: envGrid.columns > 1
        ? (envGrid.width - envGrid.columnSpacing * (envGrid.columns - 1)) / envGrid.columns
        : envGrid.width

      Repeater {
        model: block.project.environments || []
        TargetRow { width: envGrid.cellWidth; env: modelData }
      }
    }
  }

  // A checkbox row. All the actual Kamal actions live in the shared bottom
  // bar and run against every checked row at once — see selectedIds /
  // launchSelected() on root.
  component TargetRow: Item {
    id: row
    property var env: ({})

    readonly property string targetId: String(row.env.targetId || "")
    readonly property bool selected: !!root.selectedTargetIds[row.targetId]
    readonly property string envLabel: row.env.label || "default"

    implicitHeight: Math.max(checkbox.height, label.implicitHeight) + Style.space(6)

    BorderSurface {
      id: checkbox
      width: Style.space(18)
      height: Style.space(18)
      radius: width / 2
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      color: row.selected ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
      borderSpec: row.selected
        ? Border.controlSpec("selected", root.foreground, Color.accent)
        : Border.controlSpec("normal", root.foreground, Color.accent)

      Text {
        anchors.centerIn: parent
        visible: row.selected
        text: "✓"
        color: Style.selectedStateColor(root.foreground, Color.accent)
        font.family: root.fontFamily
        font.pixelSize: Math.round(checkbox.height * 0.85)
        font.bold: true
      }
    }

    Text {
      id: label
      anchors.left: checkbox.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: row.envLabel
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleSelected(row.targetId)
    }
  }

  // One row of action chips, run against every currently-selected target.
  component ActionGroup: Column {
    id: group
    property string heading: ""
    property var actions: []

    spacing: Style.space(6)

    PanelSectionHeader { text: group.heading; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }

    Flow {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: group.actions

        Button {
          radius: root.buttonRadius
          required property var modelData
          text: modelData.label
          iconText: modelData.icon || ""
          tooltipText: (modelData.enabled === false && modelData.disabledReason) ? modelData.disabledReason : ""
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          focusable: true
          enabled: modelData.enabled !== false
          onClicked: root.launchSelected(modelData.action, undefined, modelData.background === true)
        }
      }
    }
  }

  // One background-job result: a spinner while running, then a check/✕
  // status line and a scrollable console-styled box with whatever the
  // script printed (ANSI already stripped in updateBackgroundJob).
  component BackgroundJobCard: Column {
    id: card
    property var job: ({})
    property bool justCopied: false
    width: parent.width
    spacing: Style.space(6)

    readonly property color statusColor: job.status === "running" ? root.foreground
      : (job.status === "done" ? "#4CAF50" : root.urgent)

    Timer {
      id: copiedResetTimer
      interval: 1500
      onTriggered: card.justCopied = false
    }

    Rectangle {
      width: parent.width
      height: cardHeader.implicitHeight + Style.space(16)
      radius: Style.cornerRadius
      color: Qt.rgba(0, 0, 0, 0.18)
      border.width: 1
      border.color: Qt.rgba(card.statusColor.r, card.statusColor.g, card.statusColor.b, 0.5)

      Row {
        id: cardHeader
        anchors.left: parent.left
        anchors.right: copyButton.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(8)
        anchors.rightMargin: Style.space(4)
        spacing: Style.space(8)

        Text {
          // Same FontAwesome "refresh" glyph as the Boot/Reboot/Restart
          // action buttons above, kept spinning while the job runs.
          anchors.verticalCenter: parent.verticalCenter
          text: card.job.status === "running" ? "" : (card.job.status === "done" ? "✓" : "✕")
          color: card.statusColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          transformOrigin: Item.Center

          RotationAnimation on rotation {
            running: card.job.status === "running"
            loops: Animation.Infinite
            from: 0
            to: 360
            duration: 900
          }

          onRotationChanged: if (card.job.status !== "running" && rotation !== 0) rotation = 0
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(32)
          spacing: 0

          Text {
            width: parent.width
            text: card.job.label
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }

          Text {
            visible: card.job.status !== "running"
            text: card.job.status === "done" ? "done" : ("exit " + card.job.exitCode)
            color: card.statusColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelActionButton {
        radius: root.buttonRadius
        id: copyButton
        anchors.right: dismissButton.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(8)
        anchors.rightMargin: Style.space(4)
        // FontAwesome "copy" glyph, from the same legacy PUA block as the
        // rest of this file's verified icons.
        iconText: card.justCopied ? "✓" : ""
        tooltipText: card.justCopied ? "Copied" : "Copy output"
        foreground: root.foreground
        enabled: card.job.output.trim() !== ""
        focusable: true
        onClicked: {
          root.copyBackgroundJobOutput(card.job.output)
          card.justCopied = true
          copiedResetTimer.restart()
        }
      }

      PanelActionButton {
        radius: root.buttonRadius
        id: dismissButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(8)
        iconText: "✕"
        tooltipText: "Dismiss"
        foreground: root.foreground
        focusable: true
        onClicked: root.dismissBackgroundJob(card.job.id)
      }
    }

    Rectangle {
      visible: card.job.output.trim() !== ""
      width: parent.width
      height: Math.min(consoleFlick.contentHeight + Style.space(16), Style.space(220))
      radius: Style.cornerRadius
      color: Qt.rgba(0, 0, 0, 0.35)
      clip: true

      Flickable {
        id: consoleFlick
        anchors.fill: parent
        anchors.margins: Style.space(8)
        contentWidth: width
        contentHeight: consoleText.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Text {
          id: consoleText
          width: consoleFlick.width
          text: card.job.output
          color: "#D0D0D0"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
        }
      }
    }
  }

  // A folder-path TextField with terminal-style Tab completion: Tab lists
  // matching subdirectories via scripts/complete-path.sh, completes to
  // their longest common prefix (exact match on a single hit, plus a
  // trailing "/" so the next Tab drills in), and shows the candidates as
  // clickable chips when there's more than one. Drop-in replacement for a
  // plain TextField — text/placeholderText/foreground/onAccepted/
  // onTextChanged all behave the same.
  component PathField: Column {
    id: pathFieldRoot
    property alias text: field.text
    property alias placeholderText: field.placeholderText
    property color foreground: root.foreground
    signal accepted()

    spacing: Style.space(4)

    property var suggestions: []
    property bool completingWithTilde: false

    function requestComplete() {
      if (completeProcess.running) return
      pathFieldRoot.completingWithTilde = field.text.trim().indexOf("~") === 0
      completeProcess.command = ["bash", root.completePathScript, field.text]
      completeProcess.running = true
    }

    function toDisplayPath(absPath) {
      if (pathFieldRoot.completingWithTilde && absPath.indexOf(root.home) === 0) {
        return "~" + absPath.substring(root.home.length)
      }
      return absPath
    }

    function applyCompletion(matches) {
      if (matches.length === 0) { pathFieldRoot.suggestions = []; return }
      var display = matches.map(pathFieldRoot.toDisplayPath)
      if (display.length === 1) {
        field.text = display[0] + "/"
        field.cursorPosition = field.text.length
        pathFieldRoot.suggestions = []
        return
      }
      var lcp = display[0]
      for (var i = 1; i < display.length; i++) {
        var b = display[i]
        var j = 0
        while (j < lcp.length && j < b.length && lcp[j] === b[j]) j++
        lcp = lcp.substring(0, j)
      }
      field.text = lcp
      field.cursorPosition = field.text.length
      pathFieldRoot.suggestions = display
    }

    Process {
      id: completeProcess
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var lines = String(text || "").split("\n")
            .map(function(s) { return s.trim() })
            .filter(function(s) { return s !== "" })
          pathFieldRoot.applyCompletion(lines)
        }
      }
    }

    TextField {
      id: field
      width: parent.width
      foreground: pathFieldRoot.foreground
      onAccepted: pathFieldRoot.accepted()
      onTextChanged: pathFieldRoot.suggestions = []

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Tab) {
          pathFieldRoot.requestComplete()
          event.accepted = true
        }
      }
    }

    Flow {
      width: parent.width
      spacing: Style.space(4)
      visible: pathFieldRoot.suggestions.length > 1

      Repeater {
        model: pathFieldRoot.suggestions
        Button {
          radius: root.buttonRadius
          required property string modelData
          text: modelData.substring(modelData.lastIndexOf("/") + 1)
          tooltipText: modelData
          fontSize: Style.font.caption
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          focusable: true
          onClicked: {
            field.text = modelData + "/"
            field.cursorPosition = field.text.length
            field.forceActiveFocus()
            pathFieldRoot.suggestions = []
          }
        }
      }
    }
  }

  component CheckRow: Row {
    id: check
    property bool ok: false
    property string label: ""

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(8)

    Text {
      text: check.ok ? "✓" : "✗"
      color: check.ok ? root.foreground : root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Text {
      text: check.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      width: check.width - check.spacing - Style.space(14)
    }
  }

  // A classic attached tab: rounded top corners, square bottom. Plain
  // Rectangle.border paints all four sides uniformly, so there's no way to
  // ask it for "bordered except the bottom" directly — instead this layers
  // two rounded rectangles, an outer one in the border color and an inner
  // one (inset by the border width) in the fill color, same technique
  // BorderSurface/BorderOverlay use elsewhere in this kit. The active tab
  // insets its fill on top/left/right only, leaving the bottom flush with
  // the outer rectangle's edge — since that fill color is the exact same
  // root.wizardCardColor the content card below uses, and the tab row sits
  // directly on the card with zero spacing, the "border" along that one
  // edge visually disappears, reading as one continuous shape. An inactive
  // tab insets on all four sides instead, so it stays a fully closed pill.
  component WizardTab: Item {
    id: tab
    property string label: ""
    property bool active: false
    signal clicked()

    readonly property real bw: Math.max(1, Style.normalBorderWidth)

    implicitWidth: tabText.implicitWidth + Style.space(28)
    implicitHeight: tabText.implicitHeight + Style.space(16)

    Rectangle {
      anchors.fill: parent
      color: root.wizardCardBorder
      topLeftRadius: root.buttonRadius
      topRightRadius: root.buttonRadius
      bottomLeftRadius: 0
      bottomRightRadius: 0
    }

    Rectangle {
      anchors.fill: parent
      anchors.topMargin: tab.bw
      anchors.leftMargin: tab.bw
      anchors.rightMargin: tab.bw
      anchors.bottomMargin: tab.active ? 0 : tab.bw
      color: tab.active ? root.wizardCardColor : "transparent"
      topLeftRadius: Math.max(0, root.buttonRadius - tab.bw)
      topRightRadius: Math.max(0, root.buttonRadius - tab.bw)
      bottomLeftRadius: 0
      bottomRightRadius: 0
    }

    Text {
      id: tabText
      anchors.centerIn: parent
      text: tab.label
      color: tab.active ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: tab.active
      textFormat: Text.PlainText
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: tab.clicked()
    }
  }
}
