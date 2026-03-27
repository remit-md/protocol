// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

/// @title MockUSDCPermitTest
/// @notice Tests for EIP-2612 permit() on MockUSDC.
contract MockUSDCPermitTest is Test {
    MockUSDC public usdc;

    address public owner;
    uint256 public ownerKey;
    address public spender = makeAddr("spender");

    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        ownerKey = uint256(keccak256(abi.encodePacked("permit-owner")));
        owner = vm.addr(ownerKey);
        usdc = new MockUSDC();
        usdc.mint(owner, 1000e6);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USD Coin"),
                keccak256("2"),
                block.chainid,
                address(usdc)
            )
        );
    }

    function _signPermit(uint256 value, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash =
            keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, usdc.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (v, r, s) = vm.sign(ownerKey, digest);
    }

    function test_permit_happyPath() public {
        uint256 value = 500e6;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(value, deadline);

        assertEq(usdc.allowance(owner, spender), 0);
        assertEq(usdc.nonces(owner), 0);

        usdc.permit(owner, spender, value, deadline, v, r, s);

        assertEq(usdc.allowance(owner, spender), value);
        assertEq(usdc.nonces(owner), 1);
    }

    function test_permit_spenderCanTransferAfterPermit() public {
        uint256 value = 200e6;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(value, deadline);
        usdc.permit(owner, spender, value, deadline, v, r, s);

        vm.prank(spender);
        usdc.transferFrom(owner, spender, value);
        assertEq(usdc.balanceOf(spender), value);
    }

    function test_permit_revert_expiredDeadline() public {
        uint256 value = 100e6;
        uint256 deadline = block.timestamp - 1;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(value, deadline + 2); // sign with valid deadline
        // Call with expired deadline - the sig won't match anyway
        vm.expectRevert("MockUSDC: permit expired");
        usdc.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_permit_revert_invalidSignature() public {
        uint256 value = 100e6;
        uint256 deadline = block.timestamp + 1 hours;

        // Sign with wrong key
        uint256 wrongKey = uint256(keccak256(abi.encodePacked("wrong")));
        bytes32 structHash =
            keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, usdc.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        vm.expectRevert("MockUSDC: invalid permit signature");
        usdc.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_permit_revert_replayNonce() public {
        uint256 value = 100e6;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(value, deadline);
        usdc.permit(owner, spender, value, deadline, v, r, s);

        // Same signature replayed - nonce incremented so sig is invalid
        vm.expectRevert("MockUSDC: invalid permit signature");
        usdc.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_permit_DOMAIN_SEPARATOR() public view {
        assertEq(usdc.DOMAIN_SEPARATOR(), _domainSeparator());
    }

    function test_permit_nonceIncrementsSequentially() public {
        uint256 deadline = block.timestamp + 1 hours;

        for (uint256 i = 0; i < 3; i++) {
            assertEq(usdc.nonces(owner), i);
            (uint8 v, bytes32 r, bytes32 s) = _signPermit(100e6, deadline);
            usdc.permit(owner, spender, 100e6, deadline, v, r, s);
        }
        assertEq(usdc.nonces(owner), 3);
    }
}
