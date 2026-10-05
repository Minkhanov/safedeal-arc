"""Hand-written mutation testing for SafeDeal.

Applies one deliberate bug at a time to src/SafeDeal.sol, runs `forge test`, then restores the file.
A mutant is "killed" when at least one test fails. Every mutant should be killed.

    forge fmt && python scripts/mutate.py
"""
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "SafeDeal.sol"
FORGE = shutil.which("forge") or str(pathlib.Path.home() / ".foundry" / "bin" / "forge")

# (description, exact text in the formatted source, replacement)
MUTANTS = [
    ("double pay: client also gets the full amount",
     "uint96 toClient = amount - toProvider;", "uint96 toClient = amount;"),
    ("accept without the provider check",
     "        if (msg.sender != d.provider) revert NotProvider();\n        if (d.status != DealStatus.Open) revert WrongDealStatus(d.status);\n        // Deadlines",
     "        if (d.status != DealStatus.Open) revert WrongDealStatus(d.status);\n        // Deadlines"),
    ("release boundary off by one",
     "if (block.timestamp < endsAt) revert ReviewPeriodNotOver(endsAt);",
     "if (block.timestamp <= endsAt) revert ReviewPeriodNotOver(endsAt);"),
    ("dispute boundary off by one",
     "if (block.timestamp >= endsAt) revert ReviewPeriodOver(endsAt);",
     "if (block.timestamp > endsAt) revert ReviewPeriodOver(endsAt);"),
    ("reclaim boundary off by one",
     "if (block.timestamp <= d.deadline) revert DeadlineNotPassed(d.deadline);",
     "if (block.timestamp < d.deadline) revert DeadlineNotPassed(d.deadline);"),
    ("dispute keeps stale settlement offers",
     "        m.disputedBlock = uint64(block.number);\n        _clearOffers(m);",
     "        m.disputedBlock = uint64(block.number);"),
    ("re-delivery keeps stale settlement offers",
     "        m.deliveredBlock = uint64(block.number);\n        _clearOffers(m);",
     "        m.deliveredBlock = uint64(block.number);"),
    ("settlement without equal amounts",
     "if (m.clientOffered && m.providerOffered && m.clientOffer == m.providerOffer) {",
     "if (m.clientOffered && m.providerOffered) {"),
    ("arbiter split unbounded",
     "        if (toProvider > m.amount) revert InvalidSplit();\n        _close(dealId, d, index, m, Resolution.ArbiterRuling, toProvider);",
     "        _close(dealId, d, index, m, Resolution.ArbiterRuling, toProvider);"),
    ("arbitration timeout pays the provider in full",
     "Resolution.ArbitrationTimeout, m.amount / 2);", "Resolution.ArbitrationTimeout, m.amount);"),
    ("no gas-starvation guard",
     "        if (gasleft() < gasBefore / 63) revert InsufficientGas();\n", ""),
    ("rejected payout not credited",
     "        claimable[token][to] += amount;\n        totalClaimable[token] += amount;\n", ""),
    ("withdraw does not zero the credit",
     "        claimable[token][msg.sender] = 0;\n", ""),
    ("cancel after acceptance",
     "        if (d.status != DealStatus.Open) revert WrongDealStatus(d.status);\n        uint96 amount = d.locked;",
     "        uint96 amount = d.locked;"),
    ("deliver ignores the deadline",
     "            if (block.timestamp > d.deadline) revert DeadlinePassed(d.deadline);\n        } else if",
     "        } else if"),
    ("deadline can be shortened",
     "if (newDeadline <= d.deadline || newDeadline <= block.timestamp",
     "if (newDeadline <= block.timestamp"),
    ("anyone can approve a milestone",
     "        if (msg.sender != d.client) revert NotClient();\n        _requireActive(d);\n        Milestone storage m = _openMilestone(dealId, d, index);\n        _close(dealId, d, index, m, Resolution.Approved, m.amount);",
     "        _requireActive(d);\n        Milestone storage m = _openMilestone(dealId, d, index);\n        _close(dealId, d, index, m, Resolution.Approved, m.amount);"),
    ("anyone can refund",
     "        if (msg.sender != d.provider) revert NotProvider();\n        _requireActive(d);\n        Milestone storage m = _openMilestone(dealId, d, index);\n        _close(dealId, d, index, m, Resolution.RefundedByProvider, 0);",
     "        _requireActive(d);\n        Milestone storage m = _openMilestone(dealId, d, index);\n        _close(dealId, d, index, m, Resolution.RefundedByProvider, 0);"),
    ("arbiter may be the provider",
     " || p.arbiter == p.provider\n", "\n"),
    ("permit not wrapped in try/catch",
     "try IStablecoin(p.token).permit(msg.sender, address(this), permitValue, permitDeadline, v, r, s) {} catch {}",
     "IStablecoin(p.token).permit(msg.sender, address(this), permitValue, permitDeadline, v, r, s);"),
    ("deal never closes",
     "        d.openMilestones -= 1;\n", ""),
    ("totalLocked not increased on create",
     "        totalLocked[p.token] += total;\n", ""),
    ("reclaim allowed for delivered milestones",
     "        if (m.status != MilestoneStatus.Pending) revert WrongMilestoneStatus(m.status);\n        // forge-lint: disable-next-line(block-timestamp)\n        if (block.timestamp <= d.deadline)",
     "        // forge-lint: disable-next-line(block-timestamp)\n        if (block.timestamp <= d.deadline)"),
    ("dispute without a review window",
     "        if (block.timestamp >= endsAt) revert ReviewPeriodOver(endsAt);\n", ""),
    ("accept after the deadline",
     "        if (block.timestamp > d.deadline) revert DeadlinePassed(d.deadline);\n        d.status = DealStatus.Active;",
     "        d.status = DealStatus.Active;"),
]


def main() -> int:
    original = SRC.read_text(encoding="utf-8")
    results = []
    try:
        for name, before, after in MUTANTS:
            if original.count(before) != 1:
                results.append((name, f"PATTERN NOT FOUND x{original.count(before)} (run forge fmt?)"))
                print(results[-1], flush=True)
                continue
            SRC.write_text(original.replace(before, after), encoding="utf-8", newline="\n")
            out = subprocess.run([FORGE, "test"], cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                                 errors="replace")
            if "Compiler run failed" in out.stdout + out.stderr:
                results.append((name, "COMPILE ERROR"))
            else:
                caught = [l.strip()[:110] for l in out.stdout.splitlines() if l.startswith("[FAIL")][:1]
                results.append((name, "killed" if out.returncode != 0 else "SURVIVED", caught))
            print(results[-1], flush=True)
    finally:
        SRC.write_text(original, encoding="utf-8", newline="\n")
    killed = sum(1 for r in results if r[1] == "killed")
    print(f"\n{killed}/{len(MUTANTS)} mutants killed")
    return 0 if killed == len(MUTANTS) else 1


if __name__ == "__main__":
    sys.exit(main())
