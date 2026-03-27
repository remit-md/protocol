# Security Policy

## Overview

Remit protocol is a collection of Solidity smart contracts implementing a universal
payment system for AI agents on EVM-compatible networks. This document describes the
security architecture, known risks, and responsible disclosure policy.

---

## Architecture

### Fund-Holding Contracts (Immutable)

The five contracts that hold user funds are **non-upgradeable**:

| Contract | Role |
|----------|------|
| `RemitEscrow` | Milestone-gated escrow with dispute resolution |
| `RemitTab` | Running credit tab with periodic settlement |
| `RemitStream` | Real-time per-second USDC streaming |
| `RemitBounty` | Post-and-award bounty pools |
| `RemitDeposit` | Locked collateral deposits |

Immutability guarantees that once deployed, fund logic cannot be altered - not even
by the protocol owner.

### Upgradeable Contracts (UUPS Proxies)

Two non-fund-holding contracts use OpenZeppelin UUPS proxies for parameter updates:

| Contract | Role | Upgrade rationale |
|----------|------|-------------------|
| `RemitRouter` | Entry point, fee routing, address registry | Fee rates and contract addresses may need updating |
| `RemitFeeCalculator` | Fee calculation with volume cliff | Fee schedule may change |

Upgrades require the `owner` address (multi-sig after mainnet launch).

### Supporting Contracts

| Contract | Role |
|----------|------|
| `RemitKeyRegistry` | EIP-712 session key management |

---

## Security Properties

### Reentrancy Protection

All state-changing functions that interact with external contracts or move funds use:

- **`nonReentrant`** (OpenZeppelin ReentrancyGuard) on every external fund-moving function
- **CEI pattern** (Checks-Effects-Interactions) - state changes committed before external calls
- **`SafeERC20`** for all USDC transfers (reverts on failed transfers, handles non-standard ERC20s)

### Access Control

| Capability | Who can call |
|-----------|--------------|
| Create payment instrument | Any authorized wallet |
| Release / withdraw funds | Designated payee or authorized relayer |
| Cancel / reclaim | Designated payer (within allowed window) |
| Set fee rates | Protocol owner only |
| Register session key | Wallet owner only |
| Upgrade proxy contracts | Protocol owner only |

### EIP-712 Authentication

API-layer requests use EIP-712 structured data signing, anchored to the Router contract address
and chain ID. This prevents cross-chain and cross-contract replay attacks.

Nonces are tracked per-wallet in Redis with a sliding 1-hour TTL to prevent replay within
valid windows.

### Rate Limiting

Payments are protected by a 4-layer rate limit:
1. IP-level rate limit (nginx)
2. Wallet-level rate limit (server)
3. Action-level rate limit (per payment type)

---

## Known Accepted Risks

No known accepted risks at this time.

---

## Internal Audit History

Two internal security reviews were conducted before external audit engagement.

### V1 Internal Review (2026-03-08)

Findings: **0 critical, 0 high, 0 medium**

Original medium finding (PRNG in `RemitArbitration`) is no longer applicable - contract was removed.

### V2 Internal Review (2026-03-09)

Focused on access control gaps and code quality. Findings resolved:

| ID | Severity | Description | Status |
|----|----------|-------------|--------|
| KR-L-01 | Low | `deauthorizeContract()` missing from KeyRegistry | Fixed |
| KR-I-02 | Low | No `allowedModelsBitmap != 0` check in `delegateKey()` | Fixed |

---

## Static Analysis (Slither)

**Tool:** slither-analyzer 0.11.5
**Date:** 2026-03-13
**Contracts analyzed:** 62 (all source contracts, excluding tests and libraries)
**Raw results:** 80

| Severity | Raw | False Positives | Real | Status |
|----------|-----|-----------------|------|--------|
| High | 2 | 0 | 2 | N/A - both in `RemitArbitration` (removed) |
| Medium | ~8 | ~7 | 1 | N/A - in `OnrampVaultFactory` (removed) |
| Low | ~20 | ~20 | 0 | All false positives |
| Info | ~50 | ~50 | 0 | Standard patterns |

