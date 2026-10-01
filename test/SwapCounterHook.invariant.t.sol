// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {SwapCounterHook} from "src/SwapCounterHook.sol";
import {HookAddressMiner} from "src/HookAddressMiner.sol";
import {HookFlags} from "src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Every successful operation is repeated on an independently initialized, hookless pool.
/// Expected counts come from completed router calls, not from the hook's events or getters.
contract SwapCounterSequenceHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    SwapCounterHook public immutable hook;
    PoolModifyLiquidityTest public immutable lpRouter;
    PoolDonateTest public immutable donateRouter;
    PoolSwapTest[3] public routers;
    PoolKey[2] internal hookedPools;
    PoolKey[2] internal plainPools;

    uint256 public successfulSwaps;
    uint256[3] public expectedByRouter;
    uint256 public rejectedCallbacks;
    uint256 public donations;
    uint256 public feeCollections;
    int256 public netToken0;
    int256 public netToken1;

    constructor(
        IPoolManager manager_,
        SwapCounterHook hook_,
        PoolModifyLiquidityTest lpRouter_,
        PoolKey[2] memory hookedPools_,
        PoolKey[2] memory plainPools_
    ) {
        manager = manager_;
        hook = hook_;
        lpRouter = lpRouter_;
        for (uint256 i; i < hookedPools_.length; ++i) {
            hookedPools[i] = hookedPools_[i];
            plainPools[i] = plainPools_[i];
        }
        donateRouter = new PoolDonateTest(manager_);
        MockERC20 token0 = MockERC20(Currency.unwrap(hookedPools_[0].currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(hookedPools_[0].currency1));
        for (uint256 i; i < routers.length; ++i) {
            routers[i] = new PoolSwapTest(manager_);
            token0.approve(address(routers[i]), type(uint256).max);
            token1.approve(address(routers[i]), type(uint256).max);
        }
        token0.approve(address(donateRouter), type(uint256).max);
        token1.approve(address(donateRouter), type(uint256).max);
    }

    function swap(uint256 routerSeed, uint256 poolSeed, uint256 amount, bool zeroForOne, bool exactOut, bytes32 data)
        external
    {
        uint256 routerIndex = bound(routerSeed, 0, routers.length - 1);
        uint256 poolIndex = bound(poolSeed, 0, hookedPools.length - 1);
        // Even 128 consecutive maximum trades fit in the funded budget and stay well inside
        // full-range liquidity. One wei remains in-domain to exercise fee/amount rounding.
        amount = bound(amount, 1, 100 ether);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactOut ? int256(amount) : -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest router = routers[routerIndex];
        bytes memory hookData = abi.encode(address(this), data);
        BalanceDelta hooked =
            router.swap(hookedPools[poolIndex], params, PoolSwapTest.TestSettings(false, false), hookData);
        BalanceDelta plain =
            router.swap(plainPools[poolIndex], params, PoolSwapTest.TestSettings(false, false), hookData);
        _recordMatchingDeltas(hooked, plain);
        ++successfulSwaps;
        ++expectedByRouter[routerIndex];
    }

    function donate(uint256 poolSeed, uint256 amount0, uint256 amount1) external {
        uint256 poolIndex = bound(poolSeed, 0, hookedPools.length - 1);
        amount0 = bound(amount0, 0, 1 ether);
        amount1 = bound(amount1, 0, 1 ether);
        BalanceDelta hooked = donateRouter.donate(hookedPools[poolIndex], amount0, amount1, "");
        BalanceDelta plain = donateRouter.donate(plainPools[poolIndex], amount0, amount1, "");
        _recordMatchingDeltas(hooked, plain);
        ++donations;
    }

    function collectFees(uint256 poolSeed) external {
        uint256 poolIndex = bound(poolSeed, 0, hookedPools.length - 1);
        // A zero liquidity change collects fees from the same LP position seeded by the fixture.
        ModifyLiquidityParams memory params = ModifyLiquidityParams(-887220, 887220, 0, bytes32(0));
        BalanceDelta hooked = lpRouter.modifyLiquidity(hookedPools[poolIndex], params, "");
        BalanceDelta plain = lpRouter.modifyLiquidity(plainPools[poolIndex], params, "");
        _recordMatchingDeltas(hooked, plain);
        ++feeCollections;
    }

    function rejectSpoofedCallback(uint256 poolSeed, address claimedSender, bool initialization) external {
        PoolKey memory key = hookedPools[bound(poolSeed, 0, hookedPools.length - 1)];
        bytes memory callData = initialization
            ? abi.encodeCall(IHooks.afterInitialize, (claimedSender, key, uint160(1 << 96), int24(0)))
            : abi.encodeCall(
                IHooks.afterSwap,
                (claimedSender, key, SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1), BalanceDelta.wrap(0), "")
            );
        (bool ok, bytes memory reason) = address(hook).call(callData);
        assertFalse(ok, "untrusted caller fabricated a callback");
        assertEq(reason, abi.encodeWithSelector(SwapCounterHook.NotPoolManager.selector));
        ++rejectedCallbacks;
    }

    function _recordMatchingDeltas(BalanceDelta hooked, BalanceDelta plain) internal {
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain), "hook changed settled amounts");
        netToken0 += int256(hooked.amount0()) + int256(plain.amount0());
        netToken1 += int256(hooked.amount1()) + int256(plain.amount1());
        // Check in the same transaction as unlock/settle, before transient storage is cleared.
        assertFalse(manager.isUnlocked(), "manager remained unlocked");
        assertEq(manager.getNonzeroDeltaCount(), 0, "unsettled currency delta");
        assertEq(manager.currencyDelta(address(hook), hookedPools[0].currency0), 0);
        assertEq(manager.currencyDelta(address(hook), hookedPools[0].currency1), 0);
    }

    function assertEquivalentPools() external view {
        for (uint256 i; i < hookedPools.length; ++i) {
            PoolId hookedId = hookedPools[i].toId();
            PoolId plainId = plainPools[i].toId();
            assertEq(_slot0Hash(hookedId), _slot0Hash(plainId), "price, tick or fees diverged");
            assertEq(manager.getLiquidity(hookedId), manager.getLiquidity(plainId), "liquidity diverged");
            (uint256 hooked0, uint256 hooked1) = manager.getFeeGrowthGlobals(hookedId);
            (uint256 plain0, uint256 plain1) = manager.getFeeGrowthGlobals(plainId);
            assertEq(hooked0, plain0, "currency0 fee growth differs");
            assertEq(hooked1, plain1, "currency1 fee growth differs");
            (,,, uint24 fee) = manager.getSlot0(hookedId);
            assertEq(fee, hookedPools[i].fee, "hook changed the configured LP fee");
        }
    }

    function _slot0Hash(PoolId id) internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        return keccak256(abi.encode(price, tick, protocolFee, lpFee));
    }
}

