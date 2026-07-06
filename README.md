# MNSCloud OpenSIPS SBC

Public standalone OpenSIPS SBC connector for MNSCloud.

This repository installs and configures local OpenSIPS runtime assets that consume the MNSCloud API
contract. It can run on MNSCloud, customer, or partner infrastructure.

## Boundary

- This repository is public and auditable by design.
- It must remain standalone and must not depend on the private MNSCloud monorepo at runtime.
- The MNSCloud API is the source of truth for authorization, tenant scope, routing ownership, billing,
  policy, and secret resolution.
- Do not commit secrets, customer data, production infrastructure values, provider credentials, or
  private business rules.

## Contract

- Product/runtime: `mnscloud-opensips-sbc`
- Project directory: `/opt/mnscloud/mnscloud-opensips-sbc`
- Installer: `scripts/install-opensips-sbc.sh`
- Validator: `scripts/validate-opensips-sbc.sh`
- Update by ref: `scripts/update-opensips-sbc.sh --ref <git-ref>`
- Update channel: `scripts/update-latest-opensips-sbc.sh [stable]`
- Rollback local OpenSIPS cfg: `scripts/rollback-opensips-sbc.sh`
- Shared package installer: `mnscloud-runtime-kit`
- Service: `opensips.service`
- Local state prefix: `/etc/mnscloud/sbc`
- Node UUID: `/etc/mnscloud/sbc/node.uuid`
- API token: `/etc/mnscloud/sbc/api.token`
- API base URL: `/etc/mnscloud/sbc/api.base`
- OpenSIPS config: `/etc/opensips/opensips.cfg`
- Config validation: `opensips -C -f /etc/opensips/opensips.cfg`
- Runtime API: `/api/v1/sbc/runtime/*`
- Runtime engine: `opensips`
- Runtime config cache: `/etc/mnscloud/sbc/runtime/config.json`
- OpenSIPS local db_text: `/etc/mnscloud/sbc/dbtext`
- Optional media relay: API-selected `RealtimeMediaServer` exposed to OpenSIPS as an
  `rtpengineSocket`.

The API/control plane must be deployed with the canonical SBC runtime contract before this connector
is installed or updated.

## Requirements

- Debian 12 or Rocky Linux 8/9.
- Root privileges for package installation, `/etc/opensips`, systemd, and `/etc/mnscloud`.
- Network reachability from the OpenSIPS host to the MNSCloud API base URL.
- `mnscloud-agent` already installed, enrolled, active, and updated with support for
  `voip.sbc.runtime` jobs. The SBC installer calls
  `/opt/mnscloud/mnscloud-agent/scripts/validate-agent.sh` and fails closed when the Agent is
  missing, inactive, unenrolled, or too old for SBC runtime jobs.
- A master `VoipSbcServer` record for this runtime, with engine `opensips` and a matching
  `VbsNodeUUID`, or an operational bootstrap flow that can bind the local node UUID.
- Optional: an active `RealtimeMediaServer` selected on the `VoipSbcServer` record when this SBC
  must anchor RTP/SRTP through `mnscloud-media`/`rtpengine`.
- Tenant-facing SBC access is configured through `VoipSbcAccount` records associated to an active
  master SBC server. `VoipSbcPeer` records identify inbound SIP interconnections and their
  authentication/monitoring policy. `VoipSbcPipe` records define the tenant-aware flow from an
  inbound peer to a direct outbound SIP destination with host, port, transport and failover. Peer
  authentication, registration, IP allowlists, SIP-I/SIP-T interworking, media policy, and codec
  policy are API/control-plane records consumed by this connector at runtime.
- SIP firewall rules opened according to the deployment model, typically `5060/udp` and `5060/tcp`.

## Install

