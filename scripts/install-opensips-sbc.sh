#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[install-opensips-sbc]"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/install-base.sh" "$@"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NODE_UUID_FILE="/etc/mnscloud/sbc/node.uuid"
API_TOKEN_FILE="/etc/mnscloud/sbc/api.token"
API_BASE_FILE="/etc/mnscloud/sbc/api.base"
MEDIA_SOCKET_FILE="/etc/mnscloud/sbc/media.socket"
DBTEXT_DIR="/etc/mnscloud/sbc/dbtext"
MI_FIFO_DIR="/run/opensips"
MI_FIFO_FILE="${MI_FIFO_DIR}/mnscloud_sbc_fifo"
AGENT_REPO_INSTALLER="/opt/mnscloud/mnscloud-agent/scripts/install-agent.sh"
AGENT_VALIDATOR="/opt/mnscloud/mnscloud-agent/scripts/validate-agent.sh"
DEFAULT_API_BASE="${MNSCLOUD_API_BASE:-https://api.example.com}"
SBC_ENGINE="${MNSCLOUD_SBC_ENGINE:-opensips}"
NODE_UUID="${MNSCLOUD_SBC_NODE_UUID:-}"
API_BASE=""
API_TOKEN="${MNSCLOUD_SBC_API_TOKEN:-}"
MEDIA_SOCKET=""
OPENSIPS_RUNTIME_KIT_DIR="${OPENSIPS_RUNTIME_KIT_DIR:-/opt/mnscloud/runtime-kit}"
OPENSIPS_RUNTIME_KIT_REPO_URL="${OPENSIPS_RUNTIME_KIT_REPO_URL:-https://github.com/manaoscloud/mnscloud-runtime-kit.git}"
OPENSIPS_RUNTIME_KIT_CHANNEL="${OPENSIPS_RUNTIME_KIT_CHANNEL:-stable}"
OPENSIPS_RUNTIME_KIT_REF="${OPENSIPS_RUNTIME_KIT_REF:-}"

normalize_url() {
  local value="$1"
  value="$(printf "%s" "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s#/*$##')"
  printf "%s" "$value"
}

