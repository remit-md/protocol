// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {IRemitKeyRegistry} from "../src/interfaces/IRemitKeyRegistry.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";

/// @title RemitKeyRegistryTest
/// @notice Unit tests for Phase 2 — Key Management (RemitKeyRegistry)
contract RemitKeyRegistryTest is Test {
    RemitKeyRegistry public registry;

    // Actors
    address public admin = makeAddr("admin");
    address public stranger = makeAddr("stranger");

    uint256 public masterKey1;
    address public master1;

    uint256 public masterKey2;
    address public master2;

    uint256 public sessionKey1;
    address public session1;

    uint256 public sessionKey2;
    address public session2;

    // A mock authorized contract
    address public authorizedContract = makeAddr("authorizedContract");

    // Delegation parameters
    uint96 constant SPEND_LIMIT = 100e6; // $100 per tx
    uint96 constant DAILY_LIMIT = 500e6; // $500 per day
    uint8 constant ALLOWED_ALL = 0xFF;
    uint8 constant ALLOWED_DIRECT_ONLY = 0x01; // PaymentType.DIRECT = 0, bit 0
    uint64 constant EXPIRES_IN_7_DAYS = 7 days;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        registry = new RemitKeyRegistry(admin);

        masterKey1 = uint256(keccak256("masterKey1"));
        masterKey2 = uint256(keccak256("masterKey2"));
        sessionKey1 = uint256(keccak256("sessionKey1"));
        sessionKey2 = uint256(keccak256("sessionKey2"));

        master1 = vm.addr(masterKey1);
        master2 = vm.addr(masterKey2);
        session1 = vm.addr(sessionKey1);
        session2 = vm.addr(sessionKey2);

        // Authorize our mock contract
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

    function _signRotation(
        uint256 signerKey,
        address masterKey,
        address oldKey,
        address newKey,
        uint64 gracePeriod,
        uint96 spendingLimit,
        uint96 dailyLimit,
        uint8 allowedModels,
        uint64 expires,
        uint256 nonce
    ) internal view returns (bytes memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.KEY_ROTATION_TYPEHASH(),
                masterKey,
                oldKey,
                newKey,
                gracePeriod,
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

    function _delegate(
        uint256 signerKey,
        address sessionKey,
        uint96 spendingLimit,
        uint96 dailyLimit,
        uint8 allowedModels,
        uint64 expires
    ) internal {
        address masterKey = vm.addr(signerKey);
        uint256 nonce = registry.getNonce(masterKey);
        bytes memory sig =
            _signDelegation(signerKey, masterKey, sessionKey, spendingLimit, dailyLimit, allowedModels, expires, nonce);
        vm.prank(masterKey);
        registry.delegateKey(sessionKey, spendingLimit, dailyLimit, allowedModels, expires, sig);
    }

    // =========================================================================
    // delegateKey
    // =========================================================================

    function test_delegateKey_happy() public {
        uint64 expires = uint64(block.timestamp + EXPIRES_IN_7_DAYS);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.KeyDelegated(master1, session1, SPEND_LIMIT, DAILY_LIMIT, expires);

        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires);

        IRemitKeyRegistry.Delegation memory d = registry.getDelegation(session1);
        assertEq(d.masterKey, master1);
        assertEq(d.sessionKey, session1);
        assertEq(d.spendingLimit, SPEND_LIMIT);
        assertEq(d.dailyLimit, DAILY_LIMIT);
        assertEq(d.allowedModelsBitmap, ALLOWED_ALL);
        assertEq(d.expires, expires);
        assertFalse(d.revoked);
        assertEq(d.dailySpent, 0);
    }

    function test_delegateKey_noExpiry() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        IRemitKeyRegistry.Delegation memory d = registry.getDelegation(session1);
        assertEq(d.expires, 0); // 0 = no expiry
    }

    function test_delegateKey_nonce_increments() public {
        assertEq(registry.getNonce(master1), 0);
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        assertEq(registry.getNonce(master1), 1);
        _delegate(masterKey1, session2, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        assertEq(registry.getNonce(master1), 2);
    }

    function test_delegateKey_revert_invalidSignature() public {
        uint64 expires = uint64(block.timestamp + EXPIRES_IN_7_DAYS);
        uint256 nonce = registry.getNonce(master1);
        // Sign with wrong key (masterKey2 instead of masterKey1)
        bytes memory sig =
            _signDelegation(masterKey2, master1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires, nonce);

        vm.prank(master1);
        vm.expectRevert(RemitErrors.InvalidSignature.selector);
        registry.delegateKey(session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires, sig);
    }

    function test_delegateKey_revert_selfDelegation() public {
        uint64 expires = uint64(block.timestamp + EXPIRES_IN_7_DAYS);
        uint256 nonce = registry.getNonce(master1);
        bytes memory sig =
            _signDelegation(masterKey1, master1, master1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires, nonce);

        vm.prank(master1);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.SelfPayment.selector, master1));
        registry.delegateKey(master1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires, sig);
    }

    function test_delegateKey_revert_zeroAddress() public {
        uint64 expires = uint64(block.timestamp + EXPIRES_IN_7_DAYS);
        uint256 nonce = registry.getNonce(master1);
        bytes memory sig =
            _signDelegation(masterKey1, master1, address(0), SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires, nonce);

        vm.prank(master1);
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        registry.delegateKey(address(0), SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires, sig);
    }

    function test_delegateKey_revert_expiredExpiry() public {
        // Warp to a known non-zero timestamp so block.timestamp - 1 != 0
        vm.warp(10_000);
        uint64 expiredTime = uint64(block.timestamp - 1); // 9,999 — clearly in the past
        uint256 nonce = registry.getNonce(master1);
        bytes memory sig =
            _signDelegation(masterKey1, master1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expiredTime, nonce);

        vm.prank(master1);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, expiredTime));
        registry.delegateKey(session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expiredTime, sig);
    }

    function test_delegateKey_revert_alreadyDelegated() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);

        // Try to delegate session1 again (still active)
        uint256 nonce = registry.getNonce(master1);
        bytes memory sig =
            _signDelegation(masterKey1, master1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0, nonce);

        vm.prank(master1);
        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.DelegationLimitExceeded.selector, session1, uint256(0), uint256(0))
        );
        registry.delegateKey(session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0, sig);
    }

    function test_delegateKey_allowsRedelegateAfterExpiry() public {
        uint64 shortExpiry = uint64(block.timestamp + 1 hours);
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, shortExpiry);

        // Warp past expiry
        vm.warp(block.timestamp + 2 hours);

        // Should be able to delegate session1 again now
        uint64 newExpiry = uint64(block.timestamp + 7 days);
        _delegate(masterKey1, session1, SPEND_LIMIT * 2, DAILY_LIMIT * 2, ALLOWED_ALL, newExpiry);

        IRemitKeyRegistry.Delegation memory d = registry.getDelegation(session1);
        assertEq(d.spendingLimit, SPEND_LIMIT * 2);
    }

    // =========================================================================
    // revokeKey
    // =========================================================================

    function test_revokeKey_happy() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        assertTrue(registry.isValidDelegation(session1));

        vm.expectEmit(true, true, false, false);
        emit RemitEvents.KeyRevoked(master1, session1);

        vm.prank(master1);
        registry.revokeKey(session1);

        assertFalse(registry.isValidDelegation(session1));
        IRemitKeyRegistry.Delegation memory d = registry.getDelegation(session1);
        assertTrue(d.revoked);
    }

    function test_revokeKey_revert_wrongMaster() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);

        vm.prank(master2); // wrong master
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, master2));
        registry.revokeKey(session1);
    }

    function test_revokeKey_revert_alreadyRevoked() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        vm.prank(master1);
        registry.revokeKey(session1);

        vm.prank(master1);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, session1));
        registry.revokeKey(session1);
    }

    // =========================================================================
    // isValidDelegation
    // =========================================================================

    function test_isValidDelegation_active() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        assertTrue(registry.isValidDelegation(session1));
    }

    function test_isValidDelegation_false_notDelegated() public {
        assertFalse(registry.isValidDelegation(session1));
    }

    function test_isValidDelegation_false_revoked() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        vm.prank(master1);
        registry.revokeKey(session1);
        assertFalse(registry.isValidDelegation(session1));
    }

    function test_isValidDelegation_false_expired() public {
        uint64 expires = uint64(block.timestamp + 1 hours);
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires);

        vm.warp(block.timestamp + 2 hours);
        assertFalse(registry.isValidDelegation(session1));
    }

    function test_isValidDelegation_true_at_expiry_boundary() public {
        uint64 expires = uint64(block.timestamp + 1 hours);
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires);

        // At exactly expiry: expires > block.timestamp fails, so it's invalid
        vm.warp(expires);
        assertFalse(registry.isValidDelegation(session1));

        // One second before: valid
        vm.warp(expires - 1);
        assertTrue(registry.isValidDelegation(session1));
    }

    // =========================================================================
    // rotateKey
    // =========================================================================

    function test_rotateKey_oldKeyInGracePeriod_newKeyActive() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);

        uint64 gracePeriod = 1 hours;
        uint256 nonce = registry.getNonce(master1);
        bytes memory sig = _signRotation(
            masterKey1, master1, session1, session2, gracePeriod, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0, nonce
        );

        vm.prank(master1);
        registry.rotateKey(session1, session2, gracePeriod, sig);

        // New key is valid
        assertTrue(registry.isValidDelegation(session2));

        // Old key is revoked but within grace period — should still be valid
        IRemitKeyRegistry.Delegation memory d1 = registry.getDelegation(session1);
        assertTrue(d1.revoked);
        assertGt(d1.gracePeriodEnds, block.timestamp);

        // isValidDelegation uses grace period logic: revoked but grace not ended → valid
        assertTrue(registry.isValidDelegation(session1));
    }

    function test_rotateKey_oldKeyInvalidAfterGrace() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);

        uint64 gracePeriod = 1 hours;
        uint256 nonce = registry.getNonce(master1);
        bytes memory sig = _signRotation(
            masterKey1, master1, session1, session2, gracePeriod, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0, nonce
        );

        vm.prank(master1);
        registry.rotateKey(session1, session2, gracePeriod, sig);

        // After grace period: old key invalid
        vm.warp(block.timestamp + 2 hours);
        assertFalse(registry.isValidDelegation(session1));
        assertTrue(registry.isValidDelegation(session2));
    }

    function test_rotateKey_revert_wrongMaster() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);

        uint256 nonce = registry.getNonce(master2); // wrong master's nonce
        bytes memory sig = _signRotation(
            masterKey2, master2, session1, session2, 1 hours, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0, nonce
        );

        vm.prank(master2);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, master2));
        registry.rotateKey(session1, session2, 1 hours, sig);
    }

    function test_rotateKey_inheritsLimitsFromOldKey() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_DIRECT_ONLY, 0);

        uint256 nonce = registry.getNonce(master1);
        bytes memory sig = _signRotation(
            masterKey1, master1, session1, session2, 1 hours, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_DIRECT_ONLY, 0, nonce
        );

        vm.prank(master1);
        registry.rotateKey(session1, session2, 1 hours, sig);

        IRemitKeyRegistry.Delegation memory d2 = registry.getDelegation(session2);
        assertEq(d2.spendingLimit, SPEND_LIMIT);
        assertEq(d2.dailyLimit, DAILY_LIMIT);
        assertEq(d2.allowedModelsBitmap, ALLOWED_DIRECT_ONLY);
    }

    // =========================================================================
    // checkSpendingLimit
    // =========================================================================

    function test_checkSpendingLimit_withinLimits() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        assertTrue(registry.checkSpendingLimit(session1, 50e6, 0)); // $50 direct
    }

    function test_checkSpendingLimit_atPerTxLimit() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        assertTrue(registry.checkSpendingLimit(session1, SPEND_LIMIT, 0)); // exact limit
    }

    function test_checkSpendingLimit_exceedsPerTxLimit() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        assertFalse(registry.checkSpendingLimit(session1, SPEND_LIMIT + 1, 0));
    }

    function test_checkSpendingLimit_modelRestriction_allowed() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_DIRECT_ONLY, 0);
        assertTrue(registry.checkSpendingLimit(session1, 50e6, 0)); // DIRECT = type 0
    }

    function test_checkSpendingLimit_modelRestriction_denied() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_DIRECT_ONLY, 0);
        assertFalse(registry.checkSpendingLimit(session1, 50e6, 1)); // PAY_PER_REQUEST = type 1
    }

    function test_checkSpendingLimit_masterKey_noLimits() public {
        // master1 has no delegation → treated as master key, always passes
        assertTrue(registry.checkSpendingLimit(master1, type(uint96).max, 0xFF));
    }

    function test_checkSpendingLimit_dailyLimit_fresh() public {
        _delegate(masterKey1, session1, 0, DAILY_LIMIT, ALLOWED_ALL, 0); // no per-tx limit
        assertTrue(registry.checkSpendingLimit(session1, DAILY_LIMIT - 1e6, 0));
    }

    function test_checkSpendingLimit_dailyLimit_accumulated() public {
        _delegate(masterKey1, session1, 0, DAILY_LIMIT, ALLOWED_ALL, 0);

        // Record 400e6 spent ($400)
        vm.prank(authorizedContract);
        registry.recordSpend(session1, 400e6);

        // 101e6 more would exceed 500e6 daily limit
        assertFalse(registry.checkSpendingLimit(session1, 101e6, 0));
        // 100e6 is exactly at the limit
        assertTrue(registry.checkSpendingLimit(session1, 100e6, 0));
    }

    // =========================================================================
    // recordSpend
    // =========================================================================

    function test_recordSpend_happy() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);

        vm.prank(authorizedContract);
        registry.recordSpend(session1, 50e6);

        IRemitKeyRegistry.Delegation memory d = registry.getDelegation(session1);
        assertEq(d.dailySpent, 50e6);
    }

    function test_recordSpend_revert_unauthorized() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        registry.recordSpend(session1, 50e6);
    }

    function test_recordSpend_revert_exceedsPerTxLimit() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);

        vm.prank(authorizedContract);
        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.DelegationLimitExceeded.selector, session1, SPEND_LIMIT + 1, SPEND_LIMIT)
        );
        registry.recordSpend(session1, SPEND_LIMIT + 1);
    }

    function test_recordSpend_revert_exceedsDailyLimit() public {
        _delegate(masterKey1, session1, 0, DAILY_LIMIT, ALLOWED_ALL, 0); // no per-tx limit

        // Record 450e6 ($450)
        vm.prank(authorizedContract);
        registry.recordSpend(session1, 450e6);

        // Trying to record 60e6 more would put us at 510e6 > 500e6 daily limit
        vm.prank(authorizedContract);
        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.DelegationLimitExceeded.selector, session1, 510e6, DAILY_LIMIT)
        );
        registry.recordSpend(session1, 60e6);
    }

    function test_recordSpend_dailyReset() public {
        _delegate(masterKey1, session1, 0, DAILY_LIMIT, ALLOWED_ALL, 0);

        // Spend most of daily limit
        vm.prank(authorizedContract);
        registry.recordSpend(session1, 450e6);

        IRemitKeyRegistry.Delegation memory d = registry.getDelegation(session1);
        assertEq(d.dailySpent, 450e6);

        // Advance to next day
        vm.warp(block.timestamp + 1 days + 1 seconds);

        // Should reset and accept full daily limit
        vm.prank(authorizedContract);
        registry.recordSpend(session1, DAILY_LIMIT);

        d = registry.getDelegation(session1);
        assertEq(d.dailySpent, DAILY_LIMIT); // fresh day: 0 + DAILY_LIMIT
    }

    function test_recordSpend_masterKey_noOp() public {
        // If session key has no delegation record, recordSpend is a no-op
        // (master keys don't have delegation records — they're never tracked)
        vm.prank(authorizedContract);
        registry.recordSpend(master1, 1_000_000e6); // would exceed any limit if tracking
        // No revert — master keys have no limits
    }

    // =========================================================================
    // getActiveDelegations
    // =========================================================================

    function test_getActiveDelegations_multiple() public {
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        _delegate(masterKey1, session2, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);

        address[] memory delegations = registry.getActiveDelegations(master1);
        assertEq(delegations.length, 2);
        assertEq(delegations[0], session1);
        assertEq(delegations[1], session2);
    }

    function test_getActiveDelegations_empty() public {
        address[] memory delegations = registry.getActiveDelegations(master1);
        assertEq(delegations.length, 0);
    }

    function test_getActiveDelegations_includes_revoked() public {
        // getActiveDelegations returns ALL delegations (callers should filter by isValidDelegation)
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, 0);
        vm.prank(master1);
        registry.revokeKey(session1);

        address[] memory delegations = registry.getActiveDelegations(master1);
        assertEq(delegations.length, 1); // still listed, but revoked
    }

    // =========================================================================
    // Multi-Sig
    // =========================================================================

    function test_configureMultiSig_happy() public {
        address[] memory signers = new address[](3);
        signers[0] = makeAddr("signer1");
        signers[1] = makeAddr("signer2");
        signers[2] = makeAddr("signer3");

        vm.prank(master1);
        registry.configureMultiSig(signers, 2, 1000e6); // 2-of-3, apply above $1000

        assertTrue(registry.requiresMultiSig(master1, 1000e6));
        assertFalse(registry.requiresMultiSig(master1, 999e6));
    }

    function test_configureMultiSig_zeroThreshold() public {
        address[] memory signers = new address[](2);
        signers[0] = makeAddr("s1");
        signers[1] = makeAddr("s2");

        vm.prank(master1);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.BelowMinimum.selector, uint256(0), uint256(1)));
        registry.configureMultiSig(signers, 0, 0);
    }

    function test_validateMultiSig_2of3_pass() public {
        uint256 signerKey1 = uint256(keccak256("s1"));
        uint256 signerKey2 = uint256(keccak256("s2"));
        uint256 signerKey3 = uint256(keccak256("s3"));

        address[] memory signers = new address[](3);
        signers[0] = vm.addr(signerKey1);
        signers[1] = vm.addr(signerKey2);
        signers[2] = vm.addr(signerKey3);

        vm.prank(master1);
        registry.configureMultiSig(signers, 2, 0); // 2-of-3, always

        // Create a hash to sign
        bytes32 hash = keccak256("test transaction");

        // Sign with signerKey1 and signerKey2
        bytes[] memory sigs = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(signerKey1, hash);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        (uint8 v2, bytes32 r2, bytes32 s2_bytes) = vm.sign(signerKey2, hash);
        sigs[1] = abi.encodePacked(r2, s2_bytes, v2);

        assertTrue(registry.validateMultiSig(master1, hash, sigs));
    }

    function test_validateMultiSig_1of3_fail() public {
        uint256 signerKey1 = uint256(keccak256("s1"));
        uint256 signerKey2 = uint256(keccak256("s2"));
        uint256 signerKey3 = uint256(keccak256("s3"));

        address[] memory signers = new address[](3);
        signers[0] = vm.addr(signerKey1);
        signers[1] = vm.addr(signerKey2);
        signers[2] = vm.addr(signerKey3);

        vm.prank(master1);
        registry.configureMultiSig(signers, 2, 0); // need 2 but only 1 provided

        bytes32 hash = keccak256("test transaction");
        bytes[] memory sigs = new bytes[](1);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(signerKey1, hash);
        sigs[0] = abi.encodePacked(r1, s1, v1);

        assertFalse(registry.validateMultiSig(master1, hash, sigs));
    }

    function test_validateMultiSig_rejectDuplicateSigs() public {
        uint256 signerKey1 = uint256(keccak256("s1"));
        uint256 signerKey2 = uint256(keccak256("s2"));

        address[] memory signers = new address[](2);
        signers[0] = vm.addr(signerKey1);
        signers[1] = vm.addr(signerKey2);

        vm.prank(master1);
        registry.configureMultiSig(signers, 2, 0);

        bytes32 hash = keccak256("test transaction");
        // Provide same signature twice (same signer twice)
        bytes[] memory sigs = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(signerKey1, hash);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r1, s1, v1); // duplicate

        assertFalse(registry.validateMultiSig(master1, hash, sigs));
    }

    function test_requiresMultiSig_notConfigured() public {
        assertFalse(registry.requiresMultiSig(master1, 1_000_000e6)); // no config → false
    }

    // =========================================================================
    // authorizeContract
    // =========================================================================

    function test_authorizeContract_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(); // Ownable error
        registry.authorizeContract(makeAddr("newContract"));
    }

    function test_authorizeContract_revert_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        registry.authorizeContract(address(0));
    }

    function test_isAuthorizedContract() public {
        assertTrue(registry.isAuthorizedContract(authorizedContract));
        assertFalse(registry.isAuthorizedContract(stranger));
    }

    // KR-L-01: deauthorizeContract
    function test_deauthorizeContract_revokesAccess() public {
        // Confirm authorized before
        assertTrue(registry.isAuthorizedContract(authorizedContract));

        vm.prank(admin);
        registry.deauthorizeContract(authorizedContract);

        assertFalse(registry.isAuthorizedContract(authorizedContract));
    }

    function test_deauthorizeContract_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.deauthorizeContract(authorizedContract);
    }

    function test_deauthorizeContract_revert_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        registry.deauthorizeContract(address(0));
    }

    // KR-I-02: allowedModelsBitmap = 0 validation in delegateKey
    function test_delegateKey_revert_zeroBitmap() public {
        address sessionKey = makeAddr("sessionKeyZeroBitmap");
        uint256 signerKey = uint256(keccak256("masterZeroBitmap"));
        address masterKey = vm.addr(signerKey);

        uint256 nonce = registry.getNonce(masterKey);
        bytes memory sig = _signDelegation(signerKey, masterKey, sessionKey, 1_000e6, 0, 0, 0, nonce);

        vm.prank(masterKey);
        vm.expectRevert(RemitErrors.ZeroAmount.selector);
        registry.delegateKey(sessionKey, 1_000e6, 0, 0, 0, sig);
    }

    // =========================================================================
    // Integration: full delegation → spend → daily reset flow
    // =========================================================================

    function test_integration_delegateSpendReset() public {
        // No per-tx limit (0), daily limit = 500e6
        _delegate(masterKey1, session1, 0, DAILY_LIMIT, ALLOWED_ALL, 0);

        // Session key is valid
        assertTrue(registry.isValidDelegation(session1));
        assertTrue(registry.checkSpendingLimit(session1, 50e6, 0));

        // Record multiple spends
        vm.prank(authorizedContract);
        registry.recordSpend(session1, 100e6); // day 1 spend: $100
        vm.prank(authorizedContract);
        registry.recordSpend(session1, 100e6); // day 1 spend: $200

        IRemitKeyRegistry.Delegation memory d = registry.getDelegation(session1);
        assertEq(d.dailySpent, 200e6);

        // Daily limit check: 300e6 more would exactly hit $500 limit; 301e6 exceeds it
        assertTrue(registry.checkSpendingLimit(session1, 300e6, 0)); // 200 + 300 = 500 ✓
        assertFalse(registry.checkSpendingLimit(session1, 301e6, 0)); // 200 + 301 = 501 > 500 ✗

        // Advance to next day
        vm.warp(block.timestamp + 1 days + 1 seconds);

        // Daily limit resets — can spend full daily limit again
        assertTrue(registry.checkSpendingLimit(session1, DAILY_LIMIT, 0));

        vm.prank(authorizedContract);
        registry.recordSpend(session1, DAILY_LIMIT);
        d = registry.getDelegation(session1);
        assertEq(d.dailySpent, DAILY_LIMIT);
    }

    function test_integration_expiredKeyRejected() public {
        uint64 expires = uint64(block.timestamp + 1 hours);
        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires);

        assertTrue(registry.isValidDelegation(session1));

        vm.warp(block.timestamp + 2 hours);

        assertFalse(registry.isValidDelegation(session1));
        // checkSpendingLimit still works (doesn't check validity, only limits)
        // Callers must check isValidDelegation separately
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_spendingLimitArithmetic(uint96 limit, uint96 amount) public {
        vm.assume(limit > 0 && limit <= 1_000_000e6); // max $1M
        vm.assume(amount <= 1_000_000e6);

        _delegate(masterKey1, session1, limit, 0, ALLOWED_ALL, 0); // no daily limit

        bool expected = amount <= limit;
        bool actual = registry.checkSpendingLimit(session1, amount, 0);
        assertEq(actual, expected);
    }

    function testFuzz_dailyLimitAccumulation(uint96 spend1, uint96 spend2) public {
        uint96 dailyLimit = 1000e6;
        vm.assume(spend1 <= dailyLimit && spend2 <= dailyLimit);
        vm.assume(uint256(spend1) + uint256(spend2) <= dailyLimit); // combined within limit

        _delegate(masterKey1, session1, 0, dailyLimit, ALLOWED_ALL, 0);

        vm.prank(authorizedContract);
        registry.recordSpend(session1, spend1);

        vm.prank(authorizedContract);
        registry.recordSpend(session1, spend2);

        IRemitKeyRegistry.Delegation memory d = registry.getDelegation(session1);
        assertEq(d.dailySpent, spend1 + spend2);
    }

    function testFuzz_ttlEdgeCases(uint64 expiresOffset) public {
        vm.assume(expiresOffset > 1 && expiresOffset < 365 days);
        uint64 expires = uint64(block.timestamp) + expiresOffset;

        _delegate(masterKey1, session1, SPEND_LIMIT, DAILY_LIMIT, ALLOWED_ALL, expires);

        // Before expiry: valid
        vm.warp(expires - 1);
        assertTrue(registry.isValidDelegation(session1));

        // At or after expiry: invalid
        vm.warp(expires);
        assertFalse(registry.isValidDelegation(session1));
    }
}
