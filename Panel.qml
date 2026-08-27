import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Kamal Deploy — finds config/deploy.yml + config/deploy.<env>.yml files
// under your configured project folders and turns each one into a bar-panel
// task-list row. Clicking a row drops down the actions from the user's own
// kamal_menu() shell function (provision / setup / deploy / accessories /
// logs / console / rack_attack / shell), plus a few more pulled from the
// Kamal CLI (rollback, details, lock, audit, restart).
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

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/eduard.kamal-deploy"
  readonly property string discoverScript: pluginDir + "/scripts/discover.sh"
  readonly property string runScript: pluginDir + "/scripts/run.sh"

  readonly property var savedSettings: bar && bar.shell && bar.shell.shellConfig
    && bar.shell.shellConfig["eduard.kamal-deploy"] && typeof bar.shell.shellConfig["eduard.kamal-deploy"] === "object"
    ? bar.shell.shellConfig["eduard.kamal-deploy"] : ({})
  readonly property var searchPaths: Array.isArray(savedSettings.searchPaths) ? savedSettings.searchPaths : []

  readonly property string generateProvisionScript: pluginDir + "/scripts/generate-provision.sh"
  readonly property string provisionCheckScript: pluginDir + "/scripts/provision-check.sh"

  property var projects: []
  property bool scanning: false
  property string lastScanError: ""
  property string expandedTargetId: ""

  // ---------------------------------------------------------- provision wizard
  property bool wizardOpen: false
  property string wizardTargetMode: "known"   // "known" | "custom"
  property string wizardKnownPath: ""
  property string wizardCustomPath: ""
  readonly property string wizardResolvedPath: (wizardTargetMode === "known" ? wizardKnownPath : wizardCustomPath).trim()
  property var wizardChecks: null
  property bool wizardChecking: false
  property bool wizardGenerating: false
  property string wizardResult: ""
  property bool wizardResultIsError: false

  onWizardResolvedPathChanged: if (root.wizardOpen) wizardCheckDebounce.restart()

  function openWizard() {
    root.wizardResult = ""
    root.wizardResultIsError = false
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
    if (root.wizardResolvedPath === "") { root.wizardChecks = null; return }
    if (checkProcess.running) return
    root.wizardChecking = true
    checkProcess.command = ["bash", root.provisionCheckScript, root.wizardResolvedPath]
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
    if (root.wizardResolvedPath === "" || generateProcess.running) return
    root.wizardGenerating = true
    root.wizardResult = ""
    generateProcess.command = ["bash", root.generateProvisionScript, root.wizardResolvedPath, JSON.stringify(options)]
    generateProcess.running = true
  }

  function saveSearchPaths(paths) {
    if (!bar || !bar.shell || typeof bar.shell.mutateShellConfig !== "function") return
    bar.shell.mutateShellConfig(function(config) {
      if (!config["eduard.kamal-deploy"] || typeof config["eduard.kamal-deploy"] !== "object") config["eduard.kamal-deploy"] = {}
      config["eduard.kamal-deploy"].searchPaths = paths
    })
  }

  function addSearchPath(p) {
    var trimmed = String(p || "").trim()
    if (trimmed === "" || root.searchPaths.indexOf(trimmed) !== -1) return
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
    } catch (e) {
      root.lastScanError = "Could not parse scan results."
    }
  }

  function toggleTarget(targetId) {
    root.expandedTargetId = (root.expandedTargetId === targetId) ? "" : targetId
  }

  function launch(targetId, action, extra) {
    var appId = "org.omarchy.kamal-deploy." + targetId + "." + action + (extra ? ("." + extra) : "")
    var args = ["omarchy-launch-or-focus-tui", "--app-id=" + appId, "bash", root.runScript, targetId, action]
    if (extra) args.push(extra)
    Quickshell.execDetached(args)
  }

  onOpenedChanged: if (opened) {
    if (root.searchPaths.length > 0 && root.projects.length === 0) root.rescan()
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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "⚓"
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
                text: "⚓"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                iconText: "↻"
                tooltipText: "Rescan"
                foreground: root.foreground
                focusable: true
                onClicked: root.rescan()
              }
            }
          }

          Button {
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
                }

                PanelActionButton {
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

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: pathField
                width: parent.width - addBtn.implicitWidth - detectBtn.implicitWidth - Style.space(16)
                placeholderText: "~/Code"
                foreground: root.foreground
                onAccepted: { root.addSearchPath(text); text = "" }
              }

              Button {
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

          Column {
            width: parent.width
            spacing: Style.space(16)
            visible: root.projects.length > 0

            Repeater {
              model: root.projects
              ProjectBlock { width: column.width; project: modelData }
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
                  text: "Generates a tailored `provision` script from your provisioning template — the Provision action on any project only runs if that file is there."
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

                  TextField {
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
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }

                // ---------- Checks ----------
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.wizardResolvedPath !== ""

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

                PanelSeparator { foreground: root.foreground }

                // ---------- Tailor ----------
                Column {
                  width: parent.width
                  spacing: Style.space(10)

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
                }

                PanelSeparator { foreground: root.foreground }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Button {
                    text: root.wizardGenerating ? "Generating…" : "Generate provision file"
                    fontSize: Style.font.bodySmall
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    bordered: true
                    focusable: true
                    enabled: root.wizardResolvedPath !== "" && !root.wizardGenerating
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

                  Button {
                    text: "Close"
                    fontSize: Style.font.bodySmall
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    bordered: true
                    focusable: true
                    onClicked: root.closeWizard()
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
                  bottomPadding: Style.space(8)
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

    spacing: Style.space(8)

    Column {
      width: parent.width
      spacing: Style.space(1)

      PanelSectionHeader {
        width: parent.width
        text: String(block.project.name || "project").toUpperCase()
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        width: parent.width
        text: String(block.project.path || "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: block.project.environments || []
        TargetRow {
          width: parent.width
          env: modelData
          accessories: block.project.accessories || []
          hasProvision: !!block.project.hasProvision
        }
      }
    }
  }

  component TargetRow: Column {
    id: row
    property var env: ({})
    property var accessories: []
    property bool hasProvision: false

    readonly property string targetId: String(row.env.targetId || "")
    readonly property bool expanded: root.expandedTargetId === row.targetId
    readonly property string envLabel: row.env.label || "default"

    spacing: Style.space(8)

    Button {
      width: parent.width
      leftAlign: true
      text: (row.expanded ? "󰅀  " : "󰅂  ") + row.envLabel
      fontSize: Style.font.body
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      focusable: true
      active: row.expanded
      onClicked: root.toggleTarget(row.targetId)
    }

    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: row.expanded
      leftPadding: Style.space(6)

      ActionGroup {
        width: parent.width - parent.leftPadding
        heading: "DEPLOY"
        actions: [
          { label: "Provision", action: "provision", enabled: row.hasProvision,
            disabledReason: "No provision script — run the Provision Wizard for this project first." },
          { label: "Setup", action: "setup" },
          { label: "Deploy", action: "deploy" },
          { label: "Rollback", action: "rollback" }
        ]
        targetId: row.targetId
      }

      ActionGroup {
        width: parent.width - parent.leftPadding
        heading: "APPLICATION"
        actions: [
          { label: "Tail logs", action: "logs" },
          { label: "Rails console", action: "console" },
          { label: "Bash shell", action: "shell" },
          { label: "Rack attack status", action: "rack_attack" },
          { label: "Restart", action: "restart" },
          { label: "Details", action: "details" }
        ]
        targetId: row.targetId
      }

      ActionGroup {
        width: parent.width - parent.leftPadding
        heading: "OPERATIONS"
        actions: [
          { label: "Lock status", action: "lock_status" },
          { label: "Release lock", action: "lock_release" },
          { label: "Audit log", action: "audit" }
        ]
        targetId: row.targetId
      }

      Column {
        id: accessoryGroup
        width: parent.width - parent.leftPadding
        spacing: Style.space(8)

        readonly property string accessoryValue: accessoryField.text.trim()
        readonly property bool accessoryValid: accessoryValue !== "" && !/\s/.test(accessoryValue)

        PanelSectionHeader { text: "ACCESSORIES"; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }

        Text {
          visible: row.accessories.length > 0
          width: parent.width
          text: "Known: " + row.accessories.join(", ")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        TextField {
          id: accessoryField
          width: parent.width
          placeholderText: row.accessories.length > 0 ? row.accessories[0] : "accessory name"
          foreground: root.foreground
        }

        Text {
          visible: accessoryField.text.trim() !== "" && !accessoryGroup.accessoryValid
          width: parent.width
          text: "Accessory name can't contain spaces."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: [
              { label: "Boot", action: "accessory_boot" },
              { label: "Reboot", action: "accessory_reboot" },
              { label: "Stop", action: "accessory_stop" },
              { label: "Restart", action: "accessory_restart" },
              { label: "Logs", action: "accessory_logs" },
              { label: "Remove", action: "accessory_remove" }
            ]

            Button {
              required property var modelData
              text: modelData.label
              fontSize: Style.font.bodySmall
              foreground: modelData.action === "accessory_remove" ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              bordered: true
              focusable: true
              enabled: accessoryGroup.accessoryValid
              onClicked: root.launch(row.targetId, modelData.action, accessoryGroup.accessoryValue)
            }
          }
        }
      }
    }
  }

  component ActionGroup: Column {
    id: group
    property string heading: ""
    property string targetId: ""
    property var actions: []

    spacing: Style.space(6)

    PanelSectionHeader { text: group.heading; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption }

    Flow {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: group.actions

        Button {
          required property var modelData
          text: modelData.label
          tooltipText: (modelData.enabled === false && modelData.disabledReason) ? modelData.disabledReason : ""
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          focusable: true
          enabled: modelData.enabled !== false
          onClicked: root.launch(group.targetId, modelData.action)
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
}
