// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface IPerpBookView {
    function openIds() external view returns (uint256[] memory);
    function isLiquidatable(uint256 id) external view returns (bool);
}

interface IFeeSink {
    function addFees() external payable;
}

/// @title IMD6900PerpPool - IMD6900's perps pool on Robinhood Chain: ETH / coin, one full-range position, owned here
/// @notice The perps engine trades against this pool (IMD6900PerpHook), and its capacity follows the pool's depth. The
///         owner opens it once the coin trades on Pons, at the price and with the ETH and coin it chooses, and anyone
///         deepens it with {addLiquidity}: added liquidity belongs to this contract, and only the owner can take any
///         out, never while that would leave an open position liquidatable. The pool's own static fee ({poolFee}, the
///         hook's too) accrues to this position, so the protocol earns it by the pool's own accounting; {compound}
///         turns what collects here back into depth.
contract IMD6900PerpPool is Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    /// @notice The pool's static fee, in hundredths of a bip (the hook holds the pool to the same)
    uint24 public immutable poolFee;
    /// @notice Where stray ETH the hook forwards goes (the coin's fee splitter, say). Settable by the owner.
    address public feeSink;

    address public hook;
    /// @notice The Pons coin (set when the pool opens)
    address public token;
    /// @notice Its Pons bonding curve: the price this pool's hook keeps the pool near (IMD6900PerpHook)
    address public curve;
    /// @notice The perps engine, checked before liquidity leaves
    address public perpEngine;

    event HookSet(address hook);
    event FeeSinkSet(address feeSink);
    event PerpEngineSet(address engine);
    event Opened(uint160 sqrtPriceX96, uint256 eth, uint256 tokens, uint128 liquidity);
    event LiquidityAdded(address indexed from, uint128 liquidity, uint256 eth, uint256 tokens);
    event Compounded(uint128 liquidity, uint256 eth, uint256 tokens);
    event LiquidityRemoved(uint128 liquidity, uint256 eth, uint256 tokens, address ethTo, address tokensTo);
    event FeesForwarded(uint256 amount);

    error OnlyPoolManager();
    error HookAlreadySet();
    error NoHook();
    error AlreadyOpen();
    error NotOpen();
    error ZeroLiquidity();
    error WouldLiquidate(uint256 id);

    constructor(IPoolManager poolManager_, uint24 poolFee_, address owner_) {
        poolManager = poolManager_;
        poolFee = poolFee_;
        _initializeOwner(owner_);
    }

    function setFeeSink(address feeSink_) external onlyOwner {
        feeSink = feeSink_;
        emit FeeSinkSet(feeSink_);
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), poolFee, TICK_SPACING, IHooks(hook));
    }

    /// @notice The pool's liquidity, all of it this contract's (the hook lets no one else add)
    function liquidity() public view returns (uint128) {
        return poolManager.getLiquidity(poolKey().toId());
    }

    /*                              OWNER                                   */

    function setHook(address hook_) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
        emit HookSet(hook_);
    }

    function setPerpEngine(address engine) external onlyOwner {
        perpEngine = engine;
        emit PerpEngineSet(engine);
    }

    /// @notice Takes `liq` of the liquidity out: its ETH to `ethTo`, its coin to `tokensTo`. Reverts if any open
    ///         position would then be liquidatable (close or liquidate it first, or remove less).
    function removeLiquidity(uint128 liq, address ethTo, address tokensTo) external onlyOwner nonReentrant {
        if (liq == 0) revert ZeroLiquidity();
        (uint256 eth, uint256 tokens) = _modify(-int256(uint256(liq)));
        address engine = perpEngine;
        if (engine != address(0)) {
            uint256[] memory ids = IPerpBookView(engine).openIds();
            for (uint256 i; i < ids.length; ++i) {
                if (IPerpBookView(engine).isLiquidatable(ids[i])) revert WouldLiquidate(ids[i]);
            }
        }
        SafeTransferLib.forceSafeTransferETH(ethTo, eth);
        SafeTransferLib.safeTransfer(token, tokensTo, tokens);
        emit LiquidityRemoved(liq, eth, tokens, ethTo, tokensTo);
    }

    /// @notice Opens the pool at `sqrtPriceX96` with the ETH sent and up to `tokenAmount` of the owner's coin
    ///         (approved); what the price doesn't take goes back to the owner. `curve_` is the coin's Pons curve, the
    ///         reference price its hook holds this pool to. Once.
    function open(address token_, address curve_, uint160 sqrtPriceX96, uint256 tokenAmount)
        external
        payable
        onlyOwner
        nonReentrant
    {
        if (hook == address(0)) revert NoHook();
        if (token != address(0)) revert AlreadyOpen();
        token = token_;
        curve = curve_;
        SafeTransferLib.safeTransferFrom(token_, msg.sender, address(this), tokenAmount);
        poolManager.initialize(poolKey(), sqrtPriceX96);
        uint128 liq = _fullRangeLiquidity(sqrtPriceX96, msg.value, tokenAmount);
        if (liq == 0) revert ZeroLiquidity();
        (uint256 ethIn, uint256 tokensIn) = _modify(int256(uint256(liq)));
        if (msg.value > ethIn) SafeTransferLib.forceSafeTransferETH(msg.sender, msg.value - ethIn);
        if (tokenAmount > tokensIn) SafeTransferLib.safeTransfer(token_, msg.sender, tokenAmount - tokensIn);
        emit Opened(sqrtPriceX96, ethIn, tokensIn, liq);
    }

    /*                               ANYONE                                 */

    /// @notice Deepens the pool with the ETH sent and up to `tokenAmount` of the caller's coin (approve first); what
    ///         the price doesn't take goes back to `refundTo`. The liquidity is this contract's, not the caller's.
    function addLiquidity(uint256 tokenAmount, address refundTo) external payable nonReentrant {
        if (token == address(0)) revert NotOpen();
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), tokenAmount);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey().toId());
        uint128 liq = _fullRangeLiquidity(sqrtPriceX96, msg.value, tokenAmount);
        if (liq == 0) revert ZeroLiquidity();
        (uint256 ethIn, uint256 tokensIn) = _modify(int256(uint256(liq)));
        if (msg.value > ethIn) SafeTransferLib.forceSafeTransferETH(refundTo, msg.value - ethIn);
        if (tokenAmount > tokensIn) SafeTransferLib.safeTransfer(token, refundTo, tokenAmount - tokensIn);
        emit LiquidityAdded(msg.sender, liq, ethIn, tokensIn);
    }

    /// @notice Pairs what this contract already holds — the ETH its fee share sends here and the coin the hook
    ///         skimmed from arbitrageurs — into more liquidity. Anyone can call it, and everything it adds belongs
    ///         to this contract like the rest.
    /// @dev Without this the two would sit here for good: {addLiquidity} pairs the CALLER's ETH and coin, not the
    ///      pool's own. This is what turns the fee share and the skim into depth.
    function compound(uint256 minEth, uint256 minTokens) external nonReentrant returns (uint128 liq) {
        if (token == address(0)) revert NotOpen();
        uint256 ethHave = address(this).balance;
        uint256 tokensHave = SafeTransferLib.balanceOf(token, address(this));
        if (ethHave < minEth || tokensHave < minTokens) revert ZeroLiquidity();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey().toId());
        liq = _fullRangeLiquidity(sqrtPriceX96, ethHave, tokensHave);
        if (liq == 0) revert ZeroLiquidity();
        (uint256 ethIn, uint256 tokensIn) = _modify(int256(uint256(liq)));
        emit Compounded(liq, ethIn, tokensIn); // what the price could not pair stays here for next time
    }

    /// @notice What {compound} has to work with right now
    function pending() external view returns (uint256 eth, uint256 tokens) {
        eth = address(this).balance;
        tokens = token == address(0) ? 0 : SafeTransferLib.balanceOf(token, address(this));
    }

    /// @notice The hook's flush of stray ETH lands here and goes on to the fee sink (kept here until one is set)
    function addFees() external payable {
        address sink = feeSink;
        if (sink == address(0)) return;
        IFeeSink(sink).addFees{value: msg.value}();
        emit FeesForwarded(msg.value);
    }

    /*                            POOL MANAGER                              */

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        int256 liquidityDelta = abi.decode(data, (int256));
        PoolKey memory key = poolKey();
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), liquidityDelta, 0
            ),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        // each currency on its own: adding owes it, removing frees it, and fees the position earned net against it
        if (a0 < 0) poolManager.settle{value: uint256(uint128(-a0))}();
        else if (a0 > 0) poolManager.take(key.currency0, address(this), uint256(uint128(a0)));
        if (a1 < 0) {
            poolManager.sync(key.currency1);
            SafeTransferLib.safeTransfer(token, address(poolManager), uint256(uint128(-a1)));
            poolManager.settle();
        } else if (a1 > 0) {
            poolManager.take(key.currency1, address(this), uint256(uint128(a1)));
        }
        return abi.encode(_abs(a0), _abs(a1));
    }

    /// @notice ETH from removals
    receive() external payable {}

    /*                              INTERNAL                                */

    function _modify(int256 liquidityDelta) internal returns (uint256 eth, uint256 tokens) {
        (eth, tokens) = abi.decode(poolManager.unlock(abi.encode(liquidityDelta)), (uint256, uint256));
    }

    /// @dev The most full-range liquidity `eth` and `tokens` can back at `sqrtPriceX96`, rounded down
    function _fullRangeLiquidity(uint160 sqrtPriceX96, uint256 eth, uint256 tokens) internal pure returns (uint128) {
        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(TICK_SPACING));
        uint160 upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(TICK_SPACING));
        uint256 fromEth = FullMath.mulDiv(eth, FullMath.mulDiv(sqrtPriceX96, upper, 1 << 96), upper - sqrtPriceX96);
        uint256 fromTokens = FullMath.mulDiv(tokens, 1 << 96, sqrtPriceX96 - lower);
        uint256 l = fromEth < fromTokens ? fromEth : fromTokens;
        if (l == 0) return 0;
        l -= 1; // rounding: never ask for more than was given
        return l > type(uint128).max ? type(uint128).max : uint128(l);
    }

    function _abs(int128 v) internal pure returns (uint256) {
        return v < 0 ? uint256(uint128(-v)) : uint256(uint128(v));
    }
}
