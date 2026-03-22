#!/usr/bin/env bash
# Verify all remit.md contracts on Blockscout (Base Sepolia)
# Run after deploy-testnet.sh
# Uses Blockscout (base-sepolia.blockscout.com) — free, no API key required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env.testnet"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run deploy-testnet.sh first."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${RPC_URL:?Need RPC_URL}"

CAST="${CAST:-cast}"
FORGE="${FORGE:-forge}"

cd "$PROJECT_ROOT/packages/contracts"

echo "=== Verifying contracts on Blockscout (Base Sepolia) ==="

verify() {
  local name=$1
  local addr=$2
  shift 2
  local args=("$@")

  echo "→ Verifying $name at $addr..."
  $FORGE verify-contract "$addr" "src/$name.sol:$name" \
    --chain base-sepolia \
    --verifier blockscout \
    --verifier-url https://base-sepolia.blockscout.com/api \
    "${args[@]}" \
    --watch || echo "  WARNING: $name verification failed (may already be verified)"
}

DEPLOYER_ADDRESS=0x3267782a9ED9B552DbF0559a20b5edaBBFC14F76

# RemitEscrow: constructor(address _usdc, address _feeCalculator, address _protocolAdmin, address _feeRecipient)
verify "RemitEscrow" "$ESCROW_ADDRESS" \
  --constructor-args "$($CAST abi-encode 'constructor(address,address,address,address)' \
    "$USDC_ADDRESS" "$FEE_CALCULATOR_ADDRESS" "$DEPLOYER_ADDRESS" "$FEE_RECIPIENT")"

# RemitTab: constructor(address _usdc, address _feeCalculator, address _feeRecipient)
verify "RemitTab" "$TAB_ADDRESS" \
  --constructor-args "$($CAST abi-encode 'constructor(address,address,address)' \
    "$USDC_ADDRESS" "$FEE_CALCULATOR_ADDRESS" "$FEE_RECIPIENT")"

# RemitStream: constructor(address _usdc, address _feeCalculator, address _feeRecipient)
verify "RemitStream" "$STREAM_ADDRESS" \
  --constructor-args "$($CAST abi-encode 'constructor(address,address,address)' \
    "$USDC_ADDRESS" "$FEE_CALCULATOR_ADDRESS" "$FEE_RECIPIENT")"

# RemitBounty: constructor(address _usdc, address _feeCalculator, address _feeRecipient)
verify "RemitBounty" "$BOUNTY_ADDRESS" \
  --constructor-args "$($CAST abi-encode 'constructor(address,address,address)' \
    "$USDC_ADDRESS" "$FEE_CALCULATOR_ADDRESS" "$FEE_RECIPIENT")"

# RemitDeposit: constructor(address _usdc)
verify "RemitDeposit" "$DEPOSIT_ADDRESS" \
  --constructor-args "$($CAST abi-encode 'constructor(address)' "$USDC_ADDRESS")"

# MockUSDC: constructor() — no args
verify "test/MockUSDC" "$USDC_ADDRESS"

# UUPS proxies — verify implementation, not proxy (proxy is ERC1967)
verify "RemitFeeCalculator" "$FEE_CALCULATOR_ADDRESS"
verify "RemitRouter" "$ROUTER_ADDRESS"

echo ""
echo "=== Verification Complete ==="
echo "View contracts on Blockscout: https://base-sepolia.blockscout.com/"
