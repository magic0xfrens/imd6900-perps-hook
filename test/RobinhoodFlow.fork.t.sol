// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMD6900PerpsLaunch} from "../src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpHook} from "../src/IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "../src/IMD6900PerpPool.sol";
import {Trader} from "./IMD6900Perps.t.sol";

struct PonsSocials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

/// @dev PonsV2LaunchFactory.TokenParams (imd6900-pons-launch src/IPons.sol)
struct PonsTokenParams {
    string name;
    string symbol;
    string logo;
    string description;
    PonsSocials socials;
    address creatorFeeRecipient;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    bytes32 expectedEconomics;
    bytes32 salt;
}

/// @dev The swarm's Pons launcher, launch #1026 (magic0xfrens/imd6900-pons-launch)
interface IPonsLaunch {
    function meta() external view returns (PonsTokenParams memory);
    function setMeta(PonsTokenParams calldata m) external;
    function launchConfigId() external view returns (uint256);
    function setClaimSupplyCeiling(uint256 supply) external;
    function launch(bytes32 salt, address expectedToken, uint256 buyEth, uint256 minTokensOut)
        external
        payable
        returns (address, uint256);
    function release(uint256 amount, address to) external;
    function releasable() external view returns (uint256);
    function setPayees(address[] calldata to, uint16[] calldata bps) external;
    function harvest(bytes32 graduatedPoolId) external returns (uint256);
    function curve() external view returns (address);
    function pons() external view returns (address);
    function launchBought() external view returns (uint256);
    function launchEth() external view returns (uint256);
}

