#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: mnscloud-cdr-diagnostic-capture.sh --enabled yes --module sbc --engine opensips --resource-type sbc_cdr --resource-uuid <id> --call-id <call-id> [--mode sip_capture|pcapng] [--interface any] [--duration 60] [--filter "port 5060"] [--include-engine-logs yes] [--include-runtime-snapshot yes]

Captures temporary SIP/PCAPNG, engine log and runtime snapshot diagnostic artifacts, uploads them
through short-lived MNSCloud API storage URLs and registers only metadata in the CDR diagnostic
attachment table.
Default is fail-closed: nothing is captured unless --enabled yes is provided.
USAGE
}

enabled="no"
module="sbc"
engine="opensips"
resource_type="sbc_cdr"
resource_uuid=""
call_id=""
mode="sip_capture"
iface="any"
duration="60"
filter_expr="port 5060"
include_engine_logs="yes"
include_runtime_snapshot="yes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enabled) enabled="${2:-}"; shift 2 ;;
    --module) module="${2:-}"; shift 2 ;;
    --engine) engine="${2:-}"; shift 2 ;;
    --resource-type) resource_type="${2:-}"; shift 2 ;;
    --resource-uuid) resource_uuid="${2:-}"; shift 2 ;;
    --call-id) call_id="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --interface) iface="${2:-}"; shift 2 ;;
    --duration) duration="${2:-}"; shift 2 ;;
    --filter) filter_expr="${2:-}"; shift 2 ;;
    --include-engine-logs) include_engine_logs="${2:-}"; shift 2 ;;
    --include-runtime-snapshot) include_runtime_snapshot="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

[[ "$enabled" == "yes" ]] || { echo "Diagnostic capture disabled."; exit 0; }
if [[ -z "$call_id" && -n "${SIP_HF_CALL_ID:-}" ]]; then
  call_id="${SIP_HF_CALL_ID}"
fi
[[ -n "$resource_uuid" && -n "$call_id" ]] || { echo "resource uuid and call id are required." >&2; exit 64; }
mode="$(tr '[:upper:]' '[:lower:]' <<<"$mode")"
[[ "$mode" == "sip_capture" || "$mode" == "pcapng" ]] || { echo "mode must be sip_capture or pcapng." >&2; exit 64; }
[[ "$duration" =~ ^[0-9]+$ && "$duration" -ge 10 && "$duration" -le 300 ]] || { echo "duration must be 10..300 seconds." >&2; exit 64; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 69; }
command -v curl >/dev/null || { echo "curl is required." >&2; exit 69; }
packet_capture_available="yes"
if [[ "$mode" == "pcapng" ]] && ! command -v dumpcap >/dev/null; then
  packet_capture_available="no"
elif [[ "$mode" != "pcapng" ]] && ! command -v tcpdump >/dev/null; then
  packet_capture_available="no"
fi

api_base="${MNSCLOUD_API_BASE:-}"
api_token="${MNSCLOUD_API_TOKEN:-}"
node_uuid="${MNSCLOUD_NODE_UUID:-}"
case "$module" in
  sbc) secret_dir="/etc/mnscloud/sbc" ;;
  softswitch) secret_dir="/etc/mnscloud/softswitch" ;;
  pabx) secret_dir="/etc/mnscloud/pabx" ;;
  *) secret_dir="" ;;
esac
[[ -n "$api_base" || -z "$secret_dir" || ! -r "$secret_dir/api.base" ]] || api_base="$(tr -d '[:space:]' < "$secret_dir/api.base")"
[[ -n "$api_token" || -z "$secret_dir" || ! -r "$secret_dir/api.token" ]] || api_token="$(tr -d '[:space:]' < "$secret_dir/api.token")"
[[ -n "$node_uuid" || -z "$secret_dir" || ! -r "$secret_dir/node.uuid" ]] || node_uuid="$(tr -d '[:space:]' < "$secret_dir/node.uuid")"
[[ -n "$api_base" && -n "$api_token" && -n "$node_uuid" ]] || { echo "MNSCLOUD_API_BASE, MNSCLOUD_API_TOKEN and MNSCLOUD_NODE_UUID are required." >&2; exit 78; }

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

