// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Minimal ERC-20 with EIP-3009 transferWithAuthorization for local testing.
/// @dev Anyone can mint — local Anvil only.
contract MockUSDC is ERC20 {
    // EIP-3009 state
    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;

    bytes32 private constant _TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint USDC to any address (no access control — test only)
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    // ── EIP-712 domain separator ──────────────────────────────────────────────

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USD Coin"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    // ── EIP-3009: transferWithAuthorization ───────────────────────────────────

    /// @notice Execute a USDC transfer on behalf of the `from` address using a
    ///         pre-signed EIP-3009 authorization.
    /// @dev Matches the real USDC transferWithAuthorization interface so the
    ///      remit.md server can settle x402 payments against this mock.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp > validAfter, "MockUSDC: not yet valid");
        require(block.timestamp < validBefore, "MockUSDC: authorization expired");
        require(!_authorizationStates[from][nonce], "MockUSDC: nonce already used");

        bytes32 structHash = keccak256(
            abi.encode(_TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));

        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == from, "MockUSDC: invalid signature");

        _authorizationStates[from][nonce] = true;
        _transfer(from, to, value);
    }

    /// @notice Check whether a nonce has been used for a given authorizer.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }
}
