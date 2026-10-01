// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {ModularOpenTokenFixture} from "./helpers/ModularOpenTokenFixture.sol";
import {OpenTokenMinter} from "../src/opentoken/OpenTokenMinter.sol";
import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OpenToken} from "../src/opentoken/OpenToken.sol";
import {OpenTokenTimelock} from "../src/opentoken/OpenTokenTimelock.sol";
import {TreasuryVault} from "../src/opentoken/TreasuryVault.sol";
import {
    PaidOpenTokenUsdcFixture,
    PaidOpenTokenWalletFixture
} from "./helpers/PaidOpenTokenFixture.sol";

contract TreasuryVaultTest is ModularOpenTokenFixture {
    PaidOpenTokenUsdcFixture private usdc;
    OpenToken private token;
    OpenTokenMinter private minter;
    TreasuryVault private vault;
    OpenTokenTimelock private timelock;
    address private finance;
    address private recipient;

    function setUp() public {
        vm.warp(100);
        usdc = new PaidOpenTokenUsdcFixture(6);
        finance = address(new PaidOpenTokenWalletFixture());
        recipient = makeAddr("provider");
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        timelock = new OpenTokenTimelock(2 days, proposers, executors);
        (token, vault, minter) =
            deploySuite(usdc, finance, address(timelock), address(this), 1000e6);
        usdc.seed(address(vault), 100e6);
    }

    function request(uint256 amount) private returns (uint256) {
        vm.prank(finance);
        return vault.requestWithdrawal(recipient, amount);
    }

    function resume() private {
        uint256 incident = vault.incidentNonce();
        bytes memory data = abi.encodeCall(vault.resume, (incident));
        timelock.schedule(address(vault), 0, data, bytes32(0), bytes32(incident), 2 days);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(vault), 0, data, bytes32(0), bytes32(incident));
    }

    function testFuzzFixedTermsDelayAndPermissionlessExecution(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1, 100e6);
        assertEq(address(vault.USDC()), address(usdc));
        assertEq(vault.governanceTimelock(), address(timelock));
        assertEq(vault.WITHDRAWAL_DELAY(), 24 hours);
        assertEq(uint256(vault.withdrawalStatus(1)), uint256(TreasuryVault.Status.Missing));
        uint256 id = request(amount);
        (
            address to,
            uint256 quantity,
            uint256 readyAt,
            uint256 incident,
            bool executed,
            bool cancelled
        ) = vault.withdrawals(id);
        assertEq(to, recipient);
        assertEq(quantity, amount);
        assertEq(readyAt, block.timestamp + 24 hours);
        assertEq(incident, 0);
        assertFalse(executed);
        assertFalse(cancelled);
        assertEq(vault.reservedUSDC(), amount);
        assertEq(vault.availableUSDC(), 100e6 - amount);
        assertEq(uint256(vault.withdrawalStatus(id)), uint256(TreasuryVault.Status.Pending));
        vm.warp(readyAt - 1);
        vm.expectRevert(TreasuryVault.InvalidWithdrawalStatus.selector);
        vault.executeWithdrawal(id);
        vm.warp(readyAt);
        assertEq(uint256(vault.withdrawalStatus(id)), uint256(TreasuryVault.Status.Ready));
        vm.prank(makeAddr("any executor"));
        vault.executeWithdrawal(id);
        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(vault.reservedUSDC(), 0);
        assertEq(uint256(vault.withdrawalStatus(id)), uint256(TreasuryVault.Status.Executed));
        vm.expectRevert(TreasuryVault.InvalidWithdrawalStatus.selector);
        vault.executeWithdrawal(id);
        vm.expectRevert(TreasuryVault.InvalidWithdrawalStatus.selector);
        vault.cancelWithdrawal(id);
    }

    function testCannotQueueFutureMintRevenueOrOverbookFunds() public {
        request(60e6);
        vm.prank(finance);
        vm.expectRevert(TreasuryVault.InsufficientUnreservedBalance.selector);
        vault.requestWithdrawal(recipient, 40e6 + 1);
        request(40e6);
        assertEq(vault.availableUSDC(), 0);
        usdc.forceBurn(address(vault), 1);
        assertEq(vault.availableUSDC(), 0);
        vm.prank(finance);
        vm.expectRevert(TreasuryVault.InsufficientUnreservedBalance.selector);
        vault.requestWithdrawal(recipient, 1);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(TreasuryVault.InsufficientBacking.selector);
        vault.executeWithdrawal(1);
        assertEq(vault.reservedUSDC(), 100e6);
        usdc.seed(address(vault), 1);
        vault.executeWithdrawal(1);
        vault.executeWithdrawal(2);
        assertEq(vault.availableUSDC(), 0);
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function testFuzzCancellationRolesAndStates(uint8 raw, bool mature) public {
        uint256 role = bound(uint256(raw), 0, 2);
        uint256 id = request(30e6);
        if (mature) vm.warp(block.timestamp + 24 hours);
        vm.prank(role == 0 ? finance : role == 1 ? address(this) : address(timelock));
        vault.cancelWithdrawal(id);
        assertEq(vault.reservedUSDC(), 0);
        assertEq(vault.availableUSDC(), 100e6);
        assertEq(uint256(vault.withdrawalStatus(id)), uint256(TreasuryVault.Status.Cancelled));
        vm.expectRevert(TreasuryVault.InvalidWithdrawalStatus.selector);
        vault.cancelWithdrawal(id);
        vm.expectRevert(TreasuryVault.InvalidWithdrawalStatus.selector);
        vault.cancelWithdrawal(id + 1);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(TreasuryVault.InvalidWithdrawalStatus.selector);
        vault.executeWithdrawal(id);
    }

    function testPausePermanentlyInvalidatesOldQueueWithoutTouchingNewReservations() public {
        uint256 old = request(40e6);
        vm.warp(block.timestamp + 24 hours);
        vault.pause();
        assertEq(vault.reservedUSDC(), 0);
        assertEq(vault.availableUSDC(), 100e6);
        assertEq(vault.reservedByIncident(0), 40e6);
        assertEq(uint256(vault.withdrawalStatus(old)), uint256(TreasuryVault.Status.Invalidated));
        vm.prank(finance);
        vm.expectRevert(TreasuryVault.WithdrawalsPaused.selector);
        vault.requestWithdrawal(recipient, 1);
        vm.expectRevert(TreasuryVault.WithdrawalsPaused.selector);
        vault.executeWithdrawal(old);
        resume();
        uint256 fresh = request(60e6);
        vm.expectRevert(TreasuryVault.InvalidWithdrawalStatus.selector);
        vault.cancelWithdrawal(old);
        assertEq(vault.reservedUSDC(), 60e6);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(TreasuryVault.InvalidWithdrawalStatus.selector);
        vault.executeWithdrawal(old);
        vault.executeWithdrawal(fresh);
        assertEq(usdc.balanceOf(recipient), 60e6);
        vault.pause();
        vault.pause();
        resume();
        assertEq(vault.reservedUSDC(), 0);
        vm.expectRevert(TreasuryVault.InvalidWithdrawalStatus.selector);
        vault.executeWithdrawal(old);
    }

    function testFuzzInvalidRecipientsAndAmount(uint8 raw) public {
        uint256 mode = bound(uint256(raw), 0, 2);
        vm.prank(finance);
        vm.expectRevert(TreasuryVault.InvalidWithdrawal.selector);
        vault.requestWithdrawal(
            mode == 0 ? address(0) : mode == 1 ? address(vault) : recipient, mode == 2 ? 0 : 1
        );
    }

    function testUnauthorizedAndRemovedFinanceCannotAct() public {
        uint256 id = request(1);
        vm.startPrank(recipient);
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.requestWithdrawal(recipient, 1);
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.cancelWithdrawal(id);
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.setFinanceSafe(finance);
        vm.stopPrank();
        address next = address(new PaidOpenTokenWalletFixture());
        vm.prank(address(timelock));
        vm.expectRevert(TreasuryVault.PauseRequired.selector);
        vault.setFinanceSafe(next);
        vault.pause();
        bytes memory data = abi.encodeCall(vault.setFinanceSafe, (next));
        timelock.schedule(address(vault), 0, data, bytes32(0), "finance", 2 days);
        vm.expectRevert();
        timelock.execute(address(vault), 0, data, bytes32(0), "finance");
        vault.pause();
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(vault), 0, data, bytes32(0), "finance");
        assertEq(vault.financeSafe(), next);
        resume();
        vm.prank(finance);
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.requestWithdrawal(recipient, 1);
        vm.prank(next);
        vault.requestWithdrawal(recipient, 1);
    }

    function testFuzzRejectInvalidFinanceRotation(uint8 raw) public {
        vault.pause();
        address[6] memory candidates = [
            address(0), recipient, address(vault), address(usdc), address(token), address(timelock)
        ];
        address next = candidates[bound(uint256(raw), 0, 5)];
        vm.prank(address(timelock));
        vm.expectRevert(TreasuryVault.InvalidConfiguration.selector);
        vault.setFinanceSafe(next);
        assertEq(vault.financeSafe(), finance);
    }

    function testFuzzInvalidStandaloneBindings(uint8 raw) public {
        uint256 mode = bound(uint256(raw), 0, 5);
        IERC20 asset = mode == 0 ? IERC20(recipient) : IERC20(address(usdc));
        IERC20 state = mode == 1
            ? IERC20(address(0))
            : mode == 2 ? IERC20(address(usdc)) : IERC20(address(token));
        address governance = mode == 3
            ? recipient
            : mode == 4 ? address(usdc) : mode == 5 ? address(token) : address(timelock);
        vm.expectRevert(TreasuryVault.InvalidConfiguration.selector);
        new TreasuryVault(asset, state, governance, finance, address(this));
    }

    function testFuzzInexactOrFailedOutflowRollsBackReservationAndPayment(uint8 raw) public {
        uint256 mode = bound(uint256(raw), 1, 6);
        usdc.seed(recipient, 1);
        uint256 id = request(10e6);
        vm.warp(block.timestamp + 24 hours);
        usdc.setOutflowFault(PaidOpenTokenUsdcFixture.OutflowFault(mode));
        vm.expectRevert();
        vault.executeWithdrawal(id);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(usdc.balanceOf(recipient), 1);
        assertEq(vault.reservedUSDC(), 10e6);
        assertEq(uint256(vault.withdrawalStatus(id)), uint256(TreasuryVault.Status.Ready));
        usdc.setOutflowFault(PaidOpenTokenUsdcFixture.OutflowFault.None);
        vault.executeWithdrawal(id);
    }

    function testFuzzOutflowCallbackCannotReenterQueue(uint8 raw) public {
        uint256 mode = bound(uint256(raw), 0, 3);
        uint256 id = request(10e6);
        vm.warp(block.timestamp + 24 hours);
        bytes memory data = mode == 0
            ? abi.encodeCall(vault.executeWithdrawal, (id))
            : mode == 1
                ? abi.encodeCall(vault.cancelWithdrawal, (id))
                : mode == 2
                    ? abi.encodeCall(vault.requestWithdrawal, (recipient, 1))
                    : abi.encodeCall(vault.setFinanceSafe, (finance));
        usdc.setCallback(address(vault), data);
        vault.executeWithdrawal(id);
        assertEq(usdc.callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(usdc.balanceOf(recipient), 10e6);
        assertEq(vault.reservedUSDC(), 0);
    }
}
