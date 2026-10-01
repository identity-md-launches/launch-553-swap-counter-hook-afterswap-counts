// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {SwapCounterHook} from "src/SwapCounterHook.sol";
import {HookAddressMiner} from "src/HookAddressMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Exercises failure AFTER the hook callback, either in the router or at the unlock boundary.
contract UnsettledCounterSwap is IUnlockCallback {
    IPoolManager immutable manager;
    SwapCounterHook immutable hook;

    error RouterAborted();

    constructor(IPoolManager manager_, SwapCounterHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function execute(PoolKey memory key, SwapParams memory params, bool abortInRouter) external {
        manager.unlock(abi.encode(key, params, abortInRouter));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, SwapParams memory params, bool abortInRouter) =
            abi.decode(data, (PoolKey, SwapParams, bool));
        uint256 totalBefore = hook.totalSwaps();
        uint256 senderBefore = hook.swapCount(address(this));
        BalanceDelta delta = manager.swap(key, params, "");
        require(BalanceDelta.unwrap(delta) != 0, "test needs an unsettled swap");
        require(hook.totalSwaps() == totalBefore + 1, "callback did not update total");
        require(hook.swapCount(address(this)) == senderBefore + 1, "callback did not update sender");
        if (abortInRouter) revert RouterAborted();
        // Deliberately leave currency deltas unpaid: PoolManager must roll the whole unlock back.
        return "";
    }
}

