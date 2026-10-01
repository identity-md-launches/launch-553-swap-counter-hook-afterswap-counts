// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title SwapCounterHook
/// @notice A Uniswap v4 hook that counts swaps. `afterSwap` increments a counter for the swap's
/// `sender` and a global counter and emits one `SwapCounted` event per swap. The hook never
/// returns a delta, never overrides a fee, never holds tokens and has no owner.
/// @dev Permissions: `afterInitialize` and `afterSwap` only. `afterInitialize` is required for an
/// IMD launch (it stops anyone initializing the hook's pool before the hook has code) and does
/// nothing but check its caller. Every other callback reverts with `HookNotImplemented`, and the
/// address the hook is deployed at must carry exactly these two permission bits or the
/// constructor reverts with `Hooks.HookAddressNotValid`.
///
/// `sender` is the address that called `PoolManager.swap`, i.e. the router or the contract that
/// unlocked the manager, not the end user behind it. See the README for what that means for the
/// per-sender counters.
contract SwapCounterHook is IHooks {
    using PoolIdLibrary for PoolKey;

    /// @notice Emitted once per swap, after the pool has settled it.
    /// @param poolId The pool the swap went through.
    /// @param sender The address that called `PoolManager.swap` (a router, not the end user).
    /// @param senderSwapCount `sender`'s swap count after this swap.
    /// @param totalSwapCount The global swap count after this swap.
    /// @param zeroForOne Swap direction, copied from the swap parameters.
    /// @param amountSpecified Signed specified amount, copied from the swap parameters.
    /// @param delta The balance delta the pool computed for the swapper. Reported, never changed.
    event SwapCounted(
        PoolId indexed poolId,
        address indexed sender,
        uint256 senderSwapCount,
        uint256 totalSwapCount,
        bool zeroForOne,
        int256 amountSpecified,
        BalanceDelta delta
    );

    /// @notice A callback was called by something other than the pool manager.
    error NotPoolManager();
    /// @notice A callback this hook does not enable was called.
    error HookNotImplemented();
    /// @notice The constructor was given the zero address as the pool manager.
    error ZeroPoolManager();

    /// @notice The only address allowed to drive the callbacks.
    IPoolManager public immutable poolManager;

    /// @notice Number of swaps counted across every pool using this hook.
    uint256 public totalSwaps;

    /// @notice Number of swaps counted for each `sender` passed to `afterSwap`.
    mapping(address sender => uint256 count) public swapsBySender;

    /// @param _poolManager The chain's Uniswap v4 PoolManager. Never hardcoded; the deployer
    /// supplies it per chain.
    constructor(IPoolManager _poolManager) {
        if (address(_poolManager) == address(0)) revert ZeroPoolManager();
        poolManager = _poolManager;
        // Reverts with HookAddressNotValid unless this address carries exactly the declared bits.
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice The permissions this hook implements. They must match its address bits.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Swap count for one sender. Equivalent to the public `swapsBySender` getter.
    function swapCount(address sender) external view returns (uint256) {
        return swapsBySender[sender];
    }

    // ----------------------------------------------------------------------------------------
    // Enabled callbacks
    // ----------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Enabled only so the launch factory can deploy the hook and initialize its pool in one
    /// transaction. Accepts any pool and changes no state.
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Counts the swap and emits `SwapCounted`. Returns a zero delta; `afterSwapReturnDelta`
    /// is disabled, so the pool manager would ignore any other value anyway.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        uint256 senderCount = ++swapsBySender[sender];
        uint256 total = ++totalSwaps;
        emit SwapCounted(key.toId(), sender, senderCount, total, params.zeroForOne, params.amountSpecified, delta);
        return (IHooks.afterSwap.selector, 0);
    }

    // ----------------------------------------------------------------------------------------
    // Disabled callbacks. The pool manager never calls them because the address bits are off;
    // anyone who does reaches a revert.
    // ----------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