Install GitHub CLI if needed:
[cli/cli installation](https://github.com/cli/cli#installation).

Authenticate GitHub CLI:

```bash
gh auth login
```

Clone the repository and install:

```bash
sudo install -d -m 0755 /opt/mnscloud
cd /opt/mnscloud
gh repo clone manaoscloud/mnscloud-opensips-sbc
cd /opt/mnscloud/mnscloud-opensips-sbc
sudo bash scripts/install-opensips-sbc.sh
```

For a no-change preview:

```bash
sudo bash scripts/install-opensips-sbc.sh --dry-run
```

The installer first validates the Agent through the shared `validate-agent.sh` contract with
`--require-active --require-enrolled --require-job voip.sbc.runtime`. It then creates or reuses `/etc/mnscloud/sbc/node.uuid`,
`/etc/mnscloud/sbc/api.token`, and `/etc/mnscloud/sbc/api.base`, validates bootstrap against the
API when possible, prepares the local OpenSIPS runtime directories, writes the OpenSIPS
configuration, and keeps the original `/etc/opensips/opensips.cfg` as
`/etc/opensips/opensips.cfg.bkp`. It also configures OpenSIPS memory defaults in
`/etc/default/opensips` and removes any legacy
`mnscloud-opensips-sbc-sync.timer`/service units. Runtime changes must be delivered by the
MNSCloud Agent `voip.sbc.runtime` job, with no periodic fallback reconciler. At the end of a
successful install, it refreshes or restarts the Agent so the host publishes the effective
`voip.sbc.manage` capability and requests the initial runtime sync when local runtime config is
missing.

API-generated commands may pass `MNSCLOUD_API_BASE`, `MNSCLOUD_SBC_NODE_UUID`, and
`MNSCLOUD_SBC_API_TOKEN`; when present, the installer persists those values before bootstrapping.
`MNSCLOUD_SBC_ENGINE` may override the default `opensips` engine for future SBC engines that
implement the same runtime contract.
When the API returns `rtpengineSocket`, the installer stores it in
`/etc/mnscloud/sbc/media.socket` and enables OpenSIPS `rtpengine` handling in the generated
configuration. Without an assigned media relay, OpenSIPS runs as SIP signaling/SBC only.
The generated OpenSIPS configuration sets both SIP `Server` and `User-Agent` headers to
`MNSCloud OpenSIPS SBC`.
Generated SIP sockets listen on all interfaces and advertise the detected public IPv4, falling
back to the first private IPv4 when public detection is unavailable. Initial INVITEs are
Record-Routed so ACK/BYE/re-INVITE requests stay on the SBC path; ACK requests without route
headers are resolved through the same runtime pipe contract and fail closed when no active pipe is
found.

## Validate

```bash
sudo bash scripts/validate-opensips-sbc.sh
sudo opensips -C -f /etc/opensips/opensips.cfg
sudo systemctl status opensips
sudo bash scripts/opensips-sbc-mi.sh reg_list
```

The validator checks shell syntax and, when OpenSIPS is installed, validates the active OpenSIPS
configuration.

## Update

Update to an explicit release, branch, tag, or commit:

```bash
sudo bash scripts/update-opensips-sbc.sh --ref v0.1.2
```

Update to the release manifest channel, defaulting to `stable`:

```bash
sudo bash scripts/update-latest-opensips-sbc.sh stable
```

Both update flows fetch the repository, checkout the target ref, rerun the installer, and then run
the validator. Existing local state under `/etc/mnscloud/sbc` is reused.

## Runtime Sync

```bash
sudo bash scripts/sync-opensips-sbc-runtime.sh
```

The sync command calls `POST /api/v1/sbc/runtime/config` using the local node UUID and API token.
It updates:

- `/etc/mnscloud/sbc/runtime/config.json`
- `/etc/mnscloud/sbc/runtime/summary.json`
- `/etc/mnscloud/sbc/dbtext/version`
- `/etc/mnscloud/sbc/dbtext/registrant`
- `/etc/mnscloud/sbc/media.socket`, when the API assigns an RTP engine socket

Files are owned by `root:root` and written as `0640`. Runtime secrets are consumed only by the SBC
host and are not embedded in public documentation or frontend code.

For installed servers, configuration changes arrive through the MNSCloud Agent
`voip.sbc.runtime` job. The Agent runs `scripts/sync-and-reload-opensips-sbc.sh`, which compares the
generated registrant table before and after sync. Removed REGISTER peers are first disabled with
the official OpenSIPS MI `reg_disable` command so the remote registrar receives an unREGISTER, then
changed registrations are applied with `reg_reload`. `opensips.service` is restarted only for
static runtime changes that cannot be applied by MI, such as a changed media socket. Manual
execution of the sync script is reserved for troubleshooting or controlled maintenance.

OpenSIPS MI commands should be executed through the repository helper so the reply FIFO is created
with the same ownership and permissions as the installed service:

```bash
sudo bash scripts/opensips-sbc-mi.sh reg_list
sudo bash scripts/opensips-sbc-mi.sh reg_reload
sudo bash scripts/opensips-sbc-mi.sh reg_force_register \
  aor=sip:user@example.com \
  contact=sip:user@203.0.113.10 \
  registrar=sip:registrar.example.com:5060\;transport=udp
sudo bash scripts/opensips-sbc-mi.sh reg_disable \
  aor=sip:user@example.com \
  contact=sip:user@203.0.113.10 \
  registrar=sip:registrar.example.com:5060\;transport=udp
```

The installed `mi_fifo` configuration keeps the command FIFO at
`/run/opensips/mnscloud_sbc_fifo` and the reply directory at `/run/opensips/`. Keep the trailing
slash in the `reply_dir` value; OpenSIPS builds the reply FIFO path from that directory and the
reply FIFO name sent in the MI command.

During install/update, the installer does not apply runtime sync directly. The MNSCloud Agent
publishes the node UUID and local runtime state in heartbeat; the API then queues a
`voip.sbc.runtime` job for the Agent whenever the assignment is new or the local runtime config is
missing.

## Rollback

```bash
sudo bash scripts/rollback-opensips-sbc.sh
```

Rollback restores `/etc/opensips/opensips.cfg.bkp`, validates the restored config, and restarts
`opensips.service`. It is a local OpenSIPS configuration rollback; API/control-plane records and
repository refs are not changed.

See `opensips.md` and `SECURITY.md` for details.

## Runtime Behavior

- OpenSIPS owns SIP signaling, runtime pipe lookup payload collection, media entry points, and
  topology control.
- RTP/SRTP media anchoring is delegated to the reusable `mnscloud-media` runtime through
  `rtpengine` when the API assigns a media relay to this SBC server.
- Codec policy is represented in SBC pipes and must remain API/control-plane driven; the
  connector applies only the runtime instructions returned by the API contract.
- Peer authentication supports the control-plane modes `ip`, `register`, `ip_digest`, and `none`.
  IP authentication must be backed by explicit allowed source addresses. REGISTER peers should also
  define allowed source addresses for inbound calls when the carrier sends INVITEs without
  Authorization, otherwise pipe lookup fails closed. REGISTER and OPTIONS status must be reported
  back to `/api/v1/sbc/runtime/peer-status`; tenant users should not edit runtime health fields
  directly.
- REGISTER peers are exported to the official OpenSIPS `uac_registrant` module through a local
  `db_text` database generated from the authenticated runtime config endpoint. The local table is
  an OpenSIPS module requirement; changes are applied at runtime through MI `reg_reload`, not by
  reinstalling the SBC.
- SIP-I/SIP-T is represented by peer/pipe signaling profiles. OpenSIPS 3.6 uses the official
  `sip_i.so` module when available from the installed package. If the module is absent, the
  installer warns and keeps SIP-I payload interworking disabled instead of generating a broken
  configuration.
- Pipe lookup is API-controlled. The connector sends source/local/RURI/From/To context; the API
  identifies the inbound peer, selects exactly one authorized pipe to a direct outbound SIP destination, or
  fails closed on ambiguity.
- Peer CDR is opt-in. New peers default to CDR disabled and must explicitly enable accounting when
  call detail collection is required. When enabled on the inbound peer, the runtime posts an `invite` accounting event
  with Call-ID, pipe, inbound peer, source, destination and selected outbound target to the API,
  which persists it in `VoipSbcCdr`.
- The generated OpenSIPS 3.6 config uses `$si`/`$sp` for the remote source and
  `$socket_in(proto|ip|port)` for the received local socket context.
