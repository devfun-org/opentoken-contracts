// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OpenToken} from "../src/opentoken/OpenToken.sol";
import {OpenTokenMinter} from "../src/opentoken/OpenTokenMinter.sol";
import {TreasuryVault} from "../src/opentoken/TreasuryVault.sol";
import {OpenTokenTimelock} from "../src/opentoken/OpenTokenTimelock.sol";
import {ModularOpenTokenFixture} from "./helpers/ModularOpenTokenFixture.sol";
import {
    PaidOpenTokenUsdcFixture,
    PaidOpenTokenWalletFixture
} from "./helpers/PaidOpenTokenFixture.sol";

// ERC1271 semantics fixture, not evidence of deployed Safe custody or threshold.
contract ContractPayerFixture is IERC1271 {
    bytes32 public approved;

    function approve(IERC20 usdc, address spender) external {
        usdc.approve(spender, type(uint256).max);
    }

    function approveDigest(bytes32 digest) external {
        approved = digest;
    }

    function isValidSignature(bytes32 digest, bytes memory) external view returns (bytes4) {
        return digest == approved ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

contract OpenTokenModulesTest is ModularOpenTokenFixture {
    OpenToken private token;
    TreasuryVault private vault;
    OpenTokenMinter private minter;
    PaidOpenTokenUsdcFixture private usdc;
    OpenTokenTimelock private timelock;
    address private finance;
    uint256 private constant KEY = 12345;
    address private payer;
    uint256 private constant CAP = 1000e6;

    function setUp() public {
        vm.warp(100);
        usdc = new PaidOpenTokenUsdcFixture(6);
        finance = address(new PaidOpenTokenWalletFixture());
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        timelock = new OpenTokenTimelock(2 days, proposers, executors);
        (token, vault, minter) = deploySuite(usdc, finance, address(timelock), address(this), CAP);
        payer = vm.addr(KEY);
        usdc.seed(payer, 10000e6);
        vm.prank(payer);
        usdc.approve(address(minter), type(uint256).max);
    }

    function config(address previous) private view returns (OpenTokenMinter.Configuration memory) {
        return OpenTokenMinter.Configuration(token, usdc, vault, address(timelock), previous, 0);
    }

    function candidate() private returns (OpenTokenMinter) {
        return new OpenTokenMinter(config(address(minter)));
    }

    function batch(OpenTokenMinter next)
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calls)
    {
        targets = new address[](3);
        values = new uint256[](3);
        calls = new bytes[](3);
        targets[0] = address(minter);
        targets[1] = address(token);
        targets[2] = address(next);
        calls[0] = abi.encodeCall(minter.retire, (address(next)));
        calls[1] = abi.encodeCall(token.setMinter, (address(minter), address(next)));
        calls[2] = abi.encodeCall(next.initializeFromPredecessor, ());
    }

    function testFuzzAtomicReplacementImportsFinalCountsAndKeepsWithdrawals(uint96 raw) public {
        uint256 amount = bound(raw, 2, CAP);
        vm.prank(payer);
        minter.mint(amount - 1);
        vm.prank(payer);
        token.burn(amount - 1);
        vm.prank(finance);
        uint256 id = vault.requestWithdrawal(payer, amount - 1);
        OpenTokenMinter next = candidate();
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) = batch(next);
        timelock.scheduleBatch(targets, values, calls, 0, "switch", 2 days);
        vm.expectRevert();
        timelock.executeBatch(targets, values, calls, 0, "switch");
        vm.prank(payer); // Included even though it happened after scheduling.
        minter.mint(1);
        vm.warp(block.timestamp + 2 days);
        timelock.executeBatch(targets, values, calls, 0, "switch");
        assertEq(token.minter(), address(next));
        assertEq(token.firstMinter(), address(minter));
        assertTrue(minter.retired());
        assertEq(minter.successor(), address(next));
        assertEq(next.mintedTotal(), amount);
        assertEq(next.authorizedMintTotal(), CAP);
        assertEq(next.remainingMintAuthorization(), CAP - amount);
        assertEq(token.totalSupply(), 1);
        assertFalse(vault.emergencyPaused());
        vault.executeWithdrawal(id); // Routine replacement did not invalidate the queue.
        vm.prank(payer);
        vm.expectRevert(OpenTokenMinter.MintUnavailable.selector);
        minter.mint(1);
        vm.prank(address(timelock));
        vm.expectRevert(OpenTokenMinter.MintUnavailable.selector);
        minter.increaseMintAuthorization(CAP + 1);
        vm.prank(address(timelock));
        token.setMinter(address(next), address(minter));
        vm.prank(payer);
        vm.expectRevert(OpenTokenMinter.MintUnavailable.selector);
        minter.mint(1);
    }

    function testRevertingBatchRollsBackRetirementAndPointerAndCanRetry() public {
        OpenTokenMinter next = candidate();
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) = batch(next);
        calls[2] = abi.encodeCall(next.increaseMintAuthorization, (CAP + 1));
        timelock.scheduleBatch(targets, values, calls, 0, "bad", 2 days);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(OpenTokenMinter.MintUnavailable.selector);
        timelock.executeBatch(targets, values, calls, 0, "bad");
        assertFalse(minter.retired());
        assertEq(minter.successor(), address(0));
        assertEq(token.minter(), address(minter));
        assertFalse(next.initialized());
        vm.prank(payer);
        minter.mint(1);
    }

    function testTokenOnlySelectedMinterCanMintAndNoZeroOrStaleSwitch() public {
        vm.expectRevert(OpenToken.Unauthorized.selector);
        token.mint(payer, 1);
        vm.expectRevert(OpenToken.Unauthorized.selector);
        token.setMinter(address(minter), address(this));
        vm.startPrank(address(timelock));
        vm.expectRevert(OpenToken.StaleMinter.selector);
        token.setMinter(address(0), address(this));
        address[5] memory bad =
            [address(0), payer, address(token), address(timelock), address(minter)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(OpenToken.InvalidConfiguration.selector);
            token.setMinter(address(minter), bad[i]);
        }
        vm.stopPrank();
        vm.startPrank(address(minter));
        vm.expectRevert(OpenToken.InvalidAmount.selector);
        token.mint(payer, 0);
        vm.expectRevert(OpenToken.InvalidRecipient.selector);
        token.mint(address(0), 1);
        vm.expectRevert(OpenToken.InvalidRecipient.selector);
        token.mint(address(token), 1);
        vm.stopPrank();
    }

    function testFuzzTokenConstructorRequiresGovernanceCode(bool self) public {
        address governance =
            self ? vm.computeCreateAddress(address(this), vm.getNonce(address(this))) : payer;
        vm.expectRevert(OpenToken.InvalidConfiguration.selector);
        new OpenToken(governance, address(minter));
    }

    function testGenesisCannotBeReplayedAfterBurnToZero() public {
        assertTrue(minter.initialized());
        assertEq(token.firstMinter(), address(minter));
        assertEq(minter.authorizedMintTotal(), CAP);
        vm.startPrank(payer);
        minter.mint(10);
        token.burn(10);
        vm.stopPrank();
        assertEq(token.totalSupply(), 0);
        vm.expectRevert(OpenTokenMinter.InvalidInitialization.selector);
        new OpenTokenMinter(config(address(0)));
        vm.prank(address(timelock));
        (bool ok,) =
            address(minter).call(abi.encodeWithSignature("initializeGenesis(uint256)", CAP));
        assertFalse(ok);
        assertEq(minter.mintedTotal(), 10);
    }

    function testFuzzGenesisTokenRejectsInvalidFirstMinter(uint8 raw) public {
        address next = raw % 3 == 0
            ? address(0)
            : raw % 3 == 1
                ? address(timelock)
                : vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(OpenToken.InvalidConfiguration.selector);
        new OpenToken(address(timelock), next);
    }

    function testReplacementCannotSupplyFreshAuthorization() public {
        OpenTokenMinter.Configuration memory c = config(address(minter));
        c.initialAuthorization = CAP;
        vm.expectRevert(OpenTokenMinter.InvalidInitialization.selector);
        new OpenTokenMinter(c);
    }

    function testGenesisDeploymentRollsBackAllChildrenAndRetainsNoAuthority() public {
        uint64 nonce = vm.getNonce(address(this));
        address genesisAddress = vm.computeCreateAddress(address(this), nonce);
        vm.expectRevert();
        deploySuite(usdc, address(0), address(timelock), address(this), CAP);
        assertEq(genesisAddress.code.length, 0);
        for (uint256 i = 1; i <= 3; ++i) {
            assertEq(vm.computeCreateAddress(genesisAddress, i).code.length, 0);
        }
        (OpenToken fresh,, OpenTokenMinter first) =
            deploySuite(usdc, finance, address(timelock), address(this), CAP);
        assertEq(fresh.totalSupply(), 0);
        assertEq(first.mintedTotal(), 0);
        assertTrue(first.initialized());
        vm.expectRevert(OpenToken.Unauthorized.selector);
        fresh.setMinter(address(first), address(this));
        vm.expectRevert(OpenTokenMinter.Unauthorized.selector);
        first.increaseMintAuthorization(CAP + 1);
        vm.prank(genesisAddress);
        vm.expectRevert(OpenToken.Unauthorized.selector);
        fresh.setMinter(address(first), address(this));
    }

    function testUninitializedInactiveAndWrongPredecessorCannotIssueOrInitialize() public {
        OpenTokenMinter next = candidate();
        vm.expectRevert(OpenTokenMinter.MintUnavailable.selector);
        next.mint(1);
        vm.expectRevert(OpenTokenMinter.Unauthorized.selector);
        next.initializeFromPredecessor();
        vm.expectRevert(OpenTokenMinter.Unauthorized.selector);
        minter.retire(address(next));
        vm.startPrank(address(timelock));
        vm.expectRevert(OpenTokenMinter.InvalidInitialization.selector);
        next.initializeFromPredecessor();
        token.setMinter(address(minter), address(next));
        vm.expectRevert(OpenTokenMinter.InvalidInitialization.selector);
        next.initializeFromPredecessor();
        token.setMinter(address(next), address(minter));
        vm.expectRevert(OpenTokenMinter.InvalidInitialization.selector);
        minter.initializeFromPredecessor();
        vm.stopPrank();
        vm.prank(payer);
        vm.expectRevert(OpenTokenMinter.InvalidRecipient.selector);
        minter.mintTo(1, address(minter));
    }

    function payment(address from, address executor)
        private
        view
        returns (OpenTokenMinter.PaymentAuthorization memory)
    {
        return OpenTokenMinter.PaymentAuthorization(
            from, payer, executor, 10e6, 0, block.timestamp + 3 days, "payment"
        );
    }

    function sign(OpenTokenMinter target, OpenTokenMinter.PaymentAuthorization memory order)
        private
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, target.paymentDigest(order));
        return abi.encodePacked(r, s, v);
    }

    function testFuzzPaymentConsentBindsTermsAndDomain(uint8 raw) public {
        OpenTokenMinter.PaymentAuthorization memory order = payment(payer, address(this));
        bytes memory signature = sign(minter, order);
        uint256 mode = bound(raw, 0, 10);
        if (mode == 0) order.payer = address(0);
        if (mode == 1) order.payer = finance;
        if (mode == 2) order.recipient = finance;
        if (mode == 3) order.executor = payer;
        if (mode == 4) order.amount++;
        if (mode == 5) order.validAfter = block.timestamp;
        if (mode == 6) order.validBefore++;
        if (mode == 7) order.nonce = "other";
        if (mode == 8) vm.chainId(block.chainid + 1);
        if (mode == 9) {
            OpenTokenMinter other = candidate();
            signature = sign(other, order);
        }
        if (mode == 10) vm.warp(order.validBefore);
        vm.expectRevert(OpenTokenMinter.InvalidPaymentAuthorization.selector);
        minter.mintWithAuthorization(order, signature);
        assertEq(minter.mintedTotal(), 0);
    }

    function testPayerConsentReplayCancellationAndPaymentRollback() public {
        OpenTokenMinter.PaymentAuthorization memory order = payment(payer, address(this));
        bytes memory signature = sign(minter, order);
        usdc.setFault(PaidOpenTokenUsdcFixture.Fault.ShortReceipt);
        vm.expectRevert();
        minter.mintWithAuthorization(order, signature);
        assertFalse(minter.authorizationUsed(payer, order.nonce));
        usdc.setFault(PaidOpenTokenUsdcFixture.Fault.None);
        minter.mintWithAuthorization(order, signature);
        assertTrue(minter.authorizationUsed(payer, order.nonce));
        vm.expectRevert(OpenTokenMinter.InvalidPaymentAuthorization.selector);
        minter.mintWithAuthorization(order, signature);
        order.nonce = "cancelled";
        signature = sign(minter, order);
        vm.prank(payer);
        minter.cancelAuthorization(order.nonce);
        vm.expectRevert(OpenTokenMinter.InvalidPaymentAuthorization.selector);
        minter.mintWithAuthorization(order, signature);
    }

    function testContractPayerConsentAndCapIncreasePurchaseAreOneBatch() public {
        vm.prank(payer);
        minter.mint(CAP);
        ContractPayerFixture company = new ContractPayerFixture();
        usdc.seed(address(company), 10e6);
        company.approve(usdc, address(minter));
        OpenTokenMinter.PaymentAuthorization memory order =
            payment(address(company), address(timelock));
        company.approveDigest(minter.paymentDigest(order));
        address[] memory targets = new address[](2);
        targets[0] = address(minter);
        targets[1] = address(minter);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(minter.increaseMintAuthorization, (CAP + 20e6));
        calls[1] =
            abi.encodeCall(minter.mintWithAuthorization, (order, bytes("contract signature")));
        timelock.scheduleBatch(targets, values, calls, 0, "priority", 2 days);
        vm.warp(block.timestamp + 2 days);
        company.approveDigest(bytes32(0));
        vm.expectRevert(OpenTokenMinter.InvalidPaymentAuthorization.selector);
        timelock.executeBatch(targets, values, calls, 0, "priority");
        assertEq(minter.authorizedMintTotal(), CAP);
        company.approveDigest(minter.paymentDigest(order));
        timelock.executeBatch(targets, values, calls, 0, "priority");
        assertEq(minter.mintedTotal(), CAP + 10e6);
        assertEq(minter.remainingMintAuthorization(), 10e6);
        vm.prank(payer); // Remaining capacity remains public.
        minter.mint(10e6);
    }

    function testFuzzMinterConstructorRejectsMismatchedBindings(uint8 raw) public {
        OpenTokenMinter.Configuration memory c = config(address(minter));
        uint256 mode = bound(raw, 0, 9);
        if (mode == 0) c.token = OpenToken(payer);
        if (mode == 1) c.usdc = IERC20(payer);
        if (mode == 2) c.treasuryVault = TreasuryVault(payer);
        if (mode == 3) c.governanceTimelock = payer;
        if (mode == 4) c.usdc = IERC20(address(new PaidOpenTokenUsdcFixture(18)));
        if (mode == 5) c.governanceTimelock = finance;
        if (mode == 6) c.token = new OpenToken(address(timelock), address(minter));
        if (mode == 7) c.usdc = IERC20(address(new PaidOpenTokenUsdcFixture(6)));
        if (mode == 8) c.predecessor = payer;
        if (mode == 9) {
            c.treasuryVault = new TreasuryVault(
                usdc, IERC20(address(token)), finance, address(this), address(this)
            );
        }
        vm.expectRevert(OpenTokenMinter.InvalidConfiguration.selector);
        new OpenTokenMinter(c);
    }

    function testRetirementRejectsUnboundOrAlreadyInitializedSuccessor() public {
        OpenTokenMinter wrong = new OpenTokenMinter(config(address(token)));
        vm.startPrank(address(timelock));
        vm.expectRevert(OpenTokenMinter.InvalidConfiguration.selector);
        minter.retire(address(0));
        vm.expectRevert(OpenTokenMinter.InvalidConfiguration.selector);
        minter.retire(address(minter));
        vm.expectRevert(OpenTokenMinter.InvalidConfiguration.selector);
        minter.retire(address(wrong));
        vm.stopPrank();
        OpenTokenMinter next = candidate();
        vm.mockCall(address(next), abi.encodeWithSignature("initialized()"), abi.encode(true));
        vm.prank(address(timelock));
        vm.expectRevert(OpenTokenMinter.InvalidConfiguration.selector);
        minter.retire(address(next));
    }

    function testImportRejectsImpossibleCountersAndCannotInitializeTwice() public {
        OpenTokenMinter next = candidate();
        vm.startPrank(address(timelock));
        minter.retire(address(next));
        token.setMinter(address(minter), address(next));
        vm.mockCall(address(minter), abi.encodeWithSignature("mintedTotal()"), abi.encode(CAP + 1));
        vm.expectRevert(OpenTokenMinter.InvalidInitialization.selector);
        next.initializeFromPredecessor();
        assertFalse(next.initialized());
        vm.clearMockedCalls();
        next.initializeFromPredecessor();
        vm.expectRevert(OpenTokenMinter.InvalidInitialization.selector);
        next.initializeFromPredecessor();
        vm.stopPrank();
    }
}