interface IPonsFactory {
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    function launchFee() external view returns (uint256);
}

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @dev An engine whose book says a position would be liquidated by any withdrawal
contract BlockingEngine {
    function openIds() external pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = 1;
    }

    function isLiquidatable(uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev An engine that is simply broken
contract BrokenEngine {
    fallback() external {
        revert("broken");
    }
}

/// @notice The Robinhood relaunch, end to end on today's live state: the swarm's Pons launcher (#1026) dev-buys with
///         2 ETH of what the old pool's pull sends it and refunds the rest to the team wallet; the IMD swarm's perps
///         launch (this repo) deploys; the team wallet releases the coin no IMDSTR holder can claim and opens the
///         perps pool at the Pons price with the refunded ETH. Then: trading through the hook, the fee split feeding
///         the pool, and the way back out: the owner can always take all of the pool's liquidity, so a new hook is
///         only ever a new pool away.
/// @dev Needs ROBINHOOD_RPC_URL. Nothing here touches the chain.
contract RobinhoodFlowForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPonsLaunch constant L = IPonsLaunch(0xE0aBb21F15766BE162429f46F494617eB5EF6Ba0);
    address constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant IMDSTR = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant COIN = 0x69005D86d2c1bb1dFE70Df48e27D6aa02D044149;
    bytes32 constant SALT = bytes32(uint256(0x11d2));
    address constant DEPLOYER = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    address constant POT_BRIDGE = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    /// @dev What the pull-all op sends the launcher (fork-measured on 2026-10-09: 2.8288 ETH)
    uint256 constant PULLED = 2.8288 ether;
    uint256 constant DEV_BUY = 2 ether;
    uint24 constant POOL_FEE = 10_000; // 1%

    IMD6900PerpPool pool;
    IMD6900PerpHook hook;
    uint256 refund;
    uint256 bought;
    Trader trader;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("robinhood"));
        vm.deal(address(L), PULLED);
        uint256 before = DEPLOYER.balance;
        vm.startPrank(DEPLOYER);
        PonsTokenParams memory m = L.meta();
        m.expectedEconomics = IPonsFactory(FACTORY).previewLaunchEconomics(L.launchConfigId(), address(0));
        L.setMeta(m);
        L.setClaimSupplyCeiling(IERC20(IMDSTR).totalSupply());
        (address coin, uint256 got) = L.launch(SALT, COIN, DEV_BUY, 0);
        vm.stopPrank();
        assertEq(coin, COIN, "the mined 0x6900 address");
        bought = got;
        refund = DEPLOYER.balance - before;
        // Pons taxes buys in the launch block ~99% (anti-sniper; the launcher's own buy is exempt): from the next
        // block on, 6.9% (1% Pons + the 5.9% creator tax). Everything below happens in later transactions.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        // the IMD swarm's launch: anyone's transaction, exactly the job's constructor arguments
        IMD6900PerpsLaunch launch = new IMD6900PerpsLaunch(PM, POOL_FEE, DEPLOYER, DEPLOYER);
        pool = launch.pool();
        hook = launch.hook();
        trader = new Trader(PM);
        vm.deal(address(trader), 10 ether);
    }

    /// @dev The Pons price as the hook reads it (coin per ETH, x2^96), and the pool's sqrt price for it
    function _ponsPrice() internal view returns (uint256 priceX96, uint160 sqrtPriceX96) {
        (uint256 q, uint256 t) = IPonsCurve(L.curve()).getReserves();
        priceX96 = FullMath.mulDiv(t, 1 << 96, q);
        sqrtPriceX96 = uint160(_sqrt(priceX96 << 96));
    }

    /// @dev The team wallet's opening: the coin worth `eth` at the Pons price, released from the launcher, and the ETH
    function _open(IMD6900PerpPool p, uint256 eth) internal returns (uint256 tokens) {
        (uint256 priceX96, uint160 sqrtP) = _ponsPrice();
        tokens = FullMath.mulDiv(eth, priceX96, 1 << 96);
        vm.startPrank(DEPLOYER);
        if (IERC20(COIN).balanceOf(DEPLOYER) < tokens) L.release(tokens - IERC20(COIN).balanceOf(DEPLOYER), DEPLOYER);
        IERC20(COIN).approve(address(p), tokens);
        p.open{value: eth}(COIN, L.curve(), sqrtP, tokens);
        vm.stopPrank();
    }

    function _key(IMD6900PerpPool p) internal view returns (PoolKey memory) {
        return p.poolKey();
    }

    function test_devBuysTwoEth_andRefundsTheRest() public {
        assertEq(L.launchEth(), DEV_BUY, "the dev buy");
        uint256 fee = IPonsFactory(FACTORY).launchFee();
        assertEq(refund, PULLED - DEV_BUY - fee, "the rest back to the team wallet");
        assertEq(IERC20(COIN).balanceOf(address(L)), bought);
        uint256 owed = IERC20(IMDSTR).totalSupply();
        assertEq(L.releasable(), bought - owed, "the coin beyond one per IMDSTR");
        emit log_named_decimal_uint("dev buy, coins", bought, 18);
        emit log_named_decimal_uint("refund to the team wallet, ETH", refund, 18);
        emit log_named_decimal_uint("releasable for the perps pool, coins", L.releasable(), 18);
    }

    function test_opensThePerpsPoolAtThePonsPrice() public {
        uint256 tokens = _open(pool, refund);
        assertGt(pool.liquidity(), 0);
        assertLt(hook.deviationBps(), 10, "opened within 0.1% of the Pons price");
        assertEq(pool.token(), COIN);
        assertEq(pool.owner(), DEPLOYER);
        assertEq(hook.owner(), DEPLOYER);
        emit log_named_decimal_uint("pool ETH", refund, 18);
        emit log_named_decimal_uint("pool coins", tokens, 18);
    }

    function test_tradesThroughTheHook_andTheBandHoldsItNearPons() public {
        _open(pool, refund);
        PoolKey memory key = _key(pool);
        // an ordinary buy and sell go through, paying the pool's 1%
        trader.swap{value: 0.02 ether}(key, true, -int256(0.02 ether));
        uint256 coins = IERC20(COIN).balanceOf(address(trader));
        assertGt(coins, 0, "bought the coin");
        trader.swap(key, false, -int256(coins / 2));
        // a buy that would drag the pool far from Pons is refused
        vm.expectRevert();
        trader.swap{value: 0.6 ether}(key, true, -int256(0.6 ether));
        // when Pons moves, a trade that pulls the pool back toward it is allowed even past the band
        vm.deal(address(this), 3 ether);
        IPonsCurve(L.curve()).buy{value: 1.5 ether}(1.5 ether, 0, address(this));
        uint256 dev = hook.deviationBps();
        assertGt(dev, hook.maxDeviationBps(), "Pons ran away from the pool");
        trader.swap{value: 0.1 ether}(key, true, -int256(0.1 ether));
        assertLt(hook.deviationBps(), dev, "the buy pulled the pool toward Pons");
    }

    /// @notice The LP always comes back to the owner: after trading, with an engine whose book would block it, and
    ///         with an engine that is broken outright. The pool's engine check is the owner's own switch.
    function test_theOwnerCanAlwaysTakeAllTheLiquidityBack() public {
        _open(pool, refund);
        PoolKey memory key = _key(pool);
        trader.swap{value: 0.05 ether}(key, true, -int256(0.05 ether));
        uint128 all = pool.liquidity();

        vm.startPrank(DEPLOYER);
        pool.setPerpEngine(address(new BlockingEngine()));
        vm.expectRevert(abi.encodeWithSelector(IMD6900PerpPool.WouldLiquidate.selector, 1));
        pool.removeLiquidity(all, DEPLOYER, DEPLOYER);
        pool.setPerpEngine(address(new BrokenEngine()));
        vm.expectRevert();
        pool.removeLiquidity(all, DEPLOYER, DEPLOYER);
        // the hook's engine can stop swaps (fail closed) but never withdrawals
        hook.setPerpEngine(address(new BrokenEngine()));
        pool.setPerpEngine(address(0));
        uint256 eth0 = DEPLOYER.balance;
        uint256 coin0 = IERC20(COIN).balanceOf(DEPLOYER);
        pool.removeLiquidity(all, DEPLOYER, DEPLOYER);
        vm.stopPrank();

        assertEq(pool.liquidity(), 0, "all of it");
        uint256 ethBack = DEPLOYER.balance - eth0;
        uint256 coinBack = IERC20(COIN).balanceOf(DEPLOYER) - coin0;
        assertGt(ethBack, refund, "the ETH, plus what the buy added");
        assertGt(coinBack, 0);
        emit log_named_decimal_uint("ETH back", ethBack, 18);
        emit log_named_decimal_uint("coins back", coinBack, 18);
    }

    /// @notice A new hook is a new pool: take the liquidity out of the first, open the second with it
    function test_upgradingTheHookIsANewPoolWithTheSameMoney() public {
        _open(pool, refund);
        uint128 all = pool.liquidity();
        vm.prank(DEPLOYER);
        pool.removeLiquidity(all, DEPLOYER, DEPLOYER);

        IMD6900PerpsLaunch next = new IMD6900PerpsLaunch(PM, POOL_FEE, DEPLOYER, DEPLOYER);
        IMD6900PerpPool pool2 = next.pool();
        assertTrue(address(next.hook()) != address(hook), "a different hook");
        _open(pool2, refund - 1e9); // the old pool's ETH, less its rounding
        assertGt(pool2.liquidity(), 0);
        assertLt(next.hook().deviationBps(), 10);
        // and it trades
        trader.swap{value: 0.01 ether}(_key(pool2), true, -int256(0.01 ether));
    }

    /// @notice The coin's fee split pays the perps pool its share, and compound turns it into depth
    function test_feeSplitFeedsThePool() public {
        _open(pool, refund);
        address[] memory to = new address[](3);
        uint16[] memory bps = new uint16[](3);
        (to[0], to[1], to[2]) = (POT_BRIDGE, address(pool), DEPLOYER);
        (bps[0], bps[1], bps[2]) = (7000, 1000, 2000);
        vm.startPrank(DEPLOYER);
        L.setPayees(to, bps);
        pool.setFeeSink(address(L));
        vm.stopPrank();

        vm.deal(address(this), 2 ether);
        IPonsCurve(L.curve()).buy{value: 1 ether}(1 ether, 0, address(this)); // Pons trading books creator fees
        uint256 p0 = address(pool).balance;
        uint256 harvested = L.harvest(bytes32(0));
        assertGt(harvested, 0, "creator fees harvested");
        uint256 share = address(pool).balance - p0;
        assertApproxEqAbs(share, harvested / 10, 2, "10% to the perps pool");
        emit log_named_decimal_uint("harvested", harvested, 18);
        // the pool's ETH share pairs with coin it holds into more depth
        vm.prank(DEPLOYER);
        L.release(1_000_000 ether, address(pool));
        uint128 liq0 = pool.liquidity();
        pool.compound(0, 0);
        assertGt(pool.liquidity(), liq0, "compounded into depth");
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }

    receive() external payable {}
}
