# Blitz.gg

Standalone home for the Blitz.gg utilities previously kept under `IPostWeirdStuffHere/Blitz.gg`.

## Repository Layout

- `Troubleshooter/` - WPF desktop app for diagnosing and fixing common Blitz.gg issues
- `Portable/` - Portable ZIP artifact updated by GitHub Actions

## Development

Open `Troubleshooter/Blitz Troubleshooter.sln` in Visual Studio or build it with the .NET SDK.

The portable ZIP is refreshed by `.github/workflows/update-blitz-portable.yml`.

For app behavior and end-user details, see `Troubleshooter/README.md`.