safe_filename_token() {
  printf '%s' "${1:-diagnostic}" | tr -c 'A-Za-z0-9_.@+-' '-' | sed -E 's/-+/-/g; s/^-|-$//g' | cut -c1-120
}

service_unit() {
  case "$module:$engine" in
    sbc:opensips) echo "opensips" ;;
    softswitch:kamailio) echo "kamailio" ;;
    pabx:asterisk) echo "asterisk" ;;
    *) echo "$engine" ;;
  esac
}

runtime_config_paths_json() {
  case "$module:$engine" in
    sbc:opensips)
      jq -n \
        --arg opensipsCfg "$(test -r /etc/opensips/opensips.cfg && grep -nE '^(socket=|listen=|advertised_|alias=|loadmodule|modparam\\(\"rr\"|record_route|record_route_preset|route\\[|create_dialog|rtpengine|rest_post)' /etc/opensips/opensips.cfg 2>/dev/null | sed -E 's/(Authorization: Bearer )[A-Za-z0-9._-]+/\\1[REDACTED]/g' || true)" \
        --arg mediaSocket "$(test -r /etc/mnscloud/sbc/media.socket && sed -E 's/(token|secret|password|pass)=([^[:space:]]+)/\\1=[REDACTED]/Ig' /etc/mnscloud/sbc/media.socket 2>/dev/null || true)" \
        '{opensipsConfig:$opensipsCfg,mediaSocket:$mediaSocket}'
      ;;
    softswitch:kamailio)
      jq -n \
        --arg kamailioCfg "$(test -r /etc/kamailio/kamailio.cfg && grep -nE '^(listen=|alias=|loadmodule|modparam\\(\"(rr|path|registrar|usrloc|rtpengine)\"|record_route|record_route_preset|route\\[|lookup\\(\"location\"\\)|t_relay|rtpengine_)' /etc/kamailio/kamailio.cfg 2>/dev/null | sed -E 's/(Authorization: Bearer )[A-Za-z0-9._-]+/\\1[REDACTED]/g' || true)" \
        --arg mediaSocket "$(test -r /etc/mnscloud/softswitch/media.socket && sed -E 's/(token|secret|password|pass)=([^[:space:]]+)/\\1=[REDACTED]/Ig' /etc/mnscloud/softswitch/media.socket 2>/dev/null || true)" \
        '{kamailioConfig:$kamailioCfg,mediaSocket:$mediaSocket}'
      ;;
    pabx:asterisk)
      jq -n \
        --arg pjsipTransports "$(command -v asterisk >/dev/null && asterisk -rx 'pjsip show transports' 2>/dev/null | sed -E 's/(password|secret|token)[^[:space:]]*/[REDACTED]/Ig' || true)" \
        --arg pjsipRegistrations "$(command -v asterisk >/dev/null && asterisk -rx 'pjsip show registrations' 2>/dev/null | sed -E 's/(password|secret|token)[^[:space:]]*/[REDACTED]/Ig' || true)" \
        '{pjsipTransports:$pjsipTransports,pjsipRegistrations:$pjsipRegistrations}'
      ;;
    *)
      jq -n '{}'
      ;;
  esac
}

collect_engine_logs() {
  local output="$1"
  local unit
  unit="$(service_unit)"
  {
    echo "# MNSCloud engine log diagnostic"
    echo "# module=${module} engine=${engine} resource_type=${resource_type} resource_uuid=${resource_uuid}"
    echo "# call_id=${call_id}"
    echo "# generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    if command -v journalctl >/dev/null; then
      journalctl -u "$unit" --no-pager -l --since "$((duration + 30)) seconds ago" 2>/dev/null \
        | awk -v call="$call_id" '
          BEGIN { IGNORECASE=1 }
          index($0, call) ||
          $0 ~ /(mnscloud|opensips|kamailio|asterisk|invite|ack|bye|cancel|route|record-route|loose|dialog|rtpengine|media|codec|error|failed|warning|critical|no socket|fallback|service unavailable|forbidden|not found)/ { print }
        ' \
        | tail -1200
    else
      echo "journalctl is not available on this runtime."
    fi
  } >"$output"
}

