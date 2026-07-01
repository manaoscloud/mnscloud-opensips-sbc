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
- Optional media relay: API-selected `RealtimeMediaServer` exposed to OpenSIPS as an
  `rtpengineSocket`.

The API/control plane must be deployed with the canonical SBC runtime contract before this connector
is installed or updated.

## Requirements

- Debian 12 or Rocky Linux 8/9.
- Root privileges for package installation, `/etc/opensips`, systemd, and `/etc/mnscloud`.
- Network reachability from the OpenSIPS host to the MNSCloud API base URL.
- A master `VoipSbcServer` record for this runtime, with engine `opensips` and a matching
  `VbsNodeUUID`, or an operational bootstrap flow that can bind the local node UUID.
- Optional: an active `RealtimeMediaServer` selected on the `VoipSbcServer` record when this SBC
  must anchor RTP/SRTP through `mnscloud-media`/`rtpengine`.
- Tenant-facing SBC access is configured through `VoipSbcAccount` records associated to an active
  master SBC server. This connector does not own provider registration.
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

The installer creates or reuses `/etc/mnscloud/sbc/node.uuid`, `/etc/mnscloud/sbc/api.token`, and
`/etc/mnscloud/sbc/api.base`, writes the OpenSIPS configuration, validates bootstrap against the API
when possible, and keeps the original `/etc/opensips/opensips.cfg` as
`/etc/opensips/opensips.cfg.bkp`.

API-generated commands may pass `MNSCLOUD_API_BASE`, `MNSCLOUD_SBC_NODE_UUID`, and
`MNSCLOUD_SBC_API_TOKEN`; when present, the installer persists those values before bootstrapping.
`MNSCLOUD_SBC_ENGINE` may override the default `opensips` engine for future SBC engines that
implement the same runtime contract.
When the API returns `rtpengineSocket`, the installer stores it in
`/etc/mnscloud/sbc/media.socket` and enables OpenSIPS `rtpengine` handling in the generated
configuration. Without an assigned media relay, OpenSIPS runs as SIP signaling/SBC only.

## Validate

```bash
sudo bash scripts/validate-opensips-sbc.sh
sudo opensips -C -f /etc/opensips/opensips.cfg
sudo systemctl status opensips
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

## Rollback

```bash
sudo bash scripts/rollback-opensips-sbc.sh
```

Rollback restores `/etc/opensips/opensips.cfg.bkp`, validates the restored config, and restarts
`opensips.service`. It is a local OpenSIPS configuration rollback; API/control-plane records and
repository refs are not changed.

See `opensips.md` and `SECURITY.md` for details.

## Runtime Behavior

- OpenSIPS owns SIP signaling, pipe lookup, media entry points, and topology control.
- RTP/SRTP media anchoring is delegated to the reusable `mnscloud-media` runtime through
  `rtpengine` when the API assigns a media relay to this SBC server.
- Codec policy is represented in SBC pipes and must remain API/control-plane driven; the
  connector applies only the runtime instructions returned by the API contract.
