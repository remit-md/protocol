#!/usr/bin/env bash
# codegen.sh - Generate typed code from shared definitions
# Generates Rust types from shared/errors.ts, events.ts, types.ts
# Generates Python/TS SDK stubs from shared/openapi.yaml
# Extracts ABIs from compiled contracts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SHARED_DIR="$ROOT_DIR/shared"
CONTRACTS_OUT="$ROOT_DIR/packages/contracts/out"
ABI_DIR="$SHARED_DIR/abis"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[codegen]${NC} $*"; }
warn() { echo -e "${YELLOW}[codegen]${NC} $*"; }

mkdir -p "$ABI_DIR"

# 1. Extract contract ABIs from Foundry output
if [ -d "$CONTRACTS_OUT" ]; then
    log "Extracting contract ABIs..."
    for contract in RemitEscrow RemitTab RemitStream RemitBounty RemitDeposit RemitFeeCalculator RemitRouter; do
        abi_file="$CONTRACTS_OUT/$contract.sol/$contract.json"
        if [ -f "$abi_file" ]; then
            jq '.abi' "$abi_file" > "$ABI_DIR/${contract}.json"
            log "  ABI: $contract"
        else
            warn "  Missing: $abi_file (run forge build first)"
        fi
    done
else
    warn "No contracts/out directory - run: cd packages/contracts && forge build"
fi

# 2. Generate OpenAPI server stubs (requires openapi-generator-cli or similar)
if command -v npx > /dev/null; then
    if [ -f "$SHARED_DIR/openapi.yaml" ]; then
        log "Generating TypeScript SDK types from OpenAPI..."
        npx --yes @openapitools/openapi-generator-cli generate \
            -i "$SHARED_DIR/openapi.yaml" \
            -g typescript-fetch \
            -o "$ROOT_DIR/packages/sdk-typescript/src/generated" \
            --additional-properties=typescriptThreePlus=true,supportsES6=true \
            > /dev/null 2>&1 && log "  TypeScript types generated" \
            || warn "  TypeScript codegen failed (non-fatal)"
    fi
fi

log "Codegen complete."
