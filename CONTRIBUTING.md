# Contributing to StarkPrivacy

Thank you for your interest in contributing. This guide covers the process for reporting issues, proposing changes, and submitting code.

## Code of Conduct

Be respectful, constructive, and professional. We welcome contributors of all experience levels.

## Getting Started

### Prerequisites

| Tool             | Version   | Purpose                            |
| ---------------- | --------- | ---------------------------------- |
| Scarb            | >= 2.16.0 | Cairo package manager and compiler |
| Starknet Foundry | >= 0.57.0 | Cairo testing (`snforge`)          |
| Node.js          | >= 20     | SDK development                    |
| Foundry (forge)  | >= 1.5.0  | EVM bridge testing                 |

### Setup

```bash
# Clone and enter the repo
git clone https://github.com/Soul-Research-Labs/Answe.git
cd starkprivacy

# Build Cairo contracts
scarb build

# Run Cairo tests
snforge test --workspace

# Setup SDK
cd sdk && npm install && npm test
```

## How to Contribute

### Reporting Bugs

- Open a GitHub issue with reproduction steps, expected vs. actual behavior, and environment details.
- **Security vulnerabilities**: Do NOT open public issues. See [SECURITY.md](SECURITY.md).

### Proposing Changes

1. Open an issue describing what you want to change and why.
2. Wait for discussion/approval before starting large changes.
3. Fork the repo and create a feature branch (`feature/your-change`).

### Submitting Pull Requests

1. **One concern per PR** — don't mix features, fixes, and refactors.
2. **Write tests** — all new code must have test coverage.
3. **Run the full suite** before submitting:
   ```bash
   scarb build
   snforge test --workspace
   cd sdk && npm run lint && npm test
   cd ../contracts/evm && forge test
   ```
4. **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat(pool): add multi-asset deposit support`
   - `fix(relayer): handle nonce gaps on restart`
   - `test(stealth): add scan edge-case coverage`
   - `docs(spec): update fee model section`

### Code Style

**Cairo:**

- Follow the default `scarb fmt` formatting.
- Use explicit types — avoid excessive inference in public APIs.
- Prefer components over inheritance for reusable contract logic.

**TypeScript:**

- Strict mode (`"strict": true` in tsconfig).
- No `any` in public APIs — use proper generics or union types.
- Tests use Vitest with `describe` / `it` / `expect` style.

**Solidity:**

- Follow Foundry formatting defaults.
- Use NatSpec comments for public/external functions.

## Project Structure

| Directory        | Contents                                                      |
| ---------------- | ------------------------------------------------------------- |
| `crates/`        | Cairo contract crates (pool, bridge, stealth, security, etc.) |
| `sdk/`           | TypeScript SDK, CLI, and tests                                |
| `contracts/evm/` | Solidity bridge contract and Foundry tests                    |
| `tests/`         | Cairo integration and fuzz tests                              |
| `scripts/`       | Deployment, devnet, and monitoring scripts                    |
| `docs/`          | Protocol spec, security checklist, formal specs, runbooks     |

## Review Process

1. All PRs require at least one approval.
2. CI must pass (Cairo build + tests, SDK lint + tests, EVM tests).
3. Security-sensitive changes require review from a core maintainer.
4. Documentation changes may be merged with a lighter review.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