/// @dev Independent callback and transaction-boundary tests, supplementing the original suite.
/// forge-config: default.fuzz.runs = 1000
contract SwapCounterHookAdversarialTest is Test {
    using stdStorage for StdStorage;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant PRICE = 1 << 96;
    bytes32 constant COUNTED_TOPIC = keccak256("SwapCounted(bytes32,address,uint256,uint256,bool,int256,int256)");
    PoolManager manager;
    SwapCounterHook hook;
    PoolSwapTest router;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolKey control;

    function setUp() public {
        manager = new PoolManager(address(this));
        bytes memory code = abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(manager));
        (, bytes32 salt) =
            HookAddressMiner.find(address(this), Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG, code);
        hook = new SwapCounterHook{salt: salt}(manager);
        router = new PoolSwapTest(manager);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        MockERC20 a = new MockERC20("A", "A", 1e30);
        MockERC20 b = new MockERC20("B", "B", 1e30);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, hook);
        control = key;
        control.hooks = IHooks(address(0));
        manager.initialize(key, PRICE);
        manager.initialize(control, PRICE);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1_000_000 ether, 0), "");
        lp.modifyLiquidity(control, ModifyLiquidityParams(-600, 600, 1_000_000 ether, 0), "");
    }

    function test_initialViewsIncludeUnseenAndZeroSenders() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.totalSwaps(), 0);
        _assertSender(address(0), 0);
        _assertSender(address(type(uint160).max), 0);
        _assertSender(address(router), 0);
    }

    // PoolManager is trusted to supply valid pool/swap parameters. At this boundary the hook is
    // only an observer: even extreme ABI-valid inputs must be copied, not decoded from hookData.
    function testFuzz_eventIsExactlyOnceAndCopiesInputs(
        address sender,
        PoolKey memory suppliedKey,
        SwapParams memory params,
        int128 amount0,
        int128 amount1,
        bytes memory hookData
    ) public {
        BalanceDelta delta = toBalanceDelta(amount0, amount1);
        _directAndCheck(sender, suppliedKey, params, delta, "", 1);
        _directAndCheck(sender, suppliedKey, params, delta, hookData, 2);
        assertEq(hook.totalSwaps(), 2);
        _assertSender(sender, 2);
    }

    function test_callbackCopiesZeroAndSignedExtremes() public {
        _directAndCheck(address(0), key, _params(true, 0), toBalanceDelta(0, 0), "", 1);
        _directAndCheck(
            address(0),
            key,
            _params(false, type(int256).min),
            toBalanceDelta(type(int128).min, type(int128).max),
            hex"ff",
            2
        );
        _directAndCheck(
            address(0),
            key,
            _params(true, type(int256).max),
            toBalanceDelta(type(int128).max, type(int128).min),
            abi.encode(address(router)),
            3
        );
        _assertSender(address(0), 3);
        _assertSender(address(router), 0);
    }

    function test_interleavedSendersAndPoolsEmitDistinctSenderAndTotalCounts() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        uint256[5] memory expectedSenderCounts = [uint256(1), 1, 2, 2, 3];
        for (uint256 i; i < expectedSenderCounts.length; ++i) {
            address sender = i % 2 == 0 ? alice : bob;
            PoolKey memory suppliedKey = key;
            suppliedKey.fee = i < 2 ? 500 : 3000;
            SwapParams memory params = _params(i % 2 == 0, -int256(i + 1));
            BalanceDelta delta = toBalanceDelta(-int128(int256(i + 1)), 0);
            vm.recordLogs();
            vm.prank(address(manager));
            (bytes4 selector, int128 returnedDelta) = hook.afterSwap(sender, suppliedKey, params, delta, "");
            assertEq(selector, IHooks.afterSwap.selector);
            assertEq(returnedDelta, 0);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1);
            _assertEvent(logs[0], sender, suppliedKey, params, delta, expectedSenderCounts[i], i + 1);
            _assertSender(sender, expectedSenderCounts[i]);
            assertEq(hook.totalSwaps(), i + 1);
        }
        _assertSender(alice, 3);
        _assertSender(bob, 2);
        _assertSender(address(manager), 0);
    }

    function test_repeatedInitializationCallbackPreservesExistingCountsAndEmitsNothing() public {
        _directAndCheck(address(router), key, _params(true, -1), toBalanceDelta(-1, 0), "", 1);
        vm.recordLogs();
        vm.startPrank(address(manager));
        assertEq(hook.afterInitialize(address(router), key, PRICE, 0), IHooks.afterInitialize.selector);
        assertEq(hook.afterInitialize(address(0), key, PRICE, 0), IHooks.afterInitialize.selector);
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.totalSwaps(), 1);
        _assertSender(address(router), 1);
    }

    function testFuzz_spoofedSenderAndOriginCannotAuthorizeCallbacks(address attacker) public {
        if (attacker == address(manager)) attacker = address(0);
        _directAndCheck(address(router), key, _params(true, -1), toBalanceDelta(-1, 0), "", 1);
        vm.recordLogs();
        vm.startPrank(attacker, address(manager));
        vm.expectRevert(SwapCounterHook.NotPoolManager.selector);
        hook.afterSwap(address(manager), key, _params(true, -1), toBalanceDelta(-1, 0), abi.encode(address(manager)));
        vm.expectRevert(SwapCounterHook.NotPoolManager.selector);
        hook.afterInitialize(address(manager), key, PRICE, 0);
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.totalSwaps(), 1);
        _assertSender(address(router), 1);
        _assertSender(address(manager), 0);
    }

    // Storage injection makes the uint256 arithmetic boundary reachable. This is a defensive
    // atomicity check, not a claim that an organic sequence can exhaust a uint256 swap counter.
    function test_senderOverflowDoesNotWrapOrChangeTotal() public {
        address sender = address(router);
        stdstore.target(address(hook))
            .sig("swapsBySender(address)")
            .with_key(sender)
            .checked_write(type(uint256).max - 1);
        stdstore.target(address(hook)).sig("totalSwaps()").checked_write(type(uint256).max - 1);
        _directAndCheck(sender, key, _params(true, -1), toBalanceDelta(-1, 0), "", type(uint256).max);
        vm.prank(address(manager));
        vm.expectRevert(stdError.arithmeticError);
        hook.afterSwap(sender, key, _params(true, -1), toBalanceDelta(-1, 0), "");
        _assertSender(sender, type(uint256).max);
        assertEq(hook.totalSwaps(), type(uint256).max);
    }

    function test_totalOverflowRollsBackTheEarlierSenderIncrement() public {
        address sender = address(router);
        stdstore.target(address(hook)).sig("swapsBySender(address)").with_key(sender).checked_write(7);
        stdstore.target(address(hook))
            .sig("swapsBySender(address)")
            .with_key(address(0xBEEF))
            .checked_write(type(uint256).max - 7);
        stdstore.target(address(hook)).sig("totalSwaps()").checked_write(type(uint256).max);
        vm.prank(address(manager));
        vm.expectRevert(stdError.arithmeticError);
        hook.afterSwap(sender, key, _params(true, -1), toBalanceDelta(-1, 0), "");
        _assertSender(sender, 7);
        _assertSender(address(0xBEEF), type(uint256).max - 7);
        assertEq(hook.totalSwaps(), type(uint256).max);
    }

    function test_oneWeiSwapsBothDirectionsAndModesMatchControl() public {
        for (uint256 i; i < 4; ++i) {
            SwapParams memory params = _params(i % 2 == 0, i < 2 ? int256(-1) : int256(1));
            BalanceDelta actual = _swapAndCheckEvent(params, i + 1);
            BalanceDelta expected = router.swap(control, params, PoolSwapTest.TestSettings(false, false), "");
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected));
        }
        _assertSender(address(router), 4);
        assertEq(hook.totalSwaps(), 4);
    }

    function test_partialFillsEmitRequestedAmountAndActualDelta() public {
        // Restore the identical starting state for each direction and exact-input/output mode.
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i % 2 == 0;
            SwapParams memory params = _params(zeroForOne, i < 2 ? -int256(1000 ether) : int256(1000 ether));
            params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1));
            BalanceDelta actual = _swapAndCheckEvent(params, 1);
            BalanceDelta expected = router.swap(control, params, PoolSwapTest.TestSettings(false, false), "");
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected));
            int128 specifiedDelta = (zeroForOne == (params.amountSpecified < 0)) ? actual.amount0() : actual.amount1();
            uint256 filled = uint256(specifiedDelta < 0 ? -int256(specifiedDelta) : int256(specifiedDelta));
            assertGt(filled, 0);
            assertLt(filled, 1000 ether, "test must exercise a partial fill");
            (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            assertEq(price, params.sqrtPriceLimitX96);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_zeroAmountRejectionPreservesPriorCounts() public {
        _swapAndCheckEvent(_params(true, -1 ether), 1);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(key, _params(false, 0), PoolSwapTest.TestSettings(false, false), "");
        assertEq(_stateHash(), beforeState);
    }

    function test_invalidPriceLimitPreservesPriorCounts() public {
        _swapAndCheckEvent(_params(true, -1 ether), 1);
        bytes32 beforeState = _stateHash();
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        SwapParams memory params = _params(true, -1 ether);
        params.sqrtPriceLimitX96 = price;
        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, price));
        router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        assertEq(_stateHash(), beforeState);
    }

    function test_unsettledSwapRollsBackCountsAndPoolState() public {
        _assertFailedUnlock(false);
    }

    function test_routerRevertRollsBackCountsAndPoolState() public {
        _assertFailedUnlock(true);
    }

    function _assertFailedUnlock(bool abortInRouter) internal {
        _swapAndCheckEvent(_params(true, -1 ether), 1);
        UnsettledCounterSwap failing = new UnsettledCounterSwap(manager, hook);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(
            abortInRouter ? UnsettledCounterSwap.RouterAborted.selector : IPoolManager.CurrencyNotSettled.selector
        );
        failing.execute(key, _params(false, -2 ether), abortInRouter);
        assertEq(_stateHash(), beforeState, "failed transaction changed persisted state");
        _assertSender(address(failing), 0);
        _swapAndCheckEvent(_params(false, -2 ether), 2);
        assertEq(hook.totalSwaps(), 2, "failed attempt was counted");
    }

    function _directAndCheck(
        address sender,
        PoolKey memory suppliedKey,
        SwapParams memory params,
        BalanceDelta delta,
        bytes memory data,
        uint256 count
    ) internal {
        vm.recordLogs();
        vm.prank(address(manager));
        (bytes4 selector, int128 returnedDelta) = hook.afterSwap(sender, suppliedKey, params, delta, data);
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(returnedDelta, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event per callback");
        _assertEvent(logs[0], sender, suppliedKey, params, delta, count, count);
    }

    function _swapAndCheckEvent(SwapParams memory params, uint256 count) internal returns (BalanceDelta delta) {
        vm.recordLogs();
        delta = router.swap(key, params, PoolSwapTest.TestSettings(false, false), hex"deadbeef");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 emitted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook)) {
                ++emitted;
                _assertEvent(logs[i], address(router), key, params, delta, count, count);
            }
        }
        assertEq(emitted, 1, "exactly one hook event per real swap");
    }

    function _assertEvent(
        Vm.Log memory entry,
        address sender,
        PoolKey memory suppliedKey,
        SwapParams memory params,
        BalanceDelta delta,
        uint256 senderCount,
        uint256 totalCount
    ) internal view {
        assertEq(entry.emitter, address(hook));
        assertEq(entry.topics.length, 3);
        assertEq(entry.topics[0], COUNTED_TOPIC);
        assertEq(entry.topics[1], keccak256(abi.encode(suppliedKey)));
        assertEq(entry.topics[2], bytes32(uint256(uint160(sender))));
        assertEq(entry.data, abi.encode(senderCount, totalCount, params.zeroForOne, params.amountSpecified, delta));
    }

    function _assertSender(address sender, uint256 count) internal view {
        assertEq(hook.swapsBySender(sender), count);
        assertEq(hook.swapCount(sender), count);
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _stateHash() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(address(manager)).getSlot0(key.toId());
        (uint256 fee0, uint256 fee1) = IPoolManager(address(manager)).getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                fee0,
                fee1,
                hook.totalSwaps(),
                hook.swapCount(address(router)),
                token0.balanceOf(address(manager)),
                token1.balanceOf(address(manager)),
                token0.balanceOf(address(this)),
                token1.balanceOf(address(this))
            )
        );
    }
}
