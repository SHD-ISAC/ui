#!/usr/bin/env bash
# SHA256-verified panel-only updater from SHD-ISAC/ui immutable no-sponsor releases.
# For conventional existing Linux amd64 systemd installations. Does not touch Xray core.
set -Eeuo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

[[ "$EUID" -eq 0 ]] || die "Run as root"
for cmd in curl sha256sum tar awk install systemctl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done
[[ "$(uname -m)" == "x86_64" ]] || die "Only Linux x86_64 is currently supported"
systemctl cat x-ui.service >/dev/null 2>&1 || die "x-ui systemd service not found (Docker unsupported)"
systemctl is-active --quiet x-ui.service || die "x-ui must be running before update"

target="${XUI_MAIN_FOLDER:-/usr/local/x-ui}/x-ui"
[[ -f "$target" && ! -L "$target" ]] || die "Existing panel binary not found: $target"
[[ -d /etc/x-ui ]] || die "Expected /etc/x-ui; check custom database paths first"

temp="$(mktemp -d /var/tmp/xui-no-sponsor.XXXXXXXX)"
backup=""
restart_on_failure=0
finish() {
  rc=$?
  if [[ "$rc" -ne 0 && "$restart_on_failure" -eq 1 ]]; then
    log "Restoring previous binary and restarting service"
    [[ -z "$backup" ]] || cp -p "$backup" "$target" || true
    systemctl daemon-reload || true
    systemctl restart x-ui.service || true
  fi
  rm -rf "$temp"
}
trap finish EXIT

# GitHub protects tags against replacement. Each release has a unique commit tag.
# Select the newest published release with BOTH required assets, not the
# official repository's latest or any stale no-sponsor-latest rolling tag.
tag="${XUI_NO_SPONSOR_TAG:-}"
if [[ -z "$tag" ]]; then
  api="https://api.github.com/repos/SHD-ISAC/ui/releases?per_page=100"
  curl -fsSL --retry 4 --connect-timeout 20 --max-time 60 \
    -o "$temp/releases.json" "$api"
  tag="$(python3 - "$temp/releases.json" <<'PY'
import json
import re
import sys
from pathlib import Path

releases = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
required = {"x-ui-linux-amd64.tar.gz", "x-ui-linux-amd64.tar.gz.sha256"}
eligible = [
    r for r in releases
    if re.fullmatch(r"no-sponsor-[0-9a-f]{40}", r.get("tag_name", ""))
    and not r.get("draft")
    and r.get("published_at")
    and required.issubset({asset.get("name") for asset in r.get("assets", [])})
]
eligible.sort(key=lambda r: r["published_at"], reverse=True)
if eligible:
    print(eligible[0]["tag_name"])
PY
)"
  [[ -n "$tag" ]] || die "No verified no-sponsor release with Linux amd64 assets found"
fi
[[ "$tag" =~ ^no-sponsor-[0-9a-f]{40}$ ]] || die "Invalid or obsolete release tag: $tag"

asset=x-ui-linux-amd64.tar.gz
url="https://github.com/SHD-ISAC/ui/releases/download/$tag/$asset"
log "Installing from immutable release $tag"
curl -fL --retry 4 --connect-timeout 20 --max-time 300 -o "$temp/$asset" "$url"
curl -fL --retry 4 --connect-timeout 20 --max-time 60 -o "$temp/$asset.sha256" "$url.sha256"

expected="$(awk -v f="$asset" '$2==f {print $1}' "$temp/$asset.sha256")"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "Invalid release SHA256 sidecar"
(cd "$temp" && printf '%s  %s\n' "$expected" "$asset" | sha256sum --check --status -) ||
  die "SHA256 mismatch; old installation unchanged"
[[ "$(tar -tzf "$temp/$asset")" == "x-ui" ]] || die "Unexpected archive layout"
tar -xzf "$temp/$asset" -C "$temp" x-ui
[[ -s "$temp/x-ui" && ! -L "$temp/x-ui" ]] || die "Invalid extracted panel binary"

backup_dir=/root/x-ui-no-sponsor-backups
install -d -m 0700 "$backup_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$backup_dir/x-ui.$stamp.bak"
cp -p "$target" "$backup"
stage="$target.new.$$"
install -m 0755 "$temp/x-ui" "$stage"
log "Stopping x-ui and backing up /etc/x-ui"
systemctl stop x-ui.service
restart_on_failure=1
tar -C /etc -czf "$backup_dir/etc-x-ui.$stamp.tar.gz" x-ui
mv -f "$stage" "$target"

install -d -m 0755 /etc/systemd/system/x-ui.service.d
printf '[Service]\nEnvironment="XUI_DISABLE_SPONSOR=true"\n' > "$temp/20-no-sponsor.conf"
install -m 0644 "$temp/20-no-sponsor.conf" /etc/systemd/system/x-ui.service.d/20-no-sponsor.conf
systemctl daemon-reload
systemctl restart x-ui.service
systemctl is-active --quiet x-ui.service || die "New x-ui failed to start"
restart_on_failure=0
log "Success. Old binary: $backup"
log "Data snapshot: $backup_dir/etc-x-ui.$stamp.tar.gz"
log "If downgrading after DB schema migrations, also restore the matching DB snapshot."
