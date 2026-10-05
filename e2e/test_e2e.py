"""SafeDeal end-to-end scenario on a local anvil node, driven through the real web UI.

    python e2e/test_e2e.py            # needs Foundry + `pip install playwright`

Deal 1 (USDC, arbiter, permit): the freelancer creates a proposal link (no transaction) -> the client
opens it and funds the deal with one signature and ONE transaction -> the freelancer accepts ->
milestone 1: delivered with a link, approved by the client -> milestone 2: delivered, the review
period passes, a stranger releases it -> milestone 3: delivered, disputed, the arbiter splits it.
Deal 2 (EURC, no arbiter, approve path): split agreed by both sides; an undelivered milestone is
reclaimed after the deadline. Deal 3: cancelled before acceptance. Deal 4: the freelancer is
blocklisted by the token, the payout is deferred, then withdrawn after unblocking.
Screenshots go to docs/screenshots/.
"""
from __future__ import annotations

import json
import subprocess
import sys

from playwright.sync_api import expect, sync_playwright

from harness import (DEV_ACCOUNTS, ROOT, WEB_PORT, Anvil, WebServer, cast, forge_script, launch_browser,
                     parse_address, rpc, tool, wallet_shim)

USDC = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
EURC = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
SD = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"  # matches web/config.js (31337)
DEPLOYER = DEV_ACCOUNTS[0]
CLIENT = DEV_ACCOUNTS[2][0]
PROVIDER = DEV_ACCOUNTS[3][0]
ARBITER = DEV_ACCOUNTS[4][0]
STRANGER = DEV_ACCOUNTS[5][0]
SHOTS = ROOT / "docs" / "screenshots"
E6 = 1_000_000


def balance(token: str, addr: str) -> int:
    return int(cast("call", token, "balanceOf(address)(uint256)", addr).split()[0])


def time_travel(seconds: int) -> None:
    rpc("evm_increaseTime", [seconds])
    rpc("evm_mine")


def nonce(addr: str) -> int:
    return int(rpc("eth_getTransactionCount", [addr, "latest"]), 16)


