#!/usr/bin/env bash
# verify-deployment.sh — Post-deployment verification for DeployMainnet.s.sol
#
# Reads deployed addresses from the Foundry broadcast file and verifies:
#   1. All contracts have code at their address
#   2. Router is wired to all fund-holding contracts
#   3. USDC address is correct across all contracts
#   4. FeeCalculator caller authorizations
#   5. KeyRegistry contract authorizations
#   6. Ownership set correctly (if GNOSIS_SAFE env var is set)
#   7. Fee recipient set correctly (if FEE_WALLET env var is set)
#
# Usage:
#   ./script/verify-deployment.sh [RPC_URL]
#
# Environment:
#   GNOSIS_SAFE  — expected admin/owner address (optional, enables ownership checks)
#   FEE_WALLET   — expected fee recipient address (optional, defaults to GNOSIS_SAFE)

set -euo pipefail

RPC_URL="${1:-http://localhost:8545}"
CHAIN_ID=8453
BROADCAST="broadcast/DeployMainnet.s.sol/$CHAIN_ID/run-latest.json"
MAINNET_USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

PASS=0
FAIL=0

echo "=== Deployment Verification ==="
echo "RPC:       $RPC_URL"
echo "Broadcast: $BROADCAST"
echo ""

if [ ! -f "$BROADCAST" ]; then
  echo "ERROR: Broadcast file not found: $BROADCAST"
  exit 1
fi

# ---------------------------------------------------------------------------
# Address extraction from broadcast JSON
# Filter CREATE transactions only — CALL transactions also have contractAddress
# set (it's the callee address, not a newly created contract).
# ---------------------------------------------------------------------------
get_address() {
  local name="$1"
  local index="${2:-0}"
  jq -r "[.transactions[] | select(.transactionType == \"CREATE\" and .contractName == \"$name\")] | .[$index].contractAddress // empty" "$BROADCAST"
}

FEECALC_PROXY=$(get_address "ERC1967Proxy" 0)
KEY_REGISTRY=$(get_address "RemitKeyRegistry")
ESCROW=$(get_address "RemitEscrow")
TAB=$(get_address "RemitTab")
STREAM=$(get_address "RemitStream")
BOUNTY=$(get_address "RemitBounty")
DEPOSIT=$(get_address "RemitDeposit")
ROUTER_PROXY=$(get_address "ERC1967Proxy" 1)

# Sanity: all addresses must be non-empty
for name in FEECALC_PROXY KEY_REGISTRY ESCROW TAB STREAM BOUNTY DEPOSIT ROUTER_PROXY; do
  val="${!name}"
  if [ -z "$val" ]; then
    echo "ERROR: Could not extract $name from broadcast file"
    exit 1
  fi
done

echo "Extracted addresses:"
echo "  FeeCalc (proxy): $FEECALC_PROXY"
echo "  KeyRegistry:     $KEY_REGISTRY"
echo "  Escrow:          $ESCROW"
echo "  Tab:             $TAB"
echo "  Stream:          $STREAM"
echo "  Bounty:          $BOUNTY"
echo "  Deposit:         $DEPOSIT"
echo "  Router (proxy):  $ROUTER_PROXY"
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
check() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  expected=$(echo "$expected" | tr '[:upper:]' '[:lower:]')
  actual=$(echo "$actual" | tr '[:upper:]' '[:lower:]')
  if [ "$expected" = "$actual" ]; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

check_true() {
  local label="$1"
  local actual="$2"
  actual=$(echo "$actual" | tr '[:upper:]' '[:lower:]' | xargs)
  if [ "$actual" = "true" ]; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label (got: $actual)"
    FAIL=$((FAIL + 1))
  fi
}

call() {
  cast call "$@" --rpc-url "$RPC_URL" 2>/dev/null || echo "CALL_FAILED"
}

has_code() {
  local code
  code=$(cast code "$1" --rpc-url "$RPC_URL" 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "0x" ]
}

# ---------------------------------------------------------------------------
# 1. Contract existence
# ---------------------------------------------------------------------------
echo "--- Contract Existence ---"
for name in FEECALC_PROXY KEY_REGISTRY ESCROW TAB STREAM BOUNTY DEPOSIT ROUTER_PROXY; do
  val="${!name}"
  if has_code "$val"; then
    echo "  PASS  $name has code"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name has NO code at $val"
    FAIL=$((FAIL + 1))
  fi
done

# Also verify real USDC exists on this chain
if has_code "$MAINNET_USDC"; then
  echo "  PASS  MAINNET_USDC has code"
  PASS=$((PASS + 1))
else
  echo "  FAIL  MAINNET_USDC has NO code at $MAINNET_USDC (not a real Base fork?)"
  FAIL=$((FAIL + 1))
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Router wiring
# ---------------------------------------------------------------------------
echo "--- Router Wiring ---"
check "Router.escrow()" "$ESCROW" "$(call "$ROUTER_PROXY" "escrow()(address)")"
check "Router.tab()" "$TAB" "$(call "$ROUTER_PROXY" "tab()(address)")"
check "Router.stream()" "$STREAM" "$(call "$ROUTER_PROXY" "stream()(address)")"
check "Router.bounty()" "$BOUNTY" "$(call "$ROUTER_PROXY" "bounty()(address)")"
check "Router.deposit()" "$DEPOSIT" "$(call "$ROUTER_PROXY" "deposit()(address)")"
check "Router.usdc()" "$MAINNET_USDC" "$(call "$ROUTER_PROXY" "usdc()(address)")"
check "Router.feeCalculator()" "$FEECALC_PROXY" "$(call "$ROUTER_PROXY" "feeCalculator()(address)")"
echo ""