/// @dev Sequential economic equivalence supplements the one-swap differential tests.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract SwapCounterHookInvariantTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant HANDLER_FUNDS = 1_000_000 ether;
    int256 internal constant LIQUIDITY = 1_000_000 ether;
    PoolManager internal manager;
    SwapCounterHook internal hook;
    SwapCounterSequenceHandler internal handler;
    PoolModifyLiquidityTest internal lpRouter;
    MockERC20 internal token0;
    MockERC20 internal token1;
    uint256 internal initialManager0;
    uint256 internal initialManager1;

    function setUp() public {
        manager = new PoolManager(address(this));
        bytes memory initCode = abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(manager));
        (, bytes32 salt) =
            HookAddressMiner.find(address(this), HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP, initCode);
        hook = new SwapCounterHook{salt: salt}(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        MockERC20 a = new MockERC20("Sequence A", "SA", SUPPLY);
        MockERC20 b = new MockERC20("Sequence B", "SB", SUPPLY);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);

        PoolKey[2] memory hookedPools;
        PoolKey[2] memory plainPools;
        for (uint256 i; i < hookedPools.length; ++i) {
            hookedPools[i] = PoolKey({
                currency0: Currency.wrap(address(token0)),
                currency1: Currency.wrap(address(token1)),
                fee: i == 0 ? 500 : 3_000,
                tickSpacing: i == 0 ? int24(10) : int24(60),
                hooks: IHooks(address(hook))
            });
            plainPools[i] = PoolKey({
                currency0: hookedPools[i].currency0,
                currency1: hookedPools[i].currency1,
                fee: hookedPools[i].fee,
                tickSpacing: hookedPools[i].tickSpacing,
                hooks: IHooks(address(0))
            });
            manager.initialize(hookedPools[i], uint160(1 << 96));
            manager.initialize(plainPools[i], uint160(1 << 96));
            ModifyLiquidityParams memory params = ModifyLiquidityParams(-887220, 887220, LIQUIDITY, bytes32(0));
            lpRouter.modifyLiquidity(hookedPools[i], params, "");
            lpRouter.modifyLiquidity(plainPools[i], params, "");
        }
        handler = new SwapCounterSequenceHandler(manager, hook, lpRouter, hookedPools, plainPools);
        token0.transfer(address(handler), HANDLER_FUNDS);
        token1.transfer(address(handler), HANDLER_FUNDS);
        initialManager0 = token0.balanceOf(address(manager));
        initialManager1 = token1.balanceOf(address(manager));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.collectFees.selector;
        selectors[3] = handler.rejectSpoofedCallback.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_countsMatchSuccessfulSwapsAcrossRoutersAndPools() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            address router = address(handler.routers(i));
            uint256 expected = handler.expectedByRouter(i);
            assertEq(hook.swapsBySender(router), expected, "sender count differs from completed swaps");
            assertEq(hook.swapCount(router), expected, "view alias disagrees");
            sum += expected;
        }
        assertEq(hook.totalSwaps(), sum, "global count differs from sender sum");
        assertEq(hook.totalSwaps(), handler.successfulSwaps(), "non-swap call changed count");
        assertEq(hook.swapCount(address(handler)), 0, "end user counted instead of router");
        assertEq(hook.swapCount(address(manager)), 0, "manager counted instead of router");
        assertEq(hook.swapCount(address(lpRouter)), 0, "liquidity operation counted as swap");
        assertEq(hook.swapCount(address(handler.donateRouter())), 0, "donation counted as swap");
    }

    function invariant_amountsPricesLiquidityAndFeesMatchTheHooklessPools() public view {
        handler.assertEquivalentPools();
    }

    function invariant_tokensAreConservedAndHookAccruesNoAssetsOrClaims() public view {
        assertEq(int256(token0.balanceOf(address(handler))), int256(HANDLER_FUNDS) + handler.netToken0());
        assertEq(int256(token1.balanceOf(address(handler))), int256(HANDLER_FUNDS) + handler.netToken1());
        assertEq(int256(token0.balanceOf(address(manager))), int256(initialManager0) - handler.netToken0());
        assertEq(int256(token1.balanceOf(address(manager))), int256(initialManager1) - handler.netToken1());
        assertEq(
            token0.balanceOf(address(this)) + token0.balanceOf(address(handler)) + token0.balanceOf(address(manager)),
            SUPPLY
        );
        assertEq(
            token1.balanceOf(address(this)) + token1.balanceOf(address(handler)) + token1.balanceOf(address(manager)),
            SUPPLY
        );
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token0))), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token1))), 0);
    }

    function test_sequenceActionsReachBothPoolsAllRoutersAndRoundingEdges() public {
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 2; ++j) {
                handler.swap(i, j, 1, true, false, bytes32(0));
                handler.swap(i, j, 1, false, true, bytes32(type(uint256).max));
                handler.swap(i, j, 100 ether, true, true, bytes32(uint256(1)));
                handler.swap(i, j, 100 ether, false, false, bytes32(uint256(2)));
                handler.donate(j, 0, 1 ether);
                handler.donate(j, 1 ether, 0);
                handler.collectFees(j);
                handler.rejectSpoofedCallback(j, address(handler.routers(i)), false);
                handler.rejectSpoofedCallback(j, address(handler.routers(i)), true);
            }
        }
        assertEq(handler.successfulSwaps(), 24);
        assertEq(handler.donations(), 12);
        assertEq(handler.feeCollections(), 6);
        assertEq(handler.rejectedCallbacks(), 12);
        invariant_countsMatchSuccessfulSwapsAcrossRoutersAndPools();
        invariant_amountsPricesLiquidityAndFeesMatchTheHooklessPools();
        invariant_tokensAreConservedAndHookAccruesNoAssetsOrClaims();
    }
}
