#!/usr/bin/env bash
# deploy-local.sh — Full local development environment setup
# Starts Docker services, applies migrations, deploys contracts to Anvil

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[deploy-local]${NC} $*"; }
warn() { echo -e "${YELLOW}[deploy-local]${NC} $*"; }
die()  { echo -e "${RED}[deploy-local] ERROR:${NC} $*" >&2; exit 1; }

# Load environment
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
else
    warn ".env not found — copying from .env.example"
    cp "$ROOT_DIR/.env.example" "$ENV_FILE"
    set -a; source "$ENV_FILE"; set +a
fi

# 1. Start Docker services
log "Starting Docker services..."
cd "$ROOT_DIR"
docker compose up -d

# 2. Wait for services
log "Waiting for Postgres..."
until docker compose exec -T postgres pg_isready -U remitmd -q 2>/dev/null; do
    sleep 1
done
log "Postgres ready."

log "Waiting for Redis..."
until docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; do
    sleep 1
done
log "Redis ready."

log "Waiting for Anvil..."
until curl -sf -X POST \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    -H 'Content-Type: application/json' \
    "${RPC_URL:-http://localhost:8545}" > /dev/null 2>&1; do
    sleep 1
done
log "Anvil ready."

# 3. Apply migrations
log "Applying database migrations..."
"$SCRIPT_DIR/migrate.sh" up

# 4. Deploy Mock USDC to Anvil
log "Deploying Mock USDC..."
DEPLOY_OUTPUT=$(forge create \
    --rpc-url "${RPC_URL:-http://localhost:8545}" \
    --private-key "${DEPLOYER_PRIVATE_KEY}" \
    --broadcast \
    packages/contracts/src/test/MockUSDC.sol:MockUSDC \
    2>&1)
USDC_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "Deployed to:" | awk '{print $3}')
[ -z "$USDC_ADDRESS" ] && die "Failed to deploy Mock USDC"
log "Mock USDC deployed at: $USDC_ADDRESS"

# Update .env
sed -i "s|^USDC_ADDRESS=.*|USDC_ADDRESS=$USDC_ADDRESS|" "$ENV_FILE"

# 5. Mint test USDC to Anvil default accounts
log "Minting test USDC to default accounts..."
ANVIL_ACCOUNTS=(
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
)
for ACCOUNT in "${ANVIL_ACCOUNTS[@]}"; do
    cast send "$USDC_ADDRESS" "mint(address,uint256)" \
        "$ACCOUNT" "1000000000000" \
        --rpc-url "${RPC_URL:-http://localhost:8545}" \
        --private-key "${DEPLOYER_PRIVATE_KEY}" > /dev/null 2>&1
    log "  Minted 1,000,000 USDC to $ACCOUNT"
done

# 6. Deploy Remit contracts
log "Deploying Remit contracts..."
DEPLOY_SCRIPT_OUTPUT=$(forge script \
    packages/contracts/script/DeployLocal.s.sol \
    --rpc-url "${RPC_URL:-http://localhost:8545}" \
    --private-key "${DEPLOYER_PRIVATE_KEY}" \
    --broadcast 2>&1) || die "Contract deployment failed:\n$DEPLOY_SCRIPT_OUTPUT"
log "Contracts deployed."

# 7. Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  remit.md local environment ready!"
echo "  Postgres:  ${DATABASE_URL:-postgres://remitmd:dev_password@localhost:5432/remitmd}"
echo "  Redis:     ${REDIS_URL:-redis://localhost:6379}"
echo "  Anvil:     ${RPC_URL:-http://localhost:8545} (chain ${CHAIN_ID:-31337})"
echo "  USDC:      $USDC_ADDRESS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
