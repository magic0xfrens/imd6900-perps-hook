// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IMD6900PerpsLaunch} from "../src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpHook} from "../src/IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "../src/IMD6900PerpPool.sol";

/// What IMD's admission checks before it deploys a launch, offline: the launch deploys on a fresh chain (nothing it
/// calls exists there), in one transaction, and no contract's code shows a refused opcode.
contract IMD6900PerpsLaunchTest is Test {
    address constant OWNER = address(0xA11CE);
    address constant FEE = address(0xFEE);
    IPoolManager constant PM = IPoolManager(address(0x8366a39CC670B4001A1121B8F6A443A643e40951)); // no code here

    function test_DeploysOnAFreshChain() public {
        IMD6900PerpsLaunch l = new IMD6900PerpsLaunch(PM, 10_000, OWNER, FEE);
        IMD6900PerpHook hook = l.hook();
        IMD6900PerpPool pool = l.pool();
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, l.FLAGS(), "the hook's address carries its flags");
        assertEq(pool.hook(), address(hook));
        assertEq(hook.launcher(), address(pool));
        assertEq(pool.owner(), OWNER);
        assertEq(hook.owner(), OWNER);
        assertEq(hook.feeAddress(), FEE);
        assertEq(pool.poolFee(), 10_000);
        assertEq(hook.poolFeePips(), 10_000);
        assertEq(address(hook.poolManager()), address(PM));
    }

    function test_FitsOneTransaction() public {
        uint256 g = gasleft();
        new IMD6900PerpsLaunch(PM, 10_000, OWNER, FEE);
        uint256 used = g - gasleft();
        emit log_named_uint("launch gas (the mining included)", used);
        assertLt(used, 1 << 24, "under EIP-7825's per-transaction cap");
    }

    function test_EachDeployerMinesItsOwnSalt() public {
        IMD6900PerpsLaunch a = new IMD6900PerpsLaunch(PM, 10_000, OWNER, FEE);
        IMD6900PerpsLaunch b = new IMD6900PerpsLaunch(PM, 10_000, OWNER, FEE);
        assertTrue(address(a.hook()) != address(b.hook()));
        assertEq(uint160(address(b.hook())) & Hooks.ALL_HOOK_MASK, b.FLAGS());
    }

    function test_RefusesADynamicFee() public {
        vm.expectRevert(); // the hook refuses it, so the launch does
        new IMD6900PerpsLaunch(PM, 0x800000, OWNER, FEE);
    }

    function test_PassesTheAdmissionScan() public {
        IMD6900PerpsLaunch l = new IMD6900PerpsLaunch(PM, 10_000, OWNER, FEE);
        _scan(type(IMD6900PerpsLaunch).creationCode, "launch creation code");
        _scan(address(l).code, "launch");
        _scan(address(l.hook()).code, "hook");
        _scan(address(l.pool()).code, "pool");
    }

    /// @dev IMD reads code as instructions (PUSH data skipped) and refuses CALLCODE, DELEGATECALL and SELFDESTRUCT
    function _scan(bytes memory code, string memory what) internal pure {
        uint256 hits;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0xf2 || op == 0xf4 || op == 0xff) ++hits;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(hits, 0, what);
    }
}
