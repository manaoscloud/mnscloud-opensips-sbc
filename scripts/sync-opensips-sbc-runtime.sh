#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[sync-opensips-sbc-runtime]"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/install-base.sh" "$@"

NODE_UUID_FILE="/etc/mnscloud/sbc/node.uuid"
API_TOKEN_FILE="/etc/mnscloud/sbc/api.token"
API_BASE_FILE="/etc/mnscloud/sbc/api.base"
MEDIA_SOCKET_FILE="/etc/mnscloud/sbc/media.socket"
RUNTIME_DIR="/etc/mnscloud/sbc/runtime"
DBTEXT_DIR="/etc/mnscloud/sbc/dbtext"
CONFIG_FILE="${RUNTIME_DIR}/config.json"
SUMMARY_FILE="${RUNTIME_DIR}/summary.json"
SBC_ENGINE="${MNSCLOUD_SBC_ENGINE:-opensips}"

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

write_secure_file() {
  local file="$1" content="$2"
  write_file "$file" "$content"
  run "chown root:root '$file'"
  run "chmod 0640 '$file'"
}

opensips_group() {
  if getent group opensips >/dev/null 2>&1; then
    printf "opensips"
  else
    printf "root"
  fi
}

secure_dbtext_path() {
  local group
  group="$(opensips_group)"
  run "chown root:${group} '${DBTEXT_DIR}'"
  run "chmod 0750 '${DBTEXT_DIR}'"
}

secure_dbtext_file() {
  local file="$1" group
  group="$(opensips_group)"
  run "chown root:${group} '${file}'"
  run "chmod 0640 '${file}'"
}

sync_runtime_config() {
  local node_uuid api_token api_base response_file http_code
  node_uuid="$(read_required_file "$NODE_UUID_FILE" "Node UUID")"
  api_token="$(read_required_file "$API_TOKEN_FILE" "SBC API token")"
  api_base="$(normalize_url "$(read_required_file "$API_BASE_FILE" "API base")")"

  run "install -d -m 0750 '${RUNTIME_DIR}' '${DBTEXT_DIR}'"
  run "chown root:root '${RUNTIME_DIR}' '${DBTEXT_DIR}'"
  secure_dbtext_path

  response_file="$(mktemp)"
  http_code="$(curl -sS -o "${response_file}" -w "%{http_code}" -X POST "${api_base}/api/v1/sbc/runtime/config?node_uuid=${node_uuid}&engine=${SBC_ENGINE}" -H "Content-Type: application/json" -H "Authorization: Bearer ${api_token}" -H "X-SBC-Engine: ${SBC_ENGINE}" --data "{\"engine\":\"${SBC_ENGINE}\"}" 2>>"${LOG_FILE}")"
  if [[ "$http_code" != "200" ]]; then
    warn "SBC runtime config response: $(tr -d '\n\r' < "$response_file" | cut -c1-500)"
    rm -f "$response_file"
    err "SBC runtime config sync failed with HTTP ${http_code}"
    return 1
  fi

  jq -e '.status == "success" and (.data.server.uuid | length > 0)' "$response_file" >/dev/null
  jq '.data' "$response_file" > "${CONFIG_FILE}.tmp"
  mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  run "chown root:root '${CONFIG_FILE}'"
  run "chmod 0640 '${CONFIG_FILE}'"

  local media_socket
  media_socket="$(jq -r '.server.rtpengineSocket // empty' "$CONFIG_FILE")"
  if [[ -n "$media_socket" ]]; then
    write_secure_file "$MEDIA_SOCKET_FILE" "$media_socket"
  else
    rm -f "$MEDIA_SOCKET_FILE"
  fi

  rm -f "$response_file"
}

write_dbtext_version() {
  cat > "${DBTEXT_DIR}/version" <<'EOF'
table_name(string) table_version(int) 
registrant:3
EOF
  secure_dbtext_file "${DBTEXT_DIR}/version"
}

write_dbtext_registrant() {
  cat > "${DBTEXT_DIR}/registrant" <<'EOF'
id(int,auto) registrar(string) proxy(string,null) aor(string) third_party_registrant(string,null) username(string,null) password(string,null) binding_URI(string) binding_params(string,null) expiry(int,null) forced_socket(string,null) cluster_shtag(string,null) state(int) 
EOF

  jq -r '
    def clean: if . == null then "" else tostring | gsub("^\\s+|\\s+$"; "") end;
    def dbt:
      if . == null then ""
      else tostring
        | gsub("\\\\"; "\\\\")
        | gsub(":"; "\\:")
        | gsub("\n"; "\\n")
        | gsub("\r"; "\\r")
        | gsub("\t"; "\\t")
      end;
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
    | [ $root.peers[]?
      | select((.authMode == "register" or .registerEnabled == 1) and .authUsername and .authPassword)
      | . as $peer
      | {
          registrar: siphost($peer.registrarHost; ($peer.registrarPort // 5060); ($peer.registrarTransport // "udp")),
          proxy: "",
          aor: aor($peer),
          thirdParty: (($peer.fromDomain // "") | if clean == "" then "" else "sip:" + clean end),
          username: ($peer.authUsername // ""),
          password: ($peer.authPassword // ""),
          binding: binding($root; $peer),
          params: "",
          expiry: ($peer.registerExpires // 3600),
          socket: "",
          cluster: "",
          state: 0
        }
      | select(.registrar != "" and .aor != "" and .binding != "")
    ]
    | to_entries[]
    | [
        (.key + 1),
        .value.registrar,
        .value.proxy,
        .value.aor,
        .value.thirdParty,
        .value.username,
        .value.password,
        .value.binding,
        .value.params,
        .value.expiry,
        .value.socket,
        .value.cluster,
        .value.state
      ]
    | map(dbt)
    | join(":")
  ' "$CONFIG_FILE" >> "${DBTEXT_DIR}/registrant"

  secure_dbtext_file "${DBTEXT_DIR}/registrant"
}

write_summary() {
  jq '{
    server: .server.name,
    nodeUUID: .server.nodeUUID,
    media: .server.rtpengineSocket,
    interfaces: (.interfaces | length),
    peers: (.peers | length),
    registerPeers: ([.peers[]? | select(.authMode == "register" or .registerEnabled == 1)] | length),
    pipes: (.pipes | length),
    syncedAt: now | todateiso8601
  }' "$CONFIG_FILE" > "${SUMMARY_FILE}.tmp"
  mv "${SUMMARY_FILE}.tmp" "$SUMMARY_FILE"
  run "chown root:root '${SUMMARY_FILE}'"
  run "chmod 0640 '${SUMMARY_FILE}'"
}

main() {
  require_root
  command -v jq >/dev/null 2>&1 || { err "jq is required for runtime sync"; return 1; }
  echo "opensips         SBC runtime sync"
  echo "Mode: $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"
  echo "Log:  ${LOG_FILE}"
  echo "=================================================="
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "sync runtime config from API and write ${CONFIG_FILE}, ${DBTEXT_DIR}/registrant"
    return 0
  fi
  sync_runtime_config
  write_dbtext_version
  write_dbtext_registrant
  write_summary
  ok "SBC runtime config synced: ${SUMMARY_FILE}"
}

main "$@"
