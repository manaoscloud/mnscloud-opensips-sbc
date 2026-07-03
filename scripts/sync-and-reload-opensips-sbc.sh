#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[sync-and-reload-opensips-sbc]"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/install-base.sh" "$@"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="/etc/mnscloud/sbc/runtime"
DBTEXT_DIR="/etc/mnscloud/sbc/dbtext"
MEDIA_SOCKET_FILE="/etc/mnscloud/sbc/media.socket"
OPENSIPS_CFG="/etc/opensips/opensips.cfg"

runtime_checksum() {
  local files=(
    "${RUNTIME_DIR}/config.json"
    "${RUNTIME_DIR}/summary.json"
    "${DBTEXT_DIR}/version"
    "${DBTEXT_DIR}/registrant"
    "${MEDIA_SOCKET_FILE}"
  )
  local file
  for file in "${files[@]}"; do
    if [[ -f "${file}" ]]; then
      sha256sum "${file}"
    else
      printf 'missing  %s\n' "${file}"
    fi
  done | sha256sum | awk '{print $1}'
}

reload_opensips_if_changed() {
  local before="$1" after="$2"
  if [[ "${before}" == "${after}" ]]; then
    ok "SBC runtime unchanged; OpenSIPS restart not required"
    return 0
  fi

  run "opensips -C -f '${OPENSIPS_CFG}'"
  run "systemctl restart opensips"
  run "systemctl is-active opensips"
  ok "SBC runtime changed; OpenSIPS restarted"
}

main() {
  require_root
  echo "opensips         SBC runtime sync + reload"
  echo "Mode: $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"
  echo "Log:  ${LOG_FILE}"
  echo "=================================================="

  if [[ "$DRY_RUN" == true ]]; then
    log DRY "bash '${SCRIPT_DIR}/sync-opensips-sbc-runtime.sh' --dry-run"
    log DRY "restart opensips only when runtime files changed"
    return 0
  fi

  local before after
  before="$(runtime_checksum)"
  bash "${SCRIPT_DIR}/sync-opensips-sbc-runtime.sh"
  after="$(runtime_checksum)"
  reload_opensips_if_changed "${before}" "${after}"
}

main "$@"
