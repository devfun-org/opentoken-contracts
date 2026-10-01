// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// OZ scheduling/execution/roles are unchanged. Both delay reads and writes use
/// this bounded value because the base contract's delay storage is private.
contract OpenTokenTimelock is TimelockController {
    uint256 public constant MINIMUM_DELAY = 48 hours;
    uint256 private boundedDelay;
    error DelayBelowMinimum();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MINIMUM_DELAY) revert DelayBelowMinimum();
        boundedDelay = minDelay;
    }

    function getMinDelay() public view override returns (uint256) {
        return boundedDelay;
    }

    function updateDelay(uint256 newDelay) external override {
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        if (newDelay < MINIMUM_DELAY) revert DelayBelowMinimum();
        emit MinDelayChange(boundedDelay, newDelay);
        boundedDelay = newDelay;
    }
}
