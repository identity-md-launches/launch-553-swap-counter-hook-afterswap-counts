// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookFlags} from "../src/HookFlags.sol";
import {HookAddressMiner} from "../src/HookAddressMiner.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract SwapCounterHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    int256 constant LIQUIDITY = 1_000_000 ether;

    PoolManager manager;
    SwapCounterHook hook;
    PoolSwapTest swapRouter;
    PoolSwapTest secondRouter;
    PoolModifyLiquidityTest lpRouter;
    MockERC20 token0;
    MockERC20 token1;

    /// @dev The hooked pool under test and an identical pool with no hook, used as the control
    /// that proves the hook changes nothing about amounts.
    PoolKey key;
    PoolKey plainKey;

    event SwapCounted(
        PoolId indexed poolId,
        address indexed sender,
        uint256 senderSwapCount,
        uint256 totalSwapCount,
        bool zeroForOne,
        int256 amountSpecified,
        BalanceDelta delta
    );

    function setUp() public {
        manager = new PoolManager(address(this));
        hook = deployHook(manager);

        swapRouter = new PoolSwapTest(manager);
        secondRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("A", "A", SUPPLY);
        MockERC20 b = new MockERC20("B", "B", SUPPLY);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(secondRouter), type(uint256).max);
        token1.approve(address(secondRouter), type(uint256).max);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        plainKey = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(address(0))
        });

        manager.initialize(key, SQRT_PRICE_1_1);
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, LIQUIDITY, bytes32(0)), "");
        lpRouter.modifyLiquidity(plainKey, ModifyLiquidityParams(-600, 600, LIQUIDITY, bytes32(0)), "");
    }

    /// @dev Mines a salt for this test contract and deploys the hook with CREATE2, as the launch
    /// factory does on chain.
    function deployHook(IPoolManager pm) internal returns (SwapCounterHook deployed) {
        bytes memory initCode = abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(pm));
        (address predicted, bytes32 salt) = HookAddressMiner.find(address(this), FLAGS, initCode);
        deployed = new SwapCounterHook{salt: salt}(pm);
        assertEq(address(deployed), predicted, "mined address disagrees with CREATE2");
    }

    function swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function doSwap(PoolSwapTest router, PoolKey memory k, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta)
    {
        return router.swap(k, swapParams(zeroForOne, amountSpecified), PoolSwapTest.TestSettings(false, false), "");
    }

    // ------------------------------------------------------------------ configuration

    function test_permissionsAreAfterInitializeAndAfterSwapOnly() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_addressCarriesExactlyTheDeclaredFlags() public view {
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertTrue(HookFlags.matches(address(hook), FLAGS));
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), 3_000));
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_constructorRejectsZeroPoolManager() public {
        vm.expectRevert(SwapCounterHook.ZeroPoolManager.selector);
        new SwapCounterHook(IPoolManager(address(0)));
    }

    function test_constructorRejectsAnAddressWithoutTheFlags() public {
        // A plain CREATE lands on an address that almost never carries exactly these two bits.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.assume(!HookFlags.matches(predicted, FLAGS));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwapCounterHook(manager);
    }

    function test_hookFlagsMirrorCore() public pure {
        assertEq(HookFlags.ALL, Hooks.ALL_HOOK_MASK);
        assertEq(HookFlags.BEFORE_INITIALIZE, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(HookFlags.AFTER_INITIALIZE, Hooks.AFTER_INITIALIZE_FLAG);
        assertEq(HookFlags.BEFORE_ADD_LIQUIDITY, Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY, Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_REMOVE_LIQUIDITY, Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_SWAP, Hooks.BEFORE_SWAP_FLAG);
        assertEq(HookFlags.AFTER_SWAP, Hooks.AFTER_SWAP_FLAG);
        assertEq(HookFlags.BEFORE_DONATE, Hooks.BEFORE_DONATE_FLAG);
        assertEq(HookFlags.AFTER_DONATE, Hooks.AFTER_DONATE_FLAG);
        assertEq(HookFlags.BEFORE_SWAP_RETURN_DELTA, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_SWAP_RETURN_DELTA, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
    }

    function testFuzz_hookFlagsMatchesComparesOnlyTheLow14Bits(address a, uint160 flags) public pure {
        assertEq(HookFlags.flagsOf(a), uint160(a) & 0x3FFF);
        assertEq(HookFlags.matches(a, flags), (uint160(a) & 0x3FFF) == (flags & 0x3FFF));
    }

    // ------------------------------------------------------------------ access control

    function test_afterInitializeRefusesCallersOtherThanThePoolManager() public {
        vm.expectRevert(SwapCounterHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_afterSwapRefusesCallersOtherThanThePoolManager() public {
        vm.expectRevert(SwapCounterHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, swapParams(true, -1 ether), toBalanceDelta(0, 0), "");
        assertEq(hook.totalSwaps(), 0);
        assertEq(hook.swapsBySender(address(this)), 0);
    }

    function testFuzz_afterSwapRefusesAnyCallerButThePoolManager(address caller, address sender) public {
        vm.assume(caller != address(manager));
        vm.prank(caller);
        vm.expectRevert(SwapCounterHook.NotPoolManager.selector);
        hook.afterSwap(sender, key, swapParams(true, -1 ether), toBalanceDelta(0, 0), "");
        assertEq(hook.totalSwaps(), 0);
    }

    function test_afterInitializeFromThePoolManagerReturnsItsSelector() public {
        vm.prank(address(manager));
        bytes4 sel = hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        assertEq(sel, IHooks.afterInitialize.selector);
    }

    function test_disabledCallbacksRevertEvenForThePoolManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = toBalanceDelta(0, 0);
        bytes4 err = SwapCounterHook.HookNotImplemented.selector;

        vm.startPrank(address(manager));
        vm.expectRevert(err);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(err);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(err);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(err);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(err);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(err);
        hook.beforeSwap(address(this), key, swapParams(true, -1 ether), "");
        vm.expectRevert(err);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(err);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ counting (direct)

    function test_afterSwapFromThePoolManagerCountsAndEmits() public {
        address sender = makeAddr("router");
        SwapParams memory params = swapParams(true, -5 ether);
        BalanceDelta delta = toBalanceDelta(-5 ether, 4 ether);

        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapCounted(key.toId(), sender, 1, 1, true, -5 ether, delta);
        vm.prank(address(manager));
        (bytes4 sel, int128 hookDelta) = hook.afterSwap(sender, key, params, delta, "");

        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0, "the hook must never return a delta");
        assertEq(hook.totalSwaps(), 1);
        assertEq(hook.swapsBySender(sender), 1);
        assertEq(hook.swapCount(sender), 1);
    }

    function testFuzz_countsPerSenderAndInTotal(address a, address b, uint8 na, uint8 nb) public {
        vm.assume(a != b);
        SwapParams memory params = swapParams(false, 1 ether);
        for (uint256 i = 0; i < na; i++) {
            vm.prank(address(manager));
            hook.afterSwap(a, key, params, toBalanceDelta(0, 0), "");
        }
        for (uint256 i = 0; i < nb; i++) {
            vm.prank(address(manager));
            hook.afterSwap(b, key, params, toBalanceDelta(0, 0), "");
        }
        assertEq(hook.swapsBySender(a), na);
        assertEq(hook.swapsBySender(b), nb);
        assertEq(hook.totalSwaps(), uint256(na) + uint256(nb));
    }

    function testFuzz_afterSwapAlwaysReturnsZeroDelta(
        address sender,
        bool zeroForOne,
        int256 amount,
        int128 d0,
        int128 d1
    ) public {
        vm.prank(address(manager));
        (bytes4 sel, int128 hookDelta) =
            hook.afterSwap(sender, key, swapParams(zeroForOne, amount), toBalanceDelta(d0, d1), "");
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
        assertEq(hook.totalSwaps(), 1);
    }

    // ------------------------------------------------------------------ counting (through the pool)

    function test_swapThroughThePoolCountsTheRouterAsSender() public {
        BalanceDelta delta = doSwap(swapRouter, key, true, -1 ether);
        assertEq(delta.amount0(), -1 ether, "exact input not fully taken");
        assertGt(delta.amount1(), 0, "no output received");

        assertEq(hook.totalSwaps(), 1);
        assertEq(hook.swapsBySender(address(swapRouter)), 1, "the sender is the router that called swap");
        assertEq(hook.swapsBySender(address(this)), 0, "the end user is not the sender v4 reports");
    }

    function test_swapThroughThePoolEmitsSwapCounted() public {
        vm.expectEmit(true, true, false, false, address(hook));
        emit SwapCounted(key.toId(), address(swapRouter), 1, 1, true, -1 ether, toBalanceDelta(0, 0));
        doSwap(swapRouter, key, true, -1 ether);
    }

    function test_swapsFromTwoRoutersAreCountedSeparately() public {
        doSwap(swapRouter, key, true, -1 ether);
        doSwap(swapRouter, key, false, -1 ether);
        doSwap(secondRouter, key, true, -1 ether);

        assertEq(hook.swapsBySender(address(swapRouter)), 2);
        assertEq(hook.swapsBySender(address(secondRouter)), 1);
        assertEq(hook.totalSwaps(), 3);
    }

    function test_swapsOnThePlainPoolAreNotCounted() public {
        doSwap(swapRouter, plainKey, true, -1 ether);
        assertEq(hook.totalSwaps(), 0);
        assertEq(hook.swapsBySender(address(swapRouter)), 0);
    }

    function test_liquidityChangesAreNotCounted() public {
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1 ether, bytes32(0)), "");
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, -1 ether, bytes32(0)), "");
        assertEq(hook.totalSwaps(), 0);
    }

    function test_hookDoesNotChangeExactInputAmounts() public {
        BalanceDelta hooked = doSwap(swapRouter, key, true, -1 ether);
        BalanceDelta plain = doSwap(swapRouter, plainKey, true, -1 ether);
        assertEq(hooked.amount0(), plain.amount0());
        assertEq(hooked.amount1(), plain.amount1());

        hooked = doSwap(swapRouter, key, false, -3 ether);
        plain = doSwap(swapRouter, plainKey, false, -3 ether);
        assertEq(hooked.amount0(), plain.amount0());
        assertEq(hooked.amount1(), plain.amount1());
        assertEq(hook.totalSwaps(), 2);
    }

    function test_hookDoesNotChangeExactOutputAmounts() public {
        BalanceDelta hooked = doSwap(swapRouter, key, true, 1 ether);
        BalanceDelta plain = doSwap(swapRouter, plainKey, true, 1 ether);
        assertEq(hooked.amount1(), 1 ether);
        assertEq(hooked.amount0(), plain.amount0());
        assertEq(hooked.amount1(), plain.amount1());
        assertEq(hook.totalSwaps(), 1);
    }

    function test_hookDoesNotChangeTheLpFee() public view {
        (,,, uint24 hookedFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        (,,, uint24 plainFee) = IPoolManager(address(manager)).getSlot0(plainKey.toId());
        assertEq(hookedFee, 3_000);
        assertEq(hookedFee, plainFee);
    }

    function test_hookHoldsNoTokensAndOwesNothing() public {
        doSwap(swapRouter, key, true, -1 ether);
        doSwap(swapRouter, key, false, 1 ether);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }

    function testFuzz_swapThroughThePoolMatchesThePlainPoolAndCounts(uint96 amount, bool zeroForOne, bool exactOut)
        public
    {
        amount = uint96(bound(amount, 1e6, 10_000 ether));
        int256 specified = exactOut ? int256(uint256(amount)) : -int256(uint256(amount));

        BalanceDelta hooked = doSwap(swapRouter, key, zeroForOne, specified);
        BalanceDelta plain = doSwap(swapRouter, plainKey, zeroForOne, specified);

        assertEq(hooked.amount0(), plain.amount0(), "amount0 differs from the hook-less pool");
        assertEq(hooked.amount1(), plain.amount1(), "amount1 differs from the hook-less pool");
        assertEq(hook.totalSwaps(), 1);
        assertEq(hook.swapsBySender(address(swapRouter)), 1);
    }

    function testFuzz_counterGrowsByOnePerSwap(uint8 n) public {
        n = uint8(bound(n, 1, 20));
        for (uint256 i = 0; i < n; i++) {
            uint256 before = hook.totalSwaps();
            doSwap(swapRouter, key, i % 2 == 0, -0.01 ether);
            assertEq(hook.totalSwaps(), before + 1);
        }
        assertEq(hook.swapsBySender(address(swapRouter)), n);
    }

    // ------------------------------------------------------------------ initialization

    function test_aSecondPoolWithTheHookInitializes() public {
        PoolKey memory other = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        manager.initialize(other, SQRT_PRICE_1_1);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(other.toId());
        assertEq(price, SQRT_PRICE_1_1);
        assertEq(hook.totalSwaps(), 0, "initialization is not a swap");
    }

    function test_swapsOnTwoPoolsShareTheCounters() public {
        PoolKey memory other = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        manager.initialize(other, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(other, ModifyLiquidityParams(-600, 600, LIQUIDITY, bytes32(0)), "");

        doSwap(swapRouter, key, true, -1 ether);
        doSwap(swapRouter, other, true, -1 ether);
        assertEq(hook.totalSwaps(), 2);
        assertEq(hook.swapsBySender(address(swapRouter)), 2);
    }
}
