# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-04

### Added

- `z2m-auto-ota` script that checks every OTA-capable Zigbee2MQTT device and
  installs available updates one device at a time over the MQTT API.
- Up to `OTA_MAX_STEPS` consecutive updates per device per run, for firmware
  that must be installed in several steps.
- `OTA_WINDOW` limit on when new updates may start, and `OTA_UPDATE_TIMEOUT`
  limit on a single update. A timed-out update ends the run so two updates
  never overlap.
- A device that already has an update running, for example one started from
  the web UI, ends the run so a second update never starts alongside it.
- `OTA_ACTIVITY_LISTEN`: before each update, listen for progress reports and
  end the run if any device is already updating.
- A dropped broker connection while waiting for a reply ends the run instead
  of waiting out the timeout.
- Device exclusion by friendly name or IEEE address; battery devices skipped
  unless `OTA_INCLUDE_BATTERY=true`.
- `--dry-run` mode.
- Sandboxed systemd service and nightly timer, `install.sh` and
  `uninstall.sh`.
- End-to-end tests against a fake Zigbee2MQTT, and CI running the prek hooks
  (ShellCheck, file hygiene, Conventional Commits) and the tests.
- prek configuration (`prek.toml`) with pre-commit and commit-msg hooks.

[Unreleased]: https://github.com/sgtsquiggs/z2m-auto-ota/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/sgtsquiggs/z2m-auto-ota/releases/tag/v1.0.0
