# AGENTS.md

Guidance for coding agents working in this repository. Read `README.md` first
for what the tool does and how it is installed.

## Layout

| Path | What it is |
|---|---|
| `bin/z2m-auto-ota` | The whole program: one bash script. |
| `systemd/z2m-auto-ota.service` | Sandboxed oneshot service that runs the script. |
| `systemd/z2m-auto-ota.timer` | Nightly schedule (02:00, 15 min random delay). |
| `z2m-auto-ota.conf.example` | Every setting with its default; installed as `/etc/z2m-auto-ota.conf`. |
| `install.sh`, `uninstall.sh` | Idempotent installer and remover, run as root on the target machine. |
| `tests/run.sh` | End-to-end test scenarios. |
| `tests/fake-z2m` | Stand-in for Zigbee2MQTT's OTA MQTT API, driven by files in a state directory. |
| `tests/devices.json` | Device list that `fake-z2m` publishes. |
| `tests/docker.sh` | Runs `tests/run.sh` in a Debian container with the dependencies installed. |
| `prek.toml` | Git hooks run by [prek](https://prek.j178.dev): ShellCheck, file hygiene, commitlint. |
| `commitlint.config.mjs` | Commit message rules (Conventional Commits) for the commitlint hook. |
| `.github/scripts/check-commit-messages.sh` | Runs the commit-msg hook on each commit in a range; used by CI. |
| `CONTRIBUTING.md` | Commit message format and the release process. |
| `CHANGELOG.md` | User-visible changes per release (Keep a Changelog). |
| `.github/workflows/ci.yml` | CI jobs: `hooks` (prek pre-commit hooks), `commit-messages` (commitlint on each pushed commit), `test`. |
| `.editorconfig` | Indentation and line-ending rules for editors. |

## Conventions

- Bash only, with `set -euo pipefail`. Runtime dependencies are limited to
  bash, `jq`, `mosquitto_pub`/`mosquitto_sub` and coreutils. Do not add more
  without a strong reason; the target is a small Debian or Raspberry Pi OS box.
- ShellCheck must pass with no warnings. Disable a check only on the line that
  needs it, with a comment saying why.
- Four-space indentation, no tabs. See `.editorconfig`.
- The config file is parsed line by line, never `source`d. New settings go in
  the defaults block and the `SETTINGS` array in `bin/z2m-auto-ota`, and get
  validated in `load_config`.
- Never put secrets on a command line, where `ps` can show them. MQTT
  connection options go through the per-run files under `XDG_CONFIG_HOME`.
- Log through `info`, `warn` and `error`, to stderr. Messages start with the
  device's friendly name where there is one.
- Keep the exit status contract, documented in `usage` and the README: 0
  nothing failed (including a run ended early on purpose), 1 Zigbee2MQTT or
  the broker unavailable or a check or update failed, 2 usage, configuration
  or dependency error, 130 interrupted.

## Testing

```sh
prek install            # once per clone: pre-commit and commit-msg hooks
prek run --all-files    # ShellCheck and file hygiene, as in CI
tests/docker.sh
```

Hooks live in `prek.toml`. Do not bypass them with `--no-verify`; fix the
problem instead. The commit-msg hook runs commitlint (needs Node.js) with the
rules in `CONTRIBUTING.md`. To check existing commits the way CI does:
`.github/scripts/check-commit-messages.sh <base> HEAD`.

`tests/run.sh` can also run directly with `mosquitto` installed, or against an
existing broker with `TEST_MQTT_HOST`/`TEST_MQTT_PORT`. Add a scenario to
`tests/run.sh` for every behaviour change. A scenario checks the exit status,
the exact sequence of requests `fake-z2m` received, and expected log lines.

## Rules

- Never point tests or experiments at a real Zigbee2MQTT with updates enabled.
  An accidental run can start real firmware updates. Use `fake-z2m`, or
  `--dry-run` against a real instance.
- Keep the configuration table in `README.md`, the defaults in
  `bin/z2m-auto-ota` and `z2m-auto-ota.conf.example` in sync.
- Commit messages follow Conventional Commits, checked by the prek commit-msg
  hook locally and in CI.
  See `CONTRIBUTING.md` for the types, what counts as a breaking change, and
  the release steps. Add user-visible changes to `CHANGELOG.md` under
  `Unreleased` in the same commit.
- When releasing, bump `VERSION` in `bin/z2m-auto-ota` and move the changelog
  entries under the new version in one `chore(release): <version>` commit.
- Do not weaken the systemd sandboxing without saying why in the commit.
- `install.sh` must stay safe to re-run and must never overwrite an existing
  `/etc/z2m-auto-ota.conf`.
- Never let two updates run at once. If the script cannot tell whether an
  update is still running, it must end the run.

## Zigbee2MQTT compatibility

The script depends on these parts of Zigbee2MQTT's MQTT API (2.x, verified
against 2.6.0). `<base>` is `Z2M_BASE_TOPIC`.

- `<base>/bridge/state` (retained): `{"state": "online"}` in 2.x. 1.x published
  the bare string `online`; both are accepted.
- `<base>/bridge/devices` (retained): an array of devices. Fields used:
  `ieee_address`, `friendly_name`, `type` (`Coordinator` is skipped),
  `supported`, `disabled`, `power_source` (`Mains ...`, `DC Source`,
  `Battery`) and `definition.supports_ota`.
- Requests go to `<base>/bridge/request/device/ota_update/{check,update}` with
  `{"id": "<ieee address or friendly name>", "transaction": "<string>"}`.
  The script always sends the IEEE address.
- Replies arrive on `<base>/bridge/response/device/ota_update/{check,update}`
  and echo `transaction`. Replies for other transactions must be ignored.
  - Success: `{"status": "ok", "data": {...}, "transaction": ...}`.
    `check` data has `update_available` (boolean). `update` data may have
    `from` and `to`, each with `software_build_id`, `file_version` and
    `date_code`. Any of these can be missing: a real reply for a Hue Play
    light bar had only `from.software_build_id` and `from.date_code`.
  - Failure: `{"status": "error", "error": "<message>", "data": {}, "transaction": ...}`.
    Requests for a device whose update is already running fail with an
    "already in progress" error.
- The `update` reply is sent only when the update has finished or failed,
  which can take hours.
- While a device updates, Zigbee2MQTT publishes progress to the device's
  state topic, `<base>/<friendly name>`, as
  `{"update": {"state": "updating", "progress": ..., "remaining": ...}}`.
  Observed every 30 to 40 seconds. Other `update.state` values are `idle`,
  `available` and `scheduled`. `find_running_update` relies on this.
- `mosquitto_sub` reconnects on its own after losing the broker; with `-d` a
  reconnect shows up as another `sending CONNECT` line. `request` treats that
  as a lost connection. When `mosquitto_sub` exits on its own, `request` tells
  a `-W` timeout from a broker error by the elapsed time, not the exit status.

Zigbee2MQTT also has `ota_update/schedule`, `unschedule` and `.../abort`
endpoints; the script does not use them.
