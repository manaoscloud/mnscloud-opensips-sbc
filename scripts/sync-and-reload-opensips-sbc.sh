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
MI_FIFO_DIR="/run/opensips"
MI_FIFO_FILE="${MI_FIFO_DIR}/mnscloud_sbc_fifo"

file_checksum() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    sha256sum "${file}" | awk '{print $1}'
  else
    printf 'missing\n'
  fi
}

run_mi() {
  command -v opensips-cli >/dev/null 2>&1 ||
    { err "opensips-cli is required for realtime MI operations"; return 1; }
  [[ -p "${MI_FIFO_FILE}" ]] ||
    { err "OpenSIPS MI FIFO not found: ${MI_FIFO_FILE}"; return 1; }

  opensips-cli \
    -o communication_type=fifo \
    -o fifo_file="${MI_FIFO_FILE}" \
    -o fifo_reply_dir="${MI_FIFO_DIR}" \
    -o output_type=none \
    -x mi "$@" >>"${LOG_FILE}" 2>&1
}

reload_registrants_if_changed() {
  local before="$1" after="$2"
  if [[ "${before}" == "${after}" ]]; then
    ok "SBC registrants unchanged; OpenSIPS MI reload not required"
    return 0
  fi

  run_mi reg_reload
  ok "SBC registrants changed; OpenSIPS uac_registrant reloaded via MI"
}

restart_when_static_runtime_changed() {
  local before="$1" after="$2"
  if [[ "${before}" == "${after}" ]]; then
    return 0
  fi

  warn "SBC media socket changed; OpenSIPS static config requires restart"
  run "opensips -C -f '${OPENSIPS_CFG}'"
  run "systemctl restart opensips"
  run "systemctl is-active opensips"
}

main() {
  require_root
  echo "opensips         SBC runtime sync + reload"
  echo "Mode: $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"
  echo "Log:  ${LOG_FILE}"
  echo "=================================================="

  if [[ "$DRY_RUN" == true ]]; then
    log DRY "bash '${SCRIPT_DIR}/sync-opensips-sbc-runtime.sh' --dry-run"
    log DRY "reload uac_registrant through OpenSIPS MI only when registrants changed"
    return 0
  fi

  local registrant_before registrant_after media_before media_after
  registrant_before="$(file_checksum "${DBTEXT_DIR}/registrant")"
  media_before="$(file_checksum "${MEDIA_SOCKET_FILE}")"
  bash "${SCRIPT_DIR}/sync-opensips-sbc-runtime.sh"
  registrant_after="$(file_checksum "${DBTEXT_DIR}/registrant")"
  media_after="$(file_checksum "${MEDIA_SOCKET_FILE}")"
  reload_registrants_if_changed "${registrant_before}" "${registrant_after}"
  restart_when_static_runtime_changed "${media_before}" "${media_after}"
}

main "$@"
