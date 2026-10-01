// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookFlags
/// @notice The 14 permission bits Uniswap v4 encodes in a hook's address, and the two reads every
/// deployer and verifier needs: which bits an address carries, and whether they are the ones wanted.
/// @dev Values mirror `Hooks.sol` in v4-core bit for bit. They are duplicated here, rather than
/// re-exported, so that tooling which only knows the delivered repository can import one small
/// library without pulling the whole core.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 8;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_DONATE = 1 << 5;
    uint160 internal constant AFTER_DONATE = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = 1 << 0;

    /// @notice Mask of every permission bit.
    uint160 internal constant ALL = (1 << 14) - 1;

    /// @notice The permission bits carried by `hook`'s address.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice True when `hook`'s address carries exactly the permission bits in `flags` (bits
    /// above the 14 permission bits in `flags` are ignored).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }
}
