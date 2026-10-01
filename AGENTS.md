# OpenToken public contracts

This repository contains only the production OpenToken source snapshot, tests,
offline verification and public deployment evidence for Base and Monad.

- Read README.md and SECURITY.md before changing source or published claims.
- Keep deployed source paths and bytes intact. They are pinned by source hashes
  and exact creation/runtime reproduction, including Solidity metadata.
- Keep historical deployment and observation records immutable. Record later
  observations separately; mint authorization is not minted supply.
- Add only production OpenToken sources, tests and offline verification code.
  No keys, RPC endpoints or operational scripts.
- Build/verification tools must remain offline and must never sign or broadcast.
- Never imply a security audit covers this snapshot without a report naming
  its exact commit. Source verification and tests establish different facts.
- Preserve MIT headers and the pinned upstream dependency licenses.
- Before pushing, run frozen dependency install, `pnpm lint`, `pnpm build`,
  `pnpm test`, `pnpm coverage`, `pnpm audit:dependencies`, and Gitleaks on the
  export and Git history with redacted output. Do not suppress credential findings.
