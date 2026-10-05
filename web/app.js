"use strict";
/*
 * SafeDeal front-end — plain JavaScript, no build step, no backend.
 *
 * Arc specifics handled here:
 *  - amounts use the 6-decimal ERC-20 interfaces of USDC and EURC, at the addresses the contract
 *    itself reports (usdc(), eurc());
 *  - "sign & pay in 1 transaction" uses the EIP-2612 permit built into Arc's stablecoins (domain
 *    name = token name, version "2"); the app checks the domain separator on-chain before asking for
 *    a signature and otherwise falls back to approve + create;
 *  - gas is paid in USDC, so fees are shown in dollars;
 *  - finality is deterministic: one receipt is final; receipts are polled every 250 ms;
 *  - delivery notes, dispute reasons and terms live in event logs; the contract stores the block of
 *    each one, so the app reads a single block instead of scanning ranges (Arc's public RPC caps
 *    eth_getLogs ranges).
 * Everything user-supplied (titles, notes, terms) is rendered with textContent, never as HTML.
 */
(function () {
  const { ethers } = window;
  const CFG = window.SAFEDEAL_CONFIG;
  const ZERO = ethers.ZeroAddress;
  const DECIMALS = 6;
  const MAX_MILESTONES = 10;
  const ARBITRATION_TIMEOUT = 30 * 86400;
  // Gas measured in the e2e run (see README); used only for the fee estimate shown before signing.
  const GAS = { create: 250000n, perMilestone: 115000n };

  const DEAL_TUPLE = "tuple(address client, uint64 deadline, uint32 reviewPeriod, address provider, uint64 createdBlock, uint8 milestoneCount, uint8 openMilestones, uint8 status, address arbiter, uint96 total, address token, uint96 locked, bytes32 termsHash, string title)";
  const MS_TUPLE = "tuple(uint96 amount, uint8 status, uint8 resolution, uint64 deliveredAt, uint64 disputedAt, uint96 toProvider, uint64 deliveredBlock, uint64 disputedBlock, uint96 clientOffer, uint96 providerOffer, bool clientOffered, bool providerOffered, string name)";
  const PARAMS_TUPLE = "tuple(address provider, address arbiter, address token, uint64 deadline, uint32 reviewPeriod, string title, string terms, string[] milestoneNames, uint96[] milestoneAmounts)";
  const ABI = [
    "function usdc() view returns (address)",
    "function eurc() view returns (address)",
    `function createDeal(${PARAMS_TUPLE} p) returns (uint256)`,
    `function createDealWithPermit(${PARAMS_TUPLE} p, uint256 permitValue, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) returns (uint256)`,
    "function accept(uint256 dealId)",
    "function cancel(uint256 dealId)",
    "function decline(uint256 dealId)",
    "function extendDeadline(uint256 dealId, uint64 newDeadline)",
    "function deliver(uint256 dealId, uint256 index, string note)",
    "function approveMilestone(uint256 dealId, uint256 index)",
    "function releaseAfterReview(uint256 dealId, uint256 index)",
    "function refund(uint256 dealId, uint256 index)",
    "function reclaimAfterDeadline(uint256 dealId, uint256 index)",
    "function dispute(uint256 dealId, uint256 index, string reason)",
    "function resolve(uint256 dealId, uint256 index, uint96 toProvider)",
    "function resolveAfterTimeout(uint256 dealId, uint256 index)",
    "function proposeSettlement(uint256 dealId, uint256 index, uint96 toProvider)",
    "function withdrawSettlement(uint256 dealId, uint256 index)",
    "function withdraw(address token)",
    `function getDeal(uint256 dealId) view returns (${DEAL_TUPLE})`,
    `function getMilestones(uint256 dealId) view returns (${MS_TUPLE}[])`,
    "function dealCount() view returns (uint256)",
    "function dealCountOf(address account) view returns (uint256)",
    "function dealsOf(address account, uint256 offset, uint256 limit) view returns (uint256[])",
    "function claimable(address token, address account) view returns (uint256)",
    "event DealCreated(uint256 indexed dealId, address indexed client, address indexed provider, address arbiter, address token, uint256 total, string terms)",
    "event MilestoneDelivered(uint256 indexed dealId, uint256 indexed index, string note)",
    "event MilestoneDisputed(uint256 indexed dealId, uint256 indexed index, string reason)",
    "event MilestoneClosed(uint256 indexed dealId, uint256 indexed index, uint8 resolution, uint256 toProvider, uint256 toClient)",
    "event PayoutDeferred(address indexed token, address indexed account, uint256 amount)",
    "error InvalidToken()", "error UnsupportedToken(address token)", "error InvalidParties()", "error InvalidMilestones()",
    "error InvalidAmount()", "error InvalidName()", "error InvalidTitle()", "error TermsTooLong()", "error NoteTooLong()",
    "error InvalidDeadline()", "error InvalidReviewPeriod()", "error UnknownDeal(uint256 dealId)",
    "error UnknownMilestone(uint256 dealId, uint256 index)", "error NotClient()", "error NotProvider()", "error NotArbiter()",
    "error NotParty()", "error WrongDealStatus(uint8 status)", "error WrongMilestoneStatus(uint8 status)",
    "error DeadlinePassed(uint64 deadline)", "error DeadlineNotPassed(uint64 deadline)", "error ReviewPeriodOver(uint64 endedAt)",
    "error ReviewPeriodNotOver(uint64 endsAt)", "error ArbitrationNotTimedOut(uint64 endsAt)", "error InvalidSplit()",
    "error NothingToWithdraw()", "error TransferFailed()", "error InsufficientGas()",
  ];
  const TOKEN_ABI = [
    "function name() view returns (string)",
    "function symbol() view returns (string)",
    "function version() view returns (string)",
    "function nonces(address owner) view returns (uint256)",
    "function DOMAIN_SEPARATOR() view returns (bytes32)",
    "function balanceOf(address owner) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 value) returns (bool)",
  ];
  const iface = new ethers.Interface(ABI);

  /** JSON-RPC provider that retries batch items rejected by a rate limit. Arc's public RPC answers
   *  some items of a batch (notably eth_getLogs) with -32005 "rate limit exceeded"; ethers does not
   *  retry per-item errors, so only those items are re-sent, with exponential backoff. */
  class RetryingProvider extends ethers.JsonRpcProvider {
    async _send(payload) {
      const list = Array.isArray(payload) ? payload : [payload];
      let results = await super._send(list);
      for (let attempt = 0; attempt < 5; attempt++) {
        const limited = new Set(results
          .filter((r) => r && r.error && (r.error.code === -32005 || /rate limit/i.test(r.error.message || "")))
          .map((r) => r.id));
        if (!limited.size) break;
        await new Promise((res) => setTimeout(res, 300 * 2 ** attempt));
        const again = await super._send(list.filter((p) => limited.has(p.id)));
        const byId = new Map(again.map((r) => [r.id, r]));
        results = results.map((r) => byId.get(r.id) || r);
      }
      return results;
    }
  }

  const DEAL_STATUS = ["None", "Open", "Active", "Closed", "Cancelled"];
  const MS = { Pending: 0, Delivered: 1, Disputed: 2, Closed: 3 };
  const RESOLUTION = [
    "", "Approved by the client", "Released after the review period", "Refunded by the freelancer",
    "Reclaimed after the deadline", "Arbiter's ruling", "Settled by agreement", "Split 50/50 after arbitration timeout",
    "Deal cancelled",
  ];

  const state = {
    net: null, read: null, sd: null, tokens: [], signer: null, account: null,
    mode: "client", deal: null, dealId: null, ms: [], chainNow: 0, watch: null, panel: null, notes: {},
    formKey: null, renderKey: null, gasPrice: null,
  };

  // ------------------------------------------------------------------ helpers

  const $ = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
  const setText = (id, t) => { $(id).textContent = t; };
  const same = (a, b) => Boolean(a && b) && a.toLowerCase() === b.toLowerCase();
  const explorerAddr = (a) => (state.net.explorer ? `${state.net.explorer}/address/${a}` : null);
  const isDeployed = () => Boolean(state.net.safeDeal) && state.net.safeDeal !== ZERO;
  const tokenOf = (addr) => state.tokens.find((t) => same(t.address, addr));
  const symbolOf = (addr) => (tokenOf(addr) || { symbol: "?" }).symbol;
  const bytesLen = (s) => new TextEncoder().encode(s).length;

  function fmtAmount(units) {
    const [i, f = ""] = ethers.formatUnits(units, DECIMALS).split(".");
    const frac = f.replace(/0+$/, "");
    const int = i.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return frac ? `${int}.${frac}` : int;
  }

  /** Amount without thousands separators, for links and inputs ("100", "99.5"). */
  function plainAmount(units) {
    const [i, f = ""] = ethers.formatUnits(units, DECIMALS).split(".");
    const frac = f.replace(/0+$/, "");
    return frac ? `${i}.${frac}` : i;
  }

  function parseAmount(text, { allowZero = false } = {}) {
    const t = String(text || "").trim().replace(",", ".");
    if (!/^\d{1,12}(\.\d{1,6})?$/.test(t)) throw new Error("Enter an amount like 250 or 99.5 (at most 6 decimals).");
    const v = ethers.parseUnits(t, DECIMALS);
    if (v === 0n && !allowZero) throw new Error("Amounts must be greater than zero.");
    return v;
  }

  function fmtDuration(sec) {
    let s = Math.max(0, Math.round(Number(sec)));
    const d = Math.floor(s / 86400); s -= d * 86400;
    const h = Math.floor(s / 3600); s -= h * 3600;
    const m = Math.floor(s / 60); s -= m * 60;
    if (d) return h ? `${d}d ${h}h` : `${d}d`;
    if (h) return m ? `${h}h ${m}m` : `${h}h`;
    if (m) return s ? `${m}m ${s}s` : `${m}m`;
    return `${s}s`;
  }
  const fmtPeriod = (sec) => {
    const s = Number(sec);
    if (s % 86400 === 0) return s === 86400 ? "1 day" : `${s / 86400} days`;
    if (s % 3600 === 0) return s === 3600 ? "1 hour" : `${s / 3600} hours`;
    if (s % 60 === 0) return s === 60 ? "1 minute" : `${s / 60} minutes`;
    return `${s} seconds`;
  };
  const fmtTime = (ts) => new Date(Number(ts) * 1000).toLocaleString();
  function relative(ts) {
    const diff = Number(ts) - state.chainNow;
    return diff >= 0 ? `in ${fmtDuration(diff)}` : `${fmtDuration(-diff)} ago`;
  }

  function addressOrEmpty(text, label) {
    const t = String(text || "").trim();
    if (!t) return ZERO;
    if (!ethers.isAddress(t)) throw new Error(`${label}: not a valid address.`);
    return ethers.getAddress(t);
  }

  function linkOrText(el, href, text) {
    el.textContent = "";
    if (href) {
      const a = document.createElement("a");
      a.href = href; a.target = "_blank"; a.rel = "noopener"; a.textContent = text;
      el.appendChild(a);
    } else {
      el.textContent = text;
    }
  }

  /** Render a user note: plain text, but a single http(s) URL becomes a link (shown in full). */
  function renderNote(el, text) {
    el.textContent = "";
    const t = String(text || "");
    if (/^https?:\/\/\S+$/i.test(t.trim())) {
      const a = document.createElement("a");
      a.href = t.trim(); a.target = "_blank"; a.rel = "noopener noreferrer nofollow"; a.textContent = t.trim();
      el.appendChild(a);
    } else {
      el.textContent = t;
    }
  }

  function showStatus(id, kind, text) {
    const el = $(id);
    el.hidden = false;
    el.className = `status${kind ? ` ${kind}` : ""}`;
    el.textContent = text;
    return el;
  }

  function toast(text) {
    const t = document.createElement("div");
    t.textContent = text;
    t.style.cssText = "position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:#0f172a;color:#fff;padding:10px 16px;border-radius:10px;font-size:14px;z-index:99;max-width:90vw";
    document.body.appendChild(t);
    setTimeout(() => t.remove(), 4500);
  }

  function qrInto(img, text) {
    const qr = window.qrcode(0, "M");
    qr.addData(text);
    qr.make();
    img.src = qr.createDataURL(5, 2);
  }

  function friendlyError(e) {
    if (!e) return "Unknown error.";
    if (e.code === "ACTION_REJECTED" || e.code === 4001 || (e.info && e.info.error && e.info.error.code === 4001)) {
      return "Request rejected in the wallet.";
    }
    let rev = e.revert;
    if (!rev && typeof e.data === "string") {
      try { rev = iface.parseError(e.data); } catch (_) { rev = null; }
    }
    const name = rev && rev.name;
    const map = {
      UnsupportedToken: "This currency is not supported by the contract.",
      InvalidParties: "Client, freelancer and arbiter must be three different addresses (the arbiter is optional).",
      InvalidMilestones: "A deal needs 1 to 10 milestones.",
      InvalidAmount: "Every milestone needs an amount above zero.",
      InvalidName: "Milestone names must be 1–31 bytes.",
      InvalidTitle: "The title must be 1–64 bytes.",
      TermsTooLong: "The terms are longer than 4,096 bytes.",
      NoteTooLong: "The note is longer than 512 bytes.",
      InvalidDeadline: "That deadline is not allowed (it must be in the future, later than the current one, within 3 years).",
      InvalidReviewPeriod: "Unsupported review period.",
      UnknownDeal: "This deal does not exist.",
      UnknownMilestone: "Unknown milestone.",
      NotClient: "Only the client can do this.",
      NotProvider: "Only the freelancer can do this.",
      NotArbiter: "Only the deal's arbiter can do this.",
      NotParty: "Only the client or the freelancer can do this.",
      WrongDealStatus: "The deal is not in the right state for this — refresh the page.",
      WrongMilestoneStatus: "The milestone is not in the right state for this — refresh the page.",
      DeadlinePassed: "The delivery deadline has passed — the client can extend it.",
      DeadlineNotPassed: "The delivery deadline has not passed yet.",
      ReviewPeriodOver: "The review period is over; the milestone can now be released.",
      ReviewPeriodNotOver: "The review period is still running.",
      ArbitrationNotTimedOut: "The 30-day arbitration window is still open.",
      InvalidSplit: "The split cannot exceed the milestone amount.",
      NothingToWithdraw: "Nothing to withdraw.",
      TransferFailed: "The token transfer failed.",
      InsufficientGas: "The transaction ran out of gas — retry with a higher gas limit.",
    };
    if (name && map[name]) return map[name];
    const reason = (rev && rev.name === "Error" && rev.args && rev.args[0]) || e.reason || "";
    if (/allowance/i.test(reason)) return "The allowance is too low — approve the full amount first.";
    if (/exceeds balance/i.test(reason)) return "Not enough funds in the wallet for this deal.";
    if (/blacklist/i.test(reason)) return "The token issuer has blocked this address.";
    const msg = e.shortMessage || reason || e.message || String(e);
    if (e.code === "INSUFFICIENT_FUNDS" || /insufficient funds/i.test(msg)) return "Not enough USDC for the network fee.";
    return msg;
  }

  function parseHash() {
    const h = window.location.hash || "#/";
    const [path, query] = h.slice(1).split("?");
    return { path: path || "/", params: new URLSearchParams(query || "") };
  }

  function chainIdFromLocation() {
    const fromHash = Number(parseHash().params.get("c"));
    if (fromHash && CFG.networks[fromHash]) return fromHash;
    const fromQuery = Number(new URLSearchParams(window.location.search).get("chain"));
    if (fromQuery && CFG.networks[fromQuery]) return fromQuery;
    return CFG.defaultChainId;
  }

  const pageBase = () => window.location.href.split("#")[0];
  const dealLink = (id) => `${pageBase()}#/deal/${id}?c=${state.net.chainId}`;

  function startPoll(fn, ms) {
    const token = {};
    state.watch = token;
    (async () => {
      while (state.watch === token) {
        await sleep(ms);
        if (state.watch !== token) return;
        try { await fn(); } catch (_) { /* keep polling */ }
      }
    })();
  }
  const stopPoll = () => { state.watch = null; };

  async function mapLimit(items, limit, fn) {
    const out = new Array(items.length);
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) { const i = next++; out[i] = await fn(items[i], i); }
    }));
    return out;
  }

  async function waitReceipt(hash, timeoutMs = 120000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const rc = await state.read.getTransactionReceipt(hash).catch(() => null);
      if (rc) {
        if (rc.status !== 1) throw new Error("The transaction reverted.");
        return rc;
      }
      await sleep(250);
    }
    throw new Error("Timed out waiting for the transaction — check it in the explorer.");
  }

  /** Static-call first (clear errors before the wallet prompt), then send and wait for the final receipt. */
  async function send(contract, method, args, statusId, label) {
    await contract[method].staticCall(...args);
    showStatus(statusId, "", `${label}: confirm in your wallet…`);
    const tx = await contract[method](...args);
    const t0 = performance.now();
    showStatus(statusId, "", `${label}: sent ${short(tx.hash)}, waiting for finality…`);
    const rc = await waitReceipt(tx.hash);
    return { rc, secs: ((performance.now() - t0) / 1000).toFixed(2), hash: tx.hash };
  }

  function parsedLogs(rc) {
    return rc.logs.map((l) => { try { return iface.parseLog(l); } catch (_) { return null; } }).filter(Boolean);
  }

  /** Chain time for timers. Arc block timestamps follow the validators' wall clock (1 s granularity),
   *  so the browser clock minus a second is used there; a local devnet can be time-travelled, so it is read. */
  async function refreshChainNow() {
    if (state.net.chainId === 31337) {
      const b = await state.read.getBlock("latest");
      state.chainNow = Math.max(Number(b.timestamp), state.chainNow);
    } else {
      state.chainNow = Math.max(Math.floor(Date.now() / 1000) - 1, state.chainNow);
    }
    return state.chainNow;
  }

  // ------------------------------------------------------------------ network & wallet

  async function initNetwork() {
    const chainId = chainIdFromLocation();
    if (state.net && state.net.chainId === chainId) return;
    const n = CFG.networks[chainId];
    state.net = { ...n, chainId };
    // Batch concurrent reads into one HTTP request: Arc's public RPC rate-limits per request.
    state.read = new RetryingProvider(n.rpc, chainId, { staticNetwork: ethers.Network.from(chainId), batchMaxCount: 10, batchStallTime: 15 });
    state.sd = new ethers.Contract(n.safeDeal, ABI, state.read);
    state.signer = null;
    state.tokens = [];
    const badge = $("net-badge");
    badge.textContent = n.name;
    badge.className = `badge${chainId === 5042 ? " live" : ""}`;
    const ft = $("ft-contract");
    if (isDeployed()) {
      ft.textContent = short(n.safeDeal);
      const href = explorerAddr(n.safeDeal);
      if (href) ft.href = href; else ft.removeAttribute("href");
      const [usdc, eurc] = await Promise.all([state.sd.usdc(), state.sd.eurc()]);
      for (const address of [usdc, eurc]) {
        if (address === ZERO) continue;
        const c = new ethers.Contract(address, TOKEN_ABI, state.read);
        state.tokens.push({ address, contract: c, symbol: await c.symbol() });
      }
    } else {
      ft.textContent = "not deployed on this network yet";
      ft.removeAttribute("href");
    }
    if (CFG.repoUrl) $("ft-source").href = CFG.repoUrl;
    const sel = $("in-token");
    sel.textContent = "";
    for (const t of state.tokens) {
      const o = document.createElement("option");
      o.value = t.address; o.textContent = t.symbol;
      sel.appendChild(o);
    }
  }

  async function ensureChain() {
    const net = state.net;
    const hex = `0x${net.chainId.toString(16)}`;
    const current = await window.ethereum.request({ method: "eth_chainId" });
    if (parseInt(current, 16) === net.chainId) return;
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
    } catch (e) {
      const code = e && (e.code !== undefined ? e.code : e.data && e.data.originalError && e.data.originalError.code);
      if (code !== 4902) throw e;
      const params = { chainId: hex, chainName: net.name, nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, rpcUrls: [net.rpc] };
      if (net.explorer) params.blockExplorerUrls = [net.explorer];
      await window.ethereum.request({ method: "wallet_addEthereumChain", params: [params] });
    }
  }

  async function connectWallet() {
    if (!window.ethereum) throw new Error("No browser wallet found. Install MetaMask, Rabby or another EVM wallet, then reload.");
    await window.ethereum.request({ method: "eth_requestAccounts" });
    await ensureChain();
    const browser = new ethers.BrowserProvider(window.ethereum, "any");
    state.signer = await browser.getSigner();
    state.account = await state.signer.getAddress();
    $("btn-connect").textContent = short(state.account);
    return state.account;
  }

  async function signerSd() {
    if (!state.signer) await connectWallet();
    else await ensureChain();
    return new ethers.Contract(state.net.safeDeal, ABI, state.signer);
  }

  // ------------------------------------------------------------------ new deal form

  function addMilestoneRow(name = "", amount = "") {
    const box = $("milestones");
    if (box.children.length >= MAX_MILESTONES) { toast("At most 10 milestones."); return; }
    const row = document.createElement("div");
    row.className = "ms-row";
    const n = document.createElement("span");
    n.className = "n";
    const nameIn = document.createElement("input");
    nameIn.className = "ms-name"; nameIn.maxLength = 31; nameIn.placeholder = "Milestone name"; nameIn.value = name; nameIn.autocomplete = "off";
    const amountIn = document.createElement("input");
    amountIn.className = "ms-amount"; amountIn.inputMode = "decimal"; amountIn.placeholder = "Amount"; amountIn.value = amount; amountIn.autocomplete = "off";
    const del = document.createElement("button");
    del.type = "button"; del.textContent = "✕"; del.title = "Remove milestone";
    del.addEventListener("click", () => { if (box.children.length > 1) { row.remove(); renumber(); updateSummary(); } });
    nameIn.addEventListener("input", updateSummary);
    amountIn.addEventListener("input", updateSummary);
    row.append(n, nameIn, amountIn, del);
    box.appendChild(row);
    renumber();
  }

  function renumber() {
    [...$("milestones").children].forEach((row, i) => { row.querySelector(".n").textContent = String(i + 1); });
  }

  function readMilestones({ strict }) {
    const names = []; const amounts = [];
    for (const row of $("milestones").children) {
      const name = row.querySelector(".ms-name").value.trim();
      const amountText = row.querySelector(".ms-amount").value;
      if (strict) {
        const len = bytesLen(name);
        if (len === 0 || len > 31) throw new Error("Each milestone needs a name of 1–31 bytes.");
        amounts.push(parseAmount(amountText));
      } else {
        try { amounts.push(parseAmount(amountText)); } catch (_) { amounts.push(0n); }
      }
      names.push(name);
    }
    return { names, amounts };
  }

  function currentSymbol() {
    const t = tokenOf($("in-token").value);
    return t ? t.symbol : "USDC";
  }

  function updateSummary() {
    const { amounts } = readMilestones({ strict: false });
    const total = amounts.reduce((a, b) => a + b, 0n);
    const sym = currentSymbol();
    setText("out-total", `${fmtAmount(total)} ${sym}`);
    const review = fmtPeriod($("in-review").value);
    const deadline = $("in-deadline").selectedOptions[0].textContent.replace(" (demo)", "");
    const arb = $("in-arbiter").value.trim();
    const who = state.mode === "provider" ? "Your client locks" : "You lock";
    const lines = [
      `${who} ${fmtAmount(total)} ${sym} in the contract. Each milestone is paid when the client approves it, or automatically ${review} after delivery unless the client disputes.`,
      `Milestones not delivered within ${deadline} of funding can be taken back by the client.`,
      arb ? "Disputes are decided by the arbiter, who can only split the milestone between the two of you." : "No arbiter: a disputed milestone is split however you both agree, or 50/50 after 30 days.",
    ];
    if (state.gasPrice && state.mode === "client") {
      const gas = GAS.create + GAS.perMilestone * BigInt(Math.max(1, amounts.length));
      const usd = Number(ethers.formatUnits(gas * state.gasPrice, 18));
      lines.push(`Network fee to fund: ≈ $${usd < 0.001 ? usd.toFixed(4) : usd.toFixed(3)}, paid in USDC.`);
    }
    $("deal-summary").textContent = lines.join(" ");
  }

  function setMode(mode) {
    state.mode = mode;
    for (const b of document.querySelectorAll(".seg-btn")) b.classList.toggle("active", b.dataset.mode === mode);
    const provider = mode === "provider";
    $("client-actions").hidden = provider;
    $("provider-actions").hidden = !provider;
    setText("lbl-provider", provider ? "Your address (where you get paid)" : "Freelancer's address");
    setText("mode-hint", provider
      ? "Describe the job and send the proposal link to your client. They fund it in one transaction; you accept on-chain."
      : "You fund the deal now. The freelancer accepts it, then delivers milestone by milestone.");
    if (provider && state.account && !$("in-provider").value) $("in-provider").value = state.account;
    updateSummary();
  }

  function readForm() {
    const provider = addressOrEmpty($("in-provider").value, "Freelancer");
    if (provider === ZERO) throw new Error("Enter the freelancer's address.");
    const arbiter = addressOrEmpty($("in-arbiter").value, "Arbiter");
    const title = $("in-title").value.trim();
    const tl = bytesLen(title);
    if (tl === 0 || tl > 64) throw new Error("The title must be 1–64 bytes.");
    const terms = $("in-terms").value;
    if (bytesLen(terms) > 4096) throw new Error("The terms are longer than 4,096 bytes.");
    const { names, amounts } = readMilestones({ strict: true });
    if (!names.length) throw new Error("Add at least one milestone.");
    const token = $("in-token").value;
    if (!tokenOf(token)) throw new Error("Choose a currency.");
    return {
      provider, arbiter, token, title, terms, names, amounts,
      deadlineSecs: Number($("in-deadline").value), reviewPeriod: Number($("in-review").value),
    };
  }

  async function buildParams(f) {
    const now = await refreshChainNow();
    if (state.account && (same(f.provider, state.account) || same(f.arbiter, state.account))) {
      throw new Error("You are the client here: the freelancer and the arbiter must be other addresses.");
    }
    if (f.arbiter !== ZERO && same(f.arbiter, f.provider)) throw new Error("The arbiter must differ from the freelancer.");
    return {
      provider: f.provider, arbiter: f.arbiter, token: f.token,
      deadline: BigInt(Math.max(now, Math.floor(Date.now() / 1000)) + f.deadlineSecs),
      reviewPeriod: f.reviewPeriod, title: f.title, terms: f.terms,
      milestoneNames: f.names, milestoneAmounts: f.amounts,
    };
  }

  async function checkFunds(token, total) {
    const bal = await tokenOf(token).contract.balanceOf(state.account);
    if (bal < total) throw new Error(`Not enough ${symbolOf(token)}: this deal needs ${fmtAmount(total)}, the wallet has ${fmtAmount(bal)}.`);
  }

  function createdDealId(rc) {
    const log = parsedLogs(rc).find((l) => l.name === "DealCreated");
    return log ? log.args.dealId : null;
  }

  async function onFundPermit(ev) {
    if (ev) ev.preventDefault();
    try {
      if (!isDeployed()) throw new Error(`SafeDeal is not deployed on ${state.net.name} yet.`);
      const f = readForm();
      const sd = await signerSd();
      const p = await buildParams(f);
      const total = f.amounts.reduce((a, b) => a + b, 0n);
      await checkFunds(f.token, total);
      const token = tokenOf(f.token).contract;
      const [name, version, nonce, separator] = await Promise.all([
        token.name(), token.version(), token.nonces(state.account), token.DOMAIN_SEPARATOR(),
      ]);
      const domain = { name, version, chainId: state.net.chainId, verifyingContract: f.token };
      if (ethers.TypedDataEncoder.hashDomain(domain) !== separator) {
        throw new Error("This token does not match the expected permit domain — use approve, then fund.");
      }
      const permitDeadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const types = { Permit: [
        { name: "owner", type: "address" }, { name: "spender", type: "address" }, { name: "value", type: "uint256" },
        { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" },
      ] };
      showStatus("new-status", "", `Sign the ${fmtAmount(total)} ${symbolOf(f.token)} spending permission in your wallet (no fee)…`);
      const sig = ethers.Signature.from(await state.signer.signTypedData(domain, types, {
        owner: state.account, spender: state.net.safeDeal, value: total, nonce, deadline: permitDeadline,
      }));
      const { rc, secs } = await send(sd, "createDealWithPermit", [p, total, permitDeadline, sig.v, sig.r, sig.s], "new-status", "Funding");
      afterCreated(createdDealId(rc), secs);
    } catch (e) {
      showStatus("new-status", "err", friendlyError(e));
    }
  }

  async function onFundApprove() {
    try {
      if (!isDeployed()) throw new Error(`SafeDeal is not deployed on ${state.net.name} yet.`);
      const f = readForm();
      const sd = await signerSd();
      const p = await buildParams(f);
      const total = f.amounts.reduce((a, b) => a + b, 0n);
      await checkFunds(f.token, total);
      const token = new ethers.Contract(f.token, TOKEN_ABI, state.signer);
      const current = await token.allowance(state.account, state.net.safeDeal);
      if (current < total) await send(token, "approve", [state.net.safeDeal, total], "new-status", "Step 1/2 — approve");
      const { rc, secs } = await send(sd, "createDeal", [p], "new-status", "Step 2/2 — fund");
      afterCreated(createdDealId(rc), secs);
    } catch (e) {
      showStatus("new-status", "err", friendlyError(e));
    }
  }

  function afterCreated(dealId, secs) {
    showStatus("new-status", "ok", `Deal #${dealId} funded ✓ Final in ${secs} s. Send the link to the freelancer.`);
    showShare({
      title: `Deal #${dealId} — send it to the freelancer`, label: "Deal link", link: dealLink(dealId),
      hint: "The freelancer opens the link and accepts. Until then you can cancel and get everything back.",
    });
  }

  function showShare({ title, label, link, hint }) {
    setText("share-title", title);
    setText("share-label", label);
    setText("share-hint", hint);
    $("out-link").value = link;
    $("out-open").href = link;
    qrInto($("qr-img"), link);
    $("share-card").hidden = false;
  }

  function onProposal() {
    try {
      const f = readForm();
      const q = new URLSearchParams();
      q.set("p", f.provider);
      if (f.arbiter !== ZERO) q.set("a", f.arbiter);
      q.set("t", symbolOf(f.token));
      q.set("title", f.title);
      q.set("m", f.names.map((n, i) => `${encodeURIComponent(n)}~${plainAmount(f.amounts[i])}`).join("|"));
      q.set("d", String(f.deadlineSecs));
      q.set("r", String(f.reviewPeriod));
      if (f.terms) q.set("terms", f.terms);
      q.set("c", String(state.net.chainId));
      const link = `${pageBase()}#/new?${q.toString()}`;
      showStatus("new-status", "ok", "Proposal link ready — no transaction was sent.");
      showShare({
        title: "Proposal link — send it to your client", label: "Proposal link", link,
        hint: "Your client sees these exact terms with your address as the freelancer, and funds the deal in one transaction.",
      });
    } catch (e) {
      showStatus("new-status", "err", friendlyError(e));
    }
  }

  function selectValue(sel, value) {
    const opt = [...sel.options].find((o) => o.value === String(value));
    if (opt) { sel.value = opt.value; return; }
    const o = document.createElement("option");
    o.value = String(value); o.textContent = fmtPeriod(value);
    sel.appendChild(o);
    sel.value = o.value;
  }

  function renderNew(params) {
    // Fill the form once per link, so reconnecting the wallet does not wipe what was typed.
    const key = params.toString();
    if (state.formKey === key && $("milestones").children.length) { updateSummary(); return; }
    state.formKey = key;
    $("share-card").hidden = true;
    $("new-status").hidden = true;
    const fromProposal = params.has("p");
    for (const id of ["in-provider", "in-arbiter", "in-title", "in-terms"]) $(id).value = "";
    $("in-deadline").value = "1209600";
    $("in-review").value = "259200";
    if (state.tokens.length) $("in-token").value = state.tokens[0].address;
    $("milestones").textContent = "";
    if (fromProposal) {
      setMode("client");
      $("in-provider").value = params.get("p") || "";
      $("in-arbiter").value = params.get("a") || "";
      $("in-title").value = params.get("title") || "";
      $("in-terms").value = params.get("terms") || "";
      const t = state.tokens.find((x) => x.symbol === params.get("t"));
      if (t) $("in-token").value = t.address;
      for (const part of String(params.get("m") || "").split("|").filter(Boolean)) {
        const [n, a] = part.split("~");
        addMilestoneRow(decodeURIComponent(n || ""), a || "");
      }
      if (params.get("d")) selectValue($("in-deadline"), params.get("d"));
      if (params.get("r")) selectValue($("in-review"), params.get("r"));
      $("proposal-banner").hidden = false;
      setText("proposal-text", `Proposal from freelancer ${short(params.get("p") || "")}. Check every field below — once you fund, the terms are fixed on-chain.`);
    } else {
      $("proposal-banner").hidden = true;
    }
    if (!$("milestones").children.length) addMilestoneRow();
    updateSummary();
  }

  // ------------------------------------------------------------------ deal view

  function roleOf(d) {
    const me = state.account;
    return {
      client: same(me, d.client), provider: same(me, d.provider),
      arbiter: d.arbiter !== ZERO && same(me, d.arbiter), connected: Boolean(me),
    };
  }

  function roleLabel(r) {
    if (r.client) return "You are the client";
    if (r.provider) return "You are the freelancer";
    if (r.arbiter) return "You are the arbiter";
    return "";
  }

  async function loadNote(event, dealId, index, block) {
    const key = `${event}:${dealId}:${index}:${block}`;
    if (state.notes[key] !== undefined) return state.notes[key];
    const ev = iface.getEvent(event);
    const topics = [ev.topicHash, ethers.zeroPadValue(ethers.toBeHex(dealId), 32), ethers.zeroPadValue(ethers.toBeHex(index), 32)];
    const logs = await state.read.getLogs({ address: state.net.safeDeal, topics, fromBlock: Number(block), toBlock: Number(block) });
    const last = logs.length ? iface.parseLog(logs[logs.length - 1]) : null;
    state.notes[key] = last ? last.args[2] : "";
    return state.notes[key];
  }

  async function loadTerms(d, dealId) {
    const el = $("dl-terms");
    if (d.termsHash === ethers.ZeroHash) { el.textContent = "None given"; el.dataset.key = ""; return; }
    if (el.dataset.key === `${state.net.chainId}:${dealId}`) return; // already shown
    el.dataset.key = `${state.net.chainId}:${dealId}`;
    try {
      const ev = iface.getEvent("DealCreated");
      const logs = await state.read.getLogs({
        address: state.net.safeDeal, topics: [ev.topicHash, ethers.zeroPadValue(ethers.toBeHex(dealId), 32)],
        fromBlock: Number(d.createdBlock), toBlock: Number(d.createdBlock),
      });
      const text = logs.length ? iface.parseLog(logs[0]).args.terms : null;
      el.textContent = "";
      if (text === null) { el.textContent = `Hash ${short(d.termsHash)} (text not found in the creation block)`; return; }
      const ok = ethers.keccak256(ethers.toUtf8Bytes(text)) === d.termsHash;
      const badge = document.createElement("span");
      badge.className = "hint";
      badge.textContent = ok ? "✓ matches the hash stored with the deal" : "✗ does NOT match the stored hash";
      const box = document.createElement("div");
      box.className = "terms-text";
      box.textContent = text;
      el.append(badge, box);
    } catch (_) {
      el.textContent = `Hash ${short(d.termsHash)}`;
      el.dataset.key = ""; // retry on the next render
    }
  }

  function dealPill(d) {
    const s = DEAL_STATUS[Number(d.status)];
    const map = { Open: ["open", "Waiting for the freelancer"], Active: ["active", "In progress"], Closed: ["closed", "Completed"], Cancelled: ["cancelled", "Cancelled"] };
    return map[s] || ["", s];
  }

  /** Text describing a milestone's state, from the viewer's perspective. */
  function msStatus(d, m) {
    const sym = symbolOf(d.token);
    const st = Number(m.status);
    if (st === MS.Pending) {
      const late = state.chainNow > Number(d.deadline);
      return { cls: "pending", text: Number(d.status) === 1 ? "Funded" : (late ? "Not delivered — deadline passed" : "In progress"), sub: "" };
    }
    if (st === MS.Delivered) {
      const ends = Number(m.deliveredAt) + Number(d.reviewPeriod);
      const over = state.chainNow >= ends;
      return { cls: "delivered", text: "Delivered", sub: over ? `Review period ended ${relative(ends)} — can be released` : `Review ends ${relative(ends)} (${fmtTime(ends)})` };
    }
    if (st === MS.Disputed) {
      const ends = Number(m.disputedAt) + ARBITRATION_TIMEOUT;
      return { cls: "disputed", text: "Disputed", sub: state.chainNow >= ends ? "Arbitration window over — can be split 50/50" : `50/50 fallback ${relative(ends)}` };
    }
    const toProvider = BigInt(m.toProvider);
    const toClient = BigInt(m.amount) - toProvider;
    let text = "Paid to freelancer";
    if (toProvider === 0n) text = "Refunded to client";
    else if (toClient > 0n) text = `Split: ${fmtAmount(toProvider)} / ${fmtAmount(toClient)} ${sym}`;
    return { cls: "closed", text, sub: RESOLUTION[Number(m.resolution)] || "" };
  }

  function offersText(d, m) {
    const sym = symbolOf(d.token);
    const parts = [];
    if (m.clientOffered) parts.push(`Client offers the freelancer ${fmtAmount(m.clientOffer)} ${sym}`);
    if (m.providerOffered) parts.push(`Freelancer asks for ${fmtAmount(m.providerOffer)} ${sym}`);
    return parts.join(" · ");
  }

  /** Buttons for one milestone, given the viewer's role and the chain time. */
  function msActions(d, m, i, r) {
    const out = [];
    if (Number(d.status) !== 2) return out; // only Active deals
    const st = Number(m.status);
    if (st === MS.Closed) return out;
    const now = state.chainNow;
    const sym = symbolOf(d.token);
    const amount = fmtAmount(m.amount);
    const reviewEnds = Number(m.deliveredAt) + Number(d.reviewPeriod);
    const add = (label, cls, fn, key) => out.push({ label, cls, fn, key });

    if (r.provider && ((st === MS.Pending && now <= Number(d.deadline)) || st === MS.Delivered)) {
      add(st === MS.Delivered ? "Deliver again" : "Mark delivered", "", () => openPanel("deliver", i), "deliver");
    }
    if (r.client) add(st === MS.Pending ? `Pay ${amount} ${sym} now` : `Approve & pay ${amount} ${sym}`, "", () => act("approveMilestone", [i], `Paying milestone ${i + 1}`), "approve");
    if (r.client && st === MS.Delivered && now < reviewEnds) add("Dispute", "danger", () => openPanel("dispute", i), "dispute");
    if (r.connected && st === MS.Delivered && now >= reviewEnds) add("Release payment", "", () => act("releaseAfterReview", [i], `Releasing milestone ${i + 1}`), "release");
    if (r.client && st === MS.Pending && now > Number(d.deadline)) add(`Reclaim ${amount} ${sym}`, "ghost", () => act("reclaimAfterDeadline", [i], `Reclaiming milestone ${i + 1}`), "reclaim");
    if (r.arbiter && st === MS.Disputed) add("Rule on dispute", "", () => openPanel("resolve", i), "resolve");
    if (r.connected && st === MS.Disputed && now >= Number(m.disputedAt) + ARBITRATION_TIMEOUT) {
      add("Split 50/50", "ghost", () => act("resolveAfterTimeout", [i], `Splitting milestone ${i + 1}`), "timeout");
    }
    if (r.client || r.provider) {
      const theirs = r.client ? (m.providerOffered ? m.providerOffer : null) : (m.clientOffered ? m.clientOffer : null);
      const mine = r.client ? m.clientOffered : m.providerOffered;
      if (theirs !== null && !(mine && (r.client ? m.clientOffer : m.providerOffer) === theirs)) {
        add(`Accept split: freelancer gets ${fmtAmount(theirs)}`, "secondary", () => act("proposeSettlement", [i, theirs], "Accepting the split"), "accept-split");
      }
      add("Propose split", "ghost", () => openPanel("settle", i), "settle");
      if (mine) add("Withdraw offer", "ghost", () => act("withdrawSettlement", [i], "Withdrawing the offer"), "withdraw-offer");
    }
    if (r.provider) add("Refund client", "ghost", () => act("refund", [i], `Refunding milestone ${i + 1}`), "refund");
    return out;
  }

  function dealActions(d, r) {
    const out = [];
    const st = Number(d.status);
    if (st === 1 && r.provider) {
      out.push({ label: "Accept deal", cls: "", key: "accept", fn: () => act("accept", [], "Accepting") });
      out.push({ label: "Decline", cls: "ghost", key: "decline", fn: () => act("decline", [], "Declining") });
    }
    if (st === 1 && r.client) out.push({ label: "Cancel & refund", cls: "danger", key: "cancel", fn: () => act("cancel", [], "Cancelling") });
    if ((st === 1 || st === 2) && r.client) out.push({ label: "Extend deadline", cls: "ghost", key: "extend", fn: () => openPanel("extend", null) });
    return out;
  }

  function mkButtons(container, list) {
    container.textContent = "";
    for (const a of list) {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = a.label;
      if (a.cls) b.className = a.cls;
      b.dataset.action = a.key;
      b.addEventListener("click", a.fn);
      container.appendChild(b);
    }
  }

  async function renderDeal(dealId, { keepStatus = false, onlyIfChanged = false } = {}) {
    state.dealId = BigInt(dealId);
    if (!keepStatus) $("deal-status").hidden = true;
    if (!isDeployed()) { setText("dl-pill", "Unavailable"); showStatus("deal-status", "warn", `SafeDeal is not deployed on ${state.net.name} yet.`); return; }
    const [d, ms] = await Promise.all([state.sd.getDeal(state.dealId), state.sd.getMilestones(state.dealId), refreshChainNow()]);
    if (Number(d.status) === 0) { setText("dl-pill", "Not found"); setText("dl-title", "This deal does not exist"); return; }
    const r = roleOf(d);
    // Skip re-rendering when nothing visible changed (polling), so buttons do not flicker.
    const phase = ms.map((m) => [
      state.chainNow >= Number(m.deliveredAt) + Number(d.reviewPeriod),
      state.chainNow >= Number(m.disputedAt) + ARBITRATION_TIMEOUT,
    ]);
    const key = JSON.stringify([d, ms, phase, state.chainNow > Number(d.deadline), state.account, state.dealId],
      (_, v) => (typeof v === "bigint" ? v.toString() : v));
    if (onlyIfChanged && key === state.renderKey) return;
    state.renderKey = key;
    state.deal = d;
    state.ms = ms;
    const sym = symbolOf(d.token);

    setText("dl-id", `Deal #${dealId}`);
    const label = roleLabel(r);
    $("dl-role").hidden = !label;
    setText("dl-role", label);
    const [cls, text] = dealPill(d);
    $("dl-pill").className = `pill ${cls}`;
    setText("dl-pill", text);
    setText("dl-title", d.title);
    const amount = $("dl-amount");
    amount.textContent = `${fmtAmount(d.total)} `;
    const small = document.createElement("small");
    small.textContent = sym;
    amount.appendChild(small);

    const paid = ms.reduce((s, m) => s + (Number(m.status) === MS.Closed ? BigInt(m.toProvider) : 0n), 0n);
    const refunded = ms.reduce((s, m) => s + (Number(m.status) === MS.Closed ? BigInt(m.amount) - BigInt(m.toProvider) : 0n), 0n);
    const pct = d.total > 0n ? Number((paid * 1000n) / BigInt(d.total)) / 10 : 0;
    $("dl-bar").style.width = `${pct}%`;
    setText("dl-progress-text", `${fmtAmount(paid)} paid · ${fmtAmount(refunded)} refunded · ${fmtAmount(d.locked)} ${sym} in escrow`);

    const party = (id, addr, mine) => {
      const el = $(id);
      linkOrText(el, explorerAddr(addr), addr);
      if (mine) { const y = document.createElement("span"); y.className = "you"; y.textContent = "YOU"; el.appendChild(y); }
    };
    party("dl-client", d.client, r.client);
    party("dl-provider", d.provider, r.provider);
    $("dl-arbiter").className = d.arbiter === ZERO ? "" : "mono";
    if (d.arbiter === ZERO) setText("dl-arbiter", "None — a dispute is settled by agreement, or split 50/50 after 30 days");
    else party("dl-arbiter", d.arbiter, r.arbiter);
    const live = Number(d.status) === 1 || Number(d.status) === 2;
    setText("dl-deadline", live ? `${fmtTime(d.deadline)} (${relative(d.deadline)})` : fmtTime(d.deadline));
    setText("dl-review", `${fmtPeriod(d.reviewPeriod)} after each delivery, then the payment can be released`);
    setText("dl-network", `${state.net.name} (chain id ${state.net.chainId})`);
    loadTerms(d, state.dealId);

    mkButtons($("dl-actions"), dealActions(d, r));
    if (!r.connected && (Number(d.status) === 1 || Number(d.status) === 2)) {
      const hint = document.createElement("p");
      hint.className = "hint";
      hint.textContent = "Read-only view. Connect the client's, freelancer's or arbiter's wallet to act on this deal.";
      $("dl-actions").appendChild(hint);
    }
    const share = Number(d.status) === 1 && r.client;
    $("dl-share").hidden = !share;
    if (share) { $("dl-link").value = dealLink(dealId); qrInto($("dl-qr"), dealLink(dealId)); }

    const tbody = $("ms-rows");
    tbody.textContent = "";
    for (let i = 0; i < ms.length; i++) {
      const m = ms[i];
      const tr = document.createElement("tr");
      tr.dataset.index = String(i);
      const td = (t) => { const c = document.createElement("td"); c.textContent = t; tr.appendChild(c); return c; };
      td(String(i + 1));
      const nameCell = td(m.name);
      td(`${fmtAmount(m.amount)} ${sym}`);
      const s = msStatus(d, m);
      const stCell = td("");
      const stText = document.createElement("span");
      stText.className = `st ${s.cls}`;
      stText.textContent = s.text;
      stCell.appendChild(stText);
      if (s.sub) { const sub = document.createElement("span"); sub.className = "sub"; sub.textContent = s.sub; stCell.appendChild(sub); }
      const offers = offersText(d, m);
      if (offers) { const sub = document.createElement("span"); sub.className = "sub offers"; sub.textContent = offers; stCell.appendChild(sub); }
      if (Number(m.deliveredBlock) > 0) {
        const sub = document.createElement("span");
        sub.className = "sub note";
        nameCell.appendChild(sub);
        loadNote("MilestoneDelivered", state.dealId, i, m.deliveredBlock).then((note) => {
          if (!note) return;
          const label = document.createElement("b"); label.textContent = "Delivery: ";
          const body = document.createElement("span");
          renderNote(body, note);
          sub.append(label, body);
        }).catch(() => {});
      }
      if (Number(m.disputedBlock) > 0) {
        const sub = document.createElement("span");
        sub.className = "sub reason";
        nameCell.appendChild(sub);
        loadNote("MilestoneDisputed", state.dealId, i, m.disputedBlock).then((reason) => {
          if (!reason) return;
          const label = document.createElement("b"); label.textContent = "Dispute: ";
          const body = document.createElement("span"); body.textContent = reason;
          sub.append(label, body);
        }).catch(() => {});
      }
      const actCell = document.createElement("td");
      const box = document.createElement("div");
      box.className = "actions";
      mkButtons(box, msActions(d, m, i, r));
      actCell.appendChild(box);
      tr.appendChild(actCell);
      tbody.appendChild(tr);
    }
    await renderClaims("claim-box", [d.token]);
  }

  async function renderClaims(boxId, tokens) {
    const box = $(boxId);
    box.hidden = true;
    if (!state.account) return;
    for (const token of tokens) {
      const amount = await state.sd.claimable(token, state.account);
      if (amount > 0n) {
        box.hidden = false;
        box.className = "status warn";
        box.textContent = `${fmtAmount(amount)} ${symbolOf(token)} is waiting for you: an earlier payout was rejected by the token (for example a blocklist). `;
        const b = document.createElement("button");
        b.type = "button"; b.className = "secondary"; b.textContent = "Withdraw"; b.id = "btn-withdraw";
        b.addEventListener("click", async () => {
          try {
            const sd = await signerSd();
            await send(sd, "withdraw", [token], boxId, "Withdrawing");
            showStatus(boxId, "ok", "Withdrawn ✓");
          } catch (e) { showStatus(boxId, "err", friendlyError(e)); }
        });
        box.appendChild(b);
        return;
      }
    }
  }

  // ------------------------------------------------------------------ action panel (inputs)

  function openPanel(kind, index) {
    const d = state.deal;
    const m = index === null ? null : state.ms[index];
    const sym = symbolOf(d.token);
    state.panel = { kind, index };
    const show = (id, on) => { $(id).hidden = !on; };
    show("ap-text-wrap", kind === "deliver" || kind === "dispute");
    show("ap-amount-wrap", kind === "resolve" || kind === "settle");
    show("ap-days-wrap", kind === "extend");
    $("ap-text").value = "";
    $("ap-amount").value = "";
    setText("ap-amount-rest", "");
    const titles = {
      deliver: [`Deliver milestone ${index + 1}: ${m && m.name}`, "Add a link to the work or a short note. The client then has the review period to approve or dispute; after that, the payment can be released by anyone.", "Delivery note (link or text, public)"],
      dispute: [`Dispute milestone ${index + 1}`, "The review timer stops. The arbiter (if any) decides; you can still agree on a split; after 30 days an unresolved dispute is split 50/50.", "Reason (public)"],
      resolve: [`Rule on milestone ${index + 1}`, `Decide how much of ${m && fmtAmount(m.amount)} ${sym} the freelancer gets. The rest goes back to the client. You cannot send funds anywhere else.`, ""],
      settle: [`Propose a split for milestone ${index + 1}`, "When both of you propose the same amount, it is paid out immediately. A new delivery or a dispute clears old offers.", ""],
      extend: ["Extend the delivery deadline", "Gives the freelancer more time for milestones that are not delivered yet. The deadline can only move later.", ""],
    };
    const [title, hint, textLabel] = titles[kind];
    setText("ap-title", title);
    setText("ap-hint", hint);
    if (textLabel) setText("ap-text-label", textLabel);
    setText("ap-amount-label", `Freelancer gets (${sym})`);
    const confirmLabels = { deliver: "Mark delivered", dispute: "Open dispute", resolve: "Confirm ruling", settle: "Propose split", extend: "Extend deadline" };
    setText("ap-confirm", confirmLabels[kind]);
    $("action-panel").hidden = false;
    $("action-panel").scrollIntoView({ block: "nearest" });
    (kind === "resolve" || kind === "settle" ? $("ap-amount") : kind === "extend" ? $("ap-days") : $("ap-text")).focus();
  }

  function updateAmountRest() {
    const p = state.panel;
    if (!p || (p.kind !== "resolve" && p.kind !== "settle")) return;
    const m = state.ms[p.index];
    try {
      const v = parseAmount($("ap-amount").value, { allowZero: true });
      setText("ap-amount-rest", v <= BigInt(m.amount) ? `client gets ${fmtAmount(BigInt(m.amount) - v)}` : "more than the milestone");
    } catch (_) { setText("ap-amount-rest", ""); }
  }

  async function onPanelConfirm() {
    const p = state.panel;
    if (!p) return;
    try {
      if (p.kind === "deliver" || p.kind === "dispute") {
        const text = $("ap-text").value.trim();
        if (bytesLen(text) > 512) throw new Error("At most 512 bytes.");
        await act(p.kind, [p.index, text], p.kind === "deliver" ? `Delivering milestone ${p.index + 1}` : "Opening a dispute");
      } else if (p.kind === "resolve" || p.kind === "settle") {
        const v = parseAmount($("ap-amount").value, { allowZero: true });
        if (v > BigInt(state.ms[p.index].amount)) throw new Error("The split cannot exceed the milestone amount.");
        await act(p.kind === "resolve" ? "resolve" : "proposeSettlement", [p.index, v], p.kind === "resolve" ? "Recording the ruling" : "Proposing the split");
      } else if (p.kind === "extend") {
        const days = Number($("ap-days").value);
        if (!Number.isFinite(days) || days <= 0 || days > 1000) throw new Error("Enter a number of days.");
        const base = Math.max(Number(state.deal.deadline), state.chainNow);
        await act("extendDeadline", [BigInt(base + Math.round(days * 86400))], "Extending the deadline");
      }
    } catch (e) {
      showStatus("deal-status", "err", friendlyError(e));
    }
  }

  function closePanel() {
    state.panel = null;
    $("action-panel").hidden = true;
  }

  /** Send a deal action: args after dealId. */
  async function act(method, args, label) {
    try {
      const sd = await signerSd();
      const { rc, secs } = await send(sd, method, [state.dealId, ...args], "deal-status", label);
      const logs = parsedLogs(rc);
      const closed = logs.filter((l) => l.name === "MilestoneClosed");
      const deferred = logs.filter((l) => l.name === "PayoutDeferred");
      const sym = symbolOf(state.deal.token);
      let text = `${label} ✓ Final in ${secs} s.`;
      for (const c of closed) {
        const parts = [];
        if (c.args.toProvider > 0n) parts.push(`${fmtAmount(c.args.toProvider)} ${sym} to the freelancer`);
        if (c.args.toClient > 0n) parts.push(`${fmtAmount(c.args.toClient)} ${sym} to the client`);
        text += ` Milestone ${Number(c.args.index) + 1}: ${parts.join(", ")}.`;
      }
      if (deferred.length) text += " One payout was rejected by the token and is held for the recipient to withdraw later.";
      closePanel();
      showStatus("deal-status", "ok", text);
      await renderDeal(state.dealId, { keepStatus: true });
    } catch (e) {
      showStatus("deal-status", "err", friendlyError(e));
    }
  }

  // ------------------------------------------------------------------ my deals

  function nextStep(d, ms, r) {
    const st = Number(d.status);
    if (st === 1) return r.provider ? "Accept or decline" : r.client ? "Waiting for the freelancer to accept" : "—";
    if (st !== 2) return "—";
    const now = state.chainNow;
    for (let i = 0; i < ms.length; i++) {
      const m = ms[i];
      const s = Number(m.status);
      if (s === MS.Delivered) {
        const ends = Number(m.deliveredAt) + Number(d.reviewPeriod);
        if (now >= ends) return `Milestone ${i + 1}: ready to release`;
        if (r.client) return `Milestone ${i + 1}: review, ${fmtDuration(ends - now)} left`;
      }
      if (s === MS.Disputed && r.arbiter) return `Milestone ${i + 1}: needs your ruling`;
      if (s === MS.Disputed) return `Milestone ${i + 1}: in dispute`;
    }
    const pending = ms.findIndex((m) => Number(m.status) === MS.Pending);
    if (pending >= 0) {
      if (now > Number(d.deadline)) return r.client ? `Deadline passed: reclaim or extend` : "Deadline passed";
      return r.provider ? `Deliver milestone ${pending + 1}` : `Milestone ${pending + 1} in progress`;
    }
    return "—";
  }

  async function loadMy() {
    if (!isDeployed()) { showStatus("my-status", "warn", `SafeDeal is not deployed on ${state.net.name} yet.`); return; }
    if (!state.account) { showStatus("my-status", "", "Connect your wallet to see your deals."); $("my-table").hidden = true; $("my-claims").hidden = true; return; }
    await refreshChainNow();
    await renderClaims("my-claims", state.tokens.map((t) => t.address));
    const count = Number(await state.sd.dealCountOf(state.account));
    const ids = count ? [...(await state.sd.dealsOf(state.account, Math.max(0, count - 200), 200))].reverse() : [];
    if (!ids.length) { showStatus("my-status", "", "No deals yet — create one on the New deal tab."); $("my-table").hidden = true; return; }
    const rows = await mapLimit(ids, 4, async (id) => {
      const [d, ms] = await Promise.all([state.sd.getDeal(id), state.sd.getMilestones(id)]);
      return { id, d, ms };
    });
    $("my-status").hidden = true;
    $("my-table").hidden = false;
    const tbody = $("my-rows");
    tbody.textContent = "";
    for (const { id, d, ms } of rows) {
      const r = roleOf(d);
      const tr = document.createElement("tr");
      tr.dataset.dealId = id.toString();
      const td = (t) => { const c = document.createElement("td"); c.textContent = t; tr.appendChild(c); return c; };
      const cell = td("");
      const a = document.createElement("a");
      a.href = `#/deal/${id}?c=${state.net.chainId}`;
      a.textContent = `#${id} ${d.title}`;
      cell.appendChild(a);
      td(r.client ? "Client" : r.provider ? "Freelancer" : r.arbiter ? "Arbiter" : "—");
      td(`${fmtAmount(d.total)} ${symbolOf(d.token)}`);
      td(dealPill(d)[1]).className = "deal-state";
      td(nextStep(d, ms, r));
      tbody.appendChild(tr);
    }
  }

  // ------------------------------------------------------------------ routing

  async function route() {
    stopPoll();
    closePanel();
    const { path, params } = parseHash();
    for (const v of ["new", "deal", "my"]) $(`view-${v}`).hidden = true;
    document.querySelectorAll("nav a").forEach((a) => a.classList.remove("active"));
    const activate = (name) => { const a = document.querySelector(`nav a[data-nav="${name}"]`); if (a) a.classList.add("active"); };
    const isHome = !/^\/(deal|my)/.test(path);
    $("intro").hidden = !isHome;
    try {
      await initNetwork();
      const m = path.match(/^\/deal\/(\d+)$/);
      if (m) {
        $("view-deal").hidden = false;
        await renderDeal(m[1]);
        startPoll(async () => { if (!state.panel) await renderDeal(m[1], { keepStatus: true, onlyIfChanged: true }); }, 6000);
      } else if (path.startsWith("/my")) {
        $("view-my").hidden = false;
        activate("my");
        await loadMy();
      } else {
        $("view-new").hidden = false;
        activate("new");
        renderNew(params);
        if (isDeployed()) {
          state.read.send("eth_gasPrice", []).then((g) => { state.gasPrice = BigInt(g); updateSummary(); }).catch(() => {});
        } else {
          showStatus("new-status", "warn", `SafeDeal is not deployed on ${state.net.name} yet.`);
        }
      }
    } catch (e) {
      toast(friendlyError(e));
    }
  }

  function init() {
    if (!ethers || !CFG) { document.body.textContent = "Failed to load scripts."; return; }
    $("btn-connect").addEventListener("click", async () => {
      try { await connectWallet(); await route(); } catch (e) { toast(friendlyError(e)); }
    });
    $("form-deal").addEventListener("submit", onFundPermit);
    $("cta-create").addEventListener("click", (ev) => {
      ev.preventDefault(); // keep the hash router's URL; just scroll to the form
      if (!/^#\/?($|new)/.test(window.location.hash || "#/")) window.location.hash = "#/";
      setTimeout(() => $("form-deal").scrollIntoView({ behavior: "smooth", block: "start" }), 50);
    });
    $("btn-fund-approve").addEventListener("click", onFundApprove);
    $("btn-proposal").addEventListener("click", onProposal);
    $("btn-add-ms").addEventListener("click", () => { addMilestoneRow(); updateSummary(); });
    for (const b of document.querySelectorAll(".seg-btn")) b.addEventListener("click", () => setMode(b.dataset.mode));
    for (const id of ["in-token", "in-review", "in-deadline", "in-arbiter"]) $(id).addEventListener("input", updateSummary);
    $("btn-copy").addEventListener("click", async () => {
      try { await navigator.clipboard.writeText($("out-link").value); toast("Link copied"); } catch (_) { $("out-link").select(); }
    });
    $("btn-copy-deal").addEventListener("click", async () => {
      try { await navigator.clipboard.writeText($("dl-link").value); toast("Link copied"); } catch (_) { $("dl-link").select(); }
    });
    $("btn-refresh-deal").addEventListener("click", () => renderDeal(state.dealId, { keepStatus: true }).catch((e) => toast(friendlyError(e))));
    $("ap-confirm").addEventListener("click", onPanelConfirm);
    $("ap-cancel").addEventListener("click", closePanel);
    $("ap-amount").addEventListener("input", updateAmountRest);
    window.addEventListener("hashchange", route);
    if (window.ethereum && typeof window.ethereum.on === "function") {
      window.ethereum.on("accountsChanged", (accs) => {
        state.signer = null;
        state.account = accs && accs[0] ? ethers.getAddress(accs[0]) : null;
        $("btn-connect").textContent = state.account ? short(state.account) : "Connect wallet";
        route();
      });
      window.ethereum.on("chainChanged", () => { state.signer = null; });
    }
    // Reconnect silently if the wallet already authorised this site. A locked or slow wallet must
    // never keep the page blank, so the page renders after at most 1.5 s either way.
    if (window.ethereum) {
      const accounts = window.ethereum.request({ method: "eth_accounts" }).then((accs) => {
        if (accs && accs[0]) {
          state.account = ethers.getAddress(accs[0]);
          $("btn-connect").textContent = short(state.account);
        }
      }).catch(() => {});
      Promise.race([accounts, sleep(1500)]).finally(route);
    } else {
      route();
    }
  }

  init();
})();
