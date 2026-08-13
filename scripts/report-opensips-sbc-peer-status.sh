#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[report-opensips-sbc-peer-status]"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/install-base.sh" "$@"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_UUID_FILE="/etc/mnscloud/sbc/node.uuid"
API_TOKEN_FILE="/etc/mnscloud/sbc/api.token"
API_BASE_FILE="/etc/mnscloud/sbc/api.base"
CONFIG_FILE="/etc/mnscloud/sbc/runtime/config.json"
SBC_ENGINE="${MNSCLOUD_SBC_ENGINE:-opensips}"
STATUS_DELAY_SECONDS="${MNSCLOUD_SBC_STATUS_REPORT_DELAY:-2}"
HTTP_CONNECT_TIMEOUT_SECONDS="${MNSCLOUD_SBC_HTTP_CONNECT_TIMEOUT:-5}"
HTTP_MAX_TIME_SECONDS="${MNSCLOUD_SBC_HTTP_MAX_TIME:-30}"

read_required_file() {
  local file="$1" label="$2" value
  [[ -r "$file" ]] || { err "${label} not found: ${file}"; return 1; }
  value="$(tr -d '[:space:]' < "$file")"
  [[ -n "$value" ]] || { err "${label} is empty: ${file}"; return 1; }
  printf "%s" "$value"
}

normalize_url() {
  local value="$1"
  value="$(printf "%s" "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s#/*$##')"
  printf "%s" "$value"
}

registered_peer_rows() {
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
    | {
        peerUUID: (.uuid // .peerUUID // ""),
        name: (.name // ""),
        aor: aor(.),
        binding: binding($root; .),
        registrar: siphost(.registrarHost; (.registrarPort // 5060); (.registrarTransport // "udp")),
        disabled: (((.status // 1) | tostring | ascii_downcase) as $status | ($status == "0" or $status == "false" or $status == "inactive" or $status == "disabled"))
      }
    | select(.peerUUID != "")
    | @base64
  ' "$CONFIG_FILE"
}

json_get() {
  local encoded="$1" expression="$2"
  printf "%s" "$encoded" | base64 -d | jq -r "$expression"
}

post_peer_status() {
  local api_base="$1" node_uuid="$2" api_token="$3" payload="$4" response_file http_code
  response_file="$(mktemp)"
  http_code="$(curl -sS -o "$response_file" -w "%{http_code}" \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$HTTP_MAX_TIME_SECONDS" \
    -X POST "${api_base}/api/v1/sbc/runtime/peer-status?node_uuid=${node_uuid}&engine=${SBC_ENGINE}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${api_token}" \
    -H "X-SBC-Engine: ${SBC_ENGINE}" \
    --data "$payload" 2>>"${LOG_FILE}")"
  if [[ "$http_code" != "200" ]]; then
    warn "SBC peer status response: $(tr -d '\n\r' < "$response_file" | cut -c1-500)"
    rm -f "$response_file"
    err "SBC peer status report failed with HTTP ${http_code}"
    return 1
  fi
  rm -f "$response_file"
}

main() {
  require_root
  command -v jq >/dev/null 2>&1 || { err "jq is required for peer status reporting"; return 1; }

  echo "opensips         SBC peer status report"
  echo "Mode: $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"
  echo "Log:  ${LOG_FILE}"
  echo "=================================================="

  [[ -r "$CONFIG_FILE" ]] || { err "SBC runtime config not found: ${CONFIG_FILE}"; return 1; }

  if [[ "$DRY_RUN" == true ]]; then
    log DRY "query OpenSIPS MI reg_list and POST peer status to API"
    registered_peer_rows >/dev/null
    return 0
  fi

  if [[ "$STATUS_DELAY_SECONDS" =~ ^[0-9]+$ ]] && (( STATUS_DELAY_SECONDS > 0 )); then
    sleep "$STATUS_DELAY_SECONDS"
  fi

  local node_uuid api_token api_base mi_output mi_status encoded peer_uuid name aor binding registrar disabled
  local registration_status registration_code registration_message health_status health_code health_message payload
  node_uuid="$(read_required_file "$NODE_UUID_FILE" "Node UUID")"
  api_token="$(read_required_file "$API_TOKEN_FILE" "SBC API token")"
  api_base="$(normalize_url "$(read_required_file "$API_BASE_FILE" "API base")")"

  mi_status="ok"
  if ! mi_output="$(bash "${SCRIPT_DIR}/opensips-sbc-mi.sh" reg_list 2>>"${LOG_FILE}")"; then
    mi_status="failed"
    mi_output=""
    warn "OpenSIPS MI reg_list failed; reporting REGISTER peers as failed"
  fi

  while IFS= read -r encoded; do
    [[ -n "$encoded" ]] || continue
    peer_uuid="$(json_get "$encoded" '.peerUUID')"
    name="$(json_get "$encoded" '.name')"
    aor="$(json_get "$encoded" '.aor')"
    binding="$(json_get "$encoded" '.binding')"
    registrar="$(json_get "$encoded" '.registrar')"
    disabled="$(json_get "$encoded" '.disabled')"

    if [[ "$disabled" == "true" ]]; then
      registration_status="disabled"
      registration_code="null"
      registration_message="SBC peer is disabled in the runtime config."
      health_status="unknown"
      health_code="null"
      health_message="SBC peer disabled."
    elif [[ "$mi_status" != "ok" ]]; then
      registration_status="failed"
      registration_code="500"
      registration_message="OpenSIPS MI reg_list failed while checking uac_registrant state."
      health_status="unreachable"
      health_code="500"
      health_message="OpenSIPS MI did not return registrant state."
    elif [[ -n "$binding" && "$mi_output" == *"$binding"* ]] || [[ -n "$aor" && "$mi_output" == *"$aor"* ]]; then
      registration_status="registered"
      registration_code="200"
      registration_message="Registered in OpenSIPS uac_registrant: ${binding:-$aor}"
      health_status="reachable"
      health_code="200"
      health_message="OpenSIPS uac_registrant contact is active."
    else
      registration_status="registering"
      registration_code="102"
      registration_message="OpenSIPS uac_registrant has not listed the expected contact yet: ${binding:-$aor}"
      health_status="unknown"
      health_code="null"
      health_message="Waiting for OpenSIPS uac_registrant contact."
    fi

    payload="$(jq -nc \
      --arg engine "$SBC_ENGINE" \
      --arg peerUUID "$peer_uuid" \
      --arg registrationStatus "$registration_status" \
      --arg registrationLastMessage "$registration_message" \
      --arg healthStatus "$health_status" \
      --arg healthLastMessage "$health_message" \
      --arg name "$name" \
      --arg aor "$aor" \
      --arg binding "$binding" \
      --arg registrar "$registrar" \
      --argjson registrationLastCode "$registration_code" \
      --argjson healthLastCode "$health_code" \
      '{
        engine: $engine,
        peerUUID: $peerUUID,
        registrationStatus: $registrationStatus,
        registrationLastCode: $registrationLastCode,
        registrationLastMessage: $registrationLastMessage,
        registrationExpiresAt: null,
        registrationNextRetryAt: null,
        healthStatus: $healthStatus,
        healthLastCode: $healthLastCode,
        healthLastMessage: $healthLastMessage,
        healthLatencyMs: null,
        observed: {
          name: $name,
          aor: $aor,
          binding: $binding,
          registrar: $registrar
        }
      }')"
    post_peer_status "$api_base" "$node_uuid" "$api_token" "$payload"
    ok "Reported SBC peer status: ${name:-$peer_uuid} ${registration_status}"
  done < <(registered_peer_rows)
}

main "$@"
