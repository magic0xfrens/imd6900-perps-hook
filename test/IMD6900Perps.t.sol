// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IMD6900PerpsLaunch} from "../src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpHook} from "../src/IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "../src/IMD6900PerpPool.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

contract Coin {
    string public constant name = "coin";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// The coin's market on Pons, as the hook reads it: a bonding curve's reserves
contract Curve {
    uint256 public q; uint256 public t; address public token;
    constructor(address token_, uint256 q_, uint256 t_) { token = token_; q = q_; t = t_; }
    function getReserves() external view returns (uint256, uint256) { return (q, t); }
    function graduated() external pure returns (bool) { return false; }
    function pairToken() external pure returns (address) { return address(0); }
    function factory() external pure returns (address) { return address(0); }
}

/// A plain trader: swaps through the PoolManager as any router would
contract Trader {
    IPoolManager immutable pm;
    PoolKey key;
    constructor(IPoolManager pm_) { pm = pm_; }
    function swap(PoolKey calldata k, bool buy, int256 amountSpecified) external payable returns (BalanceDelta d) {
        key = k;
        d = abi.decode(pm.unlock(abi.encode(buy, amountSpecified)), (BalanceDelta));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool buy, int256 amt) = abi.decode(data, (bool, int256));
        BalanceDelta d = pm.swap(key, SwapParams(buy, amt, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(d);
    }
    function _settle(Currency c, int128 v) internal {
        if (v < 0) {
            if (c.isAddressZero()) pm.settle{value: uint128(-v)}();
            else { pm.sync(c); Coin(Currency.unwrap(c)).transfer(address(pm), uint128(-v)); pm.settle(); }
        } else if (v > 0) pm.take(c, address(this), uint128(v));
    }
    receive() external payable {}
}

/// Someone who isn't the pool, trying to add liquidity next to it
contract Squatter {
    IPoolManager immutable pm; PoolKey key;
    constructor(IPoolManager pm_) { pm = pm_; }
    function add(PoolKey calldata k) external { key = k; pm.unlock(""); }
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        pm.modifyLiquidity(key, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e9, 0), "");
        return "";
    }
}

/// Against a real Uniswap v4 PoolManager (vendored for tests only), offline: the launch, then the pool opened by its
/// owner, traded both ways, held near the Pons price, and closed to anyone else's liquidity.
contract IMD6900PerpsTest is Test {
    IPoolManager PM;
    address constant OWNER = address(0xA11CE);
    uint24 constant FEE = 10_000;
    IMD6900PerpsLaunch l; IMD6900PerpHook hook; IMD6900PerpPool pool; Coin coin; Curve curve; Trader trader;

    function setUp() public {
        PM = IPoolManager(address(new PoolManager(address(this))));
        l = new IMD6900PerpsLaunch(PM, FEE, OWNER, OWNER);
        hook = l.hook(); pool = l.pool();
        coin = new Coin();
        curve = new Curve(address(coin), 1 ether, 1e27); // 1e9 coin per ETH
        coin.mint(OWNER, 2e27);
        vm.deal(OWNER, 10 ether);
        vm.startPrank(OWNER);
        coin.approve(address(pool), type(uint256).max);
        pool.open{value: 2 ether}(address(coin), address(curve), _sqrt(1e9) << 96, 2e27);
        vm.stopPrank();
        trader = new Trader(PM);
        vm.deal(address(trader), 10 ether);
        coin.mint(address(trader), 1e27);
    }

    function test_OpensAtThePrice() public view {
        assertGt(pool.liquidity(), 0);
        assertLt(hook.deviationBps(), 10, "the pool opens at the Pons price");
    }

    function test_TradesBothWays() public {
        PoolKey memory k = pool.poolKey();
        BalanceDelta d = trader.swap(k, true, -0.01 ether); // buy coin with 0.01 ETH
        assertGt(d.amount1(), 0);
        vm.prank(address(trader)); coin.approve(address(trader), type(uint256).max);
        d = trader.swap(k, false, -1e24); // sell a million coin
        assertGt(d.amount0(), 0);
    }

    function test_RefusesToDriftFarFromPons() public {
        PoolKey memory k = pool.poolKey();
        vm.expectRevert(); // TooFarFromPons, wrapped by the PoolManager
        trader.swap(k, true, -1 ether); // a 1 ETH buy into 2 ETH of depth moves it far past 30%
    }

    function test_OnlyThePoolAddsLiquidity() public {
        Squatter s = new Squatter(PM);
        PoolKey memory k = pool.poolKey();
        vm.expectRevert(); // OnlyLauncher, wrapped
        s.add(k);
    }

    function test_OnlyTheOwnerOpensAndRemoves() public {
        vm.expectRevert(); // already open, and not the owner either
        pool.open(address(coin), address(curve), uint160(1 << 96), 0);
        uint128 liq = pool.liquidity();
        vm.expectRevert();
        pool.removeLiquidity(liq / 2, address(this), address(this));
        vm.prank(OWNER);
        pool.removeLiquidity(liq / 2, OWNER, OWNER);
        assertApproxEqRel(pool.liquidity(), liq / 2, 1e15);
    }

    function test_AnyoneDeepensIt() public {
        uint128 before = pool.liquidity();
        coin.mint(address(this), 1e27);
        coin.approve(address(pool), type(uint256).max);
        pool.addLiquidity{value: 1 ether}(1e27, address(this));
        assertGt(pool.liquidity(), before);
    }

    function test_PerpsOffUntilAnEngineIsSet() public view {
        assertEq(hook.perpEngine(), address(0)); // spot only until the owner wires the engine
    }

    receive() external payable {}

    function _sqrt(uint256 x) internal pure returns (uint160 z) {
        uint256 r = x; uint256 y = (x + 1) / 2;
        while (y < r) { r = y; y = (x / y + y) / 2; }
        z = uint160(r);
    }
}