validate_api_base() {
  [[ "$1" =~ ^https?://[^[:space:]/]+(:[0-9]+)?(/[^[:space:]]*)?$ ]]
}

validate_mnscloud_agent() {
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "bash '${AGENT_VALIDATOR}' --require-active --require-enrolled --require-job voip.sbc.runtime"
    return 0
  fi

  [[ -x "${AGENT_VALIDATOR}" ]] ||
    { err "mnscloud-agent validator not found at ${AGENT_VALIDATOR}. Update/reinstall the Agent before installing the SBC."; return 1; }
  bash "${AGENT_VALIDATOR}" --require-active --require-enrolled --require-job voip.sbc.runtime
}

refresh_agent_capabilities() {
  local install_label
  install_label="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'mnscloud-agent')"
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "refresh mnscloud-agent capabilities so it publishes voip.sbc.manage"
    return 0
  fi

  if [[ -x "${AGENT_REPO_INSTALLER}" ]]; then
    info "Refreshing mnscloud-agent capabilities after SBC runtime install."
    bash "${AGENT_REPO_INSTALLER}" --api-base "${API_BASE}" --install-label "${install_label}"
    return 0
  fi

  warn "mnscloud-agent source repo not found at ${AGENT_REPO_INSTALLER}; restarting service so runtime capability detection can refresh."
  run "systemctl restart mnscloud-agent"
}

prompt_api_base() {
  local value=""
  if [[ -t 0 ]]; then
    read -r -p "Enter the MNSCloud API base URL [${DEFAULT_API_BASE}]: " value
  fi
  value="${value:-${DEFAULT_API_BASE}}"
  normalize_url "$value"
}

ensure_api_base_file() {
  local dir value
  dir="$(dirname "${API_BASE_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"

  if [[ -n "${MNSCLOUD_API_BASE:-}" ]]; then
    API_BASE="$(normalize_url "${MNSCLOUD_API_BASE}")"
    validate_api_base "${API_BASE}" || { err "URL base da API invalida: ${API_BASE}"; return 1; }
    write_file "${API_BASE_FILE}" "${API_BASE}"
    ok "API base saved from environment to ${API_BASE_FILE}: ${API_BASE}"
  elif [[ -f "${API_BASE_FILE}" ]]; then
    value="$(tr -d '[:space:]' < "${API_BASE_FILE}")"
    API_BASE="$(normalize_url "$value")"
    ok "API base carregada de ${API_BASE_FILE}: ${API_BASE}"
  else
    API_BASE="$(prompt_api_base)"
    validate_api_base "${API_BASE}" || { err "URL base da API invalida: ${API_BASE}"; return 1; }
    write_file "${API_BASE_FILE}" "${API_BASE}"
    ok "API base saved to ${API_BASE_FILE}: ${API_BASE}"
  fi

  validate_api_base "${API_BASE}" || { err "URL base da API invalida em ${API_BASE_FILE}: ${API_BASE}"; return 1; }
  run "chown root:root '${API_BASE_FILE}'"
  run "chmod 0640 '${API_BASE_FILE}'"
}

detect_opensips_os() {
  [[ -r /etc/os-release ]] || { err "Could not read /etc/os-release"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:12) echo "debian"; return 0 ;;
    rocky:8*|rocky:9*) echo "rocky"; return 0 ;;
  esac
  err "Unsupported operating system for OpenSIPS. Supported: Debian 12 and Rocky 8/9."
  exit 2
}

resolve_runtime_kit_ref() {
  local kit_dir="$1" channel="$2" manifest ref
  manifest="$(git -C "$kit_dir" show "origin/main:releases/manifest.json" 2>/dev/null)" ||
    { err "cannot read runtime kit release manifest from origin/main"; return 1; }
  ref="$(printf '%s\n' "$manifest" | awk -v channel="$channel" '
    $0 ~ "\"" channel "\"" { in_channel = 1; next }
    in_channel && /"ref"[[:space:]]*:/ {
      gsub(/.*"ref"[[:space:]]*:[[:space:]]*"/, "")
      gsub(/".*/, "")
      print
      exit
    }
    in_channel && /^[[:space:]]*}/ { in_channel = 0 }
  ')"
  [[ "$ref" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
    { err "invalid runtime kit ref for channel ${channel}: ${ref:-empty}"; return 1; }
  printf '%s\n' "$ref"
}

load_runtime_kit() {
  [[ "${OPENSIPS_RUNTIME_KIT_LOADED:-0}" == "1" ]] && return 0
  command -v git >/dev/null 2>&1 || run "if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y --no-install-recommends ca-certificates git; else dnf install -y ca-certificates git; fi"
  if [[ -d "${OPENSIPS_RUNTIME_KIT_DIR}/.git" ]]; then
    run "git -C '${OPENSIPS_RUNTIME_KIT_DIR}' fetch --all --tags --prune"
  else
    run "install -d -m 0755 '$(dirname "$OPENSIPS_RUNTIME_KIT_DIR")'"
    run "git clone '${OPENSIPS_RUNTIME_KIT_REPO_URL}' '${OPENSIPS_RUNTIME_KIT_DIR}'"
  fi
  if [[ -z "$OPENSIPS_RUNTIME_KIT_REF" ]]; then
    OPENSIPS_RUNTIME_KIT_REF="$(resolve_runtime_kit_ref "$OPENSIPS_RUNTIME_KIT_DIR" "$OPENSIPS_RUNTIME_KIT_CHANNEL")"
    info "Resolved runtime kit ${OPENSIPS_RUNTIME_KIT_CHANNEL} channel to ${OPENSIPS_RUNTIME_KIT_REF}"
  fi
  run "git -C '${OPENSIPS_RUNTIME_KIT_DIR}' -c advice.detachedHead=false checkout '${OPENSIPS_RUNTIME_KIT_REF}'"
  git -C "$OPENSIPS_RUNTIME_KIT_DIR" pull --ff-only origin "$OPENSIPS_RUNTIME_KIT_REF" 2>/dev/null || true
  [[ -r "${OPENSIPS_RUNTIME_KIT_DIR}/lib/packages.sh" ]] || { err "runtime kit packages library not found"; return 1; }
  export MNSCLOUD_RUNTIME_KIT_LOG_PREFIX="mnscloud-opensips-sbc/runtime-kit"
  # shellcheck disable=SC1091
  source "${OPENSIPS_RUNTIME_KIT_DIR}/lib/packages.sh"
  OPENSIPS_RUNTIME_KIT_LOADED=1
}

generate_uuid() { [[ -r /proc/sys/kernel/random/uuid ]] && tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid && return 0; command -v uuidgen >/dev/null 2>&1 && uuidgen | tr '[:upper:]' '[:lower:]'; }

generate_secret_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
    return 0
  fi
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

ensure_api_token_file() {
  local dir
  dir="$(dirname "${API_TOKEN_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"

  if [[ -n "${API_TOKEN}" ]]; then
    write_file "${API_TOKEN_FILE}" "${API_TOKEN}"
    ok "SBC API token saved from environment to ${API_TOKEN_FILE}"
  elif [[ -f "${API_TOKEN_FILE}" ]]; then
    API_TOKEN="$(tr -d '[:space:]' < "${API_TOKEN_FILE}")"
    ok "SBC API token loaded from ${API_TOKEN_FILE}"
  else
    API_TOKEN="$(generate_secret_32)"
    write_file "${API_TOKEN_FILE}" "${API_TOKEN}"
    ok "SBC API token created at ${API_TOKEN_FILE}"
  fi

  run "chown root:root '${API_TOKEN_FILE}'"
  run "chmod 0640 '${API_TOKEN_FILE}'"
}

ensure_node_uuid_file() {
  local dir compact
  dir="$(dirname "${NODE_UUID_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"
  if [[ -n "${NODE_UUID}" ]]; then
    write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
    ok "Node UUID saved from environment to ${NODE_UUID_FILE}: ${NODE_UUID}"
  elif [[ -f "${NODE_UUID_FILE}" ]]; then
    NODE_UUID="$(tr -d '[:space:]' < "${NODE_UUID_FILE}")"
    ok "Node UUID loaded from ${NODE_UUID_FILE}: ${NODE_UUID}"
  else
    NODE_UUID="$(generate_uuid)"
    write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
    ok "Node UUID created at ${NODE_UUID_FILE}: ${NODE_UUID}"
  fi
  compact="${NODE_UUID//-/}"
  [[ "${compact}" =~ ^[0-9A-Fa-f]{32}$ ]] || { err "Node UUID invalido em ${NODE_UUID_FILE}: ${NODE_UUID}"; return 1; }
  compact="$(echo "${compact}" | tr '[:upper:]' '[:lower:]')"
  NODE_UUID="${compact:0:8}-${compact:8:4}-${compact:12:4}-${compact:16:4}-${compact:20:12}"
  write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
  run "chown root:root '${NODE_UUID_FILE}'"
  run "chmod 0640 '${NODE_UUID_FILE}'"
}

load_media_socket_file() {
  if [[ -f "${MEDIA_SOCKET_FILE}" ]]; then
    MEDIA_SOCKET="$(tr -d '[:space:]' < "${MEDIA_SOCKET_FILE}")"
    [[ -n "${MEDIA_SOCKET}" ]] && ok "SBC media socket loaded from ${MEDIA_SOCKET_FILE}: ${MEDIA_SOCKET}"
  fi
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf "%s" "$value"
}

json_field() {
  local field="$1" file="$2"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n1
}

private_ipv4() {
  ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true
}

public_ipv4() {
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null ||
    curl -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null ||
    true
}

bootstrap_node_via_api() {
  local hostname_value private_ip public_ip payload response_file http_code server_uuid media_socket
  hostname_value="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  private_ip="$(private_ipv4)"
  public_ip="$(public_ipv4)"
  info "Bootstrap metadata: hostname=${hostname_value:-unknown}, privateIP=${private_ip:-unknown}, publicIP=${public_ip:-unknown}"
  payload="{\"engine\":\"$(json_escape "${SBC_ENGINE}")\",\"hostname\":\"$(json_escape "${hostname_value}")\""
  [[ -n "${private_ip}" ]] && payload+=",\"privateIP\":\"$(json_escape "${private_ip}")\""
  [[ -n "${public_ip}" ]] && payload+=",\"publicIP\":\"$(json_escape "${public_ip}")\""
  payload+="}"
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "POST ${API_BASE}/api/v1/sbc/runtime/bootstrap?node_uuid=${NODE_UUID}&engine=${SBC_ENGINE} with local token ${API_TOKEN_FILE}"
    return 0
  fi
  response_file="$(mktemp)"
  http_code="$(curl -sS -o "${response_file}" -w "%{http_code}" -X POST "${API_BASE}/api/v1/sbc/runtime/bootstrap?node_uuid=${NODE_UUID}&engine=${SBC_ENGINE}" -H "Content-Type: application/json" -H "Authorization: Bearer ${API_TOKEN}" -H "X-SBC-Engine: ${SBC_ENGINE}" --data "${payload}" 2>>"${LOG_FILE}")"
  server_uuid="$(json_field "serverUUID" "${response_file}")"
  if [[ "${http_code}" == "200" ]]; then
    media_socket="$(json_field "rtpengineSocket" "${response_file}")"
    [[ -z "${media_socket}" ]] && media_socket="$(json_field "mediaSocket" "${response_file}")"
    if [[ -n "${media_socket}" ]]; then
      MEDIA_SOCKET="${media_socket}"
      write_file "${MEDIA_SOCKET_FILE}" "${MEDIA_SOCKET}"
      run "chown root:root '${MEDIA_SOCKET_FILE}'"
      run "chmod 0640 '${MEDIA_SOCKET_FILE}'"
    else
      MEDIA_SOCKET=""
      rm -f "${MEDIA_SOCKET_FILE}"
    fi
    rm -f "${response_file}"
    ok "Node UUID vinculado via API bootstrap. serverUUID: ${server_uuid:-unknown}"
    [[ -n "${MEDIA_SOCKET}" ]] && ok "SBC media relay enabled: ${MEDIA_SOCKET}"
    return 0
  fi
  rm -f "${response_file}"
  warn "SBC API bootstrap returned HTTP ${http_code}. Register the Node UUID manually if necessary."
  return 1
}

install_packages_debian() {
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "load mnscloud-runtime-kit and run mrtk_ensure_opensips"
    return 0
  fi
  load_runtime_kit
  mrtk_ensure_opensips
}

install_packages_rocky() {
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "load mnscloud-runtime-kit and run mrtk_ensure_opensips"
    return 0
  fi
  load_runtime_kit
  mrtk_ensure_opensips
}
backup_once() { local file="$1"; [[ -f "$file" && ! -f "${file}.bkp" ]] && run "cp -a '${file}' '${file}.bkp'" || true; }

opensips_group() {
  if getent group opensips >/dev/null 2>&1; then
    printf "opensips"
  else
    printf "root"
  fi
}

ensure_opensips_dbtext_permissions() {
  local group
  [[ -d "${DBTEXT_DIR}" ]] || return 0
  group="$(opensips_group)"
  run "chown root:${group} '${DBTEXT_DIR}'"
  run "chmod 0750 '${DBTEXT_DIR}'"
  for file in "${DBTEXT_DIR}/version" "${DBTEXT_DIR}/registrant"; do
    [[ -f "${file}" ]] || continue
    run "chown root:${group} '${file}'"
    run "chmod 0640 '${file}'"
  done
}

ensure_opensips_runtime_dirs() {
  local group
  group="$(opensips_group)"
  run "install -d -o root -g '${group}' -m 0770 '${MI_FIFO_DIR}'"
  write_file "/etc/tmpfiles.d/mnscloud-opensips-sbc.conf" "d ${MI_FIFO_DIR} 0770 root ${group} -"
}

configure_opensips_defaults() {
  local defaults_file="/etc/default/opensips"
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "set OpenSIPS shared/private memory defaults in ${defaults_file}"
    return 0
  fi

  backup_once "${defaults_file}"
  [[ -f "${defaults_file}" ]] || write_file "${defaults_file}" "# MNSCloud OpenSIPS runtime defaults"

  if grep -q '^S_MEMORY=' "${defaults_file}"; then
    run "sed -i 's/^S_MEMORY=.*/S_MEMORY=512/' '${defaults_file}'"
  else
    printf '\nS_MEMORY=512\n' >> "${defaults_file}"
  fi

  if grep -q '^P_MEMORY=' "${defaults_file}"; then
    run "sed -i 's/^P_MEMORY=.*/P_MEMORY=32/' '${defaults_file}'"
  else
    printf 'P_MEMORY=32\n' >> "${defaults_file}"
  fi

  run "chown root:root '${defaults_file}'"
  run "chmod 0644 '${defaults_file}'"
  ok "OpenSIPS memory defaults configured: S_MEMORY=512 P_MEMORY=32"
}

opensips_module_path() {
  local arch
  if command -v dpkg-architecture >/dev/null 2>&1; then
    arch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
    [[ -n "${arch}" && -d "/usr/lib/${arch}/opensips/modules" ]] && {
      printf "/usr/lib/%s/opensips/modules/" "${arch}"
      return 0
    }
  fi
  for dir in \
    /usr/lib/x86_64-linux-gnu/opensips/modules \
    /usr/lib64/opensips/modules \
    /usr/lib/opensips/modules; do
    if [[ -d "${dir}" ]]; then
      printf "%s/" "${dir%/}"
      return 0
    fi
  done
  case "$(detect_opensips_os)" in
    debian) printf "/usr/lib/x86_64-linux-gnu/opensips/modules/" ;;
    rocky) printf "/usr/lib64/opensips/modules/" ;;
  esac
}

write_opensips_config() {
  local cfg="/etc/opensips/opensips.cfg" module_path sip_i_modules="" uac_modules="" uac_params="" rtpengine_modules="" rtpengine_params="" rtpengine_bye="" rtpengine_offer="" rtpengine_reply=""
  module_path="$(opensips_module_path)"
  if [[ -r "${module_path%/}/sip_i.so" ]]; then
    sip_i_modules='loadmodule "sip_i.so"'
  else
    warn "OpenSIPS sip_i module not found at ${module_path%/}/sip_i.so; SIP-I payload interworking will stay disabled until the package provides it"
  fi
  if [[ -r "${module_path%/}/db_text.so" && -r "${module_path%/}/uac.so" && -r "${module_path%/}/uac_auth.so" && -r "${module_path%/}/uac_registrant.so" && -r "${module_path%/}/mi_fifo.so" ]]; then
    uac_modules='loadmodule "db_text.so"
loadmodule "uac_auth.so"
loadmodule "uac.so"
loadmodule "uac_registrant.so"
loadmodule "mi_fifo.so"'
    uac_params="modparam(\"db_text\", \"db_mode\", 1)
modparam(\"uac_registrant\", \"db_url\", \"text://${DBTEXT_DIR}\")
modparam(\"uac_registrant\", \"table_name\", \"registrant\")
modparam(\"uac_registrant\", \"timer_interval\", 30)
modparam(\"uac_registrant\", \"failure_retry_interval\", 60)
modparam(\"mi_fifo\", \"fifo_name\", \"${MI_FIFO_FILE}\")
modparam(\"mi_fifo\", \"reply_dir\", \"${MI_FIFO_DIR}/\")
modparam(\"mi_fifo\", \"fifo_mode\", 0660)"
  else
    warn "OpenSIPS db_text/uac/uac_auth/uac_registrant/mi_fifo modules not found; active REGISTER peers will stay disabled until the modules are installed"
  fi
  if [[ -n "${MEDIA_SOCKET}" ]]; then
    [[ -r "${module_path%/}/rtpengine.so" ]] ||
      { err "OpenSIPS rtpengine module not found at ${module_path%/}/rtpengine.so while media relay is assigned"; return 1; }
    rtpengine_modules='loadmodule "rtpengine.so"'
    rtpengine_params="modparam(\"rtpengine\", \"rtpengine_sock\", \"${MEDIA_SOCKET}\")"
    rtpengine_bye='  if (is_method("BYE|CANCEL")) {
    rtpengine_delete();
  }
'
    rtpengine_offer='    if (has_body("application/sdp")) {
      rtpengine_offer("replace-origin replace-session-connection");
    }
    t_on_reply("MNSCLOUD_RTPENGINE_REPLY");
'
    rtpengine_reply='
onreply_route[MNSCLOUD_RTPENGINE_REPLY] {
  if (has_body("application/sdp")) {
    rtpengine_answer("replace-origin replace-session-connection");
  }
}
'
  fi
  backup_once "$cfg"
  write_file "$cfg" "#### MNSCloud OpenSIPS SBC ####
log_level=3
xlog_level=3
udp_workers=4
server_header=\"Server: MNSCloud OpenSIPS SBC\"
user_agent_header=\"User-Agent: MNSCloud OpenSIPS SBC\"
socket=udp:0.0.0.0:5060
socket=tcp:0.0.0.0:5060
mpath=\"${module_path}\"

loadmodule \"proto_udp.so\"
loadmodule \"proto_tcp.so\"
loadmodule \"sl.so\"
loadmodule \"tm.so\"
loadmodule \"rr.so\"
loadmodule \"maxfwd.so\"
loadmodule \"textops.so\"
loadmodule \"sipmsgops.so\"
loadmodule \"rest_client.so\"
loadmodule \"json.so\"
${sip_i_modules}
${uac_modules}
${rtpengine_modules}

${uac_params}
${rtpengine_params}

route {
  if (!mf_process_maxfwd_header(10)) { sl_send_reply(483, \"Too Many Hops\"); exit; }
  if (is_method(\"OPTIONS\")) { sl_send_reply(200, \"OK\"); exit; }
${rtpengine_bye}

  if (is_method(\"INVITE\")) {
    xlog(\"L_INFO\", \"mnscloud SBC pipe lookup for \$rU from \$si\\n\");
    \$var(pipe_payload) = \"{\\\"engine\\\":\\\"${SBC_ENGINE}\\\",\\\"direction\\\":\\\"inbound\\\",\\\"destination\\\":\\\"\" + \$rU + \"\\\",\\\"source_ip\\\":\\\"\" + \$si + \"\\\",\\\"source_port\\\":\" + \$sp + \",\\\"source_transport\\\":\\\"\" + \$socket_in(proto) + \"\\\",\\\"local_ip\\\":\\\"\" + \$socket_in(ip) + \"\\\",\\\"local_port\\\":\" + \$socket_in(port) + \",\\\"from_user\\\":\\\"\" + \$fU + \"\\\",\\\"from_domain\\\":\\\"\" + \$fd + \"\\\",\\\"to_user\\\":\\\"\" + \$tU + \"\\\",\\\"to_domain\\\":\\\"\" + \$td + \"\\\",\\\"ruri_user\\\":\\\"\" + \$rU + \"\\\",\\\"ruri_domain\\\":\\\"\" + \$rd + \"\\\",\\\"auth_username\\\":\\\"\" + \$au + \"\\\"}\";
    rest_append_hf(\"Authorization: Bearer ${API_TOKEN}\");
    rest_append_hf(\"X-SBC-Engine: ${SBC_ENGINE}\");
    \$var(rest_rc) = rest_post(\"${API_BASE}/api/v1/sbc/runtime/pipe?node_uuid=${NODE_UUID}&engine=${SBC_ENGINE}\", \$var(pipe_payload), \"application/json\", \$var(body), \$var(ct), \$var(http_code));
    if (\$var(rest_rc) < 0) { sl_send_reply(503, \"Pipe lookup failed\"); exit; }
    if (\$var(http_code) != 200) { sl_send_reply(503, \"Pipe lookup failed\"); exit; }
    \$json(pipe) := \$var(body);
    if (\$json(pipe/allowed) != \"true\") { sl_send_reply(403, \"Pipe not allowed\"); exit; }
    if (\$json(pipe/host) == NULL || \$json(pipe/port) == NULL) { sl_send_reply(503, \"Pipe target missing\"); exit; }
    \$var(dst_transport) = \$json(pipe/transport);
    if (\$var(dst_transport) == NULL) { \$var(dst_transport) = \"udp\"; }
    \$du = \"sip:\" + \$json(pipe/host) + \":\" + \$json(pipe/port) + \";transport=\" + \$var(dst_transport);
${rtpengine_offer}
  }

  if (!t_relay()) { sl_send_reply(500, \"Relay failed\"); }
  exit;
}
${rtpengine_reply}
"
  run "opensips -C -f '${cfg}'"
}

enable_service() {
  run "systemctl enable opensips"
  run "systemctl restart opensips"
  run "systemctl is-active opensips"
}

remove_runtime_sync_units() {
  local sync_script="${SCRIPT_DIR}/sync-and-reload-opensips-sbc.sh"
  [[ -x "${sync_script}" ]] || run "chmod +x '${sync_script}'"

  run "systemctl disable --now mnscloud-opensips-sbc-sync.timer >/dev/null 2>&1 || true"
  run "systemctl disable --now mnscloud-opensips-sbc-sync.service >/dev/null 2>&1 || true"
  run "rm -f /etc/systemd/system/mnscloud-opensips-sbc-sync.timer /etc/systemd/system/mnscloud-opensips-sbc-sync.service"
  run "systemctl daemon-reload"
  run "systemctl reset-failed mnscloud-opensips-sbc-sync.timer mnscloud-opensips-sbc-sync.service >/dev/null 2>&1 || true"
  ok "SBC runtime fallback timer removed; runtime sync is Agent job only"
}

main() {
  require_root
  echo "opensips         SBC - OpenSIPS 3.6.x (official repository)"
  echo "Mode: $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"
  echo "Log:  ${LOG_FILE}"
  echo "=================================================="
  local app_security_script="${MNSCLOUD_MONOREPO_ROOT:-${PROJECT_ROOT}}/scripts/application-security.sh"
  [[ -f "${app_security_script}" ]] && run "bash '${app_security_script}'"
  ensure_local_hostname_hosts
  validate_mnscloud_agent
  ensure_api_base_file
  ensure_node_uuid_file
  ensure_api_token_file
  case "$(detect_opensips_os)" in debian) install_packages_debian ;; rocky) install_packages_rocky ;; esac
  configure_opensips_defaults
  bootstrap_node_via_api || true
  ensure_opensips_dbtext_permissions
  ensure_opensips_runtime_dirs
  load_media_socket_file
  write_opensips_config
  enable_service
  remove_runtime_sync_units
  refresh_agent_capabilities
  ok "OpenSIPS SBC installed. Node UUID: ${NODE_UUID}"
}

main "$@"