**All real findings were in contracts that have since been removed from the codebase.** Zero unresolved findings in current source.

---

## Test Coverage

**Test runner:** Foundry (forge)
**Date:** 2026-03-13
**Total tests:** 470 passing, 0 failing

| Type | Count |
|------|-------|
| Unit tests | ~370 |
| Fuzz tests | ~56 (256 runs each) |
| Invariant tests | 3 (128,000 calls each) |
| Integration / E2E | ~40 |

### Fund-Holding Contract Line Coverage

| Contract | Line Coverage |
|----------|--------------|
| RemitEscrow | 96.17% |
| RemitTab | 99.15% |
| RemitStream | 100% |
| RemitBounty | 100% |
| RemitDeposit | 100% |

### Fund Conservation Invariants

Three invariant test suites (128,000 calls each) verify no fund leakage:
- `DepositInvariantTest`: `contractBalance == ghostLocked`
- `StreamInvariantTest`: `contractBalance <= deposited`
- `BountyInvariantTest`: `contractBalance == ghostLocked`

---

## Dependency Audit

**Tool:** cargo-audit (server dependencies)
**Date:** 2026-03-13
**Result:** 0 critical, 0 high advisories

One medium advisory (`rsa` crate via `sqlx-mysql`, RUSTSEC-2023-0071) has no available fix and
is accepted - the server does not use MySQL, making it unexploitable in this context.

---

## External Audit Status

No external audit has been conducted yet. This is disclosed in the interest of transparency.

An external audit engagement is planned before mainnet launch. This document, along with
`AUDIT_SCOPE.md`, will be provided to the auditing firm.

---

## Responsible Disclosure

If you discover a security vulnerability in the Remit protocol contracts, please report it
**privately** before public disclosure.

**Contact:** security@remit.md
**Subject:** `[SECURITY] <brief description>`

**Response commitment:**
- Acknowledgment within 48 hours
- Initial assessment within 5 business days
- Fix + disclosure timeline agreed within 30 days

**Scope (in scope for bounty consideration):**
- All contracts in `src/` of this repository
- Fund theft or unauthorized access to held USDC
- Permanent denial of service on fund-holding contracts
- Privilege escalation beyond documented access control

**Out of scope:**
- Server API (proprietary, not in this repository)
- Front-end applications (dashboard, playground)
- Documentation and configuration files
- Issues in third-party dependencies (report to the upstream project)
- Informational findings from automated scanners without proven exploitability
- Theoretical risks explicitly accepted in this document
- Gas optimization suggestions (use regular issues)

**Please do not:** open public GitHub issues for security vulnerabilities, post on social media,
or disclose to third parties before we have had a chance to fix and coordinate disclosure.

---

## Bug Bounty Rewards

Rewards are paid in USDC on Base for confirmed vulnerabilities:

| Severity | Impact | Reward |
|----------|--------|--------|
| Critical | Direct fund drain, unauthorized token transfers | $5,000 - $25,000 |
| High | Fund lockup, permanent griefing, fee bypass | $2,000 - $10,000 |
| Medium | Logic errors affecting state, access control bypass (non-fund) | $500 - $2,000 |
| Low | Gas optimization with measurable impact, minor logic issues | $100 - $500 |

Reward amounts are determined based on severity, impact, and quality of the report.

**Rules:**
- Do not exploit vulnerabilities on mainnet. Use a local fork for testing.
- Do not publicly disclose vulnerabilities before they are fixed.
- One vulnerability per report.
- First reporter of a given vulnerability receives the reward.

**Safe Harbor:** We will not pursue legal action against researchers who act in good faith,
follow this disclosure policy, do not access or modify other users' data, do not disrupt the
protocol's normal operation, and report findings promptly.

---

*Last updated: 2026-03-26*
