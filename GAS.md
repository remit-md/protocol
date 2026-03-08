# Gas Benchmarks

> **Note:** Benchmarks pending. `forge` (Foundry) is not yet installed on this machine.
> Run `forge test --gas-report` after installing Foundry to generate real numbers.
> Install: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

## Expected Gas Ranges (from architecture research)

Based on the contract implementations and comparable Solidity patterns, estimated costs at Base L2 prices (~0.001 Gwei base fee, typical L2):

| Operation | Estimated Gas | USD @ 0.001 Gwei |
|-----------|--------------|------------------|
| `createEscrow` (no milestones) | 120,000–150,000 | ~$0.0004 |
| `createEscrow` (3 milestones) | 180,000–220,000 | ~$0.0006 |
| `claimStart` | 45,000–55,000 | ~$0.0002 |
| `releaseEscrow` | 80,000–100,000 | ~$0.0003 |
| `releaseMilestone` | 60,000–80,000 | ~$0.0002 |
| `openTab` | 120,000–140,000 | ~$0.0004 |
| `closeTab` | 100,000–120,000 | ~$0.0003 |
| `openStream` | 130,000–150,000 | ~$0.0004 |
| `closeStream` | 110,000–130,000 | ~$0.0004 |
| `withdraw` (stream) | 80,000–100,000 | ~$0.0003 |
| `postBounty` | 140,000–160,000 | ~$0.0005 |
| `awardBounty` | 110,000–130,000 | ~$0.0004 |
| `lockDeposit` | 100,000–120,000 | ~$0.0003 |
| `payDirect` (router) | 80,000–100,000 | ~$0.0003 |

## Storage Packing Notes

All contracts use `uint96` for USDC amounts (max ~79.2 billion USDC — exceeds total supply).
Packed structs reduce SLOAD/SSTORE costs:

**Escrow struct** (packed into 4 slots):
- Slot 1: `payer` (20 bytes) + `amount` (12 bytes)
- Slot 2: `payee` (20 bytes) + `feeAmount` (12 bytes)
- Slot 3: `timeout` (8) + `createdAt` (8) + `status` (1) + `claimStarted` (1) + `evidenceSubmitted` (1) = 19 bytes
- Slot 4: `evidenceHash` (32 bytes)

**Stream struct** (packed into 3 slots):
- Slot 1: `payer` (20 bytes) + `maxTotal` (12 bytes)
- Slot 2: `payee` (20 bytes) + `withdrawn` (12 bytes)
- Slot 3: `ratePerSecond` (8) + `startedAt` (8) + `closedAt` (8) + `status` (1) = 25 bytes

## To Generate Real Benchmarks

```bash
cd packages/contracts

# Install Foundry first
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Run tests with gas report
forge test --gas-report 2>&1 | tee gas-report.txt

# View per-function summary
grep -A 50 "RemitEscrow" gas-report.txt
```

## Optimization Notes

- `via_ir = false` in foundry.toml — enable for production to reduce gas ~5-10%
- `optimizer_runs = 200` — optimal for deployment cost vs call cost balance
- All external calls use `SafeERC20.safeTransferFrom` (adds ~200 gas vs direct call)
- ReentrancyGuard: ~2,300 gas overhead per guarded function (two SSTORE operations)
