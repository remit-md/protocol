// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitArbitration} from "../src/RemitArbitration.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";

/// @title RemitArbitrationFuzzTest
/// @notice Fuzz/property tests for RemitArbitration.sol numeric invariants.
/// @dev Focuses on: bond storage/claiming exactness, tier threshold ordering,
///      and percentage-split math safety.
contract RemitArbitrationFuzzTest is Test {
    MockUSDC internal usdc;
    RemitArbitration internal arb;

    address internal owner = makeAddr("owner");

    function setUp() public {
        usdc = new MockUSDC();
        arb = new RemitArbitration(address(usdc), owner);
    }

    // =========================================================================
    // Fuzz: registerArbitrator — bond stored exactly
    // =========================================================================

    /// @dev Any wallet that registers stores exactly MIN_ARBITRATOR_BOND.
    function testFuzz_registerArbitrator_bondStoredExactly(address wallet) public {
        vm.assume(wallet != address(0));
        vm.assume(wallet.code.length == 0); // EOA only
        vm.assume(arb.getArbitrator(wallet).wallet == address(0)); // not yet registered

        uint256 bond = arb.MIN_ARBITRATOR_BOND();
        usdc.mint(wallet, bond);
        vm.prank(wallet);
        usdc.approve(address(arb), bond);

        uint256 arbBefore = usdc.balanceOf(address(arb));

        vm.prank(wallet);
        arb.registerArbitrator("ipfs://fuzz-meta");

        assertEq(
            usdc.balanceOf(address(arb)) - arbBefore,
            bond,
            "contract balance must increase by exactly MIN_ARBITRATOR_BOND"
        );
        assertEq(arb.getArbitrator(wallet).bondAmount, bond, "stored bondAmount must equal MIN_ARBITRATOR_BOND");
    }

    // =========================================================================
    // Fuzz: claimArbitratorBond — wallet receives exact bond after cooldown
    // =========================================================================

    /// @dev After removing themselves and waiting the cooldown, an arbitrator
    ///      must receive back exactly the registered bond amount.
    function testFuzz_claimArbitratorBond_exactReturn(address wallet) public {
        vm.assume(wallet != address(0));
        vm.assume(wallet.code.length == 0);
        vm.assume(arb.getArbitrator(wallet).wallet == address(0));

        uint256 bond = arb.MIN_ARBITRATOR_BOND();
        usdc.mint(wallet, bond);
        vm.prank(wallet);
        usdc.approve(address(arb), bond);

        vm.prank(wallet);
        arb.registerArbitrator("ipfs://fuzz-claim");

        // Remove from pool
        vm.prank(wallet);
        arb.removeArbitrator();

        // Wait out the cooldown (7 days)
        vm.warp(block.timestamp + arb.ARBITRATOR_BOND_COOLDOWN() + 1);

        uint256 walletBefore = usdc.balanceOf(wallet);

        vm.prank(wallet);
        arb.claimArbitratorBond();

        assertEq(
            usdc.balanceOf(wallet) - walletBefore, bond, "claimed bond must equal exactly the registered bond amount"
        );
        assertEq(arb.getArbitrator(wallet).bondAmount, 0, "bondAmount must be zero after claim");
    }

    // =========================================================================
    // Fuzz: percentage split math — no overflow for any valid percent pair
    // =========================================================================

    /// @dev For any (payerPercent, payeePercent) where p+q==100 and any disputed
    ///      amount up to uint96.max, the split computation must not overflow.
    ///      Simulates the math from _executeDecision: amount * percent / 100.
    function testFuzz_percentageSplit_noOverflow(uint8 p, uint96 amount) public pure {
        // Constrain p to [0, 100] so q = 100 - p is also valid
        p = uint8(bound(p, 0, 100));
        uint8 q = uint8(100 - uint256(p));

        // Replicate _executeDecision arithmetic: (amount * percent) / 100
        uint256 payerShare = (uint256(amount) * uint256(p)) / 100;
        uint256 payeeShare = (uint256(amount) * uint256(q)) / 100;

        // Shares must not exceed amount individually
        assertLe(payerShare, amount, "payer share must not exceed amount");
        assertLe(payeeShare, amount, "payee share must not exceed amount");

        // Sum must not exceed amount (rounding may leave dust)
        assertLe(payerShare + payeeShare, amount, "total shares must not exceed amount");
    }

    // =========================================================================
    // Fuzz: tier threshold ordering invariant
    // =========================================================================

    /// @dev ADMIN_AMOUNT_THRESHOLD < POOL_REQUIRED_THRESHOLD at all times.
    function testFuzz_tierThresholds_orderingInvariant() public view {
        assertLt(
            arb.ADMIN_AMOUNT_THRESHOLD(),
            arb.POOL_REQUIRED_THRESHOLD(),
            "Admin threshold must be less than Pool threshold"
        );
    }

    // =========================================================================
    // Fuzz: cooldown invariant — claimArbitratorBond reverts before cooldown ends
    // =========================================================================

    /// @dev claimArbitratorBond must revert with ArbitrationCooldownNotMet
    ///      when called before the 7-day cooldown expires.
    function testFuzz_claimArbitratorBond_revertBeforeCooldown(address wallet, uint64 earlyWarp) public {
        vm.assume(wallet != address(0));
        vm.assume(wallet.code.length == 0);
        vm.assume(arb.getArbitrator(wallet).wallet == address(0));

        // earlyWarp must be less than the cooldown
        earlyWarp = uint64(bound(earlyWarp, 0, arb.ARBITRATOR_BOND_COOLDOWN() - 1));

        uint256 bond = arb.MIN_ARBITRATOR_BOND();
        usdc.mint(wallet, bond);
        vm.prank(wallet);
        usdc.approve(address(arb), bond);

        vm.prank(wallet);
        arb.registerArbitrator("ipfs://fuzz-cooldown");

        vm.prank(wallet);
        arb.removeArbitrator();

        // Warp by less than the full cooldown
        if (earlyWarp > 0) vm.warp(block.timestamp + earlyWarp);

        vm.prank(wallet);
        vm.expectRevert(); // ArbitrationCooldownNotMet
        arb.claimArbitratorBond();
    }
}