collect_runtime_snapshot() {
  local output="$1"
  local unit
  unit="$(service_unit)"
  local host kernel active version sockets git_ref configs
  host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  kernel="$(uname -a 2>/dev/null || true)"
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  case "$unit" in
    opensips) version="$(opensips -V 2>&1 | head -20 || true)" ;;
    kamailio) version="$(kamailio -v 2>&1 | head -20 || true)" ;;
    asterisk) version="$(asterisk -rx 'core show version' 2>/dev/null || asterisk -V 2>/dev/null || true)" ;;
    *) version="" ;;
  esac
  sockets="$(ss -H -lntup 2>/dev/null | grep -E '(:5060|:5061|:5080|:5081|:10000|:20000|:2223)' || true)"
  case "$module:$engine" in
    sbc:opensips) git_ref="$(git -C /opt/mnscloud/mnscloud-opensips-sbc describe --tags --always --dirty 2>/dev/null || true)" ;;
    softswitch:kamailio) git_ref="$(git -C /opt/mnscloud/mnscloud-kamailio-softswitch describe --tags --always --dirty 2>/dev/null || true)" ;;
    pabx:asterisk) git_ref="$(git -C /opt/mnscloud/mnscloud-asterisk describe --tags --always --dirty 2>/dev/null || true)" ;;
    *) git_ref="" ;;
  esac
  configs="$(runtime_config_paths_json)"
  jq -n \
    --arg generatedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg diagnosticModule "$module" \
    --arg engine "$engine" \
    --arg resourceType "$resource_type" \
    --arg resourceUUID "$resource_uuid" \
    --arg callID "$call_id" \
    --arg host "$host" \
    --arg kernel "$kernel" \
    --arg serviceUnit "$unit" \
    --arg serviceActive "$active" \
    --arg version "$version" \
    --arg sockets "$sockets" \
    --arg gitRef "$git_ref" \
    --argjson runtimeConfig "$configs" \
    '{generatedAt:$generatedAt,module:$diagnosticModule,engine:$engine,resourceType:$resourceType,resourceUUID:$resourceUUID,callID:$callID,host:$host,kernel:$kernel,service:{unit:$serviceUnit,active:$serviceActive,version:$version},listeningSockets:$sockets,gitRef:$gitRef,runtimeConfig:$runtimeConfig}'
      >"$output"
}

