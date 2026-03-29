// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {IRemitKeyRegistry} from "../src/interfaces/IRemitKeyRegistry.sol";

/// @title RemitKeyRegistryFuzzTest
/// @notice Property-based fuzz tests for RemitKeyRegistry
contract RemitKeyRegistryFuzzTest is Test {
    RemitKeyRegistry public registry;

    address public admin = makeAddr("admin");
    address public authorizedContract = makeAddr("authorizedContract");

    function setUp() public {
        registry = new RemitKeyRegistry(admin);

        vm.prank(admin);
        registry.authorizeContract(authorizedContract);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _signDelegation(
        uint256 signerKey,
        address masterKey,
        address sessionKey,
        uint96 spendingLimit,
        uint96 dailyLimit,
        uint8 allowedModels,
        uint64 expires,
        uint256 nonce
    ) internal view returns (bytes memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.KEY_DELEGATION_TYPEHASH(),
                masterKey,
                sessionKey,
                spendingLimit,
                dailyLimit,
                allowedModels,
                expires,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // Fuzz: delegation spending limit enforcement
    // =========================================================================

    /// @dev recordSpend reverts when amount exceeds per-tx spending limit
    function testFuzz_spendingLimitEnforced(uint96 spendLimit, uint96 amount) public {
        spendLimit = uint96(bound(spendLimit, 1, type(uint88).max));
        amount = uint96(bound(amount, spendLimit + 1, type(uint96).max));

        uint256 masterPk = uint256(keccak256("fuzz-master-spend"));
        uint256 sessionPk = uint256(keccak256("fuzz-session-spend"));
        address master = vm.addr(masterPk);
        address session = vm.addr(sessionPk);

        uint256 nonce = registry.getNonce(master);
        bytes memory sig =
            _signDelegation(masterPk, master, session, spendLimit, 0, 0xFF, uint64(block.timestamp + 7 days), nonce);

        vm.prank(master);
        registry.delegateKey(session, spendLimit, 0, 0xFF, uint64(block.timestamp + 7 days), sig);

        vm.prank(authorizedContract);
        vm.expectRevert();
        registry.recordSpend(session, amount);
    }

    /// @dev recordSpend succeeds when amount <= spending limit
    function testFuzz_spendingLimitAllows(uint96 spendLimit, uint96 amount) public {
        spendLimit = uint96(bound(spendLimit, 1, type(uint88).max));
        amount = uint96(bound(amount, 1, spendLimit));

        uint256 masterPk = uint256(keccak256("fuzz-master-allow"));
        uint256 sessionPk = uint256(keccak256("fuzz-session-allow"));
        address master = vm.addr(masterPk);
        address session = vm.addr(sessionPk);

        uint256 nonce = registry.getNonce(master);
        bytes memory sig =
            _signDelegation(masterPk, master, session, spendLimit, 0, 0xFF, uint64(block.timestamp + 7 days), nonce);

        vm.prank(master);
        registry.delegateKey(session, spendLimit, 0, 0xFF, uint64(block.timestamp + 7 days), sig);

        vm.prank(authorizedContract);
        registry.recordSpend(session, amount);
    }

    // =========================================================================
    // Fuzz: daily limit enforcement
    // =========================================================================

    /// @dev Daily limit resets at day boundary
    function testFuzz_dailyLimitResetsAtDayBoundary(uint96 dailyLimit) public {
        dailyLimit = uint96(bound(dailyLimit, 1, type(uint88).max));

        uint256 masterPk = uint256(keccak256("fuzz-master-daily"));
        uint256 sessionPk = uint256(keccak256("fuzz-session-daily"));
        address master = vm.addr(masterPk);
        address session = vm.addr(sessionPk);

        uint256 nonce = registry.getNonce(master);
        bytes memory sig =
            _signDelegation(masterPk, master, session, 0, dailyLimit, 0xFF, uint64(block.timestamp + 30 days), nonce);

        vm.prank(master);
        registry.delegateKey(session, 0, dailyLimit, 0xFF, uint64(block.timestamp + 30 days), sig);

        // Spend exactly the daily limit
        vm.prank(authorizedContract);
        registry.recordSpend(session, dailyLimit);

        // Next spend should fail (daily limit exceeded)
        vm.prank(authorizedContract);
        vm.expectRevert();
        registry.recordSpend(session, 1);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        // Should succeed again after daily reset
        vm.prank(authorizedContract);
        registry.recordSpend(session, dailyLimit);
    }

    // =========================================================================
    // Fuzz: delegation expiry
    // =========================================================================

    /// @dev isValidDelegation returns false after expiry
    function testFuzz_delegationExpiresCorrectly(uint64 expiryOffset) public {
        expiryOffset = uint64(bound(expiryOffset, 1 hours, 365 days));

        uint256 masterPk = uint256(keccak256("fuzz-master-expiry"));
        uint256 sessionPk = uint256(keccak256("fuzz-session-expiry"));
        address master = vm.addr(masterPk);
        address session = vm.addr(sessionPk);

        uint64 expires = uint64(block.timestamp) + expiryOffset;
        uint256 nonce = registry.getNonce(master);
        bytes memory sig = _signDelegation(masterPk, master, session, 100e6, 0, 0xFF, expires, nonce);

        vm.prank(master);
        registry.delegateKey(session, 100e6, 0, 0xFF, expires, sig);

        // Valid before expiry
        assertTrue(registry.isValidDelegation(session));

        // Warp past expiry
        vm.warp(expires);

        // Invalid after expiry
        assertFalse(registry.isValidDelegation(session));
    }

    // =========================================================================
    // Fuzz: payment type bitmask
    // =========================================================================

    /// @dev checkSpendingLimit respects allowedModelsBitmap
    function testFuzz_paymentTypeBitmask(uint8 bitmap, uint8 paymentType) public {
        // Ensure bitmap is non-zero (0 means no types allowed, rejected at delegation)
        bitmap = uint8(bound(bitmap, 1, 0xFE)); // Exclude 0xFF which allows all
        paymentType = uint8(bound(paymentType, 0, 6)); // PaymentType enum range

        uint256 masterPk = uint256(keccak256("fuzz-master-bitmap"));
        uint256 sessionPk = uint256(keccak256("fuzz-session-bitmap"));
        address master = vm.addr(masterPk);
        address session = vm.addr(sessionPk);

        uint256 nonce = registry.getNonce(master);
        bytes memory sig =
            _signDelegation(masterPk, master, session, 0, 0, bitmap, uint64(block.timestamp + 7 days), nonce);

        vm.prank(master);
        registry.delegateKey(session, 0, 0, bitmap, uint64(block.timestamp + 7 days), sig);

        bool allowed = (bitmap & (uint8(1) << paymentType)) != 0;
        bool ok = registry.checkSpendingLimit(session, 1e6, paymentType);

        assertEq(ok, allowed, "bitmask check must match expected");
    }

    // =========================================================================
    // Fuzz: revoked key is no longer valid
    // =========================================================================

    /// @dev isValidDelegation returns false after revocation
    function testFuzz_revokedKeyInvalid(uint64 expiryOffset) public {
        expiryOffset = uint64(bound(expiryOffset, 1 hours, 365 days));

        uint256 masterPk = uint256(keccak256("fuzz-master-revoke"));
        uint256 sessionPk = uint256(keccak256("fuzz-session-revoke"));
        address master = vm.addr(masterPk);
        address session = vm.addr(sessionPk);

        uint64 expires = uint64(block.timestamp) + expiryOffset;
        uint256 nonce = registry.getNonce(master);
        bytes memory sig = _signDelegation(masterPk, master, session, 100e6, 0, 0xFF, expires, nonce);

        vm.prank(master);
        registry.delegateKey(session, 100e6, 0, 0xFF, expires, sig);
        assertTrue(registry.isValidDelegation(session));

        vm.prank(master);
        registry.revokeKey(session);
        assertFalse(registry.isValidDelegation(session));
    }
}
