# Security Policy

## Reporting a Vulnerability

StarkPrivacy handles cryptographic assets. We take security seriously.

**Do NOT open a public issue for security vulnerabilities.**

### Disclosure Process

1. **Email** security findings to: **security@soulresearchlabs.com**
2. Include:
   - Description of the vulnerability
   - Steps to reproduce or proof of concept
   - Affected components (Cairo contracts, SDK, bridge, etc.)
   - Severity assessment (Critical / High / Medium / Low)
3. You will receive an acknowledgement within **48 hours**.
4. We will provide a fix timeline within **5 business days**.

### Scope

The following are in scope for responsible disclosure:

| Component                       | Scope                                                      |
| ------------------------------- | ---------------------------------------------------------- |
| Cairo contracts (`crates/`)     | All on-chain logic                                         |
| TypeScript SDK (`sdk/`)         | Cryptographic operations, key management, proof generation |
| EVM bridge (`contracts/evm/`)   | Solidity bridge contract                                   |
| Deployment scripts (`scripts/`) | Credential handling, safety checks                         |
| Governance pipeline             | MultiSig, Timelock, Proxy interactions                     |

### Out of Scope

- Social engineering attacks
- Denial of service against public RPC providers
- Issues in third-party dependencies (report upstream)
- Issues in development-only code (MockVerifier, devnet scripts)

### Severity Definitions

| Severity     | Description                                                        | Response Time |
| ------------ | ------------------------------------------------------------------ | ------------- |
| **Critical** | Direct loss of funds, privacy break, governance bypass             | < 4 hours     |
| **High**     | Potential fund loss under specific conditions, nullifier collision | < 24 hours    |
| **Medium**   | DoS of protocol operations, relayer griefing, gas exhaustion       | < 72 hours    |
| **Low**      | Information leak, UX issues, non-critical edge cases               | < 1 week      |

### Safe Harbor

We will not pursue legal action against researchers who:

- Act in good faith
- Do not exploit vulnerabilities beyond proof of concept
- Do not access or modify other users' data
- Report findings promptly and privately

### Bug Bounty

A formal bug bounty program will be announced prior to mainnet launch. Contact the security email for current bounty eligibility.
