"""Local end-to-end harness: anvil + forge deploy + static web server + EIP-1193 wallet shim.

Only anvil's public, well-known development accounts are used. Nothing here touches a real
network or a real key.
"""
from __future__ import annotations

import functools
import http.server
import json
import os
import pathlib
import re
import shutil
import socketserver
import subprocess
import threading
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
ANVIL_PORT = int(os.environ.get("ANVIL_PORT", "8545"))
WEB_PORT = int(os.environ.get("WEB_PORT", "8787"))
RPC = f"http://127.0.0.1:{ANVIL_PORT}"

# anvil default mnemonic "test test test test test test test test test test test junk"
DEV_ACCOUNTS = [
    ("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"),
    ("0x70997970C51812dc3A010C7d01b50e0d17dc79C8", "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"),
    ("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"),
    ("0x90F79bf6EB2c4f870365E785982E1f101E93b906", "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"),
    ("0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65", "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"),
    ("0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc", "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"),
]


def tool(name: str) -> str:
    """Locate a Foundry binary (PATH or ~/.foundry/bin)."""
    found = shutil.which(name)
    if found:
        return found
    for cand in (pathlib.Path.home() / ".foundry" / "bin" / f"{name}.exe", pathlib.Path.home() / ".foundry" / "bin" / name):
        if cand.exists():
            return str(cand)
    raise FileNotFoundError(f"{name} not found — install Foundry (https://getfoundry.sh)")


def rpc(method: str, params: list | None = None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        out = json.loads(r.read())
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


class Anvil:
    def __init__(self):
        self.proc: subprocess.Popen | None = None

    def __enter__(self):
        self.proc = subprocess.Popen(
            [tool("anvil"), "--port", str(ANVIL_PORT), "--silent"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(100):
            try:
                rpc("eth_chainId")
                return self
            except Exception:
                time.sleep(0.1)
        raise RuntimeError("anvil did not start")

    def __exit__(self, *exc):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def forge_script(script: str, key: str, extra_env: dict | None = None) -> str:
    env = {**os.environ, **(extra_env or {})}
    out = subprocess.run(
        [tool("forge"), "script", script, "--rpc-url", RPC, "--private-key", key, "--broadcast"],
        cwd=ROOT, capture_output=True, text=True, env=env, encoding="utf-8", errors="replace",
    )
    if out.returncode != 0:
        raise RuntimeError(f"forge script failed:\n{out.stdout}\n{out.stderr}")
    return out.stdout


def cast(*args: str) -> str:
    out = subprocess.run([tool("cast"), *args, "--rpc-url", RPC], capture_output=True, text=True, encoding="utf-8", errors="replace")
    if out.returncode != 0:
        raise RuntimeError(f"cast {' '.join(args)} failed: {out.stderr}")
    return out.stdout.strip()


def parse_address(stdout: str, label: str) -> str:
    m = re.search(re.escape(label) + r"\s*(0x[0-9a-fA-F]{40})", stdout)
    if not m:
        raise RuntimeError(f"'{label}' not found in:\n{stdout}")
    return m.group(1)


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):  # keep test output clean
        pass


class WebServer:
    def __init__(self, directory: pathlib.Path):
        self.directory = directory
        self.httpd = None

    def __enter__(self):
        handler = functools.partial(_QuietHandler, directory=str(self.directory))
        socketserver.TCPServer.allow_reuse_address = True
        self.httpd = socketserver.ThreadingTCPServer(("127.0.0.1", WEB_PORT), handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()


def wallet_shim(account: str, chain_id: int = 31337) -> str:
    """EIP-1193 provider that forwards to anvil; anvil signs for its unlocked dev accounts."""
    return """
(() => {
  const RPC = %s;
  const listeners = {};
  window.ethereum = {
    isShim: true,
    _account: %s,
    _chainId: %s,
    on(ev, fn) { (listeners[ev] = listeners[ev] || []).push(fn); },
    removeListener(ev, fn) { listeners[ev] = (listeners[ev] || []).filter((f) => f !== fn); },
    async request({ method, params }) {
      if (method === "eth_requestAccounts" || method === "eth_accounts") return [this._account];
      if (method === "eth_chainId") return this._chainId;
      if (method === "wallet_switchEthereumChain") {
        if (params[0].chainId.toLowerCase() !== this._chainId) { const e = new Error("Unrecognized chain"); e.code = 4902; throw e; }
        return null;
      }
      if (method === "wallet_addEthereumChain") return null;
      const res = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params: params || [] }) });
      const j = await res.json();
      if (j.error) { const e = new Error(j.error.message); e.code = j.error.code; e.data = j.error.data; throw e; }
      return j.result;
    },
  };
})();
""" % (json.dumps(RPC), json.dumps(account), json.dumps(hex(chain_id)))


def launch_browser(p):
    """Prefer an installed Chrome/Edge so no browser download is needed."""
    for channel in ("chrome", "msedge", None):
        try:
            return p.chromium.launch(channel=channel, headless=True) if channel else p.chromium.launch(headless=True)
        except Exception:
            continue
    raise RuntimeError("No Chromium-based browser available for Playwright")
