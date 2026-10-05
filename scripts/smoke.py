"""Live smoke test: one SafeDeal deal through all three payout paths, using Foundry's `cast`.

    CLIENT_KEY=... PROVIDER_KEY=... ARBITER_KEY=... SAFEDEAL=0x... RPC_URL=https://rpc.mainnet.arc.io \\
        python scripts/smoke.py [--sweep] [--out docs/mainnet-smoke.json]

Three wallets you control play client, freelancer and arbiter. The client funds a 3-milestone deal
with ONE transaction (EIP-2612 permit signed by `cast wallet sign`), the freelancer accepts, then:
  milestone 1 is delivered and approved by the client;
  milestone 2 is delivered and released by a third party after the review period (60 s);
  milestone 3 is delivered, disputed by the client and split by the arbiter.
Every receipt is checked (status 1) and recorded with its gas. `--sweep` sends what is left on the
freelancer and arbiter wallets back to the client afterwards.

Keys are read from the environment only and are never printed or written anywhere.
"""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

CAST = shutil.which("cast") or str(pathlib.Path.home() / ".foundry" / "bin" / "cast")
RPC = os.environ.get("RPC_URL", "https://rpc.mainnet.arc.io")
SD = os.environ["SAFEDEAL"]
KEYS = {role: os.environ[f"{role.upper()}_KEY"] for role in ("client", "provider", "arbiter")}
UNITS = int(os.environ.get("MILESTONE_UNITS", "50000"))  # 0.05 USDC per milestone
REVIEW = 60
GAS_TOPUP_WEI = int(os.environ.get("GAS_TOPUP_WEI", str(20 * 10**15)))  # 0.02 USDC (native, 18 decimals)
DEAL_SIG = "(address,address,address,uint64,uint32,string,string,string[],uint96[])"
SECRETS = set(KEYS.values())


def _scrub(text: str) -> str:
    for s in SECRETS:
        text = text.replace(s, "<key>").replace(s[2:], "<key>")
    return text


def cast(*args: str, key: str | None = None, rpc: bool = True) -> str:
    cmd = [CAST, *args]
    if rpc:
        cmd += ["--rpc-url", RPC]
    if key:
        cmd += ["--private-key", key]
    out = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if out.returncode != 0:
        raise RuntimeError(_scrub(f"cast {args[0]} failed: {out.stderr.strip() or out.stdout.strip()}"))
    return out.stdout.strip()


def addr_of(key: str) -> str:
    return cast("wallet", "address", "--private-key", key, rpc=False)


def num(text: str) -> int:
    return int(text.split()[0])


TXS: list[dict] = []


def send(label: str, role: str, to: str, *args: str) -> dict:
    rc = json.loads(cast("send", to, *args, "--json", key=KEYS[role]))
    if rc.get("status") not in ("0x1", 1, "1"):
        raise RuntimeError(f"{label}: transaction reverted ({rc.get('transactionHash')})")
    entry = {"step": label, "by": role, "tx": rc["transactionHash"], "block": int(rc["blockNumber"], 16),
             "gasUsed": int(rc["gasUsed"], 16), "effectiveGasPrice": int(rc["effectiveGasPrice"], 16)}
    TXS.append(entry)
    print(f"  {label:<38} {entry['tx']}  gas {entry['gasUsed']:>8,}", flush=True)
    return entry


def sign_permit(token: str, owner: str, value: int, deadline: int, chain_id: int) -> tuple[int, str, str]:
    name = cast("call", token, "name()(string)").strip('"')
    version = cast("call", token, "version()(string)").strip('"')
    nonce = num(cast("call", token, "nonces(address)(uint256)", owner))
    typed = {
        "types": {
            "EIP712Domain": [{"name": "name", "type": "string"}, {"name": "version", "type": "string"},
                             {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}],
            "Permit": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"},
                       {"name": "value", "type": "uint256"}, {"name": "nonce", "type": "uint256"},
                       {"name": "deadline", "type": "uint256"}],
        },
        "primaryType": "Permit",
        "domain": {"name": name, "version": version, "chainId": chain_id, "verifyingContract": token},
        "message": {"owner": owner, "spender": SD, "value": value, "nonce": nonce, "deadline": deadline},
    }
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "permit.json"
        path.write_text(json.dumps(typed), encoding="utf-8")
        sig = cast("wallet", "sign", "--data", "--from-file", str(path), "--private-key", KEYS["client"], rpc=False)
    sig = sig.removeprefix("0x")
    return int(sig[128:130], 16), "0x" + sig[:64], "0x" + sig[64:128]


