// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @notice A minimal owner, written for this repository's tests: v4-core's PoolManager (ProtocolFees) imports solmate's
///         Owned, which is AGPL, so this stands in for it with the same interface. Never part of the launch.
abstract contract Owned {
    event OwnershipTransferred(address indexed user, address indexed newOwner);

    address public owner;

    modifier onlyOwner() virtual {
        require(msg.sender == owner, "UNAUTHORIZED");
        _;
    }

    constructor(address _owner) {
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }
}
