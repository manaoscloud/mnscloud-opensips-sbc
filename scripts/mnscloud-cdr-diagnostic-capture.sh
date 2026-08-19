#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: mnscloud-cdr-diagnostic-capture.sh --enabled yes --module sbc --engine opensips --resource-type sbc_cdr --resource-uuid <id> --call-id <call-id> [--mode sip_capture|pcapng] [--interface any] [--duration 60] [--filter "port 5060"]

Captures a temporary SIP text or PCAPNG diagnostic artifact, uploads it through a short-lived
MNSCloud API storage URL and registers only metadata in the CDR diagnostic attachment table.
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
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

[[ "$enabled" == "yes" ]] || { echo "Diagnostic capture disabled."; exit 0; }
[[ -n "$resource_uuid" && -n "$call_id" ]] || { echo "resource uuid and call id are required." >&2; exit 64; }
mode="$(tr '[:upper:]' '[:lower:]' <<<"$mode")"
[[ "$mode" == "sip_capture" || "$mode" == "pcapng" ]] || { echo "mode must be sip_capture or pcapng." >&2; exit 64; }
[[ "$duration" =~ ^[0-9]+$ && "$duration" -ge 10 && "$duration" -le 300 ]] || { echo "duration must be 10..300 seconds." >&2; exit 64; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 69; }
command -v curl >/dev/null || { echo "curl is required." >&2; exit 69; }
if [[ "$mode" == "pcapng" ]]; then
  command -v dumpcap >/dev/null || { echo "dumpcap is required for pcapng capture." >&2; exit 69; }
else
  command -v tcpdump >/dev/null || { echo "tcpdump is required for sip_capture." >&2; exit 69; }
fi

api_base="${MNSCLOUD_API_BASE:-}"
api_token="${MNSCLOUD_API_TOKEN:-}"
node_uuid="${MNSCLOUD_NODE_UUID:-}"
[[ -n "$api_base" && -n "$api_token" && -n "$node_uuid" ]] || { echo "MNSCLOUD_API_BASE, MNSCLOUD_API_TOKEN and MNSCLOUD_NODE_UUID are required." >&2; exit 78; }

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

if [[ "$mode" == "pcapng" ]]; then
  artifact="$tmp_dir/cdr-diagnostic.pcapng"
  filename="cdr-diagnostic.pcapng"
  content_type="application/vnd.tcpdump.pcap"
  timeout "$duration" dumpcap -q -i "$iface" -f "$filter_expr" -w "$artifact" >/dev/null 2>&1 || true
  contains_payload="true"
else
  artifact="$tmp_dir/cdr-diagnostic.sip"
  filename="cdr-diagnostic.sip"
  content_type="text/plain; charset=utf-8"
  timeout "$duration" tcpdump -A -s 0 -n -i "$iface" "$filter_expr" >"$artifact" 2>/dev/null || true
  contains_payload="false"
fi
[[ -s "$artifact" ]] || { echo "No packets captured." >&2; exit 75; }

size_bytes="$(stat -c '%s' "$artifact")"
checksum="$(sha256sum "$artifact" | awk '{print $1}')"
capture_mode="$mode"
[[ "$capture_mode" == "sip_capture" ]] && capture_mode="full"

prepare_payload="$(jq -n \
  --arg diagnosticModule "$module" --arg engine "$engine" --arg resourceType "$resource_type" \
  --arg resourceUUID "$resource_uuid" --arg diagnosticType "$mode" --arg contentType "$content_type" \
  '{module:$diagnosticModule,engine:$engine,resourceType:$resourceType,resourceUUID:$resourceUUID,diagnosticType:$diagnosticType,contentType:$contentType}')"

runtime_query="node_uuid=${node_uuid}&engine=${engine}"
prepare_response="$(curl -fsS -X POST "${api_base%/}/api/v1/voip/cdr-diagnostics/runtime/upload-url?${runtime_query}" \
  -H "Authorization: Bearer $api_token" -H "Content-Type: application/json" -H "X-MNSCloud-Node-UUID: $node_uuid" --data "$prepare_payload")"
upload_url="$(jq -r '.data.uploadUrl // empty' <<<"$prepare_response")"
storage_key="$(jq -r '.data.key // empty' <<<"$prepare_response")"
storage_account_uuid="$(jq -r '.data.storageAccountUUID // empty' <<<"$prepare_response")"
[[ -n "$upload_url" && -n "$storage_key" ]] || { echo "API did not return upload URL." >&2; exit 75; }

curl -fsS -X PUT "$upload_url" -H "Content-Type: $content_type" --data-binary "@$artifact" >/dev/null

register_payload="$(jq -n \
  --arg diagnosticModule "$module" --arg engine "$engine" --arg resourceType "$resource_type" \
  --arg resourceUUID "$resource_uuid" --arg callID "$call_id" --arg storageAccountUUID "$storage_account_uuid" \
  --arg storageObjectKey "$storage_key" --arg checksumSha256 "$checksum" --arg diagnosticType "$mode" \
  --arg captureMode "$capture_mode" --arg originalFilename "$filename" --arg contentType "$content_type" \
  --argjson sizeBytes "$size_bytes" --argjson containsPayload "$contains_payload" \
  '{module:$diagnosticModule,engine:$engine,resourceType:$resourceType,resourceUUID:$resourceUUID,callID:$callID,diagnosticType:$diagnosticType,captureMode:$captureMode,storageMode:"storage",storageAccountUUID:$storageAccountUUID,storageObjectKey:$storageObjectKey,originalFilename:$originalFilename,contentType:$contentType,sizeBytes:$sizeBytes,checksumSha256:$checksumSha256,sanitized:false,containsSdp:true,containsPayload:$containsPayload,status:"available"}')"

curl -fsS -X POST "${api_base%/}/api/v1/voip/cdr-diagnostics/runtime?${runtime_query}" \
  -H "Authorization: Bearer $api_token" -H "Content-Type: application/json" -H "X-MNSCloud-Node-UUID: $node_uuid" --data "$register_payload"
