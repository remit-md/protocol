# remit.md / protocol

Solidity smart contracts for the [remit.md](https://remit.md) payment protocol - escrow, tabs, streams, bounties on EVM L2s.

## Contracts

| Contract | Purpose | Upgradeable |
|----------|---------|-------------|
| `RemitEscrow` | Milestone-based escrow with splits and disputes | No |
| `RemitTab` | Off-chain payment channels (EIP-712 signed vouchers) | No |
| `RemitStream` | Lockup-linear token streaming | No |
| `RemitBounty` | Post/submit/award bounties | No |
| `RemitDeposit` | Refundable security deposits | No |
| `RemitFeeCalculator` | Marginal fee tiers with monthly reset | Yes (UUPS) |
| `RemitRouter` | Contract registry + direct payments | Yes (UUPS) |

All fund-holding contracts are immutable (no proxy). Reentrancy guards and CEI pattern enforced throughout.

## Also included

- **`remit.md`** - The full protocol specification (agent-readable)
- **`shared/`** - Source-of-truth type definitions, error codes, events, and OpenAPI spec
- **`scripts/`** - Deploy, verify, and codegen tooling

## Setup

```bash
# Install dependencies
forge install

# Build
forge build

# Test (222 tests, includes fuzz)
forge test

# Test with extended fuzz runs
forge test --fuzz-runs 1000

# Format
forge fmt
```

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation). Solidity 0.8.24, optimizer enabled (200 runs).

## Deploy

```bash
# Local (Anvil)
scripts/deploy-local.sh

# Testnet (Base Sepolia)
scripts/deploy-testnet.sh
```

## License

MIT
