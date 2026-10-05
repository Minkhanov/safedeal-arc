// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {SafeDeal, IStablecoin} from "../src/SafeDeal.sol";
import {MockStablecoin} from "./mocks/MockStablecoin.sol";

/// @notice Drives SafeDeal through random sequences of every action, by the right and the wrong
///         actors, with time jumps and blocklist toggles. Calls that revert are simply skipped.
contract SafeDealHandler is Test {
    SafeDeal public sd;
    MockStablecoin public usdc;
    MockStablecoin public eurc;
    address[5] public actors; // 0,1 clients; 2,3 providers; 4 arbiter (any of them may act in any role)

    uint256 public calls;
    mapping(bytes32 => uint256) public hits; // successful calls per action, for coverage reporting

    constructor(SafeDeal _sd, MockStablecoin _usdc, MockStablecoin _eurc) {
        sd = _sd;
        usdc = _usdc;
        eurc = _eurc;
        for (uint256 i = 0; i < 5; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            usdc.mint(actors[i], 1_000_000e6);
            eurc.mint(actors[i], 1_000_000e6);
            vm.startPrank(actors[i]);
            usdc.approve(address(sd), type(uint256).max);
            eurc.approve(address(sd), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 5];
    }

    /// One of the three most recent deals, so that sequences (create, accept, deliver, dispute...) line up.
    function _dealId(uint256 seed) internal view returns (uint256) {
        uint256 n = sd.dealCount();
        if (n == 0) return 1;
        uint256 window = n < 3 ? n : 3;
        return n - (seed % window);
    }

    enum Role {
        Client,
        Provider,
        Arbiter
    }

    /// The expected actor for an action 80% of the time, otherwise anyone (to exercise access control).
    function _who(uint256 id, uint256 seed, Role role) internal view returns (address) {
        if (seed % 5 == 0) return _actor(seed >> 8);
        SafeDeal.Deal memory d = sd.getDeal(id);
        if (role == Role.Client) return d.client;
        if (role == Role.Provider) return d.provider;
        return d.arbiter == address(0) ? _actor(seed >> 8) : d.arbiter;
    }

    /// A milestone index of the deal (mostly valid; one in eight is out of range on purpose).
    function _idx(uint256 id, uint8 index) internal view returns (uint256) {
        uint256 n = sd.getDeal(id).milestoneCount;
        if (n == 0 || index % 8 == 7) return index;
        return index % n;
    }

    function _hit(bytes32 what) internal {
        hits[what]++;
    }

    function create(uint256 seed, uint96 a0, uint96 a1, uint96 a2, uint8 count) external {
        calls++;
        SafeDeal.DealParams memory p = _params(seed, _amounts([a0, a1, a2], count));
        vm.prank(_actor(seed));
        try sd.createDeal(p) {
            _hit("create");
        } catch {}
    }

    function _amounts(uint96[3] memory raw, uint8 count) internal pure returns (uint96[] memory amounts) {
        uint256 n = bound(count, 1, 3);
        amounts = new uint96[](n);
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = uint96(bound(raw[i], 1, 10_000e6));
        }
    }

    function _params(uint256 seed, uint96[] memory amounts) internal view returns (SafeDeal.DealParams memory p) {
        string[] memory names = new string[](amounts.length);
        for (uint256 i = 0; i < amounts.length; i++) {
            names[i] = "M";
        }
        p.provider = _actor(seed >> 8);
        p.arbiter = (seed >> 16) % 3 == 0 ? address(0) : _actor(seed >> 24);
        p.token = (seed >> 32) % 2 == 0 ? address(usdc) : address(eurc);
        p.deadline = uint64(block.timestamp + 1 hours + ((seed >> 40) % 10 days));
        p.reviewPeriod = uint32(60 + ((seed >> 48) % 3 days));
        p.title = "Deal";
        p.milestoneNames = names;
        p.milestoneAmounts = amounts;
    }

    function accept(uint256 seed) external {
        calls++;
        uint256 id = _dealId(seed);
        vm.prank(_who(id, seed >> 4, Role.Provider));
        try sd.accept(id) {
            _hit("accept");
        } catch {}
    }

    function cancelOrDecline(uint256 seed) external {
        calls++;
        uint256 id = _dealId(seed);
        address who = _who(id, seed >> 4, seed % 2 == 0 ? Role.Client : Role.Provider);
        vm.prank(who);
        if (seed % 2 == 0) {
            try sd.cancel(id) {
                _hit("cancel");
            } catch {}
        } else {
            try sd.decline(id) {
                _hit("decline");
            } catch {}
        }
    }

    function deliver(uint256 seed, uint8 index) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        vm.prank(_who(id, seed >> 4, Role.Provider));
        try sd.deliver(id, m, "note") {
            _hit("deliver");
        } catch {}
    }

    function approve(uint256 seed, uint8 index) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        vm.prank(_who(id, seed >> 4, Role.Client));
        try sd.approveMilestone(id, m) {
            _hit("approve");
        } catch {}
    }

    function release(uint256 seed, uint8 index) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        vm.prank(_actor(seed >> 4));
        try sd.releaseAfterReview(id, m) {
            _hit("release");
        } catch {}
    }

    function refund(uint256 seed, uint8 index) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        vm.prank(_who(id, seed >> 4, Role.Provider));
        try sd.refund(id, m) {
            _hit("refund");
        } catch {}
    }

    function reclaim(uint256 seed, uint8 index) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        vm.prank(_who(id, seed >> 4, Role.Client));
        try sd.reclaimAfterDeadline(id, m) {
            _hit("reclaim");
        } catch {}
    }

    function dispute(uint256 seed, uint8 index) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        vm.prank(_who(id, seed >> 4, Role.Client));
        try sd.dispute(id, m, "why") {
            _hit("dispute");
        } catch {}
    }

    function resolve(uint256 seed, uint8 index, uint96 toProvider) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        vm.prank(_who(id, seed >> 4, Role.Arbiter));
        try sd.resolve(id, m, uint96(bound(toProvider, 0, 10_000e6))) {
            _hit("resolve");
        } catch {}
    }

    function resolveAfterTimeout(uint256 seed, uint8 index) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        try sd.resolveAfterTimeout(id, m) {
            _hit("resolveTimeout");
        } catch {}
    }

    function propose(uint256 seed, uint8 index, uint96 toProvider) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        // Small grid of amounts so that the two sides actually match sometimes.
        uint96 amount = uint96(bound(toProvider, 0, 4)) * 1e6;
        vm.prank(_who(id, seed >> 4, (seed >> 12) % 2 == 0 ? Role.Client : Role.Provider));
        try sd.proposeSettlement(id, m, amount) {
            _hit("propose");
        } catch {}
    }

    function withdrawOffer(uint256 seed, uint8 index) external {
        calls++;
        uint256 id = _dealId(seed);
        uint256 m = _idx(id, index);
        vm.prank(_who(id, seed >> 4, (seed >> 12) % 2 == 0 ? Role.Client : Role.Provider));
        try sd.withdrawSettlement(id, m) {
            _hit("withdrawOffer");
        } catch {}
    }

    function extend(uint256 seed, uint32 by) external {
        calls++;
        uint256 id = _dealId(seed);
        SafeDeal.Deal memory d = sd.getDeal(id);
        vm.prank(_who(id, seed >> 4, Role.Client));
        try sd.extendDeadline(id, d.deadline + uint64(bound(by, 1, 3 days))) {
            _hit("extend");
        } catch {}
    }

    function toggleBlocklist(uint256 seed) external {
        calls++;
        address who = _actor(seed);
        MockStablecoin t = seed % 2 == 0 ? usdc : eurc;
        t.setBlacklisted(who, !t.isBlacklisted(who));
        _hit("blocklist");
    }

    function withdraw(uint256 seed) external {
        calls++;
        address who = _actor(seed);
        address token = (seed >> 8) % 2 == 0 ? address(usdc) : address(eurc);
        vm.prank(who);
        try sd.withdraw(token) {
            _hit("withdraw");
        } catch {}
    }

    function warp(uint32 secs) external {
        calls++;
        // Mostly short steps (reviews, deadlines); sometimes a month (arbitration timeout).
        vm.warp(block.timestamp + (secs % 16 == 0 ? 31 days : bound(secs, 1, 1 days)));
        vm.roll(block.number + 1);
    }
}

