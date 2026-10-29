# No-sponsor fork: build and migration

This branch ports upstream PR #6845. The `main` branch remains untouched and tracks
MHSanaei/3x-ui.

- Opt-out requires `XUI_DISABLE_SPONSOR=true` in the x-ui process environment.
  It returns empty sponsor data, rejects logos, and prevents sponsor-source fetching.
  Sponsors navigation is not removed.
- Pinned-action CI builds a static **Linux amd64 panel binary only** and publishes
  immutable releases tagged `no-sponsor-<40-character commit SHA>`. Wait for a successful Actions run.
  It does **not** update Xray, geosite/geoip, certificates, system service files,
  or other bundled components.
- Supported updater: `scripts/update-no-sponsor.sh`. It checks SHA256 and archive
  layout; backs up the prior binary and `/etc/x-ui`; installs a systemd override
  to enable opt-out; updates only the x-ui binary; and restarts the service.
- It supports conventional Linux x86_64 **systemd** installations, not Docker.
  If XUI_DB_FOLDER, XUI_MAIN_FOLDER, or service ExecStart are customized, review
  the script before running. Restoring an older binary might also require
  restoring the matching database backup after schema migrations.

## On an existing VPS

First take a VPS snapshot and confirm that `systemctl cat x-ui` shows
`ExecStart=/usr/local/x-ui/x-ui` and that `/etc/x-ui` contains the live data.
Review the file from this fork, then invoke:

```bash
curl -fsSLo /root/update-no-sponsor.sh \
  https://raw.githubusercontent.com/SHD-ISAC/ui/no-sponsor/scripts/update-no-sponsor.sh
less /root/update-no-sponsor.sh
sudo bash /root/update-no-sponsor.sh
sudo systemctl status x-ui
```

Check your panel, inbound ports, subscription links, and client connectivity.
The updater uses Python 3 to select the newest published immutable no-sponsor release with both required assets. Set `XUI_NO_SPONSOR_TAG=no-sponsor-<full commit SHA>` to install a specific release.

The official built-in updater, upstream install script and `x-ui` menu still
target MHSanaei/3x-ui: **do not use their Update functions**, as they could
overwrite your patch. Continue using the updater above, downloading a fresh
copy each time.

## Syncing upstream

Sync `main` with upstream; merge or rebase approved upstream commits into
`no-sponsor`; resolve conflicts and run tests. Avoid merging `no-sponsor` into
`main`. A push to `no-sponsor` builds a new prerelease.
