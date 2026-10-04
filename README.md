# z2m-auto-ota

Nightly, one-at-a-time installation of Zigbee firmware updates for
[Zigbee2MQTT](https://www.zigbee2mqtt.io/).

Zigbee2MQTT checks devices for OTA firmware updates on its own, but it never
installs them: each update has to be started by hand from the web UI. Starting
several at once makes every update slow, because they share one radio channel,
and some fail partway with timeouts.

`z2m-auto-ota` is a small bash script plus a systemd timer. Each night it asks
Zigbee2MQTT to check every OTA-capable device and installs any available update,
waiting for each one to finish before starting the next.

## Requirements

- Zigbee2MQTT 2.x with its MQTT API (tested with 2.6.0). Zigbee2MQTT can run in
  Docker or natively; the script only talks to the MQTT broker.
- Linux with systemd (the service uses `LoadCredential=` and `DynamicUser=`,
  so systemd 247 or newer).
- `bash`, `jq`, `mosquitto-clients` (`mosquitto_pub` and `mosquitto_sub`) and
  `stdbuf` from coreutils. On Debian-based systems `install.sh` installs
  `jq` and `mosquitto-clients` if they are missing.

## Install

```sh
git clone https://github.com/sgtsquiggs/z2m-auto-ota.git
cd z2m-auto-ota
sudo ./install.sh --no-enable
```

The installer:

- copies the script to `/usr/local/bin/z2m-auto-ota`,
- copies the service and timer to `/etc/systemd/system/`,
- creates `/etc/z2m-auto-ota.conf` (mode 0600) from
  `z2m-auto-ota.conf.example`, unless that file already exists,
- enables and starts `z2m-auto-ota.timer`, unless `--no-enable` is given.

`--no-enable` keeps the nightly timer off until you have checked the config.
Without it, the next nightly run uses the config as installed, even if you
have not looked at it yet.

Review the config and do a dry run, which checks every device but installs
nothing:

```sh
sudoedit /etc/z2m-auto-ota.conf
sudo z2m-auto-ota --dry-run
```

When the dry run lists your devices as expected, turn on the nightly timer:

```sh
sudo systemctl enable --now z2m-auto-ota.timer
```

The defaults work for a broker on the same machine that allows anonymous
clients, with Zigbee2MQTT's default base topic.

### Rebuilding a machine

There is nothing else to set up. On a new or rebuilt machine, run the same
steps: clone the repository, run `sudo ./install.sh`, and restore or recreate
`/etc/z2m-auto-ota.conf`. If you keep a copy of your config, that file is the
only state worth backing up.

## Configuration

`/etc/z2m-auto-ota.conf` holds `KEY=VALUE` lines, with no spaces around the
`=`. Lines starting with `#` are ignored, but a `#` later in a line is part of
the value, so keep comments on their own lines. Values may be wrapped in single
or double quotes. Every setting is optional. The file is parsed, never
executed, and an unknown key is an error.

| Setting | Default | Meaning |
|---|---|---|
| `Z2M_MQTT_HOST` | `localhost` | MQTT broker host. |
| `Z2M_MQTT_PORT` | `1883` | MQTT broker port. |
| `Z2M_MQTT_USER` | empty | Broker username. Leave empty for anonymous access. |
| `Z2M_MQTT_PASSWORD` | empty | Broker password. |
| `Z2M_BASE_TOPIC` | `zigbee2mqtt` | Must match `mqtt.base_topic` in Zigbee2MQTT's `configuration.yaml`. |
| `OTA_EXCLUDE` | empty | Comma-separated friendly names or IEEE addresses that are never updated, e.g. `Garage Door Sensor,0x00124b0012345678`. |
| `OTA_INCLUDE_BATTERY` | `false` | Also update battery-powered devices. These sleep most of the time, so checks are slow and often time out. |
| `OTA_MAX_STEPS` | `5` | Most updates one device gets in a single run. Some devices must install several firmware versions in sequence. |
| `OTA_WINDOW` | `14400` | Seconds after the run starts during which new updates may begin. An update in progress is allowed to finish, so the run can last up to `OTA_WINDOW` + `OTA_UPDATE_TIMEOUT`. |
| `OTA_CHECK_TIMEOUT` | `300` | Seconds to wait for Zigbee2MQTT to answer an update check. |
| `OTA_UPDATE_TIMEOUT` | `14400` | Seconds to wait for one update to finish. If it runs over, the run ends. |
| `OTA_ACTIVITY_LISTEN` | `90` | Seconds to listen, before each update, for progress reports from an update started elsewhere. If one is running, the run ends. `0` turns this off. |

TLS connections to the broker are not supported.

## Usage

```sh
sudo z2m-auto-ota --dry-run                 # report available updates, install nothing
sudo systemctl start --no-block z2m-auto-ota  # run a real update pass now, in the background
journalctl -u z2m-auto-ota -f               # follow the log
systemctl list-timers z2m-auto-ota.timer    # see when the next run is
```

Running `sudo z2m-auto-ota` directly also works, but a full pass can take hours,
so starting the service is usually better. Use `--config FILE` to read a
different config file.

The timer runs at 02:00 with up to 15 minutes of random delay, so a light that
restarts after its update does not bother anyone. Missed runs are not caught up
at boot. To change the schedule:

```sh
sudo systemctl edit z2m-auto-ota.timer
```

and add, for example:

```ini
[Timer]
OnCalendar=
OnCalendar=Sun *-*-* 03:00
```

The first, empty `OnCalendar=` clears the default schedule.

Exit status:

| Status | Meaning |
|---|---|
| 0 | Nothing failed. This includes nothing to update, the update window ending, and the run ending because another update was already running. |
| 1 | Zigbee2MQTT was offline, the broker could not be reached or the connection dropped, or a check or update failed. |
| 2 | Usage or configuration error, or a missing dependency. |
| 130 | Interrupted, for example by `systemctl stop`. |

Any status other than 0 marks the service as failed, so the run shows up in
`systemctl --failed`.

## How it works

The script uses Zigbee2MQTT's documented MQTT request/response API. With the
default base topic:

1. It reads the retained `zigbee2mqtt/bridge/state` and stops unless
   Zigbee2MQTT is online.
2. It reads the retained device list from `zigbee2mqtt/bridge/devices` and keeps
   devices that are supported, not disabled, not the coordinator, and report
   `supports_ota`. Unless `OTA_INCLUDE_BATTERY=true`, only devices powered by
   mains or DC are kept. Excluded devices are skipped.
3. For each device, in the order Zigbee2MQTT lists them, it publishes
   `{"id": "<ieee address>", "transaction": "<unique id>"}` to
   `zigbee2mqtt/bridge/request/device/ota_update/check` and waits for the reply
   on `zigbee2mqtt/bridge/response/device/ota_update/check`.
4. If an update is available, it first listens on `zigbee2mqtt/#` for
   `OTA_ACTIVITY_LISTEN` seconds. While a device updates, Zigbee2MQTT publishes
   its progress (`"update": {"state": "updating", ...}`) to the device's state
   topic, every 30 to 40 seconds in practice. If any device reports an update
   in progress, the run ends.
5. Otherwise it publishes the same kind of request as the check to
   `.../device/ota_update/update` and waits for the reply, which Zigbee2MQTT
   sends only when the update has finished or failed.
6. After a successful update it checks the same device again and repeats, up to
   `OTA_MAX_STEPS` times, because some firmware has to be installed in steps.

Zigbee2MQTT copies the `transaction` field into its reply, so replies to other
clients, such as the web UI, are ignored. The script subscribes to the response
topic and waits for the broker's acknowledgement before publishing a request,
so it cannot miss a fast reply.

Rules that keep updates from overlapping or running into the day:

- The script starts one update at a time and waits for it to finish.
- An update started elsewhere, for example from the web UI, ends the run. A
  check of that device fails with "already in progress", and the listen before
  each update catches one on any other device.
- No new update starts more than `OTA_WINDOW` seconds after the run began. The
  window is checked before each device check and again just before each
  update.
- If an update does not finish within `OTA_UPDATE_TIMEOUT`, Zigbee2MQTT may
  still be working on it, so the whole run ends rather than starting another
  update alongside it.
- A failed update or check is logged and the run moves on to the next device.
  It will be tried again on the next run.
- If the broker cannot be reached, or the connection drops while the script
  waits for a reply, the run ends. A reply sent while the connection was down
  is lost, so the script does not keep waiting for it.

## Security

- `/etc/z2m-auto-ota.conf` is created with mode 0600 because it may hold the
  broker password.
- The service receives the config through systemd's `LoadCredential=`, so the
  file can stay readable by root only while the service runs unprivileged.
- The service runs with `DynamicUser=yes`, no capabilities, a read-only view of
  the file system, a private `/tmp`, and network access limited to IP and Unix
  sockets.
- The broker password is never put on a command line. The script writes the
  connection options to a private temporary directory, read by
  `mosquitto_pub` and `mosquitto_sub` through `XDG_CONFIG_HOME`, and deletes
  it on exit.

## Upgrading

```sh
cd z2m-auto-ota
git pull
sudo ./install.sh
```

The installer replaces the script and units and keeps your existing config.
It also enables and starts the timer again. If you turned the timer off, or
manage it yourself, upgrade with `sudo ./install.sh --no-enable` instead.
Check `CHANGELOG.md` for new settings.

## Uninstalling

```sh
sudo ./uninstall.sh          # keeps /etc/z2m-auto-ota.conf
sudo ./uninstall.sh --purge  # also removes the config
```

Stopping the service during an update does not stop the update itself;
Zigbee2MQTT finishes it on its own.

## Limitations

- It has no integration with the Zigbee2MQTT web UI. Results are in the
  journal, not in Zigbee2MQTT.
- Battery devices are skipped by default and are unreliable when included,
  because they only respond when they wake up.
- Detecting updates started elsewhere relies on their progress reports. An
  update that starts after the listen, or one scheduled in Zigbee2MQTT to run
  when a device next wakes up, can still overlap with the script's update.
- It depends on the shape of Zigbee2MQTT's MQTT API: the topic names, the
  `bridge/devices` fields, the reply fields and the echoed `transaction`. A
  future Zigbee2MQTT release that changes them could break it. The dry run is a
  quick way to confirm it still works after upgrading Zigbee2MQTT.

## Development

The tests run the real script against `tests/fake-z2m`, a stand-in for
Zigbee2MQTT's OTA API, over a real MQTT broker. They never touch a real
Zigbee2MQTT or real devices.

Git hooks are managed with [prek](https://prek.j178.dev), configured in
`prek.toml`. They run ShellCheck and file hygiene checks before each commit,
and check each commit message with [commitlint](https://commitlint.js.org/),
which needs Node.js. Set them up once per clone:

```sh
prek install            # install the pre-commit and commit-msg hooks
prek run --all-files    # run the pre-commit hooks on everything
tests/docker.sh         # run the tests in a Debian container
tests/run.sh            # or run them directly
```

`tests/run.sh` starts a throwaway `mosquitto` broker if it can find one on
`PATH`. Debian and Ubuntu install the broker to `/usr/sbin`, which is not on a
normal user's `PATH`, so run `PATH="$PATH:/usr/sbin" tests/run.sh` there. To
use an existing broker instead, set `TEST_MQTT_HOST` (and `TEST_MQTT_PORT`);
the broker-restart scenario is then skipped. Each run uses its own base topic
under `z2m-auto-ota-test/` and removes its retained messages afterwards.

CI runs three jobs on every push and pull request: `hooks` runs the prek
pre-commit hooks on all files, `commit-messages` runs the commit-msg hook
(commitlint) on each pushed commit to check that it follows
[Conventional Commits](https://www.conventionalcommits.org/), and `test` runs
the tests.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the commit format and release
process, and `AGENTS.md` for code conventions.

## License

[MIT](LICENSE)
