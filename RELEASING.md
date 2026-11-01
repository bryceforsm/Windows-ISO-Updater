# Releasing

How to publish a new version of Windows ISO Updater. A release takes one small pull request and one workflow run, and needs write access to the repository.

## Before you start

Check that `main` holds everything you want to ship, its checks are passing, and `CHANGELOG.md` has entries under `## [Unreleased]`. Those entries become the release notes, so read them the way someone downloading the release would.

## Steps

1. **Prepare the changelog** from an up-to-date `main`:

   ```powershell
   git switch main
   git pull
   git switch -c release-notes
   .\tools\Update-Changelog.ps1
   ```

   This moves the Unreleased entries under a heading for the current version, such as `## [2026.10.31.5](https://github.com/bryceforsm/Windows-ISO-Updater/releases/tag/2026.10.31.5) - 2026-10-31`. The link starts working when the release is published in step 4.

2. **Merge that change in its own pull request.** Commit only `CHANGELOG.md`. A commit that touches `src/` changes the version, and the heading would no longer match.

   ```powershell
   git add CHANGELOG.md
   git commit -m "Prepare the changelog for release"
   git push -u origin release-notes
   gh pr create --fill
   ```

3. **Try a dry run.** In GitHub, go to **Actions**, then **Release**, then **Run workflow**, keep the branch on `main`, and tick the dry run option. The log shows the version, notes and checksums. Nothing is published.

   ```powershell
   gh workflow run release.yml --ref main -f dry_run=true
   ```

4. **Publish.** Run the same workflow without the dry run option. Publishing is immediate, so check the dry run's log first.

   ```powershell
   gh workflow run release.yml --ref main
   ```

5. **Check the [Releases page](https://github.com/bryceforsm/Windows-ISO-Updater/releases).** The new release should have the notes from the changelog and these three files: `Run-Windows-ISO-Updater.bat`, `Windows-ISO-Updater.ps1` and `SHA256SUMS.txt`.

## If the workflow stops

| Message | What happened | What to do |
|---|---|---|
| `CHANGELOG.md has no section for <version>` | Step 1 and 2 were skipped, or a commit touching `src/` merged after them and moved the version. | If the changelog was never prepared, do steps 1 and 2. If it was, change the old version in the newest heading and its link to the version in the message, in a pull request. Move any new Unreleased entries under it too, so nothing is left out of the notes. |
| `Release <version> already exists` | This version is already published, usually because only docs have changed since. | In a pull request, run `.\tools\Update-Version.ps1`, commit the result, and merge it. Then start again from step 1. |
| A test or lint failure | The code on `main` fails its checks. | Fix it in a pull request, then update the changelog heading as in the first row, because that fix changes the version. |

`Update-Changelog.ps1` stops with similar messages if the Unreleased section is empty or the version already has a section.

## Good to know

- **Versions are automatic.** The pre-commit hook sets the version on any commit that touches `src/`. On a new clone, install it once with `.\tools\Update-Version.ps1 -InstallHook`.
- **The workflow never changes `main`.** The ruleset only accepts pull requests, so the changelog is prepared first and the workflow only reads it. The tag and release point at the commit the workflow ran on.
- **Taking a release back.** Delete it on the Releases page and delete its tag. Nothing on `main` changes, so the changelog section stays until you remove it in a pull request.
- **Adding checksums to a hand-made release.** Run the **Release checksums** workflow with the release's tag. Releases from the Release workflow already have them.
