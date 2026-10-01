// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ModularOpenTokenFixture} from "./helpers/ModularOpenTokenFixture.sol";
import {OpenTokenMinter} from "../src/opentoken/OpenTokenMinter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OpenTokenTimelock} from "../src/opentoken/OpenTokenTimelock.sol";
import {TreasuryVault} from "../src/opentoken/TreasuryVault.sol";
import {PaidOpenTokenCollector, IPaidOpenToken} from "../src/opentoken/PaidOpenTokenCollector.sol";
import {OpenToken} from "../src/opentoken/OpenToken.sol";
import {OpenTokenDepositReceiver} from "../src/credits/OpenTokenDepositFactory.sol";
import {
    PaidOpenTokenUsdcFixture,
    PaidOpenTokenWalletFixture
} from "./helpers/PaidOpenTokenFixture.sol";

contract OpenTokenTest is ModularOpenTokenFixture {
    PaidOpenTokenUsdcFixture private usdc;
    OpenToken private token;
    OpenTokenMinter private minter;
    TreasuryVault private vault;
    TimelockController private timelock;
    address private treasury;
    address private payer;
    address private recipient;
    address private finance;
    uint256 private constant DELAY = 2 days;
    uint256 private constant INITIAL_AUTHORIZATION = 1_000_000e6;

    event Issued(
        address indexed payer,
        address indexed recipient,
        address indexed asset,
        uint256 paymentAmount,
        uint256 issuedAmount,
        address destination
    );
    event EmergencyPaused(address indexed authority, uint256 incidentNonce);
    event EmergencyResumed(uint256 incidentNonce);
    event MintAuthorizationIncreased(uint256 previousTotal, uint256 newTotal);

    function setUp() public {
        vm.warp(100);
        usdc = new PaidOpenTokenUsdcFixture(6);
        finance = address(new PaidOpenTokenWalletFixture());
        payer = makeAddr("payer");
        recipient = makeAddr("recipient");
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new OpenTokenTimelock(DELAY, proposers, executors);
        (token, vault, minter) =
            deploySuite(usdc, finance, address(timelock), address(this), INITIAL_AUTHORIZATION);
        treasury = address(vault);
        usdc.seed(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(minter), type(uint256).max);
    }

    function _mint(uint256 amount) private {
        vm.prank(payer);
        minter.mint(amount);
    }

    function _target(bytes memory data) private view returns (address) {
        return bytes4(data) == minter.increaseMintAuthorization.selector
            ? address(minter)
            : address(vault);
    }

    function _schedule(bytes memory data, bytes32 salt) private {
        timelock.schedule(_target(data), 0, data, bytes32(0), salt, DELAY);
    }

    function _execute(bytes memory data, bytes32 salt) private {
        timelock.execute(_target(data), 0, data, bytes32(0), salt);
    }

    function testMetadataAndNoInitialIssuance() public view {
        assertEq(token.name(), "OpenTokens");
        assertEq(token.symbol(), "TOKEN");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), 0);
        assertEq(minter.authorizedMintTotal(), INITIAL_AUTHORIZATION);
        assertEq(minter.mintedTotal(), 0);
        assertEq(minter.remainingMintAuthorization(), INITIAL_AUTHORIZATION);
        assertEq(address(minter.USDC()), address(usdc));
        assertEq(address(vault.token()), address(token));
        assertEq(vault.financeSafe(), finance);
        assertEq(token.governanceTimelock(), address(timelock));
        assertEq(vault.guardian(), address(this));
    }

    function testSingleSafeGuardianAndBillionAuthorization() public {
        (OpenToken beta, TreasuryVault treasuryBeta, OpenTokenMinter issuer) =
            deploySuite(usdc, finance, address(timelock), finance, 1_000_000_000e6);
        assertEq(treasuryBeta.guardian(), finance);
        assertEq(issuer.authorizedMintTotal(), 1_000_000_000_000_000);
        assertEq(beta.totalSupply(), 0);
        vm.prank(finance);
        treasuryBeta.pause();
        vm.warp(block.timestamp + 365 days);
        assertTrue(treasuryBeta.emergencyPaused());
        vm.prank(finance);
        treasuryBeta.pause();
        assertEq(treasuryBeta.incidentNonce(), 2);
    }

    function testFuzzExactPaymentMintsToCallerOrRecipient(uint96 raw, bool gift) public {
        uint256 amount = bound(uint256(raw), 1, 1_000_000e6);
        address to = gift ? recipient : payer;
        vm.expectEmit(true, true, true, true, address(minter));
        emit Issued(payer, to, address(usdc), amount, amount, treasury);
        vm.prank(payer);
        if (gift) minter.mintTo(amount, to);
        else minter.mint(amount);
        assertEq(usdc.balanceOf(treasury), amount);
        assertEq(usdc.balanceOf(payer), 1_000_000e6 - amount);
        assertEq(usdc.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), amount);
        assertEq(minter.mintedTotal(), amount);
        assertEq(minter.remainingMintAuthorization(), INITIAL_AUTHORIZATION - amount);
    }

    function testRejectsZeroAmountAndSelfOrZeroRecipientBeforePayment() public {
        vm.startPrank(payer);
        vm.expectRevert(OpenToken.InvalidAmount.selector);
        minter.mint(0);
        vm.expectRevert(OpenToken.InvalidAmount.selector);
        minter.mintTo(0, recipient);
        vm.expectRevert(OpenTokenMinter.InvalidRecipient.selector);
        minter.mintTo(1, address(0));
        vm.expectRevert(OpenTokenMinter.InvalidRecipient.selector);
        minter.mintTo(1, address(token));
        vm.stopPrank();
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(token.totalSupply(), 0);
    }

    function testTreasuryCannotSelfPayAndPayerCannotSpendAnotherAllowance() public {
        usdc.seed(treasury, 10e6);
        vm.startPrank(treasury);
        usdc.approve(address(minter), 10e6);
        vm.expectRevert(OpenTokenMinter.TreasurySelfPayment.selector);
        minter.mintTo(10e6, recipient);
        vm.stopPrank();
        vm.prank(recipient);
        vm.expectRevert();
        minter.mintTo(10e6, recipient);
        assertEq(usdc.balanceOf(treasury), 10e6);
        assertEq(usdc.balanceOf(payer), 1_000_000e6);
        assertEq(token.totalSupply(), 0);
    }

    function testFuzzFailedOrInexactPaymentRollsBackEverything(uint8 raw) public {
        uint256 mode = bound(uint256(raw), 1, 5);
        usdc.seed(treasury, 5e6);
        vm.prank(payer);
        usdc.approve(address(minter), 10e6);
        usdc.setFault(PaidOpenTokenUsdcFixture.Fault(mode));
        vm.prank(payer);
        vm.expectRevert();
        minter.mintTo(10e6, recipient);
        assertEq(usdc.balanceOf(payer), 1_000_000e6);
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(usdc.allowance(payer, address(minter)), 10e6);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(minter.mintedTotal(), 0);
        assertEq(minter.remainingMintAuthorization(), INITIAL_AUTHORIZATION);
        usdc.setFault(PaidOpenTokenUsdcFixture.Fault.None);
        _mint(10e6);
        assertEq(token.totalSupply(), 10e6);
    }

    function testSafeTransferSupportsNoReturnAndStillChecksReceipt() public {
        usdc.setFault(PaidOpenTokenUsdcFixture.Fault.NoReturn);
        _mint(10e6);
        assertEq(usdc.balanceOf(treasury), 10e6);
        assertEq(token.totalSupply(), 10e6);
    }

    function testUnsolicitedPaymentDoesNotMintAndCannotBeClaimedByNextPayer() public {
        vm.prank(payer);
        usdc.transfer(treasury, 20e6);
        vm.prank(payer);
        usdc.transfer(address(token), 5e6);
        assertEq(token.totalSupply(), 0);
        _mint(10e6);
        assertEq(token.balanceOf(payer), 10e6);
        assertEq(usdc.balanceOf(treasury), 30e6);
        assertEq(usdc.balanceOf(address(token)), 5e6);
    }

    function testTransfersAndCallerOnlyBurnWorkDuringStopAndUsdcFailure() public {
        _mint(10e6);
        vault.pause();
        usdc.setFault(PaidOpenTokenUsdcFixture.Fault.RevertTransfer);
        usdc.setFailBalanceRead(true);
        vm.startPrank(payer);
        token.transfer(recipient, 4e6);
        token.approve(recipient, 2e6);
        token.burn(1e6);
        vm.stopPrank();
        vm.startPrank(recipient);
        token.transferFrom(payer, recipient, 2e6);
        token.burn(5e6);
        vm.expectRevert(OpenToken.InvalidAmount.selector);
        token.burn(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, recipient, 1e6, 2e6
            )
        );
        token.burn(2e6);
        vm.stopPrank();
        assertEq(token.totalSupply(), 4e6);
        assertEq(token.balanceOf(payer), 3e6);
        assertEq(token.balanceOf(recipient), 1e6);
        assertEq(minter.mintedTotal(), 10e6);
        assertEq(minter.remainingMintAuthorization(), INITIAL_AUTHORIZATION - 10e6);
    }

    function testRepeatedPauseHasNoExpiryAndRequiresTimelockRecovery() public {
        for (uint256 i = 1; i <= 3; ++i) {
            vault.pause();
            assertEq(vault.incidentNonce(), i);
            vm.warp(block.timestamp + 30 days);
            vm.prank(payer);
            vm.expectRevert(OpenTokenMinter.MintUnavailable.selector);
            minter.mint(1);
            bytes memory data = abi.encodeCall(vault.resume, (i));
            _schedule(data, bytes32(i));
            vm.warp(block.timestamp + DELAY);
            _execute(data, bytes32(i));
            _mint(1);
        }
        vm.prank(address(timelock));
        vault.pause();
        assertEq(vault.incidentNonce(), 4);
    }

    function testUnauthorizedCallersCannotPauseRecoverOrRotateGuardian() public {
        vm.startPrank(payer);
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.pause();
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.resume(0);
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.setGuardian(payer);
        vm.stopPrank();
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.resume(0);
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.setGuardian(payer);
    }

    function testDelayedRecoveryAndNewIncidentInvalidatesQueuedResume() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit EmergencyPaused(address(this), 1);
        vault.pause();
        bytes memory stale = abi.encodeCall(vault.resume, (1));
        _schedule(stale, "stale");
        vm.expectRevert();
        _execute(stale, "stale");
        vault.pause();
        assertEq(vault.incidentNonce(), 2);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(TreasuryVault.InvalidRecovery.selector);
        _execute(stale, "stale");
        assertTrue(vault.emergencyPaused());
        bytes memory current = abi.encodeCall(vault.resume, (2));
        _schedule(current, "current");
        vm.warp(block.timestamp + DELAY);
        vm.expectEmit(false, false, false, true, address(vault));
        emit EmergencyResumed(2);
        _execute(current, "current");
        assertFalse(vault.emergencyPaused());
        _mint(1);
    }

    function testRecoveryCannotResumeActiveToken() public {
        bytes memory data = abi.encodeCall(vault.resume, (0));
        _schedule(data, "active");
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(TreasuryVault.InvalidRecovery.selector);
        _execute(data, "active");
    }

    function testRepeatedPausesCannotInvalidateGuardianReplacement() public {
        address next = makeAddr("new guardian");
        bytes memory data = abi.encodeCall(vault.setGuardian, (next));
        _schedule(data, "rotation");
        vault.pause();
        vault.pause();
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        vm.warp(block.timestamp + DELAY);
        _execute(data, "rotation");
        assertEq(vault.guardian(), next);
        assertTrue(vault.emergencyPaused());
        vm.expectRevert(TreasuryVault.Unauthorized.selector);
        vault.pause();
        vm.prank(next);
        vault.pause();
        assertEq(vault.incidentNonce(), 3);
        // A standalone guardian does not inherit the proposer's cancellation role.
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), next));
        vm.prank(next);
        vm.expectRevert();
        timelock.cancel(bytes32(0));
    }

    function testFuzzRejectsInvalidGuardianEvenFromGovernance(uint8 raw) public {
        address[5] memory invalid =
            [address(0), address(token), address(usdc), treasury, address(timelock)];
        address next = invalid[bound(uint256(raw), 0, 4)];
        vm.prank(address(timelock));
        vm.expectRevert(TreasuryVault.InvalidConfiguration.selector);
        vault.setGuardian(next);
        assertEq(vault.guardian(), address(this));
    }

    function testFuzzPaymentCallbacksCannotReenterAnyPrivilegedMutation(uint8 raw) public {
        uint256 mode = bound(raw, 0, 2);
        bytes memory data = mode == 0
            ? abi.encodeCall(minter.mint, (1))
            : mode == 1
                ? abi.encodeCall(minter.mintTo, (1, recipient))
                : abi.encodeCall(minter.increaseMintAuthorization, (INITIAL_AUTHORIZATION + 1));
        usdc.setCallback(address(minter), data);
        _mint(10e6);
        assertEq(usdc.callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(token.totalSupply(), 10e6);
        assertEq(usdc.balanceOf(treasury), 10e6);
    }

    function testPaidMintToReceiverAndNormalTransferConvertWithoutB20Roles() public {
        PaidOpenTokenCollector collector =
            new PaidOpenTokenCollector(IPaidOpenToken(address(token)), vault, address(timelock));
        bytes32 salt = keccak256("billing-account");
        address receiver = collector.factory().predict(salt);
        vm.prank(payer);
        minter.mintTo(30e6, receiver);
        _mint(70e6);
        vm.prank(payer);
        token.transfer(receiver, 70e6);
        assertEq(collector.nextConversionId(), 0);
        assertEq(token.totalSupply(), 100e6);
        vault.pause();
        usdc.setFailBalanceRead(true);
        vm.prank(recipient);
        assertEq(collector.convert(salt), 1);
        (address source, uint256 amount) = collector.conversions(1);
        assertEq(source, receiver);
        assertEq(amount, 100e6);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(OpenTokenDepositReceiver(receiver).burner(), address(collector));
        vm.expectRevert("empty");
        collector.convert(salt);
    }

    function testZeroInitialAuthorizationRejectsBeforeReadingOrCollectingUsdc() public {
        (token, vault, minter) = deploySuite(usdc, finance, address(timelock), address(this), 0);
        treasury = address(vault);
        assertEq(minter.authorizedMintTotal(), 0);
        assertEq(token.totalSupply(), 0);
        usdc.setFailBalanceRead(true);
        vm.prank(payer);
        vm.expectRevert(OpenTokenMinter.InsufficientMintAuthorization.selector);
        minter.mint(1);
        assertEq(minter.mintedTotal(), 0);
        usdc.setFailBalanceRead(false);
        assertEq(usdc.balanceOf(treasury), 0);
        bytes memory data = abi.encodeCall(minter.increaseMintAuthorization, (1e6));
        _schedule(data, "first-authorization");
        vm.warp(block.timestamp + DELAY);
        _execute(data, "first-authorization");
        vm.prank(payer);
        usdc.approve(address(minter), 1e6);
        _mint(1e6);
        assertEq(minter.mintedTotal(), 1e6);
        assertEq(minter.remainingMintAuthorization(), 0);
    }

    function testRecyclingUsdcAndBurningWithNewPayersAndDaysCannotResetAuthorization() public {
        (token, vault, minter) = deploySuite(usdc, finance, address(timelock), address(this), 500e6);
        treasury = address(vault);
        for (uint256 i; i < 5; ++i) {
            address buyer = i % 2 == 0 ? payer : recipient;
            address nextBuyer = i % 2 == 0 ? recipient : payer;
            vm.startPrank(buyer);
            usdc.approve(address(minter), 100e6);
            if (i % 2 == 0) minter.mint(100e6);
            else minter.mintTo(100e6, buyer);
            token.burn(100e6);
            vm.stopPrank();

            vm.prank(finance);
            uint256 id = vault.requestWithdrawal(nextBuyer, 100e6);
            vm.warp(block.timestamp + 1 days);
            vault.executeWithdrawal(id);
        }
        assertEq(minter.mintedTotal(), 500e6);
        assertEq(token.totalSupply(), 0);
        assertEq(minter.remainingMintAuthorization(), 0);
        assertEq(usdc.balanceOf(treasury), 0);
        vm.prank(recipient);
        vm.expectRevert(OpenTokenMinter.InsufficientMintAuthorization.selector);
        minter.mintTo(100e6, payer);
        assertEq(minter.mintedTotal(), 500e6);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function testFuzzAllMintEntryPointsShareOneLifetimeCeiling(uint96 raw) public {
        uint256 first = bound(uint256(raw), 1, INITIAL_AUTHORIZATION - 1);
        _mint(first);
        uint256 remaining = INITIAL_AUTHORIZATION - first;
        usdc.seed(recipient, remaining + 1);
        vm.startPrank(recipient);
        usdc.approve(address(minter), remaining + 1);
        vm.expectRevert(OpenTokenMinter.InsufficientMintAuthorization.selector);
        minter.mintTo(remaining + 1, payer);
        minter.mintTo(remaining, payer);
        vm.stopPrank();
        assertEq(minter.mintedTotal(), INITIAL_AUTHORIZATION);
        assertEq(minter.remainingMintAuthorization(), 0);
        assertEq(usdc.balanceOf(treasury), INITIAL_AUTHORIZATION);
        vm.prank(payer);
        token.burn(INITIAL_AUTHORIZATION);
        vm.prank(payer);
        vm.expectRevert(OpenTokenMinter.InsufficientMintAuthorization.selector);
        minter.mint(1);
    }

    function testOnlyRecoveryTimelockMayIncreaseAuthorization() public {
        address[4] memory callers = [payer, treasury, address(this), finance];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TreasuryVault.Unauthorized.selector);
            minter.increaseMintAuthorization(INITIAL_AUTHORIZATION + 1);
        }
        assertEq(minter.authorizedMintTotal(), INITIAL_AUTHORIZATION);
    }

    function testQueuedCeilingDoesNotOverwriteIssuanceSinceSchedulingOrResumeMint() public {
        uint256 ceiling = INITIAL_AUTHORIZATION + 100e6;
        bytes memory data = abi.encodeCall(minter.increaseMintAuthorization, (ceiling));
        _schedule(data, "ceiling");
        vm.expectRevert();
        _execute(data, "ceiling");
        _mint(10e6);
        vault.pause();
        vm.warp(block.timestamp + DELAY);
        vm.expectEmit(false, false, false, true, address(minter));
        emit MintAuthorizationIncreased(INITIAL_AUTHORIZATION, ceiling);
        _execute(data, "ceiling");
        assertEq(minter.authorizedMintTotal(), ceiling);
        assertEq(minter.mintedTotal(), 10e6);
        assertEq(minter.remainingMintAuthorization(), ceiling - 10e6);
        assertEq(token.totalSupply(), 10e6);
        assertTrue(vault.emergencyPaused());
        assertEq(vault.incidentNonce(), 1);
    }

    function testStaleOrEqualCeilingCannotReduceOrResetAuthorization() public {
        bytes memory lower =
            abi.encodeCall(minter.increaseMintAuthorization, (INITIAL_AUTHORIZATION + 10e6));
        bytes memory higher =
            abi.encodeCall(minter.increaseMintAuthorization, (INITIAL_AUTHORIZATION + 20e6));
        _schedule(lower, "lower");
        _schedule(higher, "higher");
        vm.warp(block.timestamp + DELAY);
        _execute(higher, "higher");
        _mint(5e6);
        vm.expectRevert(OpenTokenMinter.InvalidMintAuthorization.selector);
        _execute(lower, "lower");
        vm.prank(address(timelock));
        vm.expectRevert(OpenTokenMinter.InvalidMintAuthorization.selector);
        minter.increaseMintAuthorization(INITIAL_AUTHORIZATION + 20e6);
        assertEq(minter.authorizedMintTotal(), INITIAL_AUTHORIZATION + 20e6);
        assertEq(minter.mintedTotal(), 5e6);
    }

    function testUsdcReadFailureDoesNotConsumeAuthorization() public {
        usdc.setFailBalanceRead(true);
        vm.prank(payer);
        vm.expectRevert();
        minter.mint(10e6);
        assertEq(minter.mintedTotal(), 0);
        assertEq(minter.remainingMintAuthorization(), INITIAL_AUTHORIZATION);
        assertEq(token.totalSupply(), 0);
    }

    function testCancelledIncreaseCannotBeExecuted() public {
        bytes memory data =
            abi.encodeCall(minter.increaseMintAuthorization, (INITIAL_AUTHORIZATION + 1));
        _schedule(data, "cancelled");
        timelock.cancel(timelock.hashOperation(_target(data), 0, data, bytes32(0), "cancelled"));
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert();
        _execute(data, "cancelled");
        assertEq(minter.authorizedMintTotal(), INITIAL_AUTHORIZATION);
    }

    function testFuzzSponsoredPermitChangesOnlySignedAllowance(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1, 1_000_000e6);
        uint256 key = 0x1234;
        address holder = vm.addr(key);
        address spender = makeAddr("permit-spender");
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(payer);
        minter.mintTo(amount, holder);
        vault.pause();
        usdc.setFailBalanceRead(true);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, _permitDigest(holder, spender, amount, deadline, token.DOMAIN_SEPARATOR()));
        // A third party submits the signature; the holder needs no native balance.
        vm.prank(recipient);
        token.permit(holder, spender, amount, deadline, v, r, s);
        assertEq(holder.balance, 0);
        assertEq(token.allowance(holder, spender), amount);
        assertEq(token.allowance(holder, recipient), 0);
        assertEq(token.nonces(holder), 1);
        assertEq(token.totalSupply(), amount);
        assertEq(token.balanceOf(holder), amount);
        vm.expectRevert();
        token.permit(holder, spender, amount, deadline, v, r, s);
        vm.prank(spender);
        token.transferFrom(holder, recipient, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.totalSupply(), amount);
        usdc.setFailBalanceRead(false);
        assertEq(usdc.balanceOf(treasury), amount);
    }

    function testPermitBindsSpenderAmountOwnerAndDeadline() public {
        uint256 key = 0x1234;
        address holder = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, _permitDigest(holder, payer, 1e6, deadline, token.DOMAIN_SEPARATOR()));
        vm.expectRevert();
        token.permit(holder, recipient, 1e6, deadline, v, r, s);
        vm.expectRevert();
        token.permit(holder, payer, 2e6, deadline, v, r, s);
        vm.expectRevert();
        token.permit(recipient, payer, 1e6, deadline, v, r, s);
        vm.expectRevert();
        token.permit(holder, payer, 1e6, deadline + 1, v, r, s);
        assertEq(token.nonces(holder), 0);
        assertEq(token.nonces(recipient), 0);
        assertEq(token.allowance(holder, payer), 0);
        assertEq(token.totalSupply(), 0);
    }

    function testPermitCannotReplayOnMonadOrAnotherToken() public {
        vm.chainId(8453);
        uint256 key = 0x1234;
        address holder = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 baseDomain = token.DOMAIN_SEPARATOR();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, _permitDigest(holder, payer, 1e6, deadline, baseDomain));
        OpenToken other = new OpenToken(address(timelock), address(minter));
        vm.expectRevert();
        other.permit(holder, payer, 1e6, deadline, v, r, s);
        vm.chainId(143);
        assertNotEq(token.DOMAIN_SEPARATOR(), baseDomain);
        vm.expectRevert();
        token.permit(holder, payer, 1e6, deadline, v, r, s);
        assertEq(token.nonces(holder), 0);
        assertEq(other.nonces(holder), 0);
        vm.chainId(8453);
        token.permit(holder, payer, 1e6, deadline, v, r, s);
        assertEq(token.nonces(holder), 1);
    }

    function testExpiredPermitDoesNotConsumeNonceOrAllowance() public {
        uint256 key = 0x1234;
        address holder = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, _permitDigest(holder, payer, 1e6, deadline, token.DOMAIN_SEPARATOR()));
        vm.warp(deadline + 1);
        vm.expectRevert();
        token.permit(holder, payer, 1e6, deadline, v, r, s);
        assertEq(token.nonces(holder), 0);
        assertEq(token.allowance(holder, payer), 0);
    }

    function _permitDigest(
        address holder,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes32 domain
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                domain,
                keccak256(
                    abi.encode(
                        keccak256(
                            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                        ),
                        holder,
                        spender,
                        value,
                        0,
                        deadline
                    )
                )
            )
        );
    }

    function testNoAdminMintBurnFromUpgradeOrRescueEntrypoints() public {
        bytes[9] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", payer, 1),
            abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("MINTER_ROLE"), payer),
            abi.encodeWithSignature("burnFrom(address,uint256)", payer, 1),
            abi.encodeWithSignature("upgradeTo(address)", payer),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", payer, bytes("")),
            abi.encodeWithSignature("initialize()"),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("release()"),
            abi.encodeWithSignature("rescue(address,address,uint256)", address(usdc), payer, 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 0);
    }
}
