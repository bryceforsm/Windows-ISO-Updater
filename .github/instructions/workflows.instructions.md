---
description: Security, shell, and coupling rules for the GitHub Actions workflows
applyTo: .github/workflows/**
---

# GitHub Actions workflows

`dependency-check.yml` is a thin wrapper around `tools/Test-Dependencies.ps1`. Most edits to one need a
matching edit to the other, so read the relevant part of the tester before changing the workflow.
`tests.yml` wraps `tools/Invoke-Tests.ps1` in the same way. `release.yml` and `release-checksums.yml` are the
only workflows that write to releases, so their `contents: write` stays on the job. The ruleset on main only
accepts pull requests, so no workflow can commit there. A release created with the workflow token does not
start other workflows, which is why `release.yml` writes `Windows-ISO-Updater.SHA256SUMS.txt` itself, and
`release-checksums.yml` covers releases made by hand. The release page lists assets by name, ignoring case and
regardless of upload order, which is what that name is for: it sorts after `Windows-ISO-Updater.ps1`, so the
checksums are always the last of the three files.

Each change is tested once, on its pull request. `tests.yml` does not run on pushes to main, because the
ruleset means everything there arrived through a pull request that already passed, and a new push to a pull
request cancels the run still going for the previous one. `dependency-check.yml` runs daily and on pull
requests, not on every branch push. `release.yml` runs the tests again before it publishes, as the final check.
Do not add push triggers back to these without a reason the pull request run does not cover.

## Security

- Pin every third-party action to a full 40-character commit SHA with the version as a trailing
  comment, as in `actions/checkout@<sha> # v7.0.1`. A tag can be moved to different code after review.
- Never put `${{ inputs.* }}`, `${{ github.event.* }}`, or any other user-controlled expression directly
  in a `run:` block. Map it to an `env:` entry and read `$env:NAME` in the script, so a typed input is
  data and never code.
- Keep `permissions:` at the workflow level and at the minimum the job needs. The dependency check only
  reads, so it stays at `contents: read`.
- Keep `timeout-minutes` on every job. A hung catalog request otherwise burns the six-hour default.

## Shell

Use `shell: powershell` for any step that runs repository PowerShell, so it runs under Windows
PowerShell 5.1 like the script does. The runner's default `pwsh` is 7 and will hide 5.1 bugs. Call
scripts with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`.

## Contracts with Test-Dependencies.ps1

Each of these spans both files. Change one side and you must change the other in the same edit.

| Contract | Workflow side | Tester side |
| --- | --- | --- |
| Exit codes | `2` is mapped to success so warnings stay green, and anything else is passed through | `0` clean, `1` failure, `2` warnings only |
| Deep run | The `DEEP` expression compares `github.event.schedule` against the monthly cron string by exact text | `-Deep` switch |
| Catalog query default | The `catalogQuery` input default and the `CATALOG_QUERY` fallback | The `-CatalogQuery` parameter default |
| Published-script check | Runs only on `refs/heads/main` | Skips unless `GITHUB_ACTIONS` is `true` and `GITHUB_REF` is main |
| Annotations | None needed, the tester writes them | Emits `::error` and `::warning` and writes `GITHUB_STEP_SUMMARY` |

The deep-run match is the trap. Editing the first-of-month cron without editing the `DEEP` expression
leaves the deep run silently never firing, and nothing reports it.

The catalog query lives in three places. When a new Windows release moves the default, change all three.

## Triggers

`push.paths` lists the files whose change can break the check. Add a path when the tester starts
reading a new file, and keep the workflow file itself in the list.

Cron is UTC only. Keep the comment that converts the time to Pacific in step with the expression.

## Validation

There is no local runner. Re-read the edited YAML for indentation and quoting, and confirm each
contract row above still holds on both sides. A real run needs a push or a manual dispatch, so ask
before triggering one.