upload_attachment() {
  local artifact="$1"
  local diagnostic_type="$2"
  local capture_mode="$3"
  local filename="$4"
  local content_type="$5"
  local sanitized="$6"
  local contains_sdp="$7"
  local contains_payload="$8"
  [[ -s "$artifact" ]] || { echo "Skipping empty diagnostic artifact ${diagnostic_type}." >&2; return 0; }
  local size_bytes checksum prepare_payload prepare_response upload_url storage_key storage_account_uuid register_payload
  size_bytes="$(stat -c '%s' "$artifact")"
  checksum="$(sha256sum "$artifact" | awk '{print $1}')"
  prepare_payload="$(jq -n \
    --arg diagnosticModule "$module" --arg engine "$engine" --arg resourceType "$resource_type" \
    --arg resourceUUID "$resource_uuid" --arg diagnosticType "$diagnostic_type" --arg contentType "$content_type" \
    '{module:$diagnosticModule,engine:$engine,resourceType:$resourceType,resourceUUID:$resourceUUID,diagnosticType:$diagnosticType,contentType:$contentType}')"
  prepare_response="$(curl -fsS -X POST "${api_base%/}/api/v1/voip/cdr-diagnostics/runtime/upload-url?${runtime_query}" \
    -H "Authorization: Bearer $api_token" -H "Content-Type: application/json" -H "X-MNSCloud-Node-UUID: $node_uuid" --data "$prepare_payload")"
  upload_url="$(jq -r '.data.uploadUrl // empty' <<<"$prepare_response")"
  storage_key="$(jq -r '.data.key // empty' <<<"$prepare_response")"
  storage_account_uuid="$(jq -r '.data.storageAccountUUID // empty' <<<"$prepare_response")"
  [[ -n "$upload_url" && -n "$storage_key" ]] || { echo "API did not return upload URL for ${diagnostic_type}." >&2; return 0; }
  curl -fsS -X PUT "$upload_url" -H "Content-Type: $content_type" --data-binary "@$artifact" >/dev/null
  register_payload="$(jq -n \
    --arg diagnosticModule "$module" --arg engine "$engine" --arg resourceType "$resource_type" \
    --arg resourceUUID "$resource_uuid" --arg callID "$call_id" --arg storageAccountUUID "$storage_account_uuid" \
    --arg storageObjectKey "$storage_key" --arg checksumSha256 "$checksum" --arg diagnosticType "$diagnostic_type" \
    --arg captureMode "$capture_mode" --arg originalFilename "$filename" --arg contentType "$content_type" \
    --argjson sizeBytes "$size_bytes" --argjson sanitized "$sanitized" --argjson containsSdp "$contains_sdp" --argjson containsPayload "$contains_payload" \
    '{module:$diagnosticModule,engine:$engine,resourceType:$resourceType,resourceUUID:$resourceUUID,callID:$callID,diagnosticType:$diagnosticType,captureMode:$captureMode,storageMode:"storage",storageAccountUUID:$storageAccountUUID,storageObjectKey:$storageObjectKey,originalFilename:$originalFilename,contentType:$contentType,sizeBytes:$sizeBytes,checksumSha256:$checksumSha256,sanitized:$sanitized,containsSdp:$containsSdp,containsPayload:$containsPayload,status:"available"}')"
  curl -fsS -X POST "${api_base%/}/api/v1/voip/cdr-diagnostics/runtime?${runtime_query}" \
    -H "Authorization: Bearer $api_token" -H "Content-Type: application/json" -H "X-MNSCloud-Node-UUID: $node_uuid" --data "$register_payload" >/dev/null
}

if [[ "$mode" == "pcapng" ]]; then
  artifact="$tmp_dir/cdr-diagnostic.pcapng"
  filename="cdr-diagnostic.pcapng"
  content_type="application/vnd.tcpdump.pcap"
  if [[ "$packet_capture_available" == "yes" ]]; then
    timeout "$duration" dumpcap -q -i "$iface" -f "$filter_expr" -w "$artifact" >/dev/null 2>&1 || true
  fi
  contains_payload="true"
else
  artifact="$tmp_dir/cdr-diagnostic.sip"
  filename="cdr-diagnostic.sip"
  content_type="text/plain; charset=utf-8"
  if [[ "$packet_capture_available" == "yes" ]]; then
    timeout "$duration" tcpdump -A -s 0 -n -i "$iface" "$filter_expr" >"$artifact" 2>/dev/null || true
  fi
  contains_payload="false"
fi
if [[ "$packet_capture_available" != "yes" ]]; then
  {
    echo "# MNSCloud packet capture diagnostic unavailable"
    echo "# requested_mode=${mode}"
    echo "# install tcpdump for sip_capture or dumpcap for pcapng on this runtime"
  } >"$artifact"
fi
capture_mode="$mode"
[[ "$capture_mode" == "sip_capture" ]] && capture_mode="full"
call_token="$(safe_filename_token "$call_id")"
runtime_query="node_uuid=${node_uuid}&engine=${engine}"

upload_attachment "$artifact" "$mode" "$capture_mode" "${call_token}-${filename}" "$content_type" "false" "true" "$contains_payload"

if [[ "$include_engine_logs" == "yes" ]]; then
  log_artifact="$tmp_dir/engine-log.txt"
  collect_engine_logs "$log_artifact"
  upload_attachment "$log_artifact" "engine_log" "log" "${call_token}-engine-log.txt" "text/plain; charset=utf-8" "true" "false" "false"
fi

if [[ "$include_runtime_snapshot" == "yes" ]]; then
  snapshot_artifact="$tmp_dir/runtime-snapshot.json"
  collect_runtime_snapshot "$snapshot_artifact"
  upload_attachment "$snapshot_artifact" "runtime_snapshot" "snapshot" "${call_token}-runtime-snapshot.json" "application/json; charset=utf-8" "true" "false" "false"
fi
