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
  (`~` is expanded, relative paths are taken as relative to your home
  folder) — press **Tab** to autocomplete it, terminal-style: one match
  completes the folder name and appends `/` so the next Tab drills in;
  several matches complete as far as they agree and show the rest as
  clickable chips — then hit **Add**, or click **Detect** to pick up common
  project folders (`~/Code`, `~/Projects`, `~/dev`, `~/RubymineProjects`,
  …) automatically. Saved in `shell.json` under `"eduard.kamal-deploy"`, so
  it survives restarts. Click **↻** to rescan on demand. As a safety baseline,
  every folder must resolve inside your home folder — `/etc`, `/`, or a
  `..`-traversal trick like `~/../../etc` are all rejected, both here and
  again by `discover.sh` itself (in case `shell.json` was hand-edited).
- **Checklist** — one section per project (named from `service:` in its base
  `deploy.yml`, or the folder name, with a small language icon — a Nerd Font
  glyph for Ruby (any `*.rb` file or a `Gemfile`/`Rakefile` in the project
  root), Go (`*.go` or `go.mod`), TypeScript (`*.ts`/`*.tsx` or
  `tsconfig.json`), or Node (`*.js`/`*.jsx` or `package.json`), a plain dot
  for anything else — checked in that order, so Ruby wins if a project has
  both a `Gemfile` and a `package.json`, e.g. a Rails app with a JS asset
  pipeline), one checkbox per destination (`default` for `config/deploy.yml`,
  `<env>` for each
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
  `production` selection queues (or opens) two of whatever that action
  uses, one per destination, since each needs its own `kamal ... -d <env>`
  in its own project directory; they can't be merged into a single command.

**Most actions never open a terminal at all.** Provision, Setup, Deploy,
Restart, Details, Lock status, Release lock, Audit log, and every
accessory action except its own Logs run in the background — a spinner
appears under **RESULTS** while it's in flight, then the real command's
output (and exit status) renders in a scrollable console-styled card you
can dismiss whenever you're done reading it, or clear in bulk once a batch
finishes. A handful of actions still open a real terminal, because they
either need genuine interactive input or never finish on their own: Tail
logs and an accessory's own Logs (`-f`, streams forever), Rails console and
Bash shell (`kamal app exec -i`, a real interactive session), and Rollback
(prompts you to pick a version). Those go through `scripts/run.sh`, opened
via `omarchy-launch-or-focus-tui` — your actual default terminal (foot,
kitty, alacritty, ghostty, whatever `xdg-terminal-exec` resolves to), with
a stable per-target-per-action window so clicking the same action twice on
the same target refocuses the running one instead of piling up windows.

Both paths resolve a clicked target the same way, through
`$XDG_RUNTIME_DIR/eduard.kamal-deploy/targets.json` (written by the last
scan) — a background run just calls `scripts/run-background.sh` (no
terminal, no colors, no "press any key" pause, plain captured
stdout/stderr) instead of `scripts/run.sh`; both share the actual
action→command mapping from `scripts/dispatch.sh` so the two paths can't
drift apart on what a given action actually runs.

## Provision Wizard

Click **+** next to the rescan button (↻) to open the wizard for setting up
a brand-new server. It:

1. **Target folder** — pick one of your discovered projects, or type a
   custom path (Tab to autocomplete, same as search folders). Same
   home-folder safety baseline as search folders — a path outside `~` is
   flagged in red and blocks both the checks and Generate, and
   `generate-provision.sh` refuses to write outside `$HOME` even if it's
   called some other way.
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

### Deploy config

The same wizard can also generate `config/deploy.yml` itself — the
`provision` script needs it anyway, since it reads `servers:` from that
file at runtime to know which hosts to SSH into. Type an **Environment**
(blank for the base config, or a name like `staging`/`production` for a
`config/deploy.<env>.yml` override), **Role**/**Hosts** (comma-separated
IPs or hostnames) plus an optional **Cmd** to override the container's
default command, a second role like `workers` is optional too, and click
**Generate deploy.yml**:

- **Base config** (blank environment) — only offered when
  `config/deploy.yml` doesn't exist yet. Renders `service`, `image`,
  `retain_containers`, and `servers:` from the form, then a full skeleton
  for everything a real deployment typically needs — `proxy` (SSL, app
  port, healthcheck, response timeout, request buffering), `registry`,
  `env` (`clear`/`secret`), and `builder` — followed by the exact same
  aliases/ssh/volumes/asset_path/boot/accessories guidance `kamal init`
  ships (copied verbatim from the installed `kamal` gem's own template,
  never re-evaluated by this wizard's own ERB pass — so its one
  illustrative `<%= %>` example line stays literal, matching what `kamal
  init` itself produces). Every value that isn't service/image/servers is
  either a genuine Kamal default (`/up` healthcheck, `Dockerfile`, `arch:
  amd64`, `retain_containers: 5`) or a generic placeholder straight from
  Kamal's own configuration docs (`DB_USER`/`DB_PASSWORD` for `env`,
  `<your registry server>` for `registry`) — never made-up, and never
  copied from any one real project's actual values.
- **Named environment** — a minimal, `servers:`-only override, the normal
  Kamal pattern for adding a destination to an app that already has a base
  config. If `config/deploy.yml` doesn't exist yet either, it's generated
  too (full skeleton, same Service/Image/servers from the form) — an
  override with nothing to override isn't useful on its own, and this
  saves a second trip through the wizard for a brand-new project. Once a
  base exists, later named-environment generations only ever touch that
  one override file.

The wizard will never let you regenerate an existing base config with a
minimal one — that would silently delete every other setting in it. Want
to change server IPs in an existing base file? Edit it by hand, or add a
named environment override instead.

## Customizing the commands

`ruby provision <env>` and `bin/rails console` come straight from the
original Rails-flavored `kamal_menu()` script this plugin is based on. If
your stack differs, edit the `case "$ACTION"` branches in
`scripts/dispatch.sh` — it's plain bash, one `kamal ...` (or arbitrary
command) per action, shared by both `scripts/run.sh` (terminal actions) and
`scripts/run-background.sh` (background actions), so a change here applies
to whichever of the two a given action actually runs through. (The
original script's Rack::Attack status check isn't included — too specific
to one app to generalize; add it back the same way if you use it.)

## Permissions & dependencies

- Requires `kamal`, `jq`, `find`, `md5sum`, `awk`, and `ruby` (stdlib `erb` +
  `json`, no gems) on `PATH` (all standard on an Omarchy/Arch install with
  Kamal already set up).
- Runs `bash scripts/discover.sh <folders...>` to scan the filesystem and
  cache results at `$XDG_RUNTIME_DIR/eduard.kamal-deploy/targets.json`.
- Every path field runs `bash scripts/complete-path.sh <partial>` (read-only
  directory listing) on Tab, restricted to `$HOME` the same way every write
  path in this plugin is.
- Runs `bash scripts/run.sh <target> <action> [accessory]` inside your
  default terminal for Tail logs / Rails console / Bash shell / Rollback /
  an accessory's own Logs — real `kamal`, `ruby`, and shell commands, with
  your real credentials and SSH keys. Every other action runs the same way
  through `bash scripts/run-background.sh <target> <action> [accessory]`
  instead, captured (not shown live) by the panel rather than opened in a
  terminal — same commands, same credentials, just no TTY; it refuses to
  run any of the terminal-only actions itself as a second guard against
  that mismatch. Review `scripts/dispatch.sh` (what each action actually
  runs) before installing if that matters to you.
- The Provision Wizard runs `bash scripts/provision-check.sh <folder> [env]`
  (read-only) and `bash scripts/generate-provision.sh <folder> <options>`,
  which **writes** `<folder>/provision` (overwriting any existing file with
  that name) and marks it executable, and/or
  `bash scripts/generate-deploy.sh <folder> <env> <options>`, which
  **writes** `<folder>/config/deploy.yml` or
  `<folder>/config/deploy.<env>.yml` (refusing to touch an existing base
  config — see **Deploy config** above).
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
| `scripts/dispatch.sh`           | Shared action→`kamal`/`ruby` command mapping, sourced by both scripts below |
| `scripts/run.sh`                | Resolves a clicked target, runs it in a real terminal (interactive/streaming actions) |
| `scripts/run-background.sh`     | Same resolution, runs in the background instead, output captured for the panel |
| `scripts/complete-path.sh`      | Read-only Tab-completion for the panel's folder fields          |
| `scripts/detect-common.sh`      | Lists common project-folder names that exist under `$HOME`     |
| `scripts/provision-check.sh`    | Read-only pre-flight checks for the Provision Wizard            |
| `scripts/generate-provision.sh` | Renders `templates/provision.erb` into `<folder>/provision`    |
| `templates/provision.erb`       | The parameterized provisioning script itself                   |
| `scripts/generate-deploy.sh`    | Renders `templates/deploy.erb` (+ `deploy-tail.yml` for a new base config) into `config/deploy.yml` or `config/deploy.<env>.yml` |
| `templates/deploy.erb`          | The `service`/`image`/`servers:` header this wizard controls   |
| `templates/deploy-tail.yml`     | Verbatim copy of `kamal init`'s proxy/registry/builder/… guidance |

## License

MIT — see [LICENSE](LICENSE).
