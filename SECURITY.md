# Security policy

Report suspected vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/devfun-org/opentoken-contracts/security/advisories/new)
or [hello@dev.fun](mailto:hello@dev.fun). Include the source commit, chain and
contract address, impact, reproduction steps and proposed mitigation if available.
Do not send private keys or live payment authorizations. Please avoid public
exploit details while maintainers assess the report.

## Scope and support

The supported snapshot is the production suite listed in README.md and
`deployments/opentoken-prod-manifest-20260929.json`. The source was deployed
from original commit `144436d36e7982273158279605d1877701fabe61`. This repository
has fresh history and contains a byte-identical export of the relevant sources.
External USDC, Safe, Permit2, deposit proxies and application services have
separate implementations and security boundaries.

No independent security review report naming this exported snapshot is
published here. Exact bytecode reproduction, source verification, coverage and
passing CI do not establish the safety of contract behavior or later governance.

## Authority and trust boundaries

- TOKEN is not a proxy. Its balance/permit implementation is immutable, but the
  Timelock can change its selected Minter after at least 48 hours. The current
  Minter checks exact new USDC receipt at Vault, cumulative mint authorization
  and Vault pause. TOKEN does not independently enforce those three checks.
  A malicious replacement can bypass them; review every proposed replacement.
- Routine replacement must retire the predecessor, switch the expected Minter
  and import final authorization/issuance counters atomically. Burns do not
  restore authorization. These guarantees depend on the chosen Minter code.
- Governance and Finance use distinct 2/3 Safes with the same three owners.
  They do not represent independent signing groups. Owner/threshold changes
  follow Safe's own quorum, without the OpenToken governance delay.
- Guardian and Timelock can pause Vault or Collector independently. Vault pause
  blocks current-Minter issuance and withdrawals and invalidates outstanding
  withdrawals by advancing the incident. TOKEN transfers and holder burns are
  not paused. Only delayed governance can resume an incident. A Vault pause
  does not cancel queued cap changes or Minter replacements.
- Finance Safe requests withdrawals of existing, unreserved USDC; anyone can
  execute an eligible request after 24 hours. Finance, Guardian or Timelock may
  cancel an eligible request. Finance replacement requires a paused Vault and
  a delayed governance call. Vault has no arbitrary-call rescue.
- USDC receipt proves a payment at issuance, not continuing reserves or a
  redemption entitlement. Holder-only TOKEN burns do not create application
  credits; application accounting follows Collector conversion separately.
- EIP2612 authorizes allowance, not a purchase. Router binds the selected Minter
  into USDC authorization and rejects a stale target before accepting payment.
  Old signatures and allowances are not revoked merely by changing the Minter.

## Disclosure hygiene

The private source repository was scanned across all available branch, tag, PR
and local reflog history before export. Public address/code-hash false positives
are documented in `verification/secret-scan.json`; no operational credential was
identified. Any subsequently discovered committed credential must be revoked
or rotated even if it was removed in a later commit. Do not publish raw scanner
reports containing secrets. CI scans this repository's complete available Git
history and export with Gitleaks; its narrow public-metadata exceptions do not
exclude files, directories or commits.
