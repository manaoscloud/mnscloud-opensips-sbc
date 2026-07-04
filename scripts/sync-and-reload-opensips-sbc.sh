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

removed_registrants() {
  local before_file="$1" after_file="$2"
  python3 - "$before_file" "$after_file" <<'PY'
import sys

def split_dbtext(line: str) -> list[str]:
    fields = []
    current = []
    escaped = False
    for char in line.rstrip("\n"):
        if escaped:
            if char == "n":
                current.append("\n")
            elif char == "r":
                current.append("\r")
            elif char == "t":
                current.append("\t")
            else:
                current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append("".join(current))
            current = []
        else:
            current.append(char)
    fields.append("".join(current))
    return fields

def keys(path: str) -> set[tuple[str, str, str]]:
    values = set()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for idx, line in enumerate(handle):
                if idx == 0 or not line.strip():
                    continue
                fields = split_dbtext(line)
                if len(fields) < 8:
                    continue
                registrar = fields[1].strip()
                aor = fields[3].strip()
                contact = fields[7].strip()
                if aor and contact and registrar:
                    values.add((aor, contact, registrar))
    except FileNotFoundError:
        pass
    return values

before = keys(sys.argv[1])
after = keys(sys.argv[2])
for aor, contact, registrar in sorted(before - after):
    print(f"{aor}\t{contact}\t{registrar}")
PY
}

opensips_group() {
  if getent group opensips >/dev/null 2>&1; then
    printf "opensips"
  else
    printf "root"
  fi
}

run_mi() {
  local method="$1" request_id reply_name reply_fifo reply_body response payload params_json arg key value
  shift || true
  [[ -p "${MI_FIFO_FILE}" ]] ||
    { err "OpenSIPS MI FIFO not found: ${MI_FIFO_FILE}"; return 1; }
  command -v jq >/dev/null 2>&1 ||
    { err "jq is required to build OpenSIPS MI JSON-RPC payloads"; return 1; }

  request_id="mnscloud-$(date +%s)-$$"
  reply_name="mnscloud_sbc_reply_$$"
  reply_fifo="${MI_FIFO_DIR}/${reply_name}"
  reply_body="$(mktemp)"
  params_json="{}"

  for arg in "$@"; do
    if [[ "${arg}" != *=* ]]; then
      err "Invalid OpenSIPS MI parameter '${arg}'. Use name=value."
      return 2
    fi
    key="${arg%%=*}"
    value="${arg#*=}"
    params_json="$(jq --arg key "${key}" --arg value "${value}" '. + {($key): $value}' <<<"${params_json}")"
  done

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
    run_mi reg_force_register "aor=${aor}" "contact=${contact}" "registrar=${registrar}" || return 1
  done
}

disable_removed_registrants() {
  local before_file="$1" after_file="$2"
  [[ -r "${before_file}" ]] || return 0
  [[ -r "${after_file}" ]] || return 0

  removed_registrants "${before_file}" "${after_file}" |
    while IFS=$'\t' read -r aor contact registrar; do
      [[ -n "${aor}" && -n "${contact}" && -n "${registrar}" ]] || continue
      if run_mi reg_disable "aor=${aor}" "contact=${contact}" "registrar=${registrar}"; then
        info "OpenSIPS disabled removed registrant: ${aor} ${contact} ${registrar}"
      else
        warn "OpenSIPS could not disable removed registrant before reload: ${aor} ${contact} ${registrar}"
      fi
    done
}

reload_registrants_if_changed() {
  local before="$1" after="$2" before_file="$3" after_file="$4"
  if [[ "${before}" == "${after}" ]]; then
    if [[ "${FORCE_REGISTER}" == "true" ]]; then
      force_active_registrants
    fi
    ok "SBC registrants unchanged; OpenSIPS MI reload not required"
    return 0
  fi

  disable_removed_registrants "${before_file}" "${after_file}"
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

  local registrant_before registrant_after media_before media_after registrant_before_file
  registrant_before_file="$(mktemp)"
  trap "rm -f '${registrant_before_file}'" EXIT
  registrant_before="$(file_checksum "${DBTEXT_DIR}/registrant")"
  if [[ -r "${DBTEXT_DIR}/registrant" ]]; then
    cp "${DBTEXT_DIR}/registrant" "${registrant_before_file}"
  fi
  media_before="$(file_checksum "${MEDIA_SOCKET_FILE}")"
  bash "${SCRIPT_DIR}/sync-opensips-sbc-runtime.sh"
  registrant_after="$(file_checksum "${DBTEXT_DIR}/registrant")"
  media_after="$(file_checksum "${MEDIA_SOCKET_FILE}")"
  reload_registrants_if_changed "${registrant_before}" "${registrant_after}" "${registrant_before_file}" "${DBTEXT_DIR}/registrant"
  restart_when_static_runtime_changed "${media_before}" "${media_after}"
}

main "$@"
