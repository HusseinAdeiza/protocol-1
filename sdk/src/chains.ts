import {defineChain} from "viem";

/**
 * The web app reads the chain through its own route handler, so no provider
 * key ever reaches the browser. Servers and scripts pass an explicit RPC URL.
 */
export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
  rpcUrls: {default: {http: ["/api/rpc/4663"]}},
  blockExplorers: {default: {name: "Blockscout", url: "https://robinhoodchain.blockscout.com"}},
});

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
  rpcUrls: {default: {http: ["/api/rpc/46630"]}},
  blockExplorers: {default: {name: "Explorer", url: "https://explorer.testnet.chain.robinhood.com"}},
  testnet: true,
});

/** Anvil, for local development against a freshly deployed set of contracts. */
export const localChain = defineChain({
  id: 31337,
  name: "Local",
  nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
  rpcUrls: {default: {http: ["/api/rpc/31337"]}},
  testnet: true,
});

export const chains = [robinhood, robinhoodTestnet, localChain] as const;

export const WETH_ADDRESS: Record<number, `0x${string}`> = {
  4663: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
};

export function explorerFor(chainId: number): string {
  return chainId === 4663
    ? "https://robinhoodchain.blockscout.com"
    : "https://explorer.testnet.chain.robinhood.com";
}
