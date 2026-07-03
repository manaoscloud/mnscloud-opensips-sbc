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

opensips_group() {
  if getent group opensips >/dev/null 2>&1; then
    printf "opensips"
  else
    printf "root"
  fi
}

run_mi() {
  local method="$1" request_id reply_name reply_fifo reply_body response
  shift || true
  [[ -p "${MI_FIFO_FILE}" ]] ||
    { err "OpenSIPS MI FIFO not found: ${MI_FIFO_FILE}"; return 1; }

  request_id="mnscloud-$(date +%s)-$$"
  reply_name="mnscloud_sbc_reply_$$"
  reply_fifo="${MI_FIFO_DIR}/${reply_name}"
  reply_body="$(mktemp)"

  rm -f "${reply_fifo}"
  mkfifo "${reply_fifo}"
  chown "root:$(opensips_group)" "${reply_fifo}" 2>/dev/null || true
  chmod 0660 "${reply_fifo}"

  timeout 8s cat "${reply_fifo}" > "${reply_body}" &
  local reader_pid="$!"
  printf ':%s:{"jsonrpc":"2.0","method":"%s","id":"%s"}\n' "${reply_name}" "${method}" "${request_id}" > "${MI_FIFO_FILE}"
  wait "${reader_pid}" || {
    rm -f "${reply_fifo}" "${reply_body}"
    err "OpenSIPS MI ${method} did not reply"
    return 1
  }

  response="$(tr -d '\r\n' < "${reply_body}")"
  rm -f "${reply_fifo}" "${reply_body}"
  info "OpenSIPS MI ${method} response: ${response}"
  [[ "${response}" != *'"error"'* ]] ||
    { err "OpenSIPS MI ${method} returned an error"; return 1; }
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
