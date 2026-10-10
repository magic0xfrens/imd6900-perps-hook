// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice IMD6900PerpPool: the pool's liquidity owner, which also names the coin and its Pons curve
interface IPerpPoolView {
    function token() external view returns (address);
    function curve() external view returns (address);
}

/// @notice The Pons bonding curve this pool prices against: its reserves are the reference price
interface IPonsCurveView {
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function graduated() external view returns (bool);
    function token() external view returns (address);
    function pairToken() external view returns (address);
    function factory() external view returns (address);
}

/// @notice Enough of the Pons factory to find where a graduated launch went on trading
interface IPonsFactoryView {
    function memeHook() external view returns (address);
    function getLaunchedToken(address token) external view returns (PonsLaunchedToken memory);
}

/// @dev PonsV2LaunchFactory.LaunchedToken, field for field
struct PonsLaunchedToken {
    address token;
    address curve;
    address deployer;
    address creatorFeeRecipient;
    address pairToken;
    uint256 graduationThreshold;
    uint24 poolFee;
    int24 tickSpacing;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    uint8 phase;
    uint256 sweptQuote;
    uint256 sweptTokens;
    uint256 sweptAt;
    bool exists;
}

/// @notice The perps engine (src/perps/PerpEngine.sol): liquidates every position a trade would sink, before it runs
interface IPerpSweep {
    function sweepLiquidations(address liquidator, int256 spec, bool isBuy, uint160 limit) external returns (uint8);
    function openCount() external view returns (uint256);
}

/// @notice Where stray ETH goes (IMD6900PerpPool, which passes it on to its fee sink)
interface IFeeSink {
    function addFees() external payable;
}

