# Kamal Deploy

An [Omarchy](https://omarchy.org/) shell plugin that turns every
[Kamal](https://kamal-deploy.org/) project on your machine into a bar-panel
checklist. It finds `config/deploy.yml` and `config/deploy.<env>.yml` files
under folders you point it at, and lets you check any number of
destinations — across one project or several — then run setup / deploy /
logs / console / accessory / lock actions against all of them at once, each
one opening (or refocusing) your default terminal so you never have to open
one by hand.

## Why

Deploying multiple Kamal apps across multiple environments usually means a
hand-rolled shell menu (`kamal_menu()` in `.bashrc`, a `bin/deploy` script,
whatever) that only knows about the one repo you're sitting in. This plugin
generalizes that: point it at your projects folder once, and every
destination in every project shows up as a clickable target, from the bar,
on any workspace.

## Install

```
git clone https://github.com/eddygarcas/omarchy-kamal-deploy.git \
  ~/.config/omarchy/plugins/eduard.kamal-deploy
omarchy-shell shell rescanPlugins
omarchy plugin enable eduard.kamal-deploy
```

## What it does

Click the bar icon (a compass) to open the panel:

- **Search folders** — folders to scan for `config/deploy*.yml`. Type a path
  (`~` is expanded) and hit **Add**, or click **Detect** to pick up common
  project folders (`~/Code`, `~/Projects`, `~/dev`, `~/RubymineProjects`,
  …) automatically. Saved in `shell.json` under `"eduard.kamal-deploy"`, so
  it survives restarts. Click **↻** to rescan on demand.
- **Checklist** — one section per project (named from `service:` in its base
  `deploy.yml`, or the folder name, with a small language badge — **RB**
  for Ruby (`Gemfile`), **GO** for Go (`go.mod`), **TS** for TypeScript
  (`tsconfig.json`), **JS** for Node (`package.json`), a plain dot for
  anything else — Ruby wins if a project has both a `Gemfile` and a
  `package.json`, e.g. a Rails app with a JS asset pipeline), one checkbox
  per destination (`default` for `config/deploy.yml`, `<env>` for each
  `config/deploy.<env>.yml`).
  **Select all** / **Clear** toggle everything at once. As soon as anything
  is checked, a **SELECTED (N)** chip row appears (click a chip's ✕ to
  uncheck just that one) followed by the shared action bar — every button
  carries an icon for its action:
  - **Deploy** — Provision (`ruby provision <env>` — enabled only once
    *every* selected target's project has a `provision` script, see
    **Provision Wizard** below), Setup (`kamal setup -v`), Deploy (`kamal
    lock release` then `kamal deploy -v`), Rollback (`kamal rollback`).
  - **Application** — Tail logs (`kamal app logs -f`), Rails console (`kamal
    app exec -i 'bin/rails console'`), Bash shell (`kamal app exec -i
    bash`), Restart (`kamal app restart`), Details (`kamal details`).
  - **Operations** — Lock status, Release lock, Audit log.
  - **Accessories** — known accessory names (parsed from every selected
    project's `accessories:` block) are listed as a hint; type one into the
    field and Boot / Reboot / Stop / Restart / Logs / Remove become
    available (Reboot releases the lock first, same as the original
    script).

  Clicking any action runs it once per checked target — a `staging` +
  `production` selection opens two terminals for **Deploy**, one per
  destination, since each needs its own `kamal ... -d <env>` in its own
  project directory; they can't be merged into a single command.

Every action shells out to `scripts/run.sh`, opened via
`omarchy-launch-or-focus-tui` — your actual default terminal (foot, kitty,
alacritty, ghostty, whatever `xdg-terminal-exec` resolves to), with a stable
per-target-per-action window so clicking the same action twice on the same
target refocuses the running one instead of piling up windows. That's what
makes `kamal app exec -i`, `rollback`'s interactive prompts, SSH passphrase
prompts, and `logs -f` work correctly — they need a real TTY, which a fake
in-panel console couldn't give them.

## Provision Wizard

Click **+** next to the rescan button (↻) to open the wizard for setting up
a brand-new server. It:

1. **Target folder** — pick one of your discovered projects, or type a
   custom path (for a project not scanned yet).
2. **Checks** — runs `scripts/provision-check.sh` against that folder and
   shows: does `config/deploy.yml` (or `deploy.<env>.yml`) exist, does the
   `Gemfile` have the `kamal` and `net-ssh` gems, does `ssh-add -l` show a
   loaded key, and whether a `provision` file is already there (would be
   overwritten).
3. **Tailor** — swap size, storage path/owner, extra firewall ports beyond
   22, Docker log rotation size/count, ulimit, and four toggles (UFW,
   fail2ban, unattended-upgrades, SSH hardening).
4. **Generate** — renders `templates/provision.erb` with those choices via
   `scripts/generate-provision.sh` (plain Ruby `ERB`, no gems needed beyond
   the stdlib) into `<target>/provision`, `chmod +x`, then rescans so the
   project's **Provision** button lights up immediately.

The template itself is the user's own Scaleway/Ubuntu Kamal provisioning
script (idempotent SSH-based steps: essentials, swap, storage dir, Docker +
`kamal` network, then the four toggleable hardening steps, then Docker
daemon log rotation), parameterized instead of hardcoded. A toggle turned
off removes that step from the generated script entirely rather than
leaving it disabled in place — re-run the wizard any time to regenerate with
different choices; it always overwrites, never merges.

## Customizing the commands

`ruby provision <env>` and `bin/rails console` come straight from the
original Rails-flavored `kamal_menu()` script this plugin is based on. If
your stack differs, edit the `case "$ACTION"` branches in `scripts/run.sh`
— it's plain bash, one `kamal ...` (or arbitrary command) per action. (The
original script's Rack::Attack status check isn't included — too specific
to one app to generalize; add it back the same way if you use it.)

## Permissions & dependencies

- Requires `kamal`, `jq`, `find`, `md5sum`, `awk`, and `ruby` (stdlib `erb` +
  `json`, no gems) on `PATH` (all standard on an Omarchy/Arch install with
  Kamal already set up).
- Runs `bash scripts/discover.sh <folders...>` to scan the filesystem and
  cache results at `$XDG_RUNTIME_DIR/eduard.kamal-deploy/targets.json`.
- Runs `bash scripts/run.sh <target> <action> [accessory]` inside your
  default terminal for every action — real `kamal`, `ruby`, and shell
  commands, with your real credentials and SSH keys. Review `scripts/run.sh`
  before installing if that matters to you.
- The Provision Wizard runs `bash scripts/provision-check.sh <folder>`
  (read-only) and `bash scripts/generate-provision.sh <folder> <options>`,
  which **writes** `<folder>/provision` (overwriting any existing file with
  that name) and marks it executable.
- Reads/writes `"eduard.kamal-deploy".searchPaths` in
  `~/.config/omarchy/shell.json`.
- Like every Quickshell plugin, `Panel.qml` runs unsandboxed inside the
  shared `omarchy-shell` process — review it before installing.

## Remove

```
omarchy plugin remove eduard.kamal-deploy
```

This deletes `~/.config/omarchy/plugins/eduard.kamal-deploy/` and removes
the widget from your bar layout. It does **not** revert the
`"eduard.kamal-deploy"` key in `shell.json` — delete it by hand, or run
`omarchy refresh shell`, if you want it gone too.

## Files

| File                            | Purpose                                                     |
|---------------------------------|---------------------------------------------------------------|
| `manifest.json`                 | Plugin manifest (`bar-widget`)                                |
| `Panel.qml`                     | Bar icon + task-list panel UI + Provision Wizard                |
| `scripts/discover.sh`           | Scans search folders for `config/deploy*.yml`, prints/caches JSON |
| `scripts/run.sh`                | Resolves a clicked target and runs the matching `kamal`/`ruby` command |
| `scripts/detect-common.sh`      | Lists common project-folder names that exist under `$HOME`     |
| `scripts/provision-check.sh`    | Read-only pre-flight checks for the Provision Wizard            |
| `scripts/generate-provision.sh` | Renders `templates/provision.erb` into `<folder>/provision`    |
| `templates/provision.erb`       | The parameterized provisioning script itself                   |

## License

MIT — see [LICENSE](LICENSE).