# ---------------------------------------------------------------------------
# 3. USDC address across all contracts
# ---------------------------------------------------------------------------
echo "--- USDC Address ---"
check "Escrow.usdc()" "$MAINNET_USDC" "$(call "$ESCROW" "usdc()(address)")"
check "Tab.usdc()" "$MAINNET_USDC" "$(call "$TAB" "usdc()(address)")"
check "Stream.usdc()" "$MAINNET_USDC" "$(call "$STREAM" "usdc()(address)")"
check "Bounty.usdc()" "$MAINNET_USDC" "$(call "$BOUNTY" "usdc()(address)")"
check "Deposit.usdc()" "$MAINNET_USDC" "$(call "$DEPOSIT" "usdc()(address)")"
echo ""

# ---------------------------------------------------------------------------
# 4. FeeCalculator authorized callers
# ---------------------------------------------------------------------------
echo "--- FeeCalculator Authorized Callers ---"
check_true "FeeCalc.authorizedCallers(Escrow)" "$(call "$FEECALC_PROXY" "authorizedCallers(address)(bool)" "$ESCROW")"
check_true "FeeCalc.authorizedCallers(Tab)" "$(call "$FEECALC_PROXY" "authorizedCallers(address)(bool)" "$TAB")"
check_true "FeeCalc.authorizedCallers(Stream)" "$(call "$FEECALC_PROXY" "authorizedCallers(address)(bool)" "$STREAM")"
check_true "FeeCalc.authorizedCallers(Bounty)" "$(call "$FEECALC_PROXY" "authorizedCallers(address)(bool)" "$BOUNTY")"
check_true "FeeCalc.authorizedCallers(Router)" "$(call "$FEECALC_PROXY" "authorizedCallers(address)(bool)" "$ROUTER_PROXY")"
echo ""

# ---------------------------------------------------------------------------
# 5. KeyRegistry authorized contracts
# ---------------------------------------------------------------------------
echo "--- KeyRegistry Authorized Contracts ---"
check_true "KeyRegistry.isAuthorizedContract(Escrow)" "$(call "$KEY_REGISTRY" "isAuthorizedContract(address)(bool)" "$ESCROW")"
check_true "KeyRegistry.isAuthorizedContract(Tab)" "$(call "$KEY_REGISTRY" "isAuthorizedContract(address)(bool)" "$TAB")"
check_true "KeyRegistry.isAuthorizedContract(Stream)" "$(call "$KEY_REGISTRY" "isAuthorizedContract(address)(bool)" "$STREAM")"
check_true "KeyRegistry.isAuthorizedContract(Bounty)" "$(call "$KEY_REGISTRY" "isAuthorizedContract(address)(bool)" "$BOUNTY")"
check_true "KeyRegistry.isAuthorizedContract(Deposit)" "$(call "$KEY_REGISTRY" "isAuthorizedContract(address)(bool)" "$DEPOSIT")"
echo ""

# ---------------------------------------------------------------------------
# 6. Ownership / Admin (if GNOSIS_SAFE is set)
# ---------------------------------------------------------------------------
ADMIN="${GNOSIS_SAFE:-}"
if [ -n "$ADMIN" ]; then
  echo "--- Ownership (admin=$ADMIN) ---"
  check "FeeCalc.owner()" "$ADMIN" "$(call "$FEECALC_PROXY" "owner()(address)")"
  check "KeyRegistry.owner()" "$ADMIN" "$(call "$KEY_REGISTRY" "owner()(address)")"
  check "Router.owner()" "$ADMIN" "$(call "$ROUTER_PROXY" "owner()(address)")"
  check "Router.protocolAdmin()" "$ADMIN" "$(call "$ROUTER_PROXY" "protocolAdmin()(address)")"
  check "Escrow.protocolAdmin()" "$ADMIN" "$(call "$ESCROW" "protocolAdmin()(address)")"
  check "Tab.protocolAdmin()" "$ADMIN" "$(call "$TAB" "protocolAdmin()(address)")"
  check "Stream.protocolAdmin()" "$ADMIN" "$(call "$STREAM" "protocolAdmin()(address)")"
  check "Bounty.protocolAdmin()" "$ADMIN" "$(call "$BOUNTY" "protocolAdmin()(address)")"
  check "Deposit.protocolAdmin()" "$ADMIN" "$(call "$DEPOSIT" "protocolAdmin()(address)")"
  echo ""
fi

# ---------------------------------------------------------------------------
# 7. Fee recipient (if FEE_WALLET is set, else falls back to GNOSIS_SAFE)
# ---------------------------------------------------------------------------
FEE_WALLET_ADDR="${FEE_WALLET:-$ADMIN}"
if [ -n "$FEE_WALLET_ADDR" ]; then
  echo "--- Fee Recipient (feeRecipient=$FEE_WALLET_ADDR) ---"
  check "Router.feeRecipient()" "$FEE_WALLET_ADDR" "$(call "$ROUTER_PROXY" "feeRecipient()(address)")"
  check "Escrow.feeRecipient()" "$FEE_WALLET_ADDR" "$(call "$ESCROW" "feeRecipient()(address)")"
  check "Tab.feeRecipient()" "$FEE_WALLET_ADDR" "$(call "$TAB" "feeRecipient()(address)")"
  check "Stream.feeRecipient()" "$FEE_WALLET_ADDR" "$(call "$STREAM" "feeRecipient()(address)")"
  check "Bounty.feeRecipient()" "$FEE_WALLET_ADDR" "$(call "$BOUNTY" "feeRecipient()(address)")"
  echo ""
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== RESULTS ==="
echo "  $PASS passed, $FAIL failed"
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "VERIFICATION FAILED"
  exit 1
else
  echo "ALL CHECKS PASSED"
fi
