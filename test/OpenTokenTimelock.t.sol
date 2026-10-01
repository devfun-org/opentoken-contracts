// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {Test} from "forge-std/Test.sol";
import {OpenTokenTimelock} from "../src/opentoken/OpenTokenTimelock.sol";

contract OpenTokenTimelockTest is Test {
    OpenTokenTimelock private timelock;
    address[] private proposers;
    address[] private executors;

    function setUp() public {
        proposers.push(address(this));
        executors.push(address(0));
        timelock = new OpenTokenTimelock(2 days, proposers, executors);
    }

    function testFuzzInitialFloor(uint32 delay) public {
        delay = uint32(bound(delay, 0, 2 days - 1));
        vm.expectRevert(OpenTokenTimelock.DelayBelowMinimum.selector);
        new OpenTokenTimelock(delay, proposers, executors);
    }

    function testOnlyDelayedSelfCallCanChangeDelayAndNeverBelowFloor() public {
        assertEq(timelock.MINIMUM_DELAY(), 2 days);
        vm.expectRevert();
        timelock.updateDelay(3 days);
        bytes memory data = abi.encodeCall(timelock.updateDelay, (3 days));
        timelock.schedule(address(timelock), 0, data, bytes32(0), "increase", 2 days);
        vm.expectRevert();
        timelock.execute(address(timelock), 0, data, bytes32(0), "increase");
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(timelock), 0, data, bytes32(0), "increase");
        assertEq(timelock.getMinDelay(), 3 days);
        data = abi.encodeCall(timelock.updateDelay, (2 days - 1));
        vm.expectRevert();
        timelock.schedule(address(timelock), 0, data, bytes32(0), "bad", 2 days);
        timelock.schedule(address(timelock), 0, data, bytes32(0), "bad", 3 days);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(OpenTokenTimelock.DelayBelowMinimum.selector);
        timelock.execute(address(timelock), 0, data, bytes32(0), "bad");
        assertEq(timelock.getMinDelay(), 3 days);
        data = abi.encodeCall(timelock.updateDelay, (2 days));
        timelock.schedule(address(timelock), 0, data, bytes32(0), "floor", 3 days);
        vm.warp(block.timestamp + 3 days);
        timelock.execute(address(timelock), 0, data, bytes32(0), "floor");
        assertEq(timelock.getMinDelay(), 2 days);
    }

    function testBatchCannotBypassDelayFloorOrGrantGuardianCancellation() public {
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(timelock.updateDelay, (0));
        vm.expectRevert();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), "batch", 2 days - 1);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), "batch", 2 days);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(OpenTokenTimelock.DelayBelowMinimum.selector);
        timelock.executeBatch(targets, values, payloads, bytes32(0), "batch");
        assertEq(timelock.getMinDelay(), 2 days);
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
    }
}
