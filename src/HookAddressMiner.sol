// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @title HookAddressMiner
/// @notice Finds a CREATE2 salt that lands a hook on an address carrying the wanted permission
/// bits. Used by the deploy script and the tests; the launch factory does the same off chain.
library HookAddressMiner {
    /// @notice Upper bound on salts tried. Two permission bits need on average 2^14 tries, so this
    /// leaves a wide margin before giving up.
    uint256 internal constant MAX_TRIES = 200_000;

    error NoSaltFound(uint160 flags);

    /// @notice Finds the first salt in `[0, MAX_TRIES)` for which `deployer` deploying
    /// `creationCodeWithArgs` with CREATE2 lands on an address whose low 14 bits equal `flags`.
    /// @param deployer The address performing the CREATE2: the test contract in `forge test`, the
    /// deterministic deployer proxy (0x4e59b44847b379578588920cA78FbF26c0B4956C) in a broadcast.
    /// @param flags The wanted permission bits (bits above the low 14 are ignored).
    /// @param creationCodeWithArgs Creation code with ABI-encoded constructor arguments appended.
    function find(address deployer, uint160 flags, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCodeWithArgs);
        for (uint256 i = 0; i < MAX_TRIES; i++) {
            address candidate = computeAddress(deployer, bytes32(i), initCodeHash);
            if (HookFlags.matches(candidate, flags)) return (candidate, bytes32(i));
        }
        revert NoSaltFound(flags);
    }

    /// @notice The CREATE2 address `deployer` produces with `salt` for code hashing to `initCodeHash`.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
