// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IMD6900PerpsLaunch} from "../src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpHook} from "../src/IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "../src/IMD6900PerpPool.sol";
import {Coin, Trader} from "./IMD6900Perps.t.sol";

/// A Pons curve whose price can move (the reference the band follows)
contract MovableCurve {
    uint256 public q; uint256 public t; address public token;
    constructor(address token_, uint256 q_, uint256 t_) { token = token_; q = q_; t = t_; }
    function set(uint256 q_, uint256 t_) external { q = q_; t = t_; }
    function getReserves() external view returns (uint256, uint256) { return (q, t); }
    function graduated() external pure returns (bool) { return false; }
    function pairToken() external pure returns (address) { return address(0); }
    function factory() external pure returns (address) { return address(0); }
}
/// A Pons market that can't be read at all
contract BrokenCurve {
    fallback() external { revert("broken"); }
}
/// A perps engine that can't answer anything
contract DeadEngine {
    fallback() external { revert("down"); }
}

/// The IMD swarm audit's findings on this launch (job ea1c84c3: math, permissions, economics, flow, imported code), each
/// fixed and held here
contract AuditFixesTest is Test {
    IPoolManager PM;
    address constant OWNER = address(0xA11CE);
    IMD6900PerpsLaunch l; IMD6900PerpHook hook; IMD6900PerpPool pool; Coin coin; MovableCurve curve; Trader trader;
    PoolKey key;

    function setUp() public {
        PM = IPoolManager(address(new PoolManager(address(this))));
        l = new IMD6900PerpsLaunch(PM, 10_000, OWNER, OWNER);
        hook = l.hook(); pool = l.pool();
        coin = new Coin();
        curve = new MovableCurve(address(coin), 1 ether, 1e27); // 1e9 coin per ETH
        coin.mint(OWNER, 2e27);
        vm.deal(OWNER, 10 ether);
        vm.startPrank(OWNER);
        coin.approve(address(pool), type(uint256).max);
        pool.open{value: 2 ether}(address(coin), address(curve), uint160(_sqrt(1e9)) << 96, 2e27);
        vm.stopPrank();
        key = pool.poolKey();
        trader = new Trader(PM);
        vm.deal(address(trader), 100 ether);
        coin.mint(address(trader), 1e28);
    }

    /// economics + flow: compound() paired the pool's idle funds at whatever price the caller had just pushed
    function test_Fix_CompoundOnlyAtThePonsPrice() public {
        vm.deal(address(pool), 0.5 ether);
        coin.mint(address(pool), 5e26);
        curve.set(1 ether, 0.9e27); // Pons moves 10% away from the pool
        vm.expectRevert(abi.encodeWithSelector(IMD6900PerpPool.OffPons.selector, hook.deviationBps()));
        pool.compound(0, 0);
        curve.set(1 ether, 1e27); // back at the pool's price
        uint128 liq0 = pool.liquidity();
        pool.compound(0, 0);
        assertGt(pool.liquidity(), liq0);
    }

    /// permissions + tests: with little gas a down engine was read as "no positions" and the trade went through
    function test_Fix_LowGasSweepFailsClosed() public {
        address dead = address(new DeadEngine());
        vm.prank(OWNER);
        hook.setPerpEngine(dead);
        vm.expectRevert(); // SweepUnavailable, at normal gas
        trader.swap(key, true, -0.01 ether);
        vm.expectRevert(); // and now at low gas too
        trader.swap{gas: 600_000}(key, true, -0.01 ether);
        vm.prank(OWNER);
        hook.setSweepFailOpen(true); // the owner's escape hatch still opens it
        trader.swap{gas: 600_000}(key, true, -0.01 ether);
    }

    /// imported code + economics: a "correction" could swing the pool through the Pons price and far out the other side
    function test_Fix_NoCrossingThroughPons() public {
        curve.set(2 ether, 1e27); // Pons at 0.5e9 coin per ETH: the pool (1e9) is 100% above it
        assertGt(hook.deviationBps(), 9_000);
        vm.expectRevert(); // a buy big enough to end far below Pons: TooFarFromPons
        trader.swap(key, true, -4 ether);
        trader.swap(key, true, -0.5 ether); // a correction that stays on its side is fine
        assertLt(hook.deviationBps(), 10_000);
    }

    /// imported code: a Pons market that couldn't be read halted all trading
    function test_Fix_UnreadablePonsLeavesTradingOpen() public {
        address broken = address(new BrokenCurve());
        vm.prank(OWNER);
        pool.setCurve(broken);
        assertEq(hook.ponsPriceX96(), 0);
        assertEq(hook.deviationBps(), 0);
        trader.swap(key, true, -0.01 ether); // the band is off, the pool trades
        vm.prank(OWNER);
        pool.setCurve(address(curve)); // and the owner can point it right again
        assertLt(hook.deviationBps(), 200);
    }

    /// permissions + economics: a zero fee address, a zero curve, a sink with no code, renounced ownership
    function test_Fix_AdminGuards() public {
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900PerpHook.ZeroAddress.selector);
        hook.updateFeeAddress(address(0));
        vm.expectRevert(IMD6900PerpHook.NoRenounce.selector);
        hook.renounceOwnership();
        vm.expectRevert(IMD6900PerpPool.NoRenounce.selector);
        pool.renounceOwnership();
        vm.expectRevert(IMD6900PerpPool.NotAContract.selector);
        pool.setFeeSink(address(0xBEEF));
        vm.expectRevert(IMD6900PerpPool.ZeroAddress.selector);
        pool.setCurve(address(0));
        vm.stopPrank();
        IMD6900PerpsLaunch l2 = new IMD6900PerpsLaunch(PM, 10_000, OWNER, OWNER);
        IMD6900PerpPool p2 = l2.pool();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PerpPool.ZeroAddress.selector);
        p2.open{value: 1 ether}(address(coin), address(0), uint160(1 << 96), 1e18);
    }

    /// imported code: an addition reported principal less the position's earned fees, refunding those fees to the caller
    function test_Fix_AnAdditionLeavesTheEarnedFeesInThePool() public {
        for (uint256 i; i < 6; ++i) { // trades both ways: the position earns its 1%
            trader.swap(key, true, -0.1 ether);
            trader.swap(key, false, -9e25);
        }
        address lp = address(0xD0E);
        vm.deal(lp, 1 ether);
        coin.mint(lp, 1e27);
        vm.startPrank(lp);
        coin.approve(address(pool), type(uint256).max);
        uint256 before = address(pool).balance;
        pool.addLiquidity{value: 1 ether}(1e27, lp);
        vm.stopPrank();
        assertGt(address(pool).balance, before, "the fees the position earned stayed in the pool, not with the caller");
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        uint256 r = x; uint256 y = (x + 1) / 2;
        while (y < r) { r = y; y = (x / y + y) / 2; }
        z = r;
    }

    receive() external payable {}
}
