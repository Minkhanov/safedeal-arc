// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeDeal, IStablecoin} from "../src/SafeDeal.sol";
import {MockStablecoin} from "./mocks/MockStablecoin.sol";
import {GasBurnerToken} from "./mocks/GasBurnerToken.sol";

contract SafeDealTest is Test {
    SafeDeal internal sd;
    MockStablecoin internal usdc;
    MockStablecoin internal eurc;

    uint256 internal clientKey = 0xC11E;
    address internal client;
    address internal provider = makeAddr("provider");
    address internal arbiter = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");

    uint96 internal constant M0 = 100e6; // 100 USDC
    uint96 internal constant M1 = 250e6;
    uint96 internal constant M2 = 150e6;
    uint96 internal constant TOTAL = M0 + M1 + M2;
    uint32 internal constant REVIEW = 3 days;
    uint64 internal constant T0 = 1_790_000_000;
    uint64 internal constant DEADLINE = T0 + 30 days;

    event DealCreated(
        uint256 indexed dealId,
        address indexed client,
        address indexed provider,
        address arbiter,
        address token,
        uint256 total,
        string terms
    );
    event DealAccepted(uint256 indexed dealId);
    event DealCancelled(uint256 indexed dealId, address indexed by);
    event DealClosed(uint256 indexed dealId);
    event DeadlineExtended(uint256 indexed dealId, uint64 deadline);
    event MilestoneDelivered(uint256 indexed dealId, uint256 indexed index, string note);
    event MilestoneDisputed(uint256 indexed dealId, uint256 indexed index, string reason);
    event SettlementProposed(uint256 indexed dealId, uint256 indexed index, address indexed by, uint256 toProvider);
    event MilestoneClosed(
        uint256 indexed dealId,
        uint256 indexed index,
        SafeDeal.Resolution resolution,
        uint256 toProvider,
        uint256 toClient
    );
    event PayoutDeferred(address indexed token, address indexed account, uint256 amount);
    event Withdrawn(address indexed token, address indexed account, uint256 amount);

    function setUp() public {
        vm.warp(T0);
        usdc = new MockStablecoin("USDC");
        eurc = new MockStablecoin("EURC");
        sd = new SafeDeal(IStablecoin(address(usdc)), IStablecoin(address(eurc)));
        client = vm.addr(clientKey);
        usdc.mint(client, 10_000e6);
        eurc.mint(client, 10_000e6);
        usdc.mint(stranger, 10_000e6);
    }

    // ------------------------------------------------------------ helpers

    function _params(address arb, address token) internal view returns (SafeDeal.DealParams memory p) {
        string[] memory names = new string[](3);
        names[0] = "Design";
        names[1] = "Build";
        names[2] = "Launch";
        uint96[] memory amounts = new uint96[](3);
        amounts[0] = M0;
        amounts[1] = M1;
        amounts[2] = M2;
        p = SafeDeal.DealParams({
            provider: provider,
            arbiter: arb,
            token: token,
            deadline: DEADLINE,
            reviewPeriod: REVIEW,
            title: "Landing page for Acme",
            terms: "Three milestones. Source code in a public repo.",
            milestoneNames: names,
            milestoneAmounts: amounts
        });
    }

    function _p() internal view returns (SafeDeal.DealParams memory) {
        return _params(arbiter, address(usdc));
    }

    function _single(uint96 amount, address arb) internal view returns (SafeDeal.DealParams memory p) {
        p = _params(arb, address(usdc));
        string[] memory names = new string[](1);
        names[0] = "Job";
        uint96[] memory amounts = new uint96[](1);
        amounts[0] = amount;
        p.milestoneNames = names;
        p.milestoneAmounts = amounts;
    }

    function _create(SafeDeal.DealParams memory p) internal returns (uint256 id) {
        vm.startPrank(client);
        MockStablecoin(p.token).approve(address(sd), type(uint256).max);
        id = sd.createDeal(p);
        vm.stopPrank();
    }

    function _createActive(SafeDeal.DealParams memory p) internal returns (uint256 id) {
        id = _create(p);
        vm.prank(provider);
        sd.accept(id);
    }

    function _active() internal returns (uint256) {
        return _createActive(_p());
    }

    function _deliver(uint256 id, uint256 index) internal {
        vm.prank(provider);
        sd.deliver(id, index, "https://example.com/work");
    }

    function _disputed(SafeDeal.DealParams memory p) internal returns (uint256 id) {
        id = _createActive(p);
        _deliver(id, 0);
        vm.prank(client);
        sd.dispute(id, 0, "Not what we agreed");
    }

    function _permitSig(uint256 key, MockStablecoin token, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(key);
        bytes32 structHash =
            keccak256(abi.encode(token.PERMIT_TYPEHASH(), owner, address(sd), value, token.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(key, digest);
    }

    function _assertAccounting(address token) internal view {
        assertEq(
            MockStablecoin(token).balanceOf(address(sd)),
            sd.totalLocked(token) + sd.totalClaimable(token),
            "escrow balance == locked + claimable"
        );
    }

    // ------------------------------------------------------------ constructor

    function test_RevertWhen_TokenHasNoCode() public {
        vm.expectRevert(SafeDeal.InvalidToken.selector);
        new SafeDeal(IStablecoin(address(0x1234)), IStablecoin(address(eurc)));
        vm.expectRevert(SafeDeal.InvalidToken.selector);
        new SafeDeal(IStablecoin(address(usdc)), IStablecoin(address(0x1234)));
        vm.expectRevert(SafeDeal.InvalidToken.selector);
        new SafeDeal(IStablecoin(address(usdc)), IStablecoin(address(usdc)));
    }

    function test_EurcIsOptional() public {
        SafeDeal only = new SafeDeal(IStablecoin(address(usdc)), IStablecoin(address(0)));
        assertTrue(only.isSupportedToken(address(usdc)));
        assertFalse(only.isSupportedToken(address(eurc)));
        assertFalse(only.isSupportedToken(address(0)));
    }

    // ------------------------------------------------------------ create

    function test_CreateDeal_StoresTermsAndPullsFunds() public {
        SafeDeal.DealParams memory p = _p();
        vm.prank(client);
        usdc.approve(address(sd), TOTAL);

        vm.expectEmit(true, true, true, true, address(sd));
        emit DealCreated(1, client, provider, arbiter, address(usdc), TOTAL, p.terms);
        vm.prank(client);
        uint256 id = sd.createDeal(p);

        assertEq(id, 1);
        SafeDeal.Deal memory d = sd.getDeal(id);
        assertEq(d.client, client);
        assertEq(d.provider, provider);
        assertEq(d.arbiter, arbiter);
        assertEq(d.token, address(usdc));
        assertEq(d.total, TOTAL);
        assertEq(d.locked, TOTAL);
        assertEq(d.deadline, DEADLINE);
        assertEq(d.reviewPeriod, REVIEW);
        assertEq(d.milestoneCount, 3);
        assertEq(d.openMilestones, 3);
        assertEq(uint8(d.status), uint8(SafeDeal.DealStatus.Open));
        assertEq(d.createdBlock, block.number);
        assertEq(d.termsHash, keccak256(bytes(p.terms)));
        assertEq(d.title, "Landing page for Acme");

        SafeDeal.Milestone[] memory ms = sd.getMilestones(id);
        assertEq(ms.length, 3);
        assertEq(ms[1].amount, M1);
        assertEq(ms[1].name, "Build");
        assertEq(uint8(ms[1].status), uint8(SafeDeal.MilestoneStatus.Pending));

        assertEq(usdc.balanceOf(address(sd)), TOTAL);
        assertEq(usdc.balanceOf(client), 10_000e6 - TOTAL);
        assertEq(sd.totalLocked(address(usdc)), TOTAL);
        assertEq(sd.dealsOf(client, 0, 10)[0], id);
        assertEq(sd.dealsOf(provider, 0, 10)[0], id);
        assertEq(sd.dealsOf(arbiter, 0, 10)[0], id);
        _assertAccounting(address(usdc));
    }

    function test_CreateDealWithPermit_OneTransaction() public {
        SafeDeal.DealParams memory p = _p();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(clientKey, usdc, TOTAL, deadline);
        assertEq(usdc.allowance(client, address(sd)), 0);
        vm.prank(client);
        uint256 id = sd.createDealWithPermit(p, TOTAL, deadline, v, r, s);
        assertEq(sd.getDeal(id).locked, TOTAL);
        assertEq(usdc.balanceOf(address(sd)), TOTAL);
        assertEq(usdc.allowance(client, address(sd)), 0, "permit allowance fully used");
    }

    function test_CreateDealWithPermit_FrontRunPermitCannotBlock() public {
        SafeDeal.DealParams memory p = _p();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(clientKey, usdc, TOTAL, deadline);
        // An observer replays the signature first; the allowance is set and the nonce consumed.
        vm.prank(stranger);
        usdc.permit(client, address(sd), TOTAL, deadline, v, r, s);
        vm.prank(client);
        uint256 id = sd.createDealWithPermit(p, TOTAL, deadline, v, r, s);
        assertEq(sd.getDeal(id).locked, TOTAL);
    }

    function test_RevertWhen_PermitWithUnsupportedToken() public {
        MockStablecoin other = new MockStablecoin("XYZ");
        SafeDeal.DealParams memory p = _params(arbiter, address(other));
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.UnsupportedToken.selector, address(other)));
        vm.prank(client);
        sd.createDealWithPermit(p, TOTAL, block.timestamp, 27, bytes32(0), bytes32(0));
    }

    function test_CreateDeal_InEurc_SeparateAccounting() public {
        uint256 a = _create(_params(arbiter, address(eurc)));
        uint256 b = _create(_p());
        assertEq(sd.getDeal(a).token, address(eurc));
        assertEq(sd.totalLocked(address(eurc)), TOTAL);
        assertEq(sd.totalLocked(address(usdc)), TOTAL);
        assertEq(eurc.balanceOf(address(sd)), TOTAL);
        assertEq(b, 2);
        _assertAccounting(address(eurc));
        _assertAccounting(address(usdc));
    }

    function test_CreateDeal_WithoutArbiterOrTerms() public {
        SafeDeal.DealParams memory p = _params(address(0), address(usdc));
        p.terms = "";
        uint256 id = _create(p);
        assertEq(sd.getDeal(id).arbiter, address(0));
        assertEq(sd.getDeal(id).termsHash, bytes32(0));
        assertEq(sd.dealCountOf(address(0)), 0, "no index entry for a missing arbiter");
    }

    function test_RevertWhen_CreateParamsInvalid() public {
        vm.startPrank(client);
        usdc.approve(address(sd), type(uint256).max);
        SafeDeal.DealParams memory p;

        p = _p();
        p.token = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.UnsupportedToken.selector, address(0xBEEF)));
        sd.createDeal(p);

        p = _p();
        p.provider = address(0);
        vm.expectRevert(SafeDeal.InvalidParties.selector);
        sd.createDeal(p);

        p = _p();
        p.provider = client;
        vm.expectRevert(SafeDeal.InvalidParties.selector);
        sd.createDeal(p);

        p = _p();
        p.arbiter = client;
        vm.expectRevert(SafeDeal.InvalidParties.selector);
        sd.createDeal(p);

        p = _p();
        p.arbiter = provider;
        vm.expectRevert(SafeDeal.InvalidParties.selector);
        sd.createDeal(p);

        p = _p();
        p.provider = address(sd);
        vm.expectRevert(SafeDeal.InvalidParties.selector);
        sd.createDeal(p);

        p = _p();
        p.milestoneAmounts = new uint96[](0);
        p.milestoneNames = new string[](0);
        vm.expectRevert(SafeDeal.InvalidMilestones.selector);
        sd.createDeal(p);

        p = _p();
        p.milestoneAmounts = new uint96[](11);
        p.milestoneNames = new string[](11);
        vm.expectRevert(SafeDeal.InvalidMilestones.selector);
        sd.createDeal(p);

        p = _p();
        p.milestoneNames = new string[](2);
        vm.expectRevert(SafeDeal.InvalidMilestones.selector);
        sd.createDeal(p);

        p = _p();
        p.milestoneAmounts[1] = 0;
        vm.expectRevert(SafeDeal.InvalidAmount.selector);
        sd.createDeal(p);

        p = _p();
        p.milestoneNames[2] = "";
        vm.expectRevert(SafeDeal.InvalidName.selector);
        sd.createDeal(p);

        p = _p();
        p.milestoneNames[2] = string(new bytes(32));
        vm.expectRevert(SafeDeal.InvalidName.selector);
        sd.createDeal(p);

        p = _p();
        p.title = "";
        vm.expectRevert(SafeDeal.InvalidTitle.selector);
        sd.createDeal(p);

        p = _p();
        p.title = string(new bytes(65));
        vm.expectRevert(SafeDeal.InvalidTitle.selector);
        sd.createDeal(p);

        p = _p();
        p.terms = string(new bytes(4097));
        vm.expectRevert(SafeDeal.TermsTooLong.selector);
        sd.createDeal(p);

        p = _p();
        p.deadline = T0;
        vm.expectRevert(SafeDeal.InvalidDeadline.selector);
        sd.createDeal(p);

        p = _p();
        p.deadline = T0 + 3 * 365 days + 1;
        vm.expectRevert(SafeDeal.InvalidDeadline.selector);
        sd.createDeal(p);

        p = _p();
        p.reviewPeriod = 59;
        vm.expectRevert(SafeDeal.InvalidReviewPeriod.selector);
        sd.createDeal(p);

        p = _p();
        p.reviewPeriod = 90 days + 1;
        vm.expectRevert(SafeDeal.InvalidReviewPeriod.selector);
        sd.createDeal(p);

        p = _p();
        p.milestoneAmounts[0] = type(uint96).max;
        vm.expectRevert(SafeDeal.InvalidAmount.selector);
        sd.createDeal(p);
        vm.stopPrank();
    }

    function test_RevertWhen_AllowanceMissing_BubblesTokenReason() public {
        SafeDeal.DealParams memory p = _p();
        vm.expectRevert(bytes("ERC20: transfer amount exceeds allowance"));
        vm.prank(client);
        sd.createDeal(p);
    }

    // ------------------------------------------------------------ accept, cancel, decline

    function test_Accept_OnlyProviderOnlyOnce() public {
        uint256 id = _create(_p());
        vm.prank(stranger);
        vm.expectRevert(SafeDeal.NotProvider.selector);
        sd.accept(id);

        vm.expectEmit(true, false, false, false, address(sd));
        emit DealAccepted(id);
        vm.prank(provider);
        sd.accept(id);
        assertEq(uint8(sd.getDeal(id).status), uint8(SafeDeal.DealStatus.Active));

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.WrongDealStatus.selector, SafeDeal.DealStatus.Active));
        sd.accept(id);
    }

    function test_RevertWhen_AcceptAfterDeadline() public {
        uint256 id = _create(_p());
        vm.warp(DEADLINE + 1);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.DeadlinePassed.selector, DEADLINE));
        sd.accept(id);
    }

    function test_RevertWhen_UnknownDeal() public {
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.UnknownDeal.selector, 7));
        sd.accept(7);
    }

    function test_Cancel_BeforeAcceptance_RefundsEverything() public {
        uint256 id = _create(_p());
        vm.prank(provider);
        vm.expectRevert(SafeDeal.NotClient.selector);
        sd.cancel(id);

        vm.expectEmit(true, true, false, false, address(sd));
        emit DealCancelled(id, client);
        vm.prank(client);
        sd.cancel(id);

        assertEq(usdc.balanceOf(client), 10_000e6);
        assertEq(usdc.balanceOf(address(sd)), 0);
        SafeDeal.Deal memory d = sd.getDeal(id);
        assertEq(uint8(d.status), uint8(SafeDeal.DealStatus.Cancelled));
        assertEq(d.locked, 0);
        assertEq(d.openMilestones, 0);
        SafeDeal.Milestone[] memory ms = sd.getMilestones(id);
        for (uint256 i = 0; i < ms.length; i++) {
            assertEq(uint8(ms[i].status), uint8(SafeDeal.MilestoneStatus.Closed));
            assertEq(uint8(ms[i].resolution), uint8(SafeDeal.Resolution.DealCancelled));
        }
        assertEq(sd.totalLocked(address(usdc)), 0);
    }

    function test_Decline_RefundsEverything() public {
        uint256 id = _create(_p());
        vm.prank(stranger);
        vm.expectRevert(SafeDeal.NotProvider.selector);
        sd.decline(id);
        vm.prank(provider);
        sd.decline(id);
        assertEq(usdc.balanceOf(client), 10_000e6);
        assertEq(uint8(sd.getDeal(id).status), uint8(SafeDeal.DealStatus.Cancelled));
    }

    function test_RevertWhen_CancelAfterAcceptance() public {
        uint256 id = _active();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.WrongDealStatus.selector, SafeDeal.DealStatus.Active));
        sd.cancel(id);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.WrongDealStatus.selector, SafeDeal.DealStatus.Active));
        sd.decline(id);
    }

    function test_RevertWhen_WorkingOnUnacceptedDeal() public {
        uint256 id = _create(_p());
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.WrongDealStatus.selector, SafeDeal.DealStatus.Open));
        sd.deliver(id, 0, "");
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.WrongDealStatus.selector, SafeDeal.DealStatus.Open));
        sd.approveMilestone(id, 0);
    }

    // ------------------------------------------------------------ deliver, approve, release

    function test_Deliver_RecordsNoteBlockAndReviewWindow() public {
        uint256 id = _active();
        vm.roll(vm.getBlockNumber() + 5);
        vm.expectEmit(true, true, false, true, address(sd));
        emit MilestoneDelivered(id, 1, "https://github.com/acme/site/pull/1");
        vm.prank(provider);
        sd.deliver(id, 1, "https://github.com/acme/site/pull/1");
        SafeDeal.Milestone memory m = sd.getMilestone(id, 1);
        assertEq(uint8(m.status), uint8(SafeDeal.MilestoneStatus.Delivered));
        assertEq(m.deliveredAt, block.timestamp);
        assertEq(m.deliveredBlock, block.number);
        assertEq(sd.reviewEndsAt(id, 1), block.timestamp + REVIEW);
        assertEq(sd.reviewEndsAt(id, 0), 0, "not under review");
        assertEq(sd.reviewEndsAt(id, 9), 0, "out of range");
    }

    function test_RevertWhen_DeliverInvalid() public {
        uint256 id = _active();
        vm.prank(client);
        vm.expectRevert(SafeDeal.NotProvider.selector);
        sd.deliver(id, 0, "");

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.UnknownMilestone.selector, id, 3));
        sd.deliver(id, 3, "");

        vm.prank(provider);
        vm.expectRevert(SafeDeal.NoteTooLong.selector);
        sd.deliver(id, 0, string(new bytes(513)));

        vm.warp(DEADLINE + 1);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.DeadlinePassed.selector, DEADLINE));
        sd.deliver(id, 0, "");
    }

    function test_Redeliver_RestartsReviewAndClearsOffers() public {
        uint256 id = _active();
        _deliver(id, 0);
        vm.prank(client);
        sd.proposeSettlement(id, 0, M0 / 2);
        vm.warp(T0 + 2 days);
        vm.prank(provider);
        sd.deliver(id, 0, "v2 with fixes");
        SafeDeal.Milestone memory m = sd.getMilestone(id, 0);
        assertEq(m.deliveredAt, T0 + 2 days);
        assertFalse(m.clientOffered, "old offer cleared");
        // Re-delivering is allowed after the deadline: it only extends the client's review.
        vm.warp(DEADLINE + 1);
        vm.prank(provider);
        sd.deliver(id, 0, "v3");
        assertEq(sd.reviewEndsAt(id, 0), DEADLINE + 1 + REVIEW);
    }

    function test_Approve_PaysProviderInFull_EvenBeforeDelivery() public {
        uint256 id = _active();
        vm.prank(stranger);
        vm.expectRevert(SafeDeal.NotClient.selector);
        sd.approveMilestone(id, 0);

        vm.expectEmit(true, true, false, true, address(sd));
        emit MilestoneClosed(id, 0, SafeDeal.Resolution.Approved, M0, 0);
        vm.prank(client);
        sd.approveMilestone(id, 0);
        assertEq(usdc.balanceOf(provider), M0);
        SafeDeal.Milestone memory m = sd.getMilestone(id, 0);
        assertEq(uint8(m.status), uint8(SafeDeal.MilestoneStatus.Closed));
        assertEq(m.toProvider, M0);
        assertEq(sd.getDeal(id).locked, M1 + M2);
        assertEq(sd.getDeal(id).openMilestones, 2);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.WrongMilestoneStatus.selector, SafeDeal.MilestoneStatus.Closed));
        sd.approveMilestone(id, 0);
        _assertAccounting(address(usdc));
    }

    function test_ReleaseAfterReview_ByAnyone() public {
        uint256 id = _active();
        _deliver(id, 1);
        uint64 endsAt = uint64(vm.getBlockTimestamp()) + REVIEW;
        vm.warp(endsAt - 1);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.ReviewPeriodNotOver.selector, endsAt));
        sd.releaseAfterReview(id, 1);

        vm.warp(endsAt);
        vm.prank(stranger);
        sd.releaseAfterReview(id, 1);
        assertEq(usdc.balanceOf(provider), M1);
        assertEq(uint8(sd.getMilestone(id, 1).resolution), uint8(SafeDeal.Resolution.ReviewTimeout));
    }

    function test_RevertWhen_ReleaseUndelivered() public {
        uint256 id = _active();
        vm.warp(DEADLINE + 365 days);
        vm.expectRevert(
            abi.encodeWithSelector(SafeDeal.WrongMilestoneStatus.selector, SafeDeal.MilestoneStatus.Pending)
        );
        sd.releaseAfterReview(id, 0);
    }

    function test_DealClosesAfterLastMilestone() public {
        uint256 id = _active();
        vm.startPrank(client);
        sd.approveMilestone(id, 0);
        sd.approveMilestone(id, 1);
        vm.expectEmit(true, false, false, false, address(sd));
        emit DealClosed(id);
        sd.approveMilestone(id, 2);
        vm.stopPrank();
        SafeDeal.Deal memory d = sd.getDeal(id);
        assertEq(uint8(d.status), uint8(SafeDeal.DealStatus.Closed));
        assertEq(d.locked, 0);
        assertEq(usdc.balanceOf(provider), TOTAL);
        assertEq(usdc.balanceOf(address(sd)), 0);
        // Nothing else can happen on a closed deal.
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.WrongDealStatus.selector, SafeDeal.DealStatus.Closed));
        sd.deliver(id, 0, "");
    }

    // ------------------------------------------------------------ refund, reclaim, deadline

    function test_ProviderRefund() public {
        uint256 id = _active();
        _deliver(id, 2);
        vm.prank(client);
        vm.expectRevert(SafeDeal.NotProvider.selector);
        sd.refund(id, 2);
        vm.prank(provider);
        sd.refund(id, 2);
        assertEq(usdc.balanceOf(client), 10_000e6 - TOTAL + M2);
        assertEq(uint8(sd.getMilestone(id, 2).resolution), uint8(SafeDeal.Resolution.RefundedByProvider));
    }

    function test_ReclaimAfterDeadline_OnlyUndeliveredMilestones() public {
        uint256 id = _active();
        _deliver(id, 0);
        vm.warp(DEADLINE);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.DeadlineNotPassed.selector, DEADLINE));
        sd.reclaimAfterDeadline(id, 1);

        vm.warp(DEADLINE + 1);
        vm.prank(stranger);
        vm.expectRevert(SafeDeal.NotClient.selector);
        sd.reclaimAfterDeadline(id, 1);

        vm.startPrank(client);
        vm.expectRevert(
            abi.encodeWithSelector(SafeDeal.WrongMilestoneStatus.selector, SafeDeal.MilestoneStatus.Delivered)
        );
        sd.reclaimAfterDeadline(id, 0);
        sd.reclaimAfterDeadline(id, 1);
        sd.reclaimAfterDeadline(id, 2);
        vm.stopPrank();
        assertEq(usdc.balanceOf(client), 10_000e6 - M0);
        // The delivered milestone still follows its review rules.
        sd.releaseAfterReview(id, 0);
        assertEq(usdc.balanceOf(provider), M0);
        assertEq(uint8(sd.getDeal(id).status), uint8(SafeDeal.DealStatus.Closed));
    }

    function test_ExtendDeadline_LetsProviderDeliverLate() public {
        uint256 id = _active();
        uint64 later = DEADLINE + 10 days;
        vm.prank(provider);
        vm.expectRevert(SafeDeal.NotClient.selector);
        sd.extendDeadline(id, later);

        vm.startPrank(client);
        vm.expectRevert(SafeDeal.InvalidDeadline.selector);
        sd.extendDeadline(id, DEADLINE);
        vm.expectRevert(SafeDeal.InvalidDeadline.selector);
        sd.extendDeadline(id, T0 + 3 * 365 days + 1);
        vm.expectEmit(true, false, false, true, address(sd));
        emit DeadlineExtended(id, later);
        sd.extendDeadline(id, later);
        vm.stopPrank();

        vm.warp(DEADLINE + 5 days);
        _deliver(id, 0);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.DeadlineNotPassed.selector, later));
        sd.reclaimAfterDeadline(id, 1);
    }

    function test_ExtendDeadline_AfterItPassed() public {
        uint256 id = _active();
        vm.warp(DEADLINE + 1 days);
        vm.prank(client);
        vm.expectRevert(SafeDeal.InvalidDeadline.selector);
        sd.extendDeadline(id, DEADLINE + 1 hours); // later than the old deadline but already in the past
        vm.prank(client);
        sd.extendDeadline(id, DEADLINE + 2 days);
        _deliver(id, 0);
    }

    // ------------------------------------------------------------ disputes

    function test_Dispute_StopsReviewTimer() public {
        uint256 id = _active();
        _deliver(id, 0);
        vm.expectEmit(true, true, false, true, address(sd));
        emit MilestoneDisputed(id, 0, "Broken on mobile");
        vm.prank(client);
        sd.dispute(id, 0, "Broken on mobile");
        SafeDeal.Milestone memory m = sd.getMilestone(id, 0);
        assertEq(uint8(m.status), uint8(SafeDeal.MilestoneStatus.Disputed));
        assertEq(m.disputedAt, block.timestamp);
        assertEq(m.disputedBlock, block.number);

        vm.warp(block.timestamp + REVIEW + 1);
        vm.expectRevert(
            abi.encodeWithSelector(SafeDeal.WrongMilestoneStatus.selector, SafeDeal.MilestoneStatus.Disputed)
        );
        sd.releaseAfterReview(id, 0);
        assertEq(sd.reviewEndsAt(id, 0), 0);
    }

    function test_RevertWhen_DisputeInvalid() public {
        uint256 id = _active();
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(SafeDeal.WrongMilestoneStatus.selector, SafeDeal.MilestoneStatus.Pending)
        );
        sd.dispute(id, 0, "");

        _deliver(id, 0);
        vm.prank(provider);
        vm.expectRevert(SafeDeal.NotClient.selector);
        sd.dispute(id, 0, "");

        vm.prank(client);
        vm.expectRevert(SafeDeal.NoteTooLong.selector);
        sd.dispute(id, 0, string(new bytes(513)));

        uint64 endsAt = uint64(vm.getBlockTimestamp()) + REVIEW;
        vm.warp(endsAt);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.ReviewPeriodOver.selector, endsAt));
        sd.dispute(id, 0, "too late");
    }

    function test_ArbiterSplitsDispute() public {
        uint256 id = _disputed(_p());
        vm.prank(client);
        vm.expectRevert(SafeDeal.NotArbiter.selector);
        sd.resolve(id, 0, M0);

        vm.prank(arbiter);
        vm.expectRevert(SafeDeal.InvalidSplit.selector);
        sd.resolve(id, 0, M0 + 1);

        vm.expectEmit(true, true, false, true, address(sd));
        emit MilestoneClosed(id, 0, SafeDeal.Resolution.ArbiterRuling, 60e6, 40e6);
        vm.prank(arbiter);
        sd.resolve(id, 0, 60e6);
        assertEq(usdc.balanceOf(provider), 60e6);
        assertEq(usdc.balanceOf(client), 10_000e6 - TOTAL + 40e6);
        assertEq(usdc.balanceOf(arbiter), 0, "the arbiter never receives funds");
        _assertAccounting(address(usdc));
    }

    function test_RevertWhen_ArbiterResolvesUndisputed() public {
        uint256 id = _active();
        _deliver(id, 0);
        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(SafeDeal.WrongMilestoneStatus.selector, SafeDeal.MilestoneStatus.Delivered)
        );
        sd.resolve(id, 0, 0);
    }

    function test_NoArbiter_DisputeSplitsHalfAfterTimeout() public {
        uint96 odd = 100_000_001; // 100.000001 USDC: the extra unit goes to the client
        uint256 id = _disputed(_single(odd, address(0)));
        vm.prank(stranger);
        vm.expectRevert(SafeDeal.NotArbiter.selector);
        sd.resolve(id, 0, 0);

        uint64 endsAt = uint64(vm.getBlockTimestamp()) + 30 days;
        vm.warp(endsAt - 1);
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.ArbitrationNotTimedOut.selector, endsAt));
        sd.resolveAfterTimeout(id, 0);

        vm.warp(endsAt);
        vm.prank(stranger);
        sd.resolveAfterTimeout(id, 0);
        assertEq(usdc.balanceOf(provider), 50_000_000);
        assertEq(usdc.balanceOf(client), 10_000e6 - odd + 50_000_001);
        assertEq(uint8(sd.getMilestone(id, 0).resolution), uint8(SafeDeal.Resolution.ArbitrationTimeout));
    }

    function test_PartiesCanGiveUpADispute() public {
        uint256 id = _disputed(_p());
        vm.prank(client);
        sd.approveMilestone(id, 0);
        assertEq(usdc.balanceOf(provider), M0);

        _deliver(id, 1);
        vm.prank(client);
        sd.dispute(id, 1, "x");
        vm.prank(provider);
        sd.refund(id, 1);
        assertEq(usdc.balanceOf(client), 10_000e6 - TOTAL + M1);
    }

    // ------------------------------------------------------------ settlement

    function test_Settlement_MatchingOffersPayOut() public {
        uint256 id = _disputed(_p());
        vm.prank(stranger);
        vm.expectRevert(SafeDeal.NotParty.selector);
        sd.proposeSettlement(id, 0, 1);

        vm.prank(client);
        vm.expectRevert(SafeDeal.InvalidSplit.selector);
        sd.proposeSettlement(id, 0, M0 + 1);

        vm.expectEmit(true, true, true, true, address(sd));
        emit SettlementProposed(id, 0, client, 30e6);
        vm.prank(client);
        sd.proposeSettlement(id, 0, 30e6);

        vm.prank(provider);
        sd.proposeSettlement(id, 0, 80e6); // no match yet
        assertEq(uint8(sd.getMilestone(id, 0).status), uint8(SafeDeal.MilestoneStatus.Disputed));

        vm.prank(client);
        sd.proposeSettlement(id, 0, 70e6); // still no match
        vm.prank(provider);
        sd.proposeSettlement(id, 0, 70e6); // match -> paid out
        SafeDeal.Milestone memory m = sd.getMilestone(id, 0);
        assertEq(uint8(m.status), uint8(SafeDeal.MilestoneStatus.Closed));
        assertEq(uint8(m.resolution), uint8(SafeDeal.Resolution.Settlement));
        assertEq(m.toProvider, 70e6);
        assertEq(usdc.balanceOf(provider), 70e6);
        assertEq(usdc.balanceOf(client), 10_000e6 - TOTAL + 30e6);
    }

    function test_Settlement_WorksWithoutDisputeAndWithoutArbiter() public {
        uint256 id = _createActive(_params(address(0), address(usdc)));
        vm.prank(provider);
        sd.proposeSettlement(id, 2, 0); // mutual cancel of a milestone
        vm.prank(client);
        sd.proposeSettlement(id, 2, 0);
        assertEq(usdc.balanceOf(client), 10_000e6 - TOTAL + M2);
    }

    function test_Settlement_OffersClearedOnDispute() public {
        uint256 id = _active();
        _deliver(id, 0);
        vm.prank(provider);
        sd.proposeSettlement(id, 0, 90e6);
        vm.prank(client);
        sd.dispute(id, 0, "x");
        assertFalse(sd.getMilestone(id, 0).providerOffered);
        // The client's matching offer must not execute the provider's stale one.
        vm.prank(client);
        sd.proposeSettlement(id, 0, 90e6);
        assertEq(uint8(sd.getMilestone(id, 0).status), uint8(SafeDeal.MilestoneStatus.Disputed));
    }

    function test_WithdrawSettlement() public {
        uint256 id = _active();
        vm.prank(client);
        sd.proposeSettlement(id, 0, 10e6);
        vm.prank(client);
        sd.withdrawSettlement(id, 0);
        assertFalse(sd.getMilestone(id, 0).clientOffered);
        vm.prank(provider);
        sd.proposeSettlement(id, 0, 10e6);
        assertEq(uint8(sd.getMilestone(id, 0).status), uint8(SafeDeal.MilestoneStatus.Pending), "no stale match");
        vm.prank(provider);
        sd.withdrawSettlement(id, 0);
        vm.prank(stranger);
        vm.expectRevert(SafeDeal.NotParty.selector);
        sd.withdrawSettlement(id, 0);
    }

    // ------------------------------------------------------------ deferred payouts (blocklist)

    function test_BlocklistedProvider_DoesNotBlockClientRefund() public {
        uint256 id = _disputed(_p());
        usdc.setBlacklisted(provider, true);

        vm.expectEmit(true, true, false, true, address(sd));
        emit PayoutDeferred(address(usdc), provider, 60e6);
        vm.prank(arbiter);
        sd.resolve(id, 0, 60e6);

        assertEq(usdc.balanceOf(client), 10_000e6 - TOTAL + 40e6, "client refund went through");
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(sd.claimable(address(usdc), provider), 60e6);
        assertEq(sd.totalClaimable(address(usdc)), 60e6);
        _assertAccounting(address(usdc));

        // Still blocklisted: withdraw reverts with the token's reason and keeps the credit.
        vm.prank(provider);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        sd.withdraw(address(usdc));
        assertEq(sd.claimable(address(usdc), provider), 60e6);

        usdc.setBlacklisted(provider, false);
        vm.expectEmit(true, true, false, true, address(sd));
        emit Withdrawn(address(usdc), provider, 60e6);
        vm.prank(provider);
        sd.withdraw(address(usdc));
        assertEq(usdc.balanceOf(provider), 60e6);
        assertEq(sd.totalClaimable(address(usdc)), 0);
        _assertAccounting(address(usdc));

        vm.prank(provider);
        vm.expectRevert(SafeDeal.NothingToWithdraw.selector);
        sd.withdraw(address(usdc));
    }

    function test_BlocklistedClient_CancelRefundIsCredited() public {
        uint256 id = _create(_p());
        usdc.setBlacklisted(client, true);
        vm.prank(provider);
        sd.decline(id);
        assertEq(uint8(sd.getDeal(id).status), uint8(SafeDeal.DealStatus.Cancelled));
        assertEq(sd.claimable(address(usdc), client), TOTAL);
        _assertAccounting(address(usdc));
    }

    function test_RevertWhen_PayoutStarvedOfGas() public {
        GasBurnerToken burner = new GasBurnerToken();
        SafeDeal sd2 = new SafeDeal(IStablecoin(address(burner)), IStablecoin(address(0)));
        burner.mint(client, 1_000e6);
        SafeDeal.DealParams memory p = _single(10e6, address(0));
        p.token = address(burner);
        vm.startPrank(client);
        burner.approve(address(sd2), type(uint256).max);
        uint256 id = sd2.createDeal(p);
        vm.stopPrank();
        vm.prank(provider);
        sd2.accept(id);
        burner.setBurn(true);
        // The transfer consumes all the gas it gets: SafeDeal must revert, not record a deferral.
        vm.prank(client);
        vm.expectRevert(SafeDeal.InsufficientGas.selector);
        sd2.approveMilestone{gas: 1_000_000}(id, 0);
        assertEq(sd2.claimable(address(burner), provider), 0);
        assertEq(uint8(sd2.getMilestone(id, 0).status), uint8(SafeDeal.MilestoneStatus.Pending));
    }

    // ------------------------------------------------------------ views

    function test_DealsOfPagination() public {
        for (uint256 i = 0; i < 5; i++) {
            _create(_p());
        }
        assertEq(sd.dealCountOf(provider), 5);
        uint256[] memory page = sd.dealsOf(provider, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 2);
        assertEq(page[1], 3);
        assertEq(sd.dealsOf(provider, 4, 10).length, 1);
        assertEq(sd.dealsOf(provider, 5, 10).length, 0);
    }

    function test_RevertWhen_MilestoneOutOfRange() public {
        uint256 id = _create(_p());
        vm.expectRevert(abi.encodeWithSelector(SafeDeal.UnknownMilestone.selector, id, 3));
        sd.getMilestone(id, 3);
    }

    // ------------------------------------------------------------ fuzz

    function testFuzz_ArbiterSplitConservesFunds(uint96 amount, uint96 toProvider) public {
        amount = uint96(bound(amount, 1, 5_000e6));
        toProvider = uint96(bound(toProvider, 0, amount));
        uint256 id = _disputed(_single(amount, arbiter));
        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(arbiter);
        sd.resolve(id, 0, toProvider);
        assertEq(usdc.balanceOf(provider), toProvider);
        assertEq(usdc.balanceOf(client) - clientBefore, amount - toProvider);
        assertEq(usdc.balanceOf(address(sd)), 0);
        assertEq(sd.totalLocked(address(usdc)), 0);
    }

    function testFuzz_CreateDealTotal(uint96[10] memory raw, uint8 count) public {
        uint256 n = bound(count, 1, 10);
        string[] memory names = new string[](n);
        uint96[] memory amounts = new uint96[](n);
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = uint96(bound(raw[i], 1, 900e6));
            names[i] = "M";
            sum += amounts[i];
        }
        SafeDeal.DealParams memory p = _p();
        p.milestoneNames = names;
        p.milestoneAmounts = amounts;
        uint256 id = _create(p);
        assertEq(sd.getDeal(id).total, sum);
        assertEq(sd.getDeal(id).milestoneCount, n);
        assertEq(usdc.balanceOf(address(sd)), sum);
        vm.prank(client);
        sd.cancel(id);
        assertEq(usdc.balanceOf(client), 10_000e6);
    }

    /// Release works exactly when the review period has passed; dispute exactly before.
    function testFuzz_ReviewWindowBoundary(uint32 review, uint32 elapsed) public {
        review = uint32(bound(review, 60, 90 days));
        elapsed = uint32(bound(elapsed, 0, 2 * uint256(review)));
        SafeDeal.DealParams memory p = _p();
        p.reviewPeriod = review;
        p.deadline = T0 + 3 * 365 days;
        uint256 id = _createActive(p);
        _deliver(id, 0);
        vm.warp(block.timestamp + elapsed);
        if (elapsed >= review) {
            sd.releaseAfterReview(id, 0);
            assertEq(usdc.balanceOf(provider), M0);
        } else {
            vm.prank(client);
            sd.dispute(id, 0, "");
            assertEq(uint8(sd.getMilestone(id, 0).status), uint8(SafeDeal.MilestoneStatus.Disputed));
        }
    }

    function testFuzz_SettlementOnlyOnExactMatch(uint96 a, uint96 b) public {
        a = uint96(bound(a, 0, M0));
        b = uint96(bound(b, 0, M0));
        uint256 id = _active();
        vm.prank(client);
        sd.proposeSettlement(id, 0, a);
        vm.prank(provider);
        sd.proposeSettlement(id, 0, b);
        bool closed = sd.getMilestone(id, 0).status == SafeDeal.MilestoneStatus.Closed;
        assertEq(closed, a == b);
        if (closed) assertEq(usdc.balanceOf(provider), a);
        _assertAccounting(address(usdc));
    }
}
