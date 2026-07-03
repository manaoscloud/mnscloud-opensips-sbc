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
FORCE_REGISTER="${MNSCLOUD_SBC_FORCE_REGISTER:-false}"

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
  local method="$1" params_json="${2:-{}}" request_id reply_name reply_fifo reply_body response payload
  shift || true
  [[ -p "${MI_FIFO_FILE}" ]] ||
    { err "OpenSIPS MI FIFO not found: ${MI_FIFO_FILE}"; return 1; }
  command -v jq >/dev/null 2>&1 ||
    { err "jq is required to build OpenSIPS MI JSON-RPC payloads"; return 1; }

  request_id="mnscloud-$(date +%s)-$$"
  reply_name="mnscloud_sbc_reply_$$"
  reply_fifo="${MI_FIFO_DIR}/${reply_name}"
  reply_body="$(mktemp)"
  if [[ "${params_json}" == "{}" ]]; then
    payload="$(jq -nc --arg method "${method}" --arg id "${request_id}" '{jsonrpc:"2.0", method:$method, id:$id}')"
  else
    payload="$(printf '%s' "${params_json}" | jq -c --arg method "${method}" --arg id "${request_id}" '{jsonrpc:"2.0", method:$method, params:., id:$id}')"
  fi

  rm -f "${reply_fifo}"
  mkfifo "${reply_fifo}"
  chown "root:$(opensips_group)" "${reply_fifo}" 2>/dev/null || true
  chmod 0660 "${reply_fifo}"

  timeout 8s cat "${reply_fifo}" > "${reply_body}" &
  local reader_pid="$!"
  printf ':%s:%s\n' "${reply_name}" "${payload}" > "${MI_FIFO_FILE}"
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

force_active_registrants() {
  local config_file="${RUNTIME_DIR}/config.json"
  [[ -r "${config_file}" ]] || {
    warn "SBC runtime config not found; cannot force REGISTER"
    return 0
  }

  jq -r '
    def clean: if . == null then "" else tostring | gsub("^\\s+|\\s+$"; "") end;
    def sipuri:
      (clean) as $v
      | if $v == "" then ""
        elif ($v | test("^sips?:")) then $v
        else "sip:" + $v
        end;
    def siphost($host; $port; $transport):
      ($host | clean) as $h
      | ($port // 5060) as $p
      | ($transport // "udp" | clean | ascii_downcase) as $t
      | if $h == "" then "" else "sip:" + $h + ":" + ($p|tostring) + ";transport=" + $t end;
    def aor($peer):
      if (($peer.aor // "") | clean) != "" then ($peer.aor | sipuri)
      elif (($peer.authUsername // "") | clean) != "" and (($peer.fromDomain // $peer.registrarHost // "") | clean) != "" then "sip:" + ($peer.authUsername | clean) + "@" + (($peer.fromDomain // $peer.registrarHost) | clean)
      else ""
      end;
    def binding($root; $peer):
      ($peer.contactUser // $peer.authUsername // "sbc") as $user
      | ($peer.contactDomain // $root.server.publicIP // $root.server.privateIP // $root.server.hostname // "") as $domain
      | if ($domain | clean) == "" then "" else "sip:" + ($user | clean) + "@" + ($domain | clean) end;
    . as $root
    | $root.peers[]?
    | select((.authMode == "register" or .registerEnabled == 1) and .authUsername and .authPassword)
    | [aor(.), binding($root; .), siphost(.registrarHost; (.registrarPort // 5060); (.registrarTransport // "udp"))]
    | select(.[0] != "" and .[1] != "" and .[2] != "")
    | @tsv
  ' "${config_file}" | while IFS=$'\t' read -r aor contact registrar; do
    [[ -n "${aor}" && -n "${contact}" && -n "${registrar}" ]] || continue
    local payload
    payload="$(jq -nc --arg aor "${aor}" --arg contact "${contact}" --arg registrar "${registrar}" '{aor:$aor, contact:$contact, registrar:$registrar}')"
    run_mi reg_force_register "${payload}" || return 1
  done
}

reload_registrants_if_changed() {
  local before="$1" after="$2"
  if [[ "${before}" == "${after}" ]]; then
    if [[ "${FORCE_REGISTER}" == "true" ]]; then
      force_active_registrants
    fi
    ok "SBC registrants unchanged; OpenSIPS MI reload not required"
    return 0
  fi

  run_mi reg_reload
  force_active_registrants
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
