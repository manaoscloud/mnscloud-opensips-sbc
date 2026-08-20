#!/usr/bin/env bash
set -Eeuo pipefail

OPENSIPS_CFG="${OPENSIPS_CFG:-/etc/opensips/opensips.cfg}"

echo "[validate-opensips-sbc] checking shell scripts"
bash -n "$(dirname "$0")/install-opensips-sbc.sh"
bash -n "$(dirname "$0")/sync-opensips-sbc-runtime.sh"
bash -n "$(dirname "$0")/sync-and-reload-opensips-sbc.sh"
bash -n "$(dirname "$0")/report-opensips-sbc-peer-status.sh"
bash -n "$(dirname "$0")/opensips-sbc-mi.sh"
bash -n "$(dirname "$0")/release-opensips-sbc.sh"
bash -n "$(dirname "$0")/update-opensips-sbc.sh"
bash -n "$(dirname "$0")/update-latest-opensips-sbc.sh"
bash -n "$(dirname "$0")/rollback-opensips-sbc.sh"

installer="$(dirname "$0")/install-opensips-sbc.sh"
grep -Fq 'socket=udp:${private_ip}:5060 as ${advertised_ip}:5060' "$installer" || {
  echo "[validate-opensips-sbc] installer must bind the private socket when advertising a public address" >&2
  exit 1
}
grep -Fq 'record_route_preset(\"${advertised_ip}:5060\", \"${private_ip}:5060\")' "$installer" || {
  echo "[validate-opensips-sbc] installer must keep dual Record-Route for private/public paths" >&2
  exit 1
}

if command -v opensips >/dev/null 2>&1 && [[ -r "$OPENSIPS_CFG" ]]; then
  echo "[validate-opensips-sbc] checking ${OPENSIPS_CFG}"
  opensips -C -f "$OPENSIPS_CFG"
else
  echo "[validate-opensips-sbc] opensips or ${OPENSIPS_CFG} not available; skipped runtime cfg check"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files opensips.service >/dev/null 2>&1; then
  systemctl is-enabled opensips >/dev/null 2>&1 || true
  systemctl is-active opensips >/dev/null 2>&1 || true
fi

echo "[validate-opensips-sbc] ok"
