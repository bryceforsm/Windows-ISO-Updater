# Changelog

What changed in each release. Versions are dates, `yyyy.MM.dd.<revision>`. Releases before this file was added are described on the [Releases page](https://github.com/bryceforsm/Windows-ISO-Updater/releases).

## [Unreleased]

## [2026.10.31.5] - 2026-10-31

### Added

- `-ConfigPath` loads build settings from a JSON profile, so a build can be repeated without a long command line. See [Using a JSON Profile](docs/usage.md#using-a-json-profile).
- Each release now includes a `SHA256SUMS` file for checking the download.

### Changed

- `-BaselineOnly` now uses the latest baseline on Microsoft's hotpatch calendar instead of the newest cumulative update. This covers extra baselines outside January, April, July and October. If the calendar cannot be read, the run warns and uses the newest security update from those four months. The next run may rebuild once because the expected update changes.
- `-UseFido` now runs one pinned version of Fido, checked by SHA-256. Overriding `-FidoUrl` now also needs `-FidoSha256`, either the new hash or an empty string.
- Running the `.ps1` directly now keeps the original window open until the elevated run finishes, and returns its exit code.

### Fixed

- The task password no longer appears on a command line when the script relaunches itself elevated, and it can no longer reach the build record on the ISO.
- A download that fails partway can no longer be reused by a later run. Update packages are also checked for damage before they are reused.
- Relaunching elevated now keeps relative paths, several `-KeepEditions` values and paths ending in a backslash intact.