/// @title IMD6900PerpHook - in-pool perps for IMD6900 on Robinhood Chain, that Uniswap's router picks up on its own
/// @notice Built for the IMD swarm to deploy (IMD6900PerpsLaunch mines its address and creates it). The pool it guards
///         is ETH / IMD6900 (the coin launched on Pons), one full-range position owned by IMD6900PerpPool, and the
///         price it keeps near is the coin's own market on Pons: its bonding curve, then its graduated pool.
///
/// @notice Uniswap routes a hooked pool automatically unless the hook uses `beforeSwapReturnsDelta`,
///         `afterSwapReturnsDelta` or `dynamicFees` (or sits at a 0x91… address), in which case it has to be
///         submitted and reviewed. This hook uses none of them, so the pool it guards is quotable by the ordinary
///         router: price comes from plain concentrated liquidity and the fee is an immutable pool parameter.
///
///         What it keeps is the only part that was ever load-bearing: before any swap that is not the engine's own,
///         the perps engine is asked to close every position that trade would sink, at the price before it moves.
///         A sweep that cannot finish reverts the trade. NO BAD DEBT outranks always-tradeable.
///
///         What it gives up, against PonsPerpHook: the hook no longer charges anything itself. The pool's static fee
///         accrues to the liquidity position, which this protocol owns in full, so the money arrives in the same
///         pocket by the pool's own accounting. The cost is that one rate applies to everyone — the engine and our
///         own arbitrage vault included — so there are no per-caller exemptions and no surcharge for trading against
///         a mispriced pool. `feeBps` and `perpFeeBps` remain only as what the engine reads to model its solvency,
///         and must be kept equal to the pool's real fee.
///
contract IMD6900PerpHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    /// @notice The trading fee can be lowered to this, never below, and never raised
    uint256 public constant MIN_FEE_BPS = 100;
    /// @notice The perps engine's rate never exceeds this (PerpEngine assumes the same cap)
    uint256 public constant MAX_PERP_FEE_BPS = 1_000;
    int24 public constant TICK_SPACING = 60;
    /// @dev Gas kept back for the rest of the swap when a sweep runs, and the least worth forwarding (MiFrens)
    uint256 internal constant SWEEP_GAS_RESERVE = 180_000;
    uint256 internal constant SWEEP_GAS_MIN = 400_000;

    /// @notice IMD6900PerpPool: initializes the pool, owns its liquidity
    address public immutable launcher;

    /// @notice Fee on every other trade, in basis points of its ETH leg
    uint256 public feeBps = 1_000;
    /// @notice Fee on the perps engine's own swaps
    uint256 public perpFeeBps = 100;
    /// @notice Receives 3% of the fees; renounceable into the launcher for good
    address public feeAddress;
    bool public feeAddressRenounced;
    /// @notice The perps engine; zero means spot only
    address public perpEngine;
    /// @notice Escape hatch: trade even when the pre-trade sweep can't run (meant only while the engine is replaced)
    bool public sweepFailOpen;
    /// @notice The one pool this hook serves
    PoolId public poolId;
    /// @notice Protocol-owned callers whose swaps the band does not judge (the engine model reads them as fee-free)
    mapping(address => bool) public feeExempt;

    /*                     FOLLOWING THE PONS PRICE                        */

    /// @notice How far this pool's price may end up from the Pons curve's. A swap that would leave it further out
    ///         than this is refused — unless it moves the price closer, which is always allowed.
    /// @dev Wide on purpose while the pool is thin: at 0.12 ETH of depth a 0.01 ETH trade already moves the price
    ///      ~15%, so a tight band would refuse ordinary trades rather than manipulation. Tighten it as the pool
    ///      deepens — that is what turns the band into real protection for the perps mark.
    uint256 public maxDeviationBps = 3_000;
    /// @dev Transient slot holding where the swap started against Pons (cancun tstore/tload): the deviation in the
    ///      low bits, bit 255 set when the pool stood above the Pons price; UNTRACKED for the engine's own swaps
    uint256 internal constant DEV_SLOT = 0x9e;
    uint256 internal constant ABOVE = 1 << 255;
    uint256 internal constant UNTRACKED = type(uint256).max;
    /// @dev What the band reads for a pool price it can't express (a sqrt price under 2^48): as far out as it gets
    uint256 internal constant OFF_SCALE = 1e12;
    uint256 internal constant Q96 = 2 ** 96;
    /// @notice The pool's own fee, in hundredths of a bip (1e6 = 100%). Fixed at construction because a dynamic
    ///         fee is one of the three things that would cost this hook its automatic routing.
    uint24 public immutable poolFeePips;

    event FeeTaken(address indexed sender, bool buy, uint256 fee);
    event FeesFlushed(uint256 toLauncher, uint256 toFeeAddress);
    event FeeLowered(uint256 feeBps);
    event PerpFeeSet(uint256 perpFeeBps);
    event PerpEngineSet(address engine);
    event SweepFailOpenSet(bool on);
    event FeeExemptSet(address indexed caller, bool exempt);
    event FeeAddressUpdated(address feeAddress);
    event FeeAddressRenounced(address by);
    event BandSet(uint256 maxDeviationBps);

    error NotOurPool();
    error OnlyLauncher();
    error FullRangeOnly();
    error ExactOutSellUnsupported();
    error InvalidFee();
    error FeeAddressIsRenounced();
    /// @notice The pre-trade liquidation sweep ran out of gas: send the trade with more gas
    error SweepGasStarved();
    /// @notice The trade would sink more positions than one transaction can liquidate: trade smaller
    error SweepTradeTooLarge();
    /// @notice The perps engine could not run its sweep at all
    error SweepUnavailable();
    /// @notice The trade would leave this pool further from the Pons price than {maxDeviationBps}
    error TooFarFromPons();
    error InvalidBand();
    error ZeroAddress();
    error NoRenounce();

    constructor(IPoolManager poolManager_, address launcher_, address feeAddress_, address owner_, uint24 poolFeePips_)
        BaseHook(poolManager_)
    {
        if (LPFeeLibrary.isDynamicFee(poolFeePips_) || poolFeePips_ > LPFeeLibrary.MAX_LP_FEE) revert InvalidFee();
        poolFeePips = poolFeePips_;
        launcher = launcher_;
        feeAddress = feeAddress_;
        _initializeOwner(owner_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*                    OWNER (the Robinhood timelock)                    */

    function lowerFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps >= feeBps || newFeeBps < MIN_FEE_BPS) revert InvalidFee();
        feeBps = newFeeBps;
        emit FeeLowered(newFeeBps);
    }

    function setPerpFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_PERP_FEE_BPS) revert InvalidFee();
        perpFeeBps = bps;
        emit PerpFeeSet(bps);
    }

    /// @dev Replaceable: an engine whose sweep can never run blocks trading (fail closed), so the owner keeps the way
    ///      out, behind the timelock like everything else. Zero turns perps off (the engine refuses new opens then).
    function setPerpEngine(address engine) external onlyOwner {
        perpEngine = engine;
        emit PerpEngineSet(engine);
    }

    function setSweepFailOpen(bool on) external onlyOwner {
        sweepFailOpen = on;
        emit SweepFailOpenSet(on);
    }

    /// @notice How far the price may drift from Pons
    function setBand(uint256 maxDeviationBps_) external onlyOwner {
        if (maxDeviationBps_ == 0) revert InvalidBand();
        maxDeviationBps = maxDeviationBps_;
        emit BandSet(maxDeviationBps_);
    }

    /// @notice Ownership never goes to nobody: the engine, the band and the escape hatches need an owner
    function renounceOwnership() public payable override onlyOwner {
        revert NoRenounce();
    }

    function setFeeExempt(address caller, bool exempt) external onlyOwner {
        feeExempt[caller] = exempt;
        emit FeeExemptSet(caller, exempt);
    }

    function updateFeeAddress(address feeAddress_) external onlyOwner {
        if (feeAddressRenounced) revert FeeAddressIsRenounced();
        if (feeAddress_ == address(0)) revert ZeroAddress();
        feeAddress = feeAddress_;
        emit FeeAddressUpdated(feeAddress_);
    }

    /// @notice Sends the fee address share to the launcher for good (the fee address itself or the owner)
    function renounceFeeAddress() external {
        if (msg.sender != feeAddress && msg.sender != owner()) revert Unauthorized();
        if (feeAddressRenounced) revert FeeAddressIsRenounced();
        feeAddressRenounced = true;
        feeAddress = launcher;
        emit FeeAddressRenounced(msg.sender);
    }

    /*                               PUBLIC                                 */

    /// @notice Sends the collected fees on: 97% to the launcher, 3% to the fee address. Anyone can call it.
    function flush() external {
        uint256 amount = address(this).balance;
        if (amount == 0) return;
        uint256 toFeeAddress = feeAddressRenounced ? 0 : (amount * 3) / 100;
        IFeeSink(launcher).addFees{value: amount - toFeeAddress}();
        if (toFeeAddress != 0) SafeTransferLib.safeTransferETH(feeAddress, toFeeAddress);
        emit FeesFlushed(amount - toFeeAddress, toFeeAddress);
    }

    /// @notice The Pons market's price, as coin per ETH scaled by 2^96, and 0 only when there is no reference at
    ///         all (before the pool is wired).
    /// @dev Two lives to follow. Before graduation the bonding curve is the market, and its reserves are the price.
    ///      At 4.2 ETH it graduates: the curve stops for good and trading moves to a Uniswap v4 pool of Pons' own,
    ///      so the reference moves with it. Without this second leg the band would quietly switch
    ///      itself off the moment the coin succeeded, which is exactly when the gap is worth the most.
    function ponsPriceX96() public view returns (uint256) {
        try this.ponsPriceUnchecked() returns (uint256 p) {
            return p;
        } catch {
            return 0; // a reference we cannot read leaves the pool trading (band off), never reverts a swap
        }
    }

    /// @notice {ponsPriceX96} without the guard: reverts if any read of the Pons market does (for that guard)
    function ponsPriceUnchecked() external view returns (uint256) {
        address c = IPerpPoolView(launcher).curve();
        if (c == address(0)) return 0;
        if (!IPonsCurveView(c).graduated()) {
            (uint256 q, uint256 t) = IPonsCurveView(c).getReserves();
            if (q == 0 || t == 0) return 0;
            return FullMath.mulDiv(t, Q96, q);
        }
        return _graduatedPriceX96(c);
    }

    /// @dev The price in Pons' graduated pool. Read through a try/catch: a reference we cannot read must leave the
    ///      pool trading (band simply off), never revert somebody's swap.
    function _graduatedPriceX96(address c) internal view returns (uint256) {
        try IPonsCurveView(c).factory() returns (address f) {
            PonsLaunchedToken memory l = IPonsFactoryView(f).getLaunchedToken(IPonsCurveView(c).token());
            if (!l.exists || l.phase != 2) return 0; // 2 = PoolCreated; before that there is no pool to read
            address coin = l.token;
            address pair = l.pairToken; // address(0) for a native launch, as ours is
            (address c0, address c1) = coin < pair ? (coin, pair) : (pair, coin);
            PoolKey memory key = PoolKey(
                Currency.wrap(c0), Currency.wrap(c1), l.poolFee, l.tickSpacing, IHooks(IPonsFactoryView(f).memeHook())
            );
            (uint160 sq,,,) = poolManager.getSlot0(key.toId());
            if (sq == 0) return 0;
            uint256 px = FullMath.mulDiv(sq, sq, Q96); // currency1 per currency0
            // this hook's prices are always coin per ETH; invert when the coin sorts first
            return c0 == coin ? FullMath.mulDiv(Q96, Q96, px) : px;
        } catch {
            return 0;
        }
    }

    /// @notice This pool's own price, on the same scale
    function poolPriceX96() public view returns (uint256) {
        (uint160 sq,,,) = poolManager.getSlot0(poolId);
        if (sq == 0) return 0;
        return FullMath.mulDiv(sq, sq, Q96);
    }

    /// @notice How far this pool sits from the Pons price, in basis points
    function deviationBps() public view returns (uint256) {
        return _deviation(poolPriceX96(), ponsPriceX96());
    }

    function _deviation(uint256 pool_, uint256 ref) internal pure returns (uint256) {
        if (ref == 0) return 0;
        if (pool_ == 0) return OFF_SCALE;
        uint256 d = pool_ > ref ? pool_ - ref : ref - pool_;
        return (d * BPS) / ref;
    }

    /// @notice Whether `sender`'s swaps are priced against Pons at all: the engine never is, so a liquidation can
    ///         always run (no bad debt outranks everything), and neither are protocol-owned callers.
    function tracksPons(address sender) public view returns (bool) {
        return sender != perpEngine && !feeExempt[sender];
    }

    /// @notice The fee a swap by `sender` pays, in basis points of its ETH leg
    function feeFor(address sender) public view returns (uint256) {
        if (feeExempt[sender]) return 0;
        if (sender == perpEngine && sender != address(0)) return perpFeeBps;
        return feeBps;
    }

    /*                              CALLBACKS                               */

    /// @dev Only the launcher, only once, only ETH / its coin with no LP fee, tick spacing 60 and this hook
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != launcher) revert OnlyLauncher();
        if (
            PoolId.unwrap(poolId) != bytes32(0) || !key.currency0.isAddressZero()
                || Currency.unwrap(key.currency1) != IPerpPoolView(launcher).token()
                || LPFeeLibrary.isDynamicFee(key.fee) || key.fee != poolFeePips || key.tickSpacing != TICK_SPACING
        ) revert NotOurPool();
        poolId = key.toId();
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _checkLiquidity(sender, params);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _checkLiquidity(sender, params);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert NotOurPool();

        // perps: close what this trade would sink, at the price before it moves (MiFrens LIQ04-A)
        _sweep(sender, params.amountSpecified, params.zeroForOne, params.sqrtPriceLimitX96);

        // remember how far from Pons we start, and on which side, so afterSwap can tell a correction from a push
        uint256 start = UNTRACKED;
        if (tracksPons(sender)) {
            uint256 pool_ = poolPriceX96();
            uint256 ref = ponsPriceX96();
            start = _deviation(pool_, ref) | (pool_ > ref ? ABOVE : 0);
        }
        assembly ("memory-safe") {
            tstore(DEV_SLOT, start)
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0); // the pool charges its own static fee
    }

    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // the band first, on the price this trader left (read before the sweep: an engine's nested swap rewrites the
        // slot, and its liquidations must neither hide a push nor be rolled back by the band)
        uint256 start;
        assembly ("memory-safe") {
            start := tload(DEV_SLOT)
        }
        _checkBand(start);
        // then a second, best-effort sweep for anything the final price leaves under water
        _sweep(sender, 0, false, 0);
        return (BaseHook.afterSwap.selector, int128(0)); // the pool charged its own fee; this hook takes nothing
    }

    /*                               INTERNAL                               */

    /// @dev The band: a swap may not leave this pool further from the Pons price than {maxDeviationBps}, unless it
    ///      moved it closer. The engine is never subject to it — a liquidation must run whatever the price is doing.
    ///      Closer means closer on the same side: a trade that crosses the Pons price to the far side must end inside
    ///      the band, so no "correction" can swing the pool through Pons and out the other way.
    function _checkBand(uint256 start) internal view {
        if (start == UNTRACKED) return;
        uint256 ref = ponsPriceX96();
        if (ref == 0) return;
        uint256 pool_ = poolPriceX96();
        uint256 devAfter = _deviation(pool_, ref);
        if (devAfter <= maxDeviationBps) return;
        uint256 devBefore = start & ~ABOVE;
        bool crossed = (start & ABOVE != 0) != (pool_ > ref);
        if (devAfter > devBefore || crossed) revert TooFarFromPons();
    }

    function _checkLiquidity(address sender, ModifyLiquidityParams calldata params) internal view {
        if (sender != launcher) revert OnlyLauncher();
        if (
            params.tickLower != TickMath.minUsableTick(TICK_SPACING)
                || params.tickUpper != TickMath.maxUsableTick(TICK_SPACING)
        ) revert FullRangeOnly();
    }

    /// @dev The liquidation sweep for both callbacks (MiFrens CauldronHook._liqSweep). `spec != 0` is the pre-trade
    ///      sweep and fails closed; the post-trade one (`spec == 0`) is best-effort. The engine's own swaps skip it:
    ///      they are the sweep. The EOA that sent the transaction is the liquidator and takes the keeper's cut.
    function _sweep(address sender, int256 spec, bool isBuy, uint160 limit) internal {
        address engine = perpEngine;
        if (engine == address(0) || sender == engine) return;
        uint256 reserve = spec != 0 ? SWEEP_GAS_RESERVE + SWEEP_GAS_MIN : SWEEP_GAS_RESERVE;
        uint256 g = gasleft();
        if (g > reserve + SWEEP_GAS_MIN) {
            (bool ok, bytes memory out) =
                engine.call{gas: g - reserve}(abi.encodeCall(IPerpSweep.sweepLiquidations, (tx.origin, spec, isBuy, limit)));
            if (spec == 0) return;
            if (!ok || out.length < 32) {
                if (!sweepFailOpen) revert SweepUnavailable();
                return;
            }
            uint256 status = abi.decode(out, (uint256));
            if (status == 2) revert SweepTradeTooLarge();
            if (status != 0) revert SweepGasStarved();
        } else if (spec != 0) {
            // too little gas to sweep: refuse the trade while positions are open, rather than trade blind (MiFrens R1C)
            // an engine that can't even say whether positions are open fails closed here too (unless fail-open is set)
            (bool ok, bytes memory ret) = engine.staticcall(abi.encodeCall(IPerpSweep.openCount, ()));
            if (!ok || ret.length < 32) {
                if (!sweepFailOpen) revert SweepUnavailable();
            } else if (abi.decode(ret, (uint256)) != 0) {
                revert SweepGasStarved();
            }
        }
    }

    /// @notice The pool pays its fee to the position itself; this is only for stray ETH
    receive() external payable {}
}
