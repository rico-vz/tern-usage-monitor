# OMP Usage Monitor for Tern

See usage for every [omp](https://omp.sh) linked account in a floating or docked panel using
[Tern](https://stencil.so/tern). Works without an open omp session.

## Install

```sh
tern plugin install https://github.com/rico-vz/tern-usage-monitor
```

To use it, open the command palette in Tern and run **Usage Monitor: Open floating panel** or
**Usage Monitor: Open side panel**.

For development, use `tern plugin link /path/to/tern-usage-monitor` instead.

Requires `omp` on your `PATH` (or `OMP_USAGE_BIN` set to its path). On Windows it also needs
PowerShell and Windows Script Host.

## Controls

With the monitor focused:

| Key | Action |
| --- | --- |
| `r` | Refresh |
| `←`, `→` | Previous / next account |
| `a` | Show all accounts |
| `c` | Toggle compact view in the side panel |
| `s` | Open or close settings (`Esc` also closes them) |

## Settings

Click **Settings** in the panel footer to choose which accounts to show, how often usage refreshes
(30 seconds to 15 minutes, or manually), whether to show used or remaining quota, whether bars and
percentages are colored, the default view, the account order, and whether to show reset times and
the time since the last update. Settings are shared by every Tern window.

## Notes

- Refreshing manually also clears omp's usage cache.
- Hover an account or quota for the full account name, amount and reset credits.

If it isn't working, make sure `omp usage --json` works in a terminal and run `tern plugin list`
to check status.
