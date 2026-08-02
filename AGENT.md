# AGENT

## Build Safety

- Before running `flutter build` or launching a newly built local binary, back up the app runtime config files first.
- Treat the user config as outside-the-repo state that may be changed by the app during startup, migration, or first-run checks.
- Ask the user for the exact config file path if it is not already known.
- Do not assume a build is side-effect free for local app data.
- Do not store runtime config or database backups inside `build/` because Flutter rebuilds may delete or recreate that directory.

## Preferred Workflow

- Before risky local verification, create a git commit or otherwise ensure code changes can be rolled back.
- Before build/run verification, back up the current ClipShare runtime config.
- Put backups in a safe location outside `build/`, such as a dedicated `backups/` directory or a user data directory.
- After verification, tell the user whether any runtime data or cache files were created or changed.

## Linux Notes

- On this machine, ClipShare may use cache and log paths under `~/.cache/top.coclyun.clipshare`.
- Wayland-specific clipboard experiments may create temporary `wl-clip-*.png` files in the app cache directory.
