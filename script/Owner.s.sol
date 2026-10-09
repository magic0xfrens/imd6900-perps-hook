// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMD6900PerpPool} from "../src/IMD6900PerpPool.sol";
import {IMD6900PerpHook} from "../src/IMD6900PerpHook.sol";

/// @dev The swarm's Pons launcher, launch #1026 (magic0xfrens/imd6900-pons-launch)
interface IPonsLaunch {
    function release(uint256 amount, address to) external;
    function releasable() external view returns (uint256);
    function setPayees(address[] calldata to, uint16[] calldata bps) external;
    function curve() external view returns (address);
    function pons() external view returns (address);
}

interface IPonsCurve {
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice The team wallet's steps once the coin is live on Pons and the IMD swarm has deployed the perps launch:
///   forge script script/Owner.s.sol --sig "open(address,uint256)" <pool> <wei> --rpc-url <robinhood> --account imdstr-deployer --sender 0x35dA… --broadcast
///   forge script script/Owner.s.sol --sig "wire(address)" <pool> --rpc-url <robinhood> --account imdstr-deployer --sender 0x35dA… --broadcast
///   forge script script/Owner.s.sol --sig "status(address)" <pool> --rpc-url <robinhood>
/// `<pool>` is IMD6900PerpsLaunch.pool() of the swarm's launch. test/RobinhoodFlow.fork.t.sol runs the same steps.
contract Owner is Script {
    IPonsLaunch constant L = IPonsLaunch(0xE0aBb21F15766BE162429f46F494617eB5EF6Ba0);
    address constant COIN = 0x69005D86d2c1bb1dFE70Df48e27D6aa02D044149;
    address constant OWNER = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    address constant POT_BRIDGE = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;

    /// @notice Opens the perps pool at the Pons curve's price with `eth` (the launch's refund) and the coin worth it
    ///         at that price, released from the launcher (the coin no IMDSTR holder can claim)
    function open(IMD6900PerpPool pool, uint256 eth) external {
        require(L.pons() == COIN, "the coin isn't launched yet");
        require(pool.owner() == OWNER && pool.token() == address(0), "not ours, or already open");
        (uint256 q, uint256 t) = IPonsCurve(L.curve()).getReserves();
        uint256 priceX96 = FullMath.mulDiv(t, 1 << 96, q); // coin per ETH, as the hook reads Pons
        uint160 sqrtP = uint160(_sqrt(priceX96 << 96));
        uint256 tokens = FullMath.mulDiv(eth, priceX96, 1 << 96);
        uint256 have = IERC20(COIN).balanceOf(OWNER);
        uint256 need = tokens > have ? tokens - have : 0;
        require(need <= L.releasable(), "not enough releasable coin");
        console2.log("Pons price, ETH per coin x1e18:", FullMath.mulDiv(q, 1e18, t));
        console2.log("opening with ETH (wei):", eth);
        console2.log("and coins:", tokens);
        vm.startBroadcast(OWNER);
        if (need != 0) L.release(need, OWNER);
        IERC20(COIN).approve(address(pool), tokens);
        pool.open{value: eth}(COIN, L.curve(), sqrtP, tokens);
        vm.stopBroadcast();
        console2.log("liquidity:", pool.liquidity());
        console2.log("deviation from Pons, bps:", IMD6900PerpHook(payable(pool.hook())).deviationBps());
    }

    /// @notice The coin's creator fees reach the pool: 70% pot bridge, 10% the perps pool, 20% the team; and the
    ///         hook's stray ETH goes on to the launcher's split
    function wire(IMD6900PerpPool pool) external {
        address[] memory to = new address[](3);
        uint16[] memory bps = new uint16[](3);
        (to[0], to[1], to[2]) = (POT_BRIDGE, address(pool), OWNER);
        (bps[0], bps[1], bps[2]) = (7000, 1000, 2000);
        vm.startBroadcast(OWNER);
        L.setPayees(to, bps);
        pool.setFeeSink(address(L));
        vm.stopBroadcast();
        console2.log("payees: pot bridge 70%, perps pool 10%, team 20%; fee sink: the launcher");
    }

    function status(IMD6900PerpPool pool) external view {
        IMD6900PerpHook hook = IMD6900PerpHook(payable(pool.hook()));
        console2.log("pool", address(pool), "hook", address(hook));
        console2.log("coin", pool.token(), "liquidity", pool.liquidity());
        console2.log("deviation from Pons, bps", hook.deviationBps());
        console2.log("perps engine (pool / hook)", pool.perpEngine(), hook.perpEngine());
        console2.log("launcher releasable", L.releasable());
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
}
