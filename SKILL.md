# MNSCloud OpenSIPS Connector Skill

Use this contract when changing the `opensips/` module or publishing `manaoscloud/mnscloud-opensips-sbc`.

## Public Repository Boundary

This module is a public edge connector. It may run on MNSCloud, customer, or partner servers and
consume the MNSCloud API contract. It must be fully standalone and must not depend on the private
monorepo at runtime.

## Security Rules

- Do not commit secrets, tokens, private keys, provider credentials, customer data, production IPs, or
  tenant-specific values.
- Do not copy API-side authorization, billing, tenant scoping, routing ownership, or private business
  rules into this module.
- Do not add hidden API bypasses, static master tokens, default production credentials, or privileged
  shortcuts.
- Use placeholders in examples: `<api_base>`, `<node_uuid>`, `<token>`, `<tenant_domain>`.
- Node UUIDs generated, persisted, displayed, or sent by installers must be normalized to lowercase.
- Local secrets must be generated on the target host and stored with restrictive permissions.
- Permanent provider credentials stay in the API/control plane.

## Contract

- Product repository: `manaoscloud/mnscloud-opensips-sbc`
- Local installer: `scripts/install-opensips-sbc.sh`
- Runtime API consumer: MNSCloud SBC runtime endpoints under `/api/v1/sbc/runtime/*`
- Local state prefix: `/etc/mnscloud/sbc`
- Runtime command environment: `MNSCLOUD_API_BASE`, `MNSCLOUD_SBC_NODE_UUID`,
  `MNSCLOUD_SBC_API_TOKEN`, and optional `MNSCLOUD_SBC_ENGINE`
- Media relay contract: OpenSIPS must use API-selected `RealtimeMediaServer` data only. When the
  API returns `rtpengineSocket`, persist it in `/etc/mnscloud/sbc/media.socket` and enable
  OpenSIPS `rtpengine`; do not hardcode media relay addresses in this public connector.
- Lifecycle scripts: install, validate, update by explicit `--ref`, update by release channel, and
  rollback of the local OpenSIPS configuration.

## Checklist

- Validate scripts with `bash scripts/validate-opensips-sbc.sh` or at least `bash -n scripts/*.sh scripts/lib/*.sh`.
- Keep README and `opensips.md` aligned with the install/update/validate/rollback lifecycle.
- Search the module for sensitive values before publishing.
- Keep all required installer helpers inside this repository.
- Keep the module consuming API contracts only.

## Contribution Governance

- External contributions must be submitted through Pull Requests.
- Follow `CONTRIBUTING.md`, `SECURITY.md`, `AGENTS.md`, and this `SKILL.md` before proposing changes.
- Do not add secrets, customer data, private infrastructure details, production domains/IPs, or hidden bypass logic.
- MNSCloud may choose to pay, sponsor, contract, or hire contributors when work demonstrates strong value, but paid work requires explicit written agreement and is never implied by opening a Pull Request.
- Keep security-sensitive decisions, tenant scope, billing, authorization, routing ownership, and secret resolution in the MNSCloud API/control plane.
