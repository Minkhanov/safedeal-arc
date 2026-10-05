// SafeDeal front-end configuration.
// After deploying, paste the contract address into `safeDeal` for the matching network.
// Token addresses are read from the contract itself (`usdc()`, `eurc()`), so they cannot drift from config.
// Network selection: `c=` in the page hash, then `?chain=` in the page URL, then `defaultChainId`.
window.SAFEDEAL_CONFIG = {
  defaultChainId: 5042,
  repoUrl: "https://github.com/Minkhanov/safedeal-arc",
  networks: {
    5042: {
      name: "Arc",
      rpc: "https://rpc.mainnet.arc.io",
      explorer: "https://explorer.arc.io",
      safeDeal: "0x72f41a9206105F79cFDa6Fd9270A519B681e2ec4", // Arc mainnet, block 24414961, Sourcify exact match
    },
    5042002: {
      name: "Arc Testnet",
      rpc: "https://rpc.testnet.arc.io",
      explorer: "https://explorer.testnet.arc.io",
      safeDeal: "0x0000000000000000000000000000000000000000", // optional: testnet address
    },
    31337: {
      name: "Local Anvil",
      rpc: "http://127.0.0.1:8545",
      explorer: "",
      // DeployLocal.s.sol from anvil account #0: MockUSDC (nonce 0), MockEURC (1), SafeDeal (2).
      safeDeal: "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
    },
  },
};
