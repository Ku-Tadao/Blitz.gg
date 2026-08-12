# Blitz.gg

Standalone home for the Blitz.gg utilities previously kept under `IPostWeirdStuffHere/Blitz.gg`.

## Repository Layout

- `Troubleshooter/` - WPF desktop app for diagnosing and fixing common Blitz.gg issues
- `Portable/` - Portable ZIP artifact updated by GitHub Actions

## Development

Open `Troubleshooter/Blitz Troubleshooter.sln` in Visual Studio or build it with the .NET SDK.

The portable ZIP is refreshed by `.github/workflows/update-blitz-portable.yml`.

## Portable updater

The updater extracts the signed Blitz application payload from the installer
with a pinned portable 7-Zip tool. It does not execute the Blitz installer, so
it can continue to refresh the archive when a new installer crashes on the
GitHub Windows runner.

Manual runs are dry-runs by default and upload the candidate archive plus
manifests for review:

```powershell
gh workflow run update-blitz-portable.yml `
  --ref master `
  -f installer_url=https://blitz.gg/download/win `
  -f publish=false
```

After reviewing the candidate artifact, a maintainer can explicitly publish
from `master`:

```powershell
gh workflow run update-blitz-portable.yml `
  --ref master `
  -f installer_url=https://blitz.gg/download/win `
  -f publish=true
```

The portable archive contains the application payload only. It intentionally
does not contain `Uninstall Blitz.exe`, because a portable archive should not
register or remove an installed application.

For app behavior and end-user details, see `Troubleshooter/README.md`.
