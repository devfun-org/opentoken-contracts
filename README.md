# OpenToken production contracts

[![Contracts CI](https://github.com/devfun-org/opentoken-contracts/actions/workflows/ci.yml/badge.svg)](https://github.com/devfun-org/opentoken-contracts/actions/workflows/ci.yml)

The production OpenToken contracts on **Base mainnet (8453)** and **Monad mainnet
(143)**, exported into fresh Git history from deployed source commit
`144436d36e7982273158279605d1877701fabe61`. Solidity sources and paths are unchanged.
The compiler is **solc 0.8.36+commit.8a079791**, optimizer 200 runs, Shanghai EVM,
with IPFS bytecode metadata. License: [MIT](LICENSE).

OpenTokens (`TOKEN`, six decimals) are issued by the current Minter against an
exact, newly received native USDC payment at TreasuryVault. Collector burns
receiver balances and emits conversion events for separate application accounting.
Mint authorization is cumulative issuance, not current supply or a reserve guarantee.
Burning TOKEN does not restore mint capacity or itself create application credits.

## Production addresses

Each contract address links to its Sourcify source verification. All **18** entries
have exact creation and runtime matches, including metadata and constructor data.
The constructor-only Genesis is included to reproduce TOKEN/Vault/Minter creation;
it retains no bootstrap authority. Factory and Receiver intentionally retain their
original `src/credits/OpenTokenDepositFactory.sol` path because renaming source
units would change verification metadata.

| Contract | Base mainnet | Monad mainnet |
| --- | --- | --- |
| OpenToken | [`0x024f68013b8b7e8E2aB85F3716ee1FE8511b3968`](https://repo.sourcify.dev/8453/0x024f68013b8b7e8E2aB85F3716ee1FE8511b3968) | [`0xcCf3517F5b75B75aA599702c90A8a2CC297791F4`](https://repo.sourcify.dev/143/0xcCf3517F5b75B75aA599702c90A8a2CC297791F4) |
| OpenTokenMinter | [`0x77cAe4a61409956d33DDb7dC063708E6324Ae7ee`](https://repo.sourcify.dev/8453/0x77cAe4a61409956d33DDb7dC063708E6324Ae7ee) | [`0x8d47e2e2358a0FF1Ba6d9a4716365f338F8f2913`](https://repo.sourcify.dev/143/0x8d47e2e2358a0FF1Ba6d9a4716365f338F8f2913) |
| TreasuryVault | [`0x6749210938556D215C13Dad2D3f6DFF49DfB9b6D`](https://repo.sourcify.dev/8453/0x6749210938556D215C13Dad2D3f6DFF49DfB9b6D) | [`0x61978CB2e675a2a317F715e8EFD2285D10D68272`](https://repo.sourcify.dev/143/0x61978CB2e675a2a317F715e8EFD2285D10D68272) |
| PaidOpenTokenCollector | [`0x4F034F5F60F27722736C4c80Ede713cC3FB20D45`](https://repo.sourcify.dev/8453/0x4F034F5F60F27722736C4c80Ede713cC3FB20D45) | [`0x526875a09d2dd24114cA4454573e3AbDc99cA31E`](https://repo.sourcify.dev/143/0x526875a09d2dd24114cA4454573e3AbDc99cA31E) |
| OpenTokenDepositFactory | [`0x5022674732fd593bbC1Af4b6007CaE15b6CF16e8`](https://repo.sourcify.dev/8453/0x5022674732fd593bbC1Af4b6007CaE15b6CF16e8) | [`0xedB30485b755c46dA0FcF841ded8aCc401E489b2`](https://repo.sourcify.dev/143/0xedB30485b755c46dA0FcF841ded8aCc401E489b2) |
| OpenTokenDepositReceiver | [`0x4b7B4a2736fAD448Aa0c50E4A8B69F7d9f40696B`](https://repo.sourcify.dev/8453/0x4b7B4a2736fAD448Aa0c50E4A8B69F7d9f40696B) | [`0x84Db4cdAf8ae4C3C2cCaAbA8cF9C6BecA478F846`](https://repo.sourcify.dev/143/0x84Db4cdAf8ae4C3C2cCaAbA8cF9C6BecA478F846) |
| OpenTokenPurchaseRouter | [`0x4978F88f73201B154A91ad7269BBA10651903950`](https://repo.sourcify.dev/8453/0x4978F88f73201B154A91ad7269BBA10651903950) | [`0x2B8D237d269EdD369Cd1BDA90d98A0Be94129c47`](https://repo.sourcify.dev/143/0x2B8D237d269EdD369Cd1BDA90d98A0Be94129c47) |
| OpenTokenTimelock | [`0xb81A87F651C326642798f7F6698104aB76292626`](https://repo.sourcify.dev/8453/0xb81A87F651C326642798f7F6698104aB76292626) | [`0xdc262805f606697b22443018B652438BD2D52567`](https://repo.sourcify.dev/143/0xdc262805f606697b22443018B652438BD2D52567) |
| OpenTokenGenesis | [`0x9a5B1Fae714816fB6E0bf3E4B53BFa01Aa9128e9`](https://repo.sourcify.dev/8453/0x9a5B1Fae714816fB6E0bf3E4B53BFa01Aa9128e9) | [`0x8c08c23A787BfE9670b0dCcAfEf0f745A60a805e`](https://repo.sourcify.dev/143/0x8c08c23A787BfE9670b0dCcAfEf0f745A60a805e) |

The Base Timelock at `0xb81A87F651C326642798f7F6698104aB76292626` is verified on
[Sourcify](https://repo.sourcify.dev/8453/0xb81A87F651C326642798f7F6698104aB76292626)
with exact creation and runtime matches. This repository makes no assertion about
an explorer's separate verification badge.

[Production deployment records](deployments/production.json) include deployment
transactions/blocks, original source commit, compiler, constructor arguments,
runtime hashes and pinned onchain observations. The
[September 29 application manifest](deployments/opentoken-prod-manifest-20260929.json)
identifies the same suites. Manifest identity does not establish application
activation, payment admission or accounting acceptance.

## Authority and limits

| Control | Enforcement |
| --- | --- |
| Mint authorization | Current Minter enforces cumulative paid issuance; only Timelock may increase the total. Burns never restore it. |
| Governance delay | At least 48 hours, including changes to the delay itself. Governance Safe holds proposer and canceller roles; execution is open once scheduled operations mature. Timelock administers itself. |
| Safe quorum | Both Governance and Finance are 2/3 on each chain at the recorded checkpoints. Their distinct addresses share the same three owners, so these are not independent signer groups. Membership changes follow Safe quorum without the OpenToken delay. |
| Guardian | Can pause Vault and Collector separately and cancel eligible withdrawals; cannot mint, increase authorization, withdraw arbitrarily or resume operations. |
| Vault pause | Blocks current-Minter issuance and withdrawals; each pause invalidates outstanding withdrawal requests. Governance resumes against the current incident after its delay. |
| Collector pause | Independently blocks conversion, with incident-bound recovery by delayed governance. Ordinary TOKEN transfers and holder burns remain available. |
| Finance | Requests withdrawals of existing unreserved USDC. Anyone may execute an eligible request after 24 hours. Finance, Guardian or Timelock may cancel. Changing Finance requires Vault pause and delayed governance. |
| Upgrade/replacement | TOKEN and the other listed contracts have no proxy upgrade entry point. Timelock can replace TOKEN's selected Minter. TOKEN does not independently enforce the Minter's payment/cap/pause rules; a malicious replacement can bypass them. Routine replacement must retire the predecessor, select the expected successor and import counters atomically. |
| Genesis | Constructor-only atomic initialization; no callable initializer or retained deployment role. |

### Recorded limits and role addresses

These are dated observations, not live settings. On October 1, 2026, the finalized
checkpoints were Base **52022367** and Monad **109533520**. Base's authorization was
still **10,000 TOKEN**; Monad's was **50,000 TOKEN**. The requested 50,000-per-chain
target does not become a Base contract limit until its delayed governance change
executes. Historical initial authorization in the manifest is not rewritten.

| Role / external asset | Base | Monad |
| --- | --- | --- |
| Governance Safe | `0x82B8fDaB5ecA2618a5E917e1831010628E366550` | `0xdD4E5337C3E7c0F91647eb54ad506d24Ef9dA307` |
| Finance Safe | `0xff1871570603C98a7308254c7Cc26a8a0Bc8F937` | `0xbaFf5DEB01c38c54c9F2C22F7b81a4C2652243a3` |
| Guardian | `0x6d9B25f186F90ad781EBcF7d205682cccD20708e` | `0x6d9B25f186F90ad781EBcF7d205682cccD20708e` |
| Native USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x754704bc059f8c67012fed69bc8a327a5aafb603` |

USDC, Safe, Permit2 and the external deposit proxy are dependencies, not OpenToken
implementations in this repository. Safe owner lists and observed role bindings
are in the deployment record. Read [SECURITY.md](SECURITY.md) for trust boundaries
and private reporting. No independent security review report naming this exported
snapshot is published here.

## Build, test and reproduce

Prerequisites: Foundry **v1.8.3**, Node **22**, PNPM **9.12.0**, and Gitleaks **8.23.3**.

```sh
git clone https://github.com/devfun-org/opentoken-contracts.git
cd opentoken-contracts
git submodule update --init
pnpm install --frozen-lockfile
pnpm lint
pnpm build
pnpm test
pnpm coverage
pnpm audit:dependencies
gitleaks git --log-opts=--all --ignore-gitleaks-allow --redact=100
```

`pnpm build` compiles with Forge, then independently compiles the preserved standard
JSON inputs with solc-js. It compares each input source to the checked-out file,
checks source hashes, reproduces creation code including constructor arguments,
and compares the complete runtime after filling only compiler-declared immutable
slots. Metadata is included; no bytecode suffix is ignored. It checks all 18
addresses against [recorded bytecode evidence](verification/production-bytecode.json)
and the pinned chain runtime hashes. The build is offline after dependencies are
installed; it never signs, broadcasts or reads an RPC endpoint. To independently
refresh chain evidence, read runtime code at the recorded block and compare its
Keccak-256 hash with the public record using your preferred chain client.

Tests cover issuance/payment errors, authorization/replay protections, Minter
replacement, withdrawal reservations/incidents, pausing, deterministic receivers,
conversion and the Timelock floor. CI also enforces per-source coverage (100% lines
and functions, at least 90% branches), dependency checks and secret scanning.
Pinned upstream dependencies retain their own licenses: OpenZeppelin Contracts
`acd4ff74de833399287ed6b31b4debf6b2b35527` and forge-std
`bf647bd6046f2f7da30d0c2bf435e5c76a780c1b`.

## Export and disclosure scope

This is a fresh repository, not the original private repository made public.
Only the production OpenToken contracts listed above, their tests, offline
build/verification code and public deployment evidence are included.

[Secret-scan evidence](verification/secret-scan.json) records the available full
private-repository history review and scanner positive controls. Gitleaks findings
for public EVM addresses and code hashes were reviewed; no operational credential
was identified for rotation. CI scans the new Git history and exported tree with
redacted output. Published build/source verification is separate from a security
review, continuing reserves and application acceptance.
