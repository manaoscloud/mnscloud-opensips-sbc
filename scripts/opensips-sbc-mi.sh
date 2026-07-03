#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[opensips-sbc-mi]"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/install-base.sh" "$@"

MI_FIFO_DIR="/run/opensips"
MI_FIFO_FILE="${MI_FIFO_DIR}/mnscloud_sbc_fifo"
METHOD="${1:-}"
TIMEOUT_SECONDS="${MNSCLOUD_SBC_MI_TIMEOUT:-8}"

usage() {
  cat <<'USAGE'
Usage: scripts/opensips-sbc-mi.sh <mi-method>

Examples:
  sudo bash scripts/opensips-sbc-mi.sh reg_list
  sudo bash scripts/opensips-sbc-mi.sh reg_reload
USAGE
}

opensips_group() {
  if getent group opensips >/dev/null 2>&1; then
    printf "opensips"
  else
    printf "root"
  fi
}

main() {
  require_root
  if [[ -z "${METHOD}" || "${METHOD}" == "-h" || "${METHOD}" == "--help" ]]; then
    usage
    [[ -n "${METHOD}" ]] && exit 0
    exit 2
  fi

  [[ -p "${MI_FIFO_FILE}" ]] || {
    err "OpenSIPS MI FIFO not found: ${MI_FIFO_FILE}"
    exit 1
  }

  local request_id reply_name reply_fifo reply_body reader_pid response
  request_id="mnscloud-$(date +%s)-$$"
  reply_name="mnscloud_sbc_reply_$$"
  reply_fifo="${MI_FIFO_DIR}/${reply_name}"
  reply_body="$(mktemp)"

  rm -f "${reply_fifo}"
  mkfifo "${reply_fifo}"
  chown "root:$(opensips_group)" "${reply_fifo}" 2>/dev/null || true
  chmod 0660 "${reply_fifo}"

  timeout "${TIMEOUT_SECONDS}s" cat "${reply_fifo}" > "${reply_body}" &
  reader_pid="$!"

  printf ':%s:{"jsonrpc":"2.0","method":"%s","id":"%s"}\n' "${reply_name}" "${METHOD}" "${request_id}" > "${MI_FIFO_FILE}"
  if ! wait "${reader_pid}"; then
    rm -f "${reply_fifo}" "${reply_body}"
    err "OpenSIPS MI ${METHOD} did not reply within ${TIMEOUT_SECONDS}s"
    exit 1
  fi

  response="$(cat "${reply_body}")"
  rm -f "${reply_fifo}" "${reply_body}"
  printf '%s\n' "${response}"
  [[ "${response}" != *'"error"'* ]] || exit 1
}

main "$@"