def main() -> int:
    SHOTS.mkdir(parents=True, exist_ok=True)
    results: dict = {}
    with Anvil(), WebServer(ROOT / "web"), sync_playwright() as p:
        out = forge_script("script/DeployLocal.s.sol:DeployLocal", DEPLOYER[1])
        assert parse_address(out, "MockUSDC deployed at:").lower() == USDC.lower()
        assert parse_address(out, "MockEURC deployed at:").lower() == EURC.lower()
        assert parse_address(out, "SafeDeal deployed at:").lower() == SD.lower()

        browser = launch_browser(p)
        errors: list[str] = []
        start = {who: balance(USDC, who) for who in (CLIENT, PROVIDER, ARBITER, STRANGER)}

        def gained(who: str, token: str = USDC) -> int:
            return balance(token, who) - (start[who] if token == USDC else 10_000 * E6)

        def new_page(account: str):
            ctx = browser.new_context(viewport={"width": 1100, "height": 1000})
            ctx.add_init_script(wallet_shim(account))
            page = ctx.new_page()
            page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
            page.on("console", lambda m: errors.append(f"console.{m.type}: {m.text}") if m.type == "error" else None)
            page.on("response", lambda r: errors.append(f"HTTP {r.status}: {r.url}") if r.status >= 400 else None)
            return page

        base = f"http://127.0.0.1:{WEB_PORT}/?chain=31337"

        def ms_button(page, index: int, action: str):
            return page.locator(f'#ms-rows tr[data-index="{index}"] button[data-action="{action}"]')

        def ms_status(page, index: int):
            return page.locator(f'#ms-rows tr[data-index="{index}"] .st')

        def deal_ok(page, timeout=20000):
            expect(page.locator("#deal-status")).to_have_class("status ok", timeout=timeout)

        # ---------------------------------------------------------------- deal 1
        # 1. The freelancer writes a proposal: no transaction is sent.
        prov = new_page(PROVIDER)
        prov.goto(f"{base}#/")
        expect(prov.locator("#net-badge")).to_have_text("Local Anvil")
        prov.click("#mode-provider")
        expect(prov.locator("#in-provider")).to_have_value(PROVIDER)
        prov.fill("#in-arbiter", ARBITER)
        prov.fill("#in-title", "Landing page for Acme")
        prov.locator(".ms-row .ms-name").nth(0).fill("Design")
        prov.locator(".ms-row .ms-amount").nth(0).fill("100")
        prov.click("#btn-add-ms")
        prov.locator(".ms-row .ms-name").nth(1).fill("Build")
        prov.locator(".ms-row .ms-amount").nth(1).fill("250")
        prov.click("#btn-add-ms")
        prov.locator(".ms-row .ms-name").nth(2).fill("Launch")
        prov.locator(".ms-row .ms-amount").nth(2).fill("150")
        prov.select_option("#in-review", "60")
        prov.select_option("#in-deadline", "86400")
        prov.fill("#in-terms", "Responsive landing page, 3 sections. Source in a public repo.")
        expect(prov.locator("#out-total")).to_have_text("500 USDC")
        n0 = nonce(PROVIDER)
        prov.click("#btn-proposal")
        expect(prov.locator("#new-status")).to_contain_text("no transaction was sent")
        assert nonce(PROVIDER) == n0, "a proposal must not send a transaction"
        proposal = prov.locator("#out-link").input_value()
        assert "#/new?p=" in proposal, proposal
        prov.screenshot(path=str(SHOTS / "01-proposal-link.png"), full_page=True)

        # 2. The client opens the proposal and funds it: one signature + ONE transaction.
        cli = new_page(CLIENT)
        cli.goto(proposal)
        expect(cli.locator("#proposal-banner")).to_be_visible()
        expect(cli.locator("#in-provider")).to_have_value(PROVIDER)
        expect(cli.locator("#out-total")).to_have_text("500 USDC")
        expect(cli.locator("#deal-summary")).to_contain_text("Disputes are decided by the arbiter")
        cli.screenshot(path=str(SHOTS / "02-client-reviews-proposal.png"), full_page=True)
        block_before = int(rpc("eth_blockNumber"), 16)
        cli.click("#btn-fund-permit")
        expect(cli.locator("#new-status")).to_have_class("status ok", timeout=20000)
        expect(cli.locator("#new-status")).to_contain_text("Deal #1 funded")
        results["fund_status"] = cli.locator("#new-status").inner_text()
        assert int(rpc("eth_blockNumber"), 16) == block_before + 1, "permit path must be ONE transaction"
        assert balance(USDC, SD) == 500 * E6
        assert gained(CLIENT) == -500 * E6
        deal1 = cli.locator("#out-link").input_value()
        assert deal1.endswith("#/deal/1?c=31337"), deal1

        # 3. The freelancer accepts.
        prov.goto(deal1)
        expect(prov.locator("#dl-pill")).to_have_text("Waiting for the freelancer")
        expect(prov.locator("#dl-role")).to_have_text("You are the freelancer")
        expect(prov.locator("#dl-terms")).to_contain_text("matches the hash")
        prov.click('#dl-actions button[data-action="accept"]')
        deal_ok(prov)
        expect(prov.locator("#dl-pill")).to_have_text("In progress")
        prov.screenshot(path=str(SHOTS / "03-freelancer-accepted.png"), full_page=True)

        # 4. Milestone 1: delivered with a link, approved by the client.
        ms_button(prov, 0, "deliver").click()
        prov.fill("#ap-text", "https://github.com/acme/landing/pull/1")
        prov.click("#ap-confirm")
        deal_ok(prov)
        expect(ms_status(prov, 0)).to_have_text("Delivered")
        cli.goto(deal1)
        expect(cli.locator('#ms-rows tr[data-index="0"] .note')).to_contain_text("github.com/acme/landing/pull/1", timeout=10000)
        ms_button(cli, 0, "approve").click()
        deal_ok(cli)
        expect(ms_status(cli, 0)).to_have_text("Paid to freelancer")
        assert gained(PROVIDER) == 100 * E6
        cli.screenshot(path=str(SHOTS / "04-client-approved.png"), full_page=True)

        # 5. Milestone 2: delivered, the client stays silent, anyone releases after the review period.
        prov.reload()
        ms_button(prov, 1, "deliver").click()
        prov.fill("#ap-text", "Build done: https://acme-landing.example")
        prov.click("#ap-confirm")
        deal_ok(prov)
        time_travel(61)
        stranger = new_page(STRANGER)
        stranger.goto(deal1)
        expect(stranger.locator("#dl-role")).to_be_hidden()
        expect(ms_button(stranger, 1, "release")).to_be_visible(timeout=10000)
        expect(ms_button(stranger, 1, "approve")).to_have_count(0)
        ms_button(stranger, 1, "release").click()
        deal_ok(stranger)
        assert gained(PROVIDER) == 350 * E6
        assert gained(STRANGER) == 0

        # 6. Milestone 3: delivered, disputed by the client, split by the arbiter (90 / 60).
        prov.reload()
        ms_button(prov, 2, "deliver").click()
        prov.fill("#ap-text", "Launch checklist")
        prov.click("#ap-confirm")
        deal_ok(prov)
        cli.reload()
        ms_button(cli, 2, "dispute").click()
        cli.fill("#ap-text", "Two sections missing on mobile")
        cli.click("#ap-confirm")
        deal_ok(cli)
        expect(ms_status(cli, 2)).to_have_text("Disputed")
        arb = new_page(ARBITER)
        arb.goto(deal1)
        expect(arb.locator("#dl-role")).to_have_text("You are the arbiter")
        expect(arb.locator('#ms-rows tr[data-index="2"] .reason')).to_contain_text("Two sections missing", timeout=10000)
        ms_button(arb, 2, "resolve").click()
        arb.fill("#ap-amount", "90")
        expect(arb.locator("#ap-amount-rest")).to_have_text("client gets 60")
        arb.click("#ap-confirm")
        deal_ok(arb)
        expect(arb.locator("#deal-status")).to_contain_text("90 USDC to the freelancer, 60 USDC to the client")
        expect(arb.locator("#dl-pill")).to_have_text("Completed")
        arb.screenshot(path=str(SHOTS / "05-arbiter-ruling.png"), full_page=True)
        assert gained(PROVIDER) == 440 * E6
        assert gained(CLIENT) == -440 * E6
        assert gained(ARBITER) == 0, "the arbiter never receives deal funds"
        assert balance(USDC, SD) == 0

        # ---------------------------------------------------------------- deal 2 (EURC, no arbiter)
        cli.goto(f"{base}#/")
        cli.click("#mode-client")
        cli.fill("#in-provider", PROVIDER)
        cli.fill("#in-arbiter", "")
        cli.fill("#in-title", "Logo in EURC")
        cli.select_option("#in-token", EURC)
        cli.locator(".ms-row .ms-name").nth(0).fill("Sketches")
        cli.locator(".ms-row .ms-amount").nth(0).fill("100")
        cli.click("#btn-add-ms")
        cli.locator(".ms-row .ms-name").nth(1).fill("Final files")
        cli.locator(".ms-row .ms-amount").nth(1).fill("200")
        cli.select_option("#in-deadline", "600")
        cli.select_option("#in-review", "60")
        cli.fill("#in-terms", "")
        expect(cli.locator("#out-total")).to_have_text("300 EURC")
        expect(cli.locator("#deal-summary")).to_contain_text("No arbiter")
        cli.click("#btn-fund-approve")
        expect(cli.locator("#new-status")).to_contain_text("Deal #2 funded", timeout=30000)
        assert balance(EURC, SD) == 300 * E6
        deal2 = cli.locator("#out-link").input_value()
        prov.goto(deal2)
        prov.click('#dl-actions button[data-action="accept"]')
        deal_ok(prov)
        # Split agreed by both: the client offers 40, the freelancer accepts it with one click.
        cli.goto(deal2)
        ms_button(cli, 0, "settle").click()
        cli.fill("#ap-amount", "40")
        cli.click("#ap-confirm")
        deal_ok(cli)
        expect(cli.locator('#ms-rows tr[data-index="0"] .offers')).to_contain_text("Client offers the freelancer 40 EURC")
        prov.reload()
        ms_button(prov, 0, "accept-split").click()
        deal_ok(prov)
        expect(ms_status(prov, 0)).to_have_text("Split: 40 / 60 EURC")
        # Milestone 2 is never delivered: after the deadline the client takes it back.
        time_travel(601)
        cli.reload()
        ms_button(cli, 1, "reclaim").click()
        deal_ok(cli)
        expect(ms_status(cli, 1)).to_have_text("Refunded to client")
        expect(cli.locator("#dl-pill")).to_have_text("Completed")
        assert gained(PROVIDER, EURC) == 40 * E6
        assert gained(CLIENT, EURC) == -40 * E6
        assert balance(EURC, SD) == 0

        # ---------------------------------------------------------------- deal 3 (cancel)
        cli.goto(f"{base}#/")
        cli.fill("#in-provider", PROVIDER)
        cli.fill("#in-title", "Cancelled job")
        cli.select_option("#in-token", USDC)
        while cli.locator(".ms-row").count() > 1:
            cli.locator(".ms-row button").last.click()
        cli.locator(".ms-row .ms-name").nth(0).fill("All")
        cli.locator(".ms-row .ms-amount").nth(0).fill("25")
        cli.click("#btn-fund-permit")
        expect(cli.locator("#new-status")).to_contain_text("Deal #3 funded", timeout=20000)
        cli.goto(cli.locator("#out-link").input_value())
        expect(cli.locator("#dl-share")).to_be_visible()
        cli.click('#dl-actions button[data-action="cancel"]')
        deal_ok(cli)
        expect(cli.locator("#dl-pill")).to_have_text("Cancelled")
        assert gained(CLIENT) == -440 * E6

        # ---------------------------------------------------------------- deal 4 (blocklisted freelancer)
        cli.goto(f"{base}#/")
        cli.fill("#in-provider", PROVIDER)
        cli.fill("#in-title", "Blocklist drill")
        cli.locator(".ms-row .ms-name").nth(0).fill("Job")
        cli.locator(".ms-row .ms-amount").nth(0).fill("10")
        cli.click("#btn-fund-permit")
        expect(cli.locator("#new-status")).to_contain_text("Deal #4 funded", timeout=20000)
        deal4 = cli.locator("#out-link").input_value()
        prov.goto(deal4)
        prov.click('#dl-actions button[data-action="accept"]')
        deal_ok(prov)
        cast("send", USDC, "setBlacklisted(address,bool)", PROVIDER, "true", "--private-key", DEPLOYER[1])
        cli.goto(deal4)
        ms_button(cli, 0, "approve").click()
        deal_ok(cli)
        expect(cli.locator("#deal-status")).to_contain_text("held for the recipient")
        assert balance(USDC, SD) == 10 * E6, "funds stay in escrow, credited to the freelancer"
        cast("send", USDC, "setBlacklisted(address,bool)", PROVIDER, "false", "--private-key", DEPLOYER[1])
        prov.goto(f"{base}#/my")
        expect(prov.locator("#my-claims")).to_contain_text("10 USDC is waiting for you", timeout=10000)
        prov.click("#btn-withdraw")
        expect(prov.locator("#my-claims")).to_contain_text("Withdrawn", timeout=20000)
        assert gained(PROVIDER) == 450 * E6
        assert balance(USDC, SD) == 0

        # ---------------------------------------------------------------- my deals
        cli.goto(f"{base}#/my")
        expect(cli.locator("#my-rows tr")).to_have_count(4, timeout=10000)
        expect(cli.locator('#my-rows tr[data-deal-id="3"] td.deal-state')).to_have_text("Cancelled")
        expect(cli.locator('#my-rows tr[data-deal-id="1"] td.deal-state')).to_have_text("Completed")
        cli.screenshot(path=str(SHOTS / "06-my-deals.png"), full_page=True)
        prov.goto(deal1)
        expect(prov.locator("#dl-progress-text")).to_contain_text("440 paid · 60 refunded · 0 USDC in escrow")
        prov.screenshot(path=str(SHOTS / "07-deal-completed.png"), full_page=True)

        # Gas used by each call (reported in the README).
        sigs = [
            "createDeal((address,address,address,uint64,uint32,string,string,string[],uint96[]))",
            "createDealWithPermit((address,address,address,uint64,uint32,string,string,string[],uint96[]),uint256,uint256,uint8,bytes32,bytes32)",
            "accept(uint256)", "cancel(uint256)", "deliver(uint256,uint256,string)", "approveMilestone(uint256,uint256)",
            "releaseAfterReview(uint256,uint256)", "dispute(uint256,uint256,string)", "resolve(uint256,uint256,uint96)",
            "proposeSettlement(uint256,uint256,uint96)", "reclaimAfterDeadline(uint256,uint256)", "withdraw(address)",
        ]
        selectors = {subprocess.run([tool("cast"), "sig", s], capture_output=True, text=True).stdout.strip(): s.split("(")[0] for s in sigs}
        logs = json.loads(cast("logs", "--from-block", "0", "--address", SD, "--json"))
        gas: dict[str, list[int]] = {}
        for tx_hash in dict.fromkeys(l["transactionHash"] for l in logs):
            rc = json.loads(cast("receipt", tx_hash, "--json"))
            name = selectors.get(cast("tx", tx_hash, "input")[:10], "?")
            gas.setdefault(name, []).append(int(rc["gasUsed"], 16))
        results["gas_by_function"] = gas

        browser.close()
        real_errors = [e for e in errors if "favicon" not in e]
        assert not real_errors, real_errors
        results["browser_errors"] = 0

    print(json.dumps(results, indent=2, ensure_ascii=False))
    print("E2E OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
