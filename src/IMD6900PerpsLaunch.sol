// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IMD6900PerpHook} from "./IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "./IMD6900PerpPool.sol";

/// @title IMD6900PerpsLaunch - IMD6900's perps hook and pool, deployed in one constructor
/// @notice What the IMD swarm launches on Robinhood Chain (evm_contracts): constructor arguments only, nothing called
///         after. Uniswap v4 reads a hook's permissions from the low 14 bits of its address, so the hook must sit at
///         a mined address; IMD deploys this from its own deployer, which nobody can mine for in advance, so this
///         constructor mines it: it tries CREATE2 salts from itself until the hook's address carries exactly the
///         hook's flags, then creates the hook there. It creates the pool first (the hook names it), wires the pool
///         to the hook and hands the pool to `owner`; the hook is born owned by `owner`. It calls nothing that existed
///         before it, so it deploys the same way on a fresh chain.
contract IMD6900PerpsLaunch {
    /// @dev beforeInitialize, beforeAddLiquidity, beforeRemoveLiquidity, beforeSwap, afterSwap: nothing that would cost
    ///      the pool Uniswap's automatic routing (no return deltas, no dynamic fee)
    uint160 public constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    /// @dev One salt in 16,384 fits on average; a million tries leave a miss at about e^-64
    uint256 internal constant MAX_TRIES = 1 << 20;

    IMD6900PerpPool public immutable pool;
    IMD6900PerpHook public immutable hook;
    bytes32 public immutable salt;

    error NoSalt();
    error BadHook();

    /// @param poolManager Uniswap v4's PoolManager on Robinhood Chain
    /// @param poolFee     the pool's static fee, hundredths of a bip (10000 = 1%), the hook's too
    /// @param owner       who runs the pool and the hook (the team's wallet, then its timelock)
    /// @param feeAddress  the hook's fee address (3% of any ETH it forwards)
    constructor(IPoolManager poolManager, uint24 poolFee, address owner, address feeAddress) {
        IMD6900PerpPool p = new IMD6900PerpPool(poolManager, poolFee, address(this));
        bytes memory init = abi.encodePacked(
            type(IMD6900PerpHook).creationCode, abi.encode(poolManager, address(p), feeAddress, owner, poolFee)
        );
        bytes32 s = _mine(keccak256(init));
        address h;
        assembly ("memory-safe") {
            h := create2(0, add(init, 0x20), mload(init), s)
        }
        if (h == address(0) || uint160(h) & Hooks.ALL_HOOK_MASK != FLAGS) revert BadHook();
        p.setHook(h);
        p.transferOwnership(owner);
        pool = p;
        hook = IMD6900PerpHook(payable(h));
        salt = s;
    }

    /// @dev The first salt whose CREATE2 address from here carries exactly {FLAGS} in its low 14 bits
    function _mine(bytes32 initHash) internal view returns (bytes32 s) {
        address me = address(this);
        uint256 flags = FLAGS;
        uint256 tries = MAX_TRIES;
        bool found;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, me) // the address in bytes 12..31
            mstore8(add(ptr, 11), 0xff) // 0xff ++ address ++ salt ++ initHash: 85 bytes from ptr + 11
            mstore(add(ptr, 0x40), initHash)
            for { let i := 0 } lt(i, tries) { i := add(i, 1) } {
                mstore(add(ptr, 0x20), i)
                if eq(and(keccak256(add(ptr, 11), 85), 0x3fff), flags) {
                    s := i
                    found := 1
                    break
                }
            }
        }
        if (!found) revert NoSalt();
    }
}
