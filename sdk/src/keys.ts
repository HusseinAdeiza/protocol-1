import {hkdf} from "@noble/hashes/hkdf.js";
import {sha256} from "@noble/hashes/sha2.js";
import {utf8ToBytes} from "@noble/hashes/utils.js";
import {keccak_256} from "@noble/hashes/sha3.js";
import {x25519} from "@noble/curves/ed25519.js";

import {getAddress} from "viem";

import {bigIntToBytes, bytesToBigInt, bytesToHex, FR, hexToBytes, type Hex} from "./field.js";
import {poseidon2} from "./poseidon.js";

/**
 * One wallet signature produces every key Backlit needs. The signature is
 * never stored; the keys live in memory for the session.
 *
 * spendingKey   authorises spending. Never leaves the device.
 * ownerPk       public, registered on chain, addresses notes to this owner.
 * viewingSk/Pk  x25519 pair that decrypts note and offer payloads.
 */
export interface BacklitKeys {
  spendingKey: bigint;
  ownerPk: bigint;
  viewingSk: Uint8Array;
  viewingPk: Uint8Array;
}

/** What signing the key message hands over, shown in the wallet. */
export const KEY_STATEMENT =
  "This signature is your Backlit key. Anyone who has it can spend your Backlit balance.";

/** The site each chain's keys are made on. Keys are tied to it. */
export const KEY_SITES: Readonly<Record<number, string>> = {
  4663: "https://backlit.ink",
  46630: "https://testnet.backlit.ink",
  31337: "http://localhost:3080",
};

export interface KeySite {
  domain: string;
  uri: string;
}

export function keySite(url: string): KeySite {
  const parsed = new URL(url);
  return {domain: parsed.host, uri: parsed.origin};
}

/**
 * The message the wallet signs, in Sign-In with Ethereum (EIP-4361) form.
 * Wallets that understand it compare its domain with the site asking and warn
 * on any other, which EIP-712 cannot do. The nonce and issue time are fixed on
 * purpose: the signature has to come out the same every time for the keys to.
 * Changing any byte of it changes every user's keys.
 */
export function keyDerivationMessage(site: KeySite, chainId: number, wallet: Hex): string {
  return [
    `${site.domain} wants you to sign in with your Ethereum account:`,
    getAddress(wallet),
    "",
    KEY_STATEMENT,
    "",
    `URI: ${site.uri}`,
    "Version: 1",
    `Chain ID: ${chainId}`,
    "Nonce: backlitkeys2",
    "Issued At: 2026-09-28T00:00:00.000Z",
  ].join("\n");
}

const SECP256K1_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;

/**
 * One canonical 65-byte form per signature: low s, v in {27, 28}, and the
 * 64-byte EIP-2098 form expanded. Wallets disagree on all three, and the seed
 * is a hash of these bytes, so without this the same key could come back as
 * different Backlit keys depending on the wallet or its firmware.
 */
export function normalizeSignature(signature: Hex): Uint8Array {
  const bytes = hexToBytes(signature);
  const r = bytes.slice(0, 32);
  let s: bigint;
  let v: number;
  if (bytes.length === 65) {
    s = bytesToBigInt(bytes.slice(32, 64));
    v = bytes[64]!;
    if (v === 0 || v === 1) v += 27;
  } else if (bytes.length === 64) {
    const yParityAndS = bytesToBigInt(bytes.slice(32, 64));
    v = 27 + Number(yParityAndS >> 255n);
    s = yParityAndS & ((1n << 255n) - 1n);
  } else {
    throw new Error("a signature is 64 or 65 bytes");
  }
  if (v !== 27 && v !== 28) throw new Error("signature recovery id out of range");
  if (s === 0n || s >= SECP256K1_N) throw new Error("signature s out of range");
  if (s > SECP256K1_N / 2n) {
    s = SECP256K1_N - s;
    v = v === 27 ? 28 : 27;
  }

  const out = new Uint8Array(65);
  out.set(r, 0);
  out.set(bigIntToBytes(s, 32), 32);
  out[64] = v;
  return out;
}

/** The 32-byte seed every key comes from, and what a backup stores. */
export function seedFromSignature(signature: Hex): Uint8Array {
  return keccak_256(normalizeSignature(signature));
}

export function deriveKeys(signature: Hex): BacklitKeys {
  return keysFromSeed(seedFromSignature(signature));
}

export function keysFromSeed(seed: Uint8Array): BacklitKeys {
  // 64 bytes of expansion, reduced mod the field, keeps the bias below any
  // meaningful threshold without rejection sampling.
  const spendMaterial = hkdf(sha256, seed, undefined, utf8ToBytes("backlit/spend"), 64);
  const spendingKey = bytesToBigInt(spendMaterial) % FR;

  const viewingSk = hkdf(sha256, seed, undefined, utf8ToBytes("backlit/view"), 32);
  const viewingPk = x25519.getPublicKey(viewingSk);

  return {spendingKey, ownerPk: poseidon2(spendingKey, 0n), viewingSk, viewingPk};
}

export function ownerPkFrom(spendingKey: bigint): bigint {
  return poseidon2(spendingKey, 0n);
}

export function viewingPkHex(keys: BacklitKeys): Hex {
  return bytesToHex(keys.viewingPk);
}
