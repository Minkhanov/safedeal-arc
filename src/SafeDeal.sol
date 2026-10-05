// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev The parts of Arc's stablecoin ERC-20 interfaces that SafeDeal uses. On Arc, USDC
///      (0x3600000000000000000000000000000000000000) and EURC are FiatToken-style tokens with
///      6 decimals and EIP-2612 permit (domain version "2").
interface IStablecoin {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

/// @title SafeDeal — milestone escrow for freelance work, paid in USDC or EURC on Arc
/// @notice A client funds a deal split into milestones. The provider (freelancer) accepts it,
///         delivers each milestone and is paid when the client approves, or automatically once
///         the review period passes without a dispute. A dispute goes to an arbiter chosen by both
///         sides when the deal was made, or is settled by mutual agreement.
/// @dev    The rule behind every function: a party can always give money to the other side on its
///         own; taking money needs the other side's consent, an expired timer or the arbiter.
///         - client alone: approveMilestone (pay the provider), extend the deadline, cancel before acceptance;
///         - provider alone: refund the client, decline before acceptance;
///         - timers: after the review period a delivered milestone pays the provider; after the
///           delivery deadline an undelivered milestone can be reclaimed by the client; a dispute
///           that nobody resolves within ARBITRATION_TIMEOUT is split 50/50;
///         - arbiter: may only split a disputed milestone between client and provider, never send
///           funds anywhere else; deals can also be made without an arbiter.
///         No owner, no fees, no upgrades, no pause. Funds are tracked in internal accounting, never
///         by balanceOf (Arc's ERC-20 view of native USDC truncates), and the contract never sends
///         native value. Payouts that the token rejects (for example a blocklisted recipient) are
///         credited to the recipient for a later withdraw() instead of blocking the other party.
contract SafeDeal {
    // ------------------------------------------------------------------ limits

    uint256 public constant MAX_MILESTONES = 10;
    uint256 public constant MAX_TITLE_BYTES = 64;
    uint256 public constant MAX_MILESTONE_NAME_BYTES = 31; // short strings fit one storage slot
    uint256 public constant MAX_TERMS_BYTES = 4096;
    uint256 public constant MAX_NOTE_BYTES = 512;
    uint32 public constant MIN_REVIEW_PERIOD = 60; // 1 minute, so demos can show a real timeout
    uint32 public constant MAX_REVIEW_PERIOD = 90 days;
    uint64 public constant MAX_DEAL_DURATION = 3 * 365 days;
    uint64 public constant ARBITRATION_TIMEOUT = 30 days;

    // ------------------------------------------------------------------ types

    enum DealStatus {
        None,
        Open, // funded, waiting for the provider to accept
        Active, // accepted; milestones are being delivered and paid
        Closed, // every milestone is paid out
        Cancelled // cancelled by the client or declined by the provider before acceptance
    }

    enum MilestoneStatus {
        Pending, // funded, not delivered yet
        Delivered, // delivered, the client's review period is running
        Disputed, // the client disputed the delivery
        Closed // paid out; see `resolution` and `toProvider`
    }

    enum Resolution {
        None,
        Approved, // client approved: everything to the provider
        ReviewTimeout, // review period passed without a dispute: everything to the provider
        RefundedByProvider, // provider refunded: everything to the client
        DeadlineReclaim, // not delivered by the deadline: everything to the client
        ArbiterRuling, // arbiter split a disputed milestone
        Settlement, // both parties agreed on a split
        ArbitrationTimeout, // dispute unresolved for ARBITRATION_TIMEOUT: split 50/50
        DealCancelled // deal cancelled or declined before acceptance: everything to the client
    }

    struct Deal {
        address client;
        uint64 deadline; // delivery deadline (unix seconds) for undelivered milestones
        uint32 reviewPeriod; // seconds the client has to approve or dispute a delivery
        address provider;
        uint64 createdBlock; // block of DealCreated, which carries the full terms text
        uint8 milestoneCount;
        uint8 openMilestones; // milestones not paid out yet
        DealStatus status;
        address arbiter; // address(0) = no arbiter
        uint96 total;
        address token;
        uint96 locked; // amount of this deal still held by the contract
        bytes32 termsHash; // keccak256 of the terms text, or 0 when no terms were given
        string title;
    }

    struct Milestone {
        uint96 amount;
        MilestoneStatus status;
        Resolution resolution;
        uint64 deliveredAt;
        uint64 disputedAt;
        uint96 toProvider; // provider's final share once closed
        uint64 deliveredBlock; // block of the latest MilestoneDelivered event (the note lives in the log)
        uint64 disputedBlock; // block of the MilestoneDisputed event (the reason lives in the log)
        uint96 clientOffer; // settlement: provider's share proposed by the client
        uint96 providerOffer; // settlement: provider's share proposed by the provider
        bool clientOffered;
        bool providerOffered;
        string name;
    }

    /// @notice Terms of a new deal. Amounts use the token's 6-decimal ERC-20 units.
    struct DealParams {
        address provider;
        address arbiter; // optional; address(0) = no arbiter
        address token; // usdc or eurc
        uint64 deadline;
        uint32 reviewPeriod;
        string title;
        string terms; // optional agreement text; hashed into storage and published in DealCreated
        string[] milestoneNames;
        uint96[] milestoneAmounts;
    }

    // ------------------------------------------------------------------ storage

    IStablecoin public immutable usdc;
    IStablecoin public immutable eurc; // address(0) on networks without EURC

    uint256 public dealCount; // deal ids start at 1
    mapping(uint256 => Deal) private _deals;
    mapping(uint256 => Milestone[]) private _milestones;
    mapping(address => uint256[]) private _dealsOf; // as client, provider or arbiter

    /// @notice Payouts the token rejected, waiting for the recipient's withdraw().
    mapping(address token => mapping(address account => uint256)) public claimable;
    /// @notice Sum of `locked` over all deals in a token.
    mapping(address token => uint256) public totalLocked;
    /// @notice Sum of `claimable` over all accounts in a token.
    mapping(address token => uint256) public totalClaimable;

    // ------------------------------------------------------------------ events

    /// @dev Title, deadline, review period and milestones are in storage (getDeal / getMilestones);
    ///      the full terms text is only published here, its hash is stored in the deal.
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
    event SettlementWithdrawn(uint256 indexed dealId, uint256 indexed index, address indexed by);
    event MilestoneClosed(
        uint256 indexed dealId, uint256 indexed index, Resolution resolution, uint256 toProvider, uint256 toClient
    );
    event PayoutDeferred(address indexed token, address indexed account, uint256 amount);
    event Withdrawn(address indexed token, address indexed account, uint256 amount);

    // ------------------------------------------------------------------ errors

    error InvalidToken();
    error UnsupportedToken(address token);
    error InvalidParties();
    error InvalidMilestones();
    error InvalidAmount();
    error InvalidName();
    error InvalidTitle();
    error TermsTooLong();
    error NoteTooLong();
    error InvalidDeadline();
    error InvalidReviewPeriod();
    error UnknownDeal(uint256 dealId);
    error UnknownMilestone(uint256 dealId, uint256 index);
    error NotClient();
    error NotProvider();
    error NotArbiter();
    error NotParty();
    error WrongDealStatus(DealStatus status);
    error WrongMilestoneStatus(MilestoneStatus status);
    error DeadlinePassed(uint64 deadline);
    error DeadlineNotPassed(uint64 deadline);
    error ReviewPeriodOver(uint64 endedAt);
    error ReviewPeriodNotOver(uint64 endsAt);
    error ArbitrationNotTimedOut(uint64 endsAt);
    error InvalidSplit();
    error NothingToWithdraw();
    error TransferFailed();
    error InsufficientGas();

    constructor(IStablecoin _usdc, IStablecoin _eurc) {
        if (address(_usdc).code.length == 0) revert InvalidToken();
        if (address(_eurc) != address(0) && (address(_eurc).code.length == 0 || _eurc == _usdc)) {
            revert InvalidToken();
        }
        usdc = _usdc;
        eurc = _eurc;
    }

    // ------------------------------------------------------------------ create & accept

    /// @notice Create and fund a deal from an existing token allowance. The provider must accept it.
    function createDeal(DealParams calldata p) external returns (uint256 dealId) {
        return _createDeal(p);
    }

    /// @notice One-transaction create: sets the allowance with an EIP-2612 signature, then creates and
    ///         funds the deal. The permit is wrapped in try/catch so a front-run of the same signature
    ///         cannot block the deal (the allowance is already in place in that case).
    function createDealWithPermit(
        DealParams calldata p,
        uint256 permitValue,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 dealId) {
        if (!isSupportedToken(p.token)) revert UnsupportedToken(p.token);
        try IStablecoin(p.token).permit(msg.sender, address(this), permitValue, permitDeadline, v, r, s) {} catch {}
        return _createDeal(p);
    }

    /// @notice Provider accepts the deal; from now on the client can no longer cancel it.
    function accept(uint256 dealId) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.provider) revert NotProvider();
        if (d.status != DealStatus.Open) revert WrongDealStatus(d.status);
        // Deadlines are hours to months; proposer timestamp skew does not matter here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > d.deadline) revert DeadlinePassed(d.deadline);
        d.status = DealStatus.Active;
        emit DealAccepted(dealId);
    }

    /// @notice Client cancels a deal the provider has not accepted yet; the full amount is refunded.
    function cancel(uint256 dealId) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.client) revert NotClient();
        _cancel(dealId, d);
    }

    /// @notice Provider declines a deal; the full amount is refunded to the client.
    function decline(uint256 dealId) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.provider) revert NotProvider();
        _cancel(dealId, d);
    }

    /// @notice Client gives the provider more time to deliver. The deadline can only move later.
    function extendDeadline(uint256 dealId, uint64 newDeadline) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.client) revert NotClient();
        if (d.status != DealStatus.Open && d.status != DealStatus.Active) revert WrongDealStatus(d.status);
        // forge-lint: disable-next-line(block-timestamp)
        if (newDeadline <= d.deadline || newDeadline <= block.timestamp || newDeadline > _now() + MAX_DEAL_DURATION) {
            revert InvalidDeadline();
        }
        d.deadline = newDeadline;
        emit DeadlineExtended(dealId, newDeadline);
    }

    // ------------------------------------------------------------------ delivery & review

    /// @notice Provider marks a milestone as delivered, with a note (e.g. a link to the work).
    ///         Delivering again while under review replaces the note and restarts the review period.
    function deliver(uint256 dealId, uint256 index, string calldata note) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.provider) revert NotProvider();
        _requireActive(d);
        if (bytes(note).length > MAX_NOTE_BYTES) revert NoteTooLong();
        Milestone storage m = _milestone(dealId, d, index);
        if (m.status == MilestoneStatus.Pending) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp > d.deadline) revert DeadlinePassed(d.deadline);
        } else if (m.status != MilestoneStatus.Delivered) {
            revert WrongMilestoneStatus(m.status);
        }
        m.status = MilestoneStatus.Delivered;
        m.deliveredAt = _now();
        // forge-lint: disable-next-line(unsafe-typecast)
        m.deliveredBlock = uint64(block.number);
        _clearOffers(m);
        emit MilestoneDelivered(dealId, index, note);
    }

    /// @notice Client approves a milestone and pays the provider in full. Allowed at any time while the
    ///         milestone is open, including before delivery or during a dispute.
    function approveMilestone(uint256 dealId, uint256 index) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.client) revert NotClient();
        _requireActive(d);
        Milestone storage m = _openMilestone(dealId, d, index);
        _close(dealId, d, index, m, Resolution.Approved, m.amount);
    }

    /// @notice After the review period, anyone can release a delivered, undisputed milestone to the provider.
    function releaseAfterReview(uint256 dealId, uint256 index) external {
        Deal storage d = _deal(dealId);
        _requireActive(d);
        Milestone storage m = _milestone(dealId, d, index);
        if (m.status != MilestoneStatus.Delivered) revert WrongMilestoneStatus(m.status);
        uint64 endsAt = m.deliveredAt + d.reviewPeriod;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < endsAt) revert ReviewPeriodNotOver(endsAt);
        _close(dealId, d, index, m, Resolution.ReviewTimeout, m.amount);
    }

    /// @notice Provider refunds a milestone to the client in full.
    function refund(uint256 dealId, uint256 index) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.provider) revert NotProvider();
        _requireActive(d);
        Milestone storage m = _openMilestone(dealId, d, index);
        _close(dealId, d, index, m, Resolution.RefundedByProvider, 0);
    }

    /// @notice After the delivery deadline, the client takes back a milestone that was never delivered.
    function reclaimAfterDeadline(uint256 dealId, uint256 index) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.client) revert NotClient();
        _requireActive(d);
        Milestone storage m = _milestone(dealId, d, index);
        if (m.status != MilestoneStatus.Pending) revert WrongMilestoneStatus(m.status);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= d.deadline) revert DeadlineNotPassed(d.deadline);
        _close(dealId, d, index, m, Resolution.DeadlineReclaim, 0);
    }

    // ------------------------------------------------------------------ disputes & settlement

    /// @notice Client disputes a delivery during its review period. This stops the review timer.
    ///         The arbiter (if any) rules; the parties can still settle; after ARBITRATION_TIMEOUT
    ///         an unresolved dispute is split 50/50.
    function dispute(uint256 dealId, uint256 index, string calldata reason) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.client) revert NotClient();
        _requireActive(d);
        if (bytes(reason).length > MAX_NOTE_BYTES) revert NoteTooLong();
        Milestone storage m = _milestone(dealId, d, index);
        if (m.status != MilestoneStatus.Delivered) revert WrongMilestoneStatus(m.status);
        uint64 endsAt = m.deliveredAt + d.reviewPeriod;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= endsAt) revert ReviewPeriodOver(endsAt);
        m.status = MilestoneStatus.Disputed;
        m.disputedAt = _now();
        // forge-lint: disable-next-line(unsafe-typecast)
        m.disputedBlock = uint64(block.number);
        _clearOffers(m);
        emit MilestoneDisputed(dealId, index, reason);
    }

    /// @notice The deal's arbiter splits a disputed milestone; the rest goes back to the client.
    function resolve(uint256 dealId, uint256 index, uint96 toProvider) external {
        Deal storage d = _deal(dealId);
        if (d.arbiter == address(0) || msg.sender != d.arbiter) revert NotArbiter();
        _requireActive(d);
        Milestone storage m = _milestone(dealId, d, index);
        if (m.status != MilestoneStatus.Disputed) revert WrongMilestoneStatus(m.status);
        if (toProvider > m.amount) revert InvalidSplit();
        _close(dealId, d, index, m, Resolution.ArbiterRuling, toProvider);
    }

    /// @notice Anyone can split a dispute 50/50 once it has been open for ARBITRATION_TIMEOUT.
    function resolveAfterTimeout(uint256 dealId, uint256 index) external {
        Deal storage d = _deal(dealId);
        _requireActive(d);
        Milestone storage m = _milestone(dealId, d, index);
        if (m.status != MilestoneStatus.Disputed) revert WrongMilestoneStatus(m.status);
        uint64 endsAt = m.disputedAt + ARBITRATION_TIMEOUT;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < endsAt) revert ArbitrationNotTimedOut(endsAt);
        _close(dealId, d, index, m, Resolution.ArbitrationTimeout, m.amount / 2);
    }

    /// @notice Client or provider proposes how to split an open milestone. When both have proposed
    ///         the same provider share, the milestone is paid out at once. Offers are cleared when the
    ///         milestone is delivered again or disputed, so an old offer cannot be matched later.
    function proposeSettlement(uint256 dealId, uint256 index, uint96 toProvider) external {
        Deal storage d = _deal(dealId);
        _requireActive(d);
        Milestone storage m = _openMilestone(dealId, d, index);
        if (toProvider > m.amount) revert InvalidSplit();
        if (msg.sender == d.client) {
            m.clientOffer = toProvider;
            m.clientOffered = true;
        } else if (msg.sender == d.provider) {
            m.providerOffer = toProvider;
            m.providerOffered = true;
        } else {
            revert NotParty();
        }
        emit SettlementProposed(dealId, index, msg.sender, toProvider);
        if (m.clientOffered && m.providerOffered && m.clientOffer == m.providerOffer) {
            _close(dealId, d, index, m, Resolution.Settlement, toProvider);
        }
    }

    /// @notice Withdraw your own settlement offer.
    function withdrawSettlement(uint256 dealId, uint256 index) external {
        Deal storage d = _deal(dealId);
        _requireActive(d);
        Milestone storage m = _openMilestone(dealId, d, index);
        if (msg.sender == d.client) {
            m.clientOffered = false;
            m.clientOffer = 0;
        } else if (msg.sender == d.provider) {
            m.providerOffered = false;
            m.providerOffer = 0;
        } else {
            revert NotParty();
        }
        emit SettlementWithdrawn(dealId, index, msg.sender);
    }

    // ------------------------------------------------------------------ deferred payouts

    /// @notice Withdraw payouts the token rejected earlier (for example while your address was
    ///         blocklisted). Funds can only go to the account they were credited to.
    function withdraw(address token) external {
        uint256 amount = claimable[token][msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        claimable[token][msg.sender] = 0;
        totalClaimable[token] -= amount;
        emit Withdrawn(token, msg.sender, amount);
        _callToken(token, abi.encodeCall(IStablecoin.transfer, (msg.sender, amount)));
    }

    // ------------------------------------------------------------------ views

    function isSupportedToken(address token) public view returns (bool) {
        return token != address(0) && (token == address(usdc) || token == address(eurc));
    }

    function getDeal(uint256 dealId) external view returns (Deal memory) {
        return _deals[dealId];
    }

    function getMilestones(uint256 dealId) external view returns (Milestone[] memory) {
        return _milestones[dealId];
    }

    function getMilestone(uint256 dealId, uint256 index) external view returns (Milestone memory) {
        if (index >= _milestones[dealId].length) revert UnknownMilestone(dealId, index);
        return _milestones[dealId][index];
    }

    /// @notice When the review period of a delivered milestone ends (0 if it is not under review).
    function reviewEndsAt(uint256 dealId, uint256 index) external view returns (uint64) {
        if (index >= _milestones[dealId].length) return 0;
        Milestone storage m = _milestones[dealId][index];
        if (m.status != MilestoneStatus.Delivered) return 0;
        return m.deliveredAt + _deals[dealId].reviewPeriod;
    }

    function dealCountOf(address account) external view returns (uint256) {
        return _dealsOf[account].length;
    }

    /// @notice Deal ids where `account` is client, provider or arbiter, oldest first.
    function dealsOf(address account, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage all = _dealsOf[account];
        if (offset >= all.length) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > all.length) end = all.length;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = all[i];
        }
    }

    // ------------------------------------------------------------------ internals

    function _createDeal(DealParams calldata p) internal returns (uint256 dealId) {
        uint96 total = _validate(p);
        uint256 n = p.milestoneAmounts.length;

        dealId = ++dealCount;
        Deal storage d = _deals[dealId];
        d.client = msg.sender;
        d.deadline = p.deadline;
        d.reviewPeriod = p.reviewPeriod;
        d.provider = p.provider;
        // Block numbers and timestamps fit uint64 for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        d.createdBlock = uint64(block.number);
        // n <= MAX_MILESTONES (10), checked in _validate.
        // forge-lint: disable-next-line(unsafe-typecast)
        d.milestoneCount = uint8(n);
        // forge-lint: disable-next-line(unsafe-typecast)
        d.openMilestones = uint8(n);
        d.status = DealStatus.Open;
        d.arbiter = p.arbiter;
        d.total = total;
        d.token = p.token;
        d.locked = total;
        d.termsHash = bytes(p.terms).length == 0 ? bytes32(0) : keccak256(bytes(p.terms));
        d.title = p.title;

        Milestone[] storage ms = _milestones[dealId];
        for (uint256 i = 0; i < n; i++) {
            Milestone storage m = ms.push();
            m.amount = p.milestoneAmounts[i];
            m.name = p.milestoneNames[i];
        }

        _dealsOf[msg.sender].push(dealId);
        _dealsOf[p.provider].push(dealId);
        if (p.arbiter != address(0)) _dealsOf[p.arbiter].push(dealId);
        totalLocked[p.token] += total;

        _emitCreated(dealId, p, total);
        _callToken(p.token, abi.encodeCall(IStablecoin.transferFrom, (msg.sender, address(this), total)));
    }

    function _emitCreated(uint256 dealId, DealParams calldata p, uint96 total) private {
        // The only earlier external call is the token's permit (supported tokens only).
        // forge-lint: disable-next-line(reentrancy-events)
        emit DealCreated(dealId, msg.sender, p.provider, p.arbiter, p.token, total, p.terms);
    }

    function _validate(DealParams calldata p) private view returns (uint96 total) {
        if (!isSupportedToken(p.token)) revert UnsupportedToken(p.token);
        if (
            p.provider == address(0) || p.provider == msg.sender || p.arbiter == msg.sender || p.arbiter == p.provider
                || p.provider == address(this) || p.arbiter == address(this)
        ) revert InvalidParties();
        uint256 n = p.milestoneAmounts.length;
        if (n == 0 || n > MAX_MILESTONES || p.milestoneNames.length != n) revert InvalidMilestones();
        uint256 len = bytes(p.title).length;
        if (len == 0 || len > MAX_TITLE_BYTES) revert InvalidTitle();
        if (bytes(p.terms).length > MAX_TERMS_BYTES) revert TermsTooLong();
        // forge-lint: disable-next-line(block-timestamp)
        if (p.deadline <= block.timestamp || p.deadline > _now() + MAX_DEAL_DURATION) revert InvalidDeadline();
        if (p.reviewPeriod < MIN_REVIEW_PERIOD || p.reviewPeriod > MAX_REVIEW_PERIOD) revert InvalidReviewPeriod();
        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) {
            // Input validation: rejecting the whole call on a bad element is intended.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (p.milestoneAmounts[i] == 0) revert InvalidAmount();
            uint256 nameLen = bytes(p.milestoneNames[i]).length;
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (nameLen == 0 || nameLen > MAX_MILESTONE_NAME_BYTES) revert InvalidName();
            sum += p.milestoneAmounts[i];
        }
        if (sum > type(uint96).max) revert InvalidAmount();
        // Checked against type(uint96).max just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        total = uint96(sum);
    }

    function _cancel(uint256 dealId, Deal storage d) private {
        if (d.status != DealStatus.Open) revert WrongDealStatus(d.status);
        uint96 amount = d.locked;
        d.status = DealStatus.Cancelled;
        d.locked = 0;
        d.openMilestones = 0;
        Milestone[] storage ms = _milestones[dealId];
        for (uint256 i = 0; i < ms.length; i++) {
            ms[i].status = MilestoneStatus.Closed;
            ms[i].resolution = Resolution.DealCancelled;
        }
        totalLocked[d.token] -= amount;
        emit DealCancelled(dealId, msg.sender);
        _payout(d.token, d.client, amount);
    }

    /// @dev Effects first, then payouts (checks-effects-interactions); the token is one of two
    ///      fixed, trusted stablecoins.
    function _close(
        uint256 dealId,
        Deal storage d,
        uint256 index,
        Milestone storage m,
        Resolution resolution,
        uint96 toProvider
    ) private {
        uint96 amount = m.amount;
        uint96 toClient = amount - toProvider;
        m.status = MilestoneStatus.Closed;
        m.resolution = resolution;
        m.toProvider = toProvider;
        _clearOffers(m);
        d.locked -= amount;
        d.openMilestones -= 1;
        totalLocked[d.token] -= amount;
        emit MilestoneClosed(dealId, index, resolution, toProvider, toClient);
        if (d.openMilestones == 0) {
            d.status = DealStatus.Closed;
            emit DealClosed(dealId);
        }
        _payout(d.token, d.provider, toProvider);
        _payout(d.token, d.client, toClient);
    }

    /// @dev Push the payout; if the token rejects it (blocklist, paused token), credit the recipient
    ///      instead so the other party's payout and the deal's state are never blocked. A failure
    ///      caused by the caller starving the call of gas reverts the whole transaction instead.
    function _payout(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 gasBefore = gasleft();
        // forge-lint: disable-next-line(calls-loop, reentrancy-no-eth)
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IStablecoin.transfer, (to, amount)));
        if (ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))))) return;
        if (gasleft() < gasBefore / 63) revert InsufficientGas();
        // Reached only when the transfer failed, so nothing moved; the token is one of two fixed,
        // trusted stablecoins chosen at deployment.
        claimable[token][to] += amount;
        totalClaimable[token] += amount;
        // forge-lint: disable-next-line(reentrancy-events)
        emit PayoutDeferred(token, to, amount);
    }

    /// @dev Token call that must succeed; bubbles the token's revert reason (e.g. "ERC20: transfer
    ///      amount exceeds allowance") so the UI can say what to fix.
    function _callToken(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok) {
            if (ret.length == 0) revert TransferFailed();
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        if (ret.length != 0 && (ret.length < 32 || !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _clearOffers(Milestone storage m) private {
        if (m.clientOffered || m.providerOffered) {
            m.clientOffered = false;
            m.providerOffered = false;
            m.clientOffer = 0;
            m.providerOffer = 0;
        }
    }

    function _deal(uint256 dealId) private view returns (Deal storage d) {
        d = _deals[dealId];
        if (d.status == DealStatus.None) revert UnknownDeal(dealId);
    }

    function _requireActive(Deal storage d) private view {
        if (d.status != DealStatus.Active) revert WrongDealStatus(d.status);
    }

    function _milestone(uint256 dealId, Deal storage d, uint256 index) private view returns (Milestone storage) {
        if (index >= d.milestoneCount) revert UnknownMilestone(dealId, index);
        return _milestones[dealId][index];
    }

    function _openMilestone(uint256 dealId, Deal storage d, uint256 index) private view returns (Milestone storage m) {
        m = _milestone(dealId, d, index);
        if (m.status == MilestoneStatus.Closed) revert WrongMilestoneStatus(m.status);
    }

    function _now() private view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp);
    }
}
