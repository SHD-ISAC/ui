#!/usr/bin/env bash
# Safe binary-only update for SHD-ISAC/ui no-sponsor releases; systemd amd64 only.
set -Eeuo pipefail
umask 077
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }
[[ "$EUID" -eq 0 ]] || die "Run this script with sudo/root"
for cmd in curl sha256sum tar awk install systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done
[[ "$(uname -m)" == "x86_64" ]] || die "Only Linux x86_64 is currently supported"
systemctl cat x-ui.service >/dev/null 2>&1 || die "x-ui systemd service not found (Docker unsupported)"
systemctl is-active --quiet x-ui.service || die "x-ui must be running before update"
tag="${XUI_NO_SPONSOR_TAG:-no-sponsor-latest}"
[[ "$tag" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid release tag"
asset=x-ui-linux-amd64.tar.gz
url="https://github.com/SHD-ISAC/ui/releases/download/$tag/$asset"
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
log "Downloading from $url"
curl -fL --retry 4 --connect-timeout 20 --max-time 300 -o "$temp/$asset" "$url"
curl -fL --retry 4 --connect-timeout 20 --max-time 60 -o "$temp/$asset.sha256" "$url.sha256"
expected="$(awk -v f="$asset" '$2==f {print $1}' "$temp/$asset.sha256")"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "Invalid SHA256 sidecar"
(cd "$temp" && printf '%s  %s\n' "$expected" "$asset" | sha256sum --check --status -) ||
  die "SHA256 mismatch, old installation unchanged"
[[ "$(tar -tzf "$temp/$asset")" == "x-ui" ]] || die "Unexpected tar contents"
tar -xzf "$temp/$asset" -C "$temp" x-ui
[[ -s "$temp/x-ui" && ! -L "$temp/x-ui" ]] || die "Missing or invalid panel binary"
backup_dir=/root/x-ui-no-sponsor-backups
install -d -m 0700 "$backup_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$backup_dir/x-ui.$stamp.bak"
cp -p "$target" "$backup"
stage="$target.new.$$"
install -m 0755 "$temp/x-ui" "$stage"
log "Stopping x-ui, backing up config and switching binary"
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
log "Database migrations may require manual DB restore when downgrading."