def sweep(client: str) -> None:
    gas_price = 25 * 10**9  # above Arc's 20 gwei floor
    for role in ("provider", "arbiter"):
        who = addr_of(KEYS[role])
        bal = num(cast("balance", who))
        limit = 30_000
        value = bal - limit * gas_price
        if value <= 0:
            print(f"  {role}: nothing to sweep")
            continue
        send(f"sweep {role} -> client", role, client, "--value", str(value), "--gas-limit", str(limit),
             "--gas-price", str(gas_price))


def main() -> int:
    out_path = None
    if "--out" in sys.argv:
        out_path = pathlib.Path(sys.argv[sys.argv.index("--out") + 1])
    client, provider, arbiter = (addr_of(KEYS[r]) for r in ("client", "provider", "arbiter"))
    chain_id = num(cast("chain-id"))
    usdc = cast("call", SD, "usdc()(address)")
    print(f"chain {chain_id}, SafeDeal {SD}, USDC {usdc}")
    print(f"client {client}\nfreelancer {provider}\narbiter {arbiter}")

    for role, who in (("provider", provider), ("arbiter", arbiter)):
        if num(cast("balance", who)) < GAS_TOPUP_WEI // 2:
            send(f"gas top-up for {role}", "client", who, "--value", str(GAS_TOPUP_WEI))

    total = 3 * UNITS
    now = num(cast("block", "latest", "--field", "timestamp"))
    deadline = now + 7 * 86400
    terms = ("Public smoke test of SafeDeal on Arc mainnet. Client, freelancer and arbiter are three wallets "
             "controlled by the SafeDeal maintainer. Each milestone exercises one payout path.")
    params = (f'({provider},{arbiter},{usdc},{deadline},{REVIEW},"SafeDeal mainnet smoke test","{terms}",'
              f'["Approve path","Review timeout path","Dispute path"],[{UNITS},{UNITS},{UNITS}])')
    v, r, s = sign_permit(usdc, client, total, now + 3600, chain_id)
    before = num(cast("call", SD, "dealCount()(uint256)"))
    send("createDealWithPermit (1 tx)", "client", SD,
         f"createDealWithPermit({DEAL_SIG},uint256,uint256,uint8,bytes32,bytes32)", params, str(total),
         str(now + 3600), str(v), r, s)
    deal = num(cast("call", SD, "dealCount()(uint256)"))
    assert deal == before + 1, "deal was not created"
    print(f"deal #{deal} funded with {total / 1e6} USDC")

    send("accept", "provider", SD, "accept(uint256)", str(deal))
    send("deliver milestone 1", "provider", SD, "deliver(uint256,uint256,string)", str(deal), "0",
         "https://github.com/Minkhanov/safedeal-arc")
    send("approveMilestone 1 (client)", "client", SD, "approveMilestone(uint256,uint256)", str(deal), "0")
    send("deliver milestone 2", "provider", SD, "deliver(uint256,uint256,string)", str(deal), "1",
         "Client stays silent: released by a third party after the review period")
    print(f"  waiting {REVIEW + 3} s for the review period…", flush=True)
    time.sleep(REVIEW + 3)
    send("releaseAfterReview 2 (third party)", "arbiter", SD, "releaseAfterReview(uint256,uint256)", str(deal), "1")
    send("deliver milestone 3", "provider", SD, "deliver(uint256,uint256,string)", str(deal), "2", "Final delivery")
    send("dispute milestone 3 (client)", "client", SD, "dispute(uint256,uint256,string)", str(deal), "2",
         "Smoke test: dispute path")
    send("resolve 3 (arbiter: 60/40)", "arbiter", SD, "resolve(uint256,uint256,uint96)", str(deal), "2",
         str(UNITS * 6 // 10))

    locked = num(cast("call", SD, "totalLocked(address)(uint256)", usdc))
    claimable = num(cast("call", SD, "totalClaimable(address)(uint256)", usdc))
    escrow = num(cast("call", usdc, "balanceOf(address)(uint256)", SD))
    print(f"escrow balance {escrow}, totalLocked {locked}, totalClaimable {claimable}")
    assert escrow >= locked + claimable

    if "--sweep" in sys.argv:
        sweep(client)

    result = {"chainId": chain_id, "safeDeal": SD, "usdc": usdc, "dealId": deal,
              "wallets": {"client": client, "freelancer": provider, "arbiter": arbiter},
              "milestoneUnits": UNITS, "transactions": TXS}
    if out_path:
        out_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"saved {out_path}")
    print("SMOKE OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
