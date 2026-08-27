# Kamal Deploy

An [Omarchy](https://omarchy.org/) shell plugin that turns every
[Kamal](https://kamal-deploy.org/) project on your machine into a bar-panel
task list. It finds `config/deploy.yml` and `config/deploy.<env>.yml` files
under folders you point it at, and lets you run setup / deploy / logs /
console / accessory / lock actions against any of them — each one opening
(or refocusing) your default terminal so you never have to open one by hand.

## Why

Deploying multiple Kamal apps across multiple environments usually means a
hand-rolled shell menu (`kamal_menu()` in `.bashrc`, a `bin/deploy` script,
whatever) that only knows about the one repo you're sitting in. This plugin
generalizes that: point it at your projects folder once, and every
destination in every project shows up as a clickable target, from the bar,
on any workspace.

## Install

```
git clone <this-repo> ~/.config/omarchy/plugins/eduard.kamal-deploy
omarchy-shell shell rescanPlugins
omarchy plugin enable eduard.kamal-deploy
```

(Swap the clone URL once this is pushed to its own repo / submitted to the
Omarchy marketplace.)

## What it does

Click the bar icon (⚓) to open the panel:

- **Search folders** — folders to scan for `config/deploy*.yml`. Type a path
  (`~` is expanded) and hit **Add**, or click **Detect** to pick up common
  project folders (`~/Code`, `~/Projects`, `~/dev`, `~/RubymineProjects`,
  …) automatically. Saved in `shell.json` under `"eduard.kamal-deploy"`, so
  it survives restarts. Click **↻** to rescan on demand.
- **Task list** — one section per project (named from `service:` in its base
  `deploy.yml`, or the folder name), one row per destination (`default` for
  `config/deploy.yml`, `<env>` for each `config/deploy.<env>.yml`). Click a
  row to drop down its actions:
  - **Deploy** — Provision (`ruby provision <env>`), Setup (`kamal setup
    -v`), Deploy (`kamal lock release` then `kamal deploy -v`), Rollback
    (`kamal rollback`).
  - **Application** — Tail logs (`kamal app logs -f`), Rails console (`kamal
    app exec -i 'bin/rails console'`), Bash shell (`kamal app exec -i
    bash`), Rack attack status (`kamal app exec --reuse 'bin/rails
    rack_attack:status'`), Restart (`kamal app restart`), Details (`kamal
    details`).
  - **Operations** — Lock status, Release lock, Audit log.
  - **Accessories** — known accessory names (parsed from the project's
    `accessories:` block) are listed as a hint; type one into the field and
    Boot / Reboot / Stop / Restart / Logs / Remove become available (Reboot
    releases the lock first, same as the original script).

Every action shells out to `scripts/run.sh`, opened via
`omarchy-launch-or-focus-tui` — your actual default terminal (foot, kitty,
alacritty, ghostty, whatever `xdg-terminal-exec` resolves to), with a stable
per-target-per-action window so clicking the same action twice refocuses the
running one instead of piling up windows. That's what makes `kamal app exec
-i`, `rollback`'s interactive prompts, SSH passphrase prompts, and `logs -f`
work correctly — they need a real TTY, which a fake in-panel console
couldn't give them.

## Customizing the commands

`ruby provision <env>`, `bin/rails console`, and `bin/rails
rack_attack:status` come straight from the original Rails-flavored
`kamal_menu()` script this plugin is based on. If your stack differs, edit
the `case "$ACTION"` branches in `scripts/run.sh` — it's plain bash, one
`kamal ...` (or arbitrary command) per action.

## Permissions & dependencies

- Requires `kamal`, `jq`, `find`, `md5sum`, and `awk` on `PATH` (all standard
  on an Omarchy/Arch install; `jq` ships with the plugin's own scan step).
- Runs `bash scripts/discover.sh <folders...>` to scan the filesystem and
  cache results at `$XDG_RUNTIME_DIR/eduard.kamal-deploy/targets.json`.
- Runs `bash scripts/run.sh <target> <action> [accessory]` inside your
  default terminal for every action — real `kamal`, `ruby`, and shell
  commands, with your real credentials and SSH keys. Review `scripts/run.sh`
  before installing if that matters to you.
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

| File                        | Purpose                                                     |
|-----------------------------|---------------------------------------------------------------|
| `manifest.json`             | Plugin manifest (`bar-widget`)                                |
| `Panel.qml`                 | Bar icon + task-list panel UI                                  |
| `scripts/discover.sh`       | Scans search folders for `config/deploy*.yml`, prints/caches JSON |
| `scripts/run.sh`            | Resolves a clicked target and runs the matching `kamal`/`ruby` command |
| `scripts/detect-common.sh`  | Lists common project-folder names that exist under `$HOME`     |

## License

MIT — see [LICENSE](LICENSE).
