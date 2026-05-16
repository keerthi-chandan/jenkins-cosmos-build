# Runbook

## Build

Build with Parameters → pick chain → Build.

Console output ends with `<daemon> version` line on success.

## Approx build times

- Babylon: 7–10 min cold, 3–4 min warm
- Celestia: 5–8 min cold
- Noble: 4–6 min cold

## Things that broke for me

**OOM during compile** — t3.micro is tight on RAM. Userdata adds 2 GB swap; if you skipped that, add it.

**`make install` ok but binary not on PATH** — `make install` drops it in `$GOPATH/bin`. Jenkinsfile prepends that to PATH in the `environment` block.

**Bad tag on checkout** — chain repo doesn't have that version. Check the releases page and update the `VERSION` in the case statement.