contract SafeDealInvariantTest is Test {
    SafeDeal internal sd;
    MockStablecoin internal usdc;
    MockStablecoin internal eurc;
    SafeDealHandler internal handler;

    function setUp() public {
        vm.warp(1_790_000_000);
        usdc = new MockStablecoin("USDC");
        eurc = new MockStablecoin("EURC");
        sd = new SafeDeal(IStablecoin(address(usdc)), IStablecoin(address(eurc)));
        handler = new SafeDealHandler(sd, usdc, eurc);
        targetContract(address(handler));
    }

    /// The escrow always holds exactly what it owes: funds locked in deals plus deferred payouts.
    function invariant_EscrowBalanceMatchesAccounting() public view {
        assertEq(usdc.balanceOf(address(sd)), sd.totalLocked(address(usdc)) + sd.totalClaimable(address(usdc)));
        assertEq(eurc.balanceOf(address(sd)), sd.totalLocked(address(eurc)) + sd.totalClaimable(address(eurc)));
    }

    /// No token is created or destroyed: actors + escrow always hold the whole supply.
    function invariant_TokensAreConserved() public view {
        uint256 u = usdc.balanceOf(address(sd));
        uint256 e = eurc.balanceOf(address(sd));
        for (uint256 i = 0; i < 5; i++) {
            u += usdc.balanceOf(handler.actors(i));
            e += eurc.balanceOf(handler.actors(i));
        }
        assertEq(u, usdc.totalSupply());
        assertEq(e, eurc.totalSupply());
    }

    /// Per deal: locked == sum of open milestones, open count matches, status matches, splits are bounded.
    function invariant_DealBookkeeping() public view {
        uint256 lockedUsdc;
        uint256 lockedEurc;
        uint256 claimUsdc;
        uint256 claimEurc;
        for (uint256 id = 1; id <= sd.dealCount(); id++) {
            SafeDeal.Deal memory d = sd.getDeal(id);
            SafeDeal.Milestone[] memory ms = sd.getMilestones(id);
            uint256 open;
            uint256 openAmount;
            uint256 sum;
            for (uint256 i = 0; i < ms.length; i++) {
                sum += ms[i].amount;
                if (ms[i].status != SafeDeal.MilestoneStatus.Closed) {
                    open++;
                    openAmount += ms[i].amount;
                } else {
                    assertLe(ms[i].toProvider, ms[i].amount);
                }
            }
            assertEq(sum, d.total, "total == sum of milestones");
            assertEq(d.locked, openAmount, "locked == open milestones");
            assertEq(d.openMilestones, open, "open count");
            if (open == 0) {
                assertTrue(d.status == SafeDeal.DealStatus.Closed || d.status == SafeDeal.DealStatus.Cancelled);
            } else {
                assertTrue(d.status == SafeDeal.DealStatus.Open || d.status == SafeDeal.DealStatus.Active);
            }
            if (d.token == address(usdc)) lockedUsdc += d.locked;
            else lockedEurc += d.locked;
        }
        for (uint256 i = 0; i < 5; i++) {
            claimUsdc += sd.claimable(address(usdc), handler.actors(i));
            claimEurc += sd.claimable(address(eurc), handler.actors(i));
        }
        assertEq(lockedUsdc, sd.totalLocked(address(usdc)));
        assertEq(lockedEurc, sd.totalLocked(address(eurc)));
        assertEq(claimUsdc, sd.totalClaimable(address(usdc)));
        assertEq(claimEurc, sd.totalClaimable(address(eurc)));
    }

    /// Deterministic long walk through the handler: proves it reaches every action (so the invariants
    /// above are checked against real payouts, disputes and deferrals) and checks them at the end.
    function test_HandlerReachesEveryAction() public {
        // Weighted toward the lifecycle (deliver, dispute, timers) so every path is reached.
        uint8[32] memory plan =
            [0, 1, 1, 2, 3, 3, 3, 3, 4, 5, 5, 6, 7, 7, 8, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 11, 11, 12, 13, 14, 15, 16];
        for (uint256 i = 0; i < 10_000; i++) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            uint8 a = plan[r % plan.length];
            uint8 idx = uint8(r >> 200);
            if (a == 0) handler.create(r >> 8, uint96(r >> 16), uint96(r >> 40), uint96(r >> 64), uint8(r >> 88));
            else if (a == 1) handler.accept(r >> 8);
            else if (a == 2) handler.cancelOrDecline(r >> 8);
            else if (a == 3) handler.deliver(r >> 8, idx);
            else if (a == 4) handler.approve(r >> 8, idx);
            else if (a == 5) handler.release(r >> 8, idx);
            else if (a == 6) handler.refund(r >> 8, idx);
            else if (a == 7) handler.reclaim(r >> 8, idx);
            else if (a == 8) handler.dispute(r >> 8, idx);
            else if (a == 9) handler.resolve(r >> 8, idx, uint96(r >> 120));
            else if (a == 10) handler.resolveAfterTimeout(r >> 8, idx);
            else if (a == 11) handler.propose(r >> 8, idx, uint96(r >> 120));
            else if (a == 12) handler.withdrawOffer(r >> 8, idx);
            else if (a == 13) handler.extend(r >> 8, uint32(r >> 120));
            else if (a == 14 && (r >> 100) % 4 == 0) handler.toggleBlocklist(r >> 8);
            else if (a == 15) handler.withdraw(r >> 8);
            else handler.warp(uint32(r >> 120));
        }
        bytes32[17] memory names = _actionNames();
        for (uint256 i = 0; i < names.length; i++) {
            console2.log(string(abi.encodePacked(names[i])), handler.hits(names[i]));
        }
        for (uint256 i = 0; i < names.length; i++) {
            assertGt(handler.hits(names[i]), 0, string(abi.encodePacked("action never succeeded: ", names[i])));
        }
        assertGt(sd.totalClaimable(address(usdc)) + sd.totalClaimable(address(eurc)) + handler.hits("withdraw"), 0);
        invariant_EscrowBalanceMatchesAccounting();
        invariant_TokensAreConserved();
        invariant_DealBookkeeping();
    }

    function _actionNames() internal pure returns (bytes32[17] memory) {
        return [
            bytes32("create"),
            "accept",
            "cancel",
            "decline",
            "deliver",
            "approve",
            "release",
            "refund",
            "reclaim",
            "dispute",
            "resolve",
            "resolveTimeout",
            "propose",
            "withdrawOffer",
            "extend",
            "blocklist",
            "withdraw"
        ];
    }

    /// Coverage report: how many successful calls each action got (visible with -vv).
    function afterInvariant() public view {
        bytes32[17] memory names = _actionNames();
        for (uint256 i = 0; i < names.length; i++) {
            console2.log(string(abi.encodePacked(names[i])), handler.hits(names[i]));
        }
    }
}
