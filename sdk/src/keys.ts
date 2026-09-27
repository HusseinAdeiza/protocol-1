import {hkdf} from "@noble/hashes/hkdf.js";
import {sha256} from "@noble/hashes/sha2.js";
import {utf8ToBytes} from "@noble/hashes/utils.js";
import {keccak_256} from "@noble/hashes/sha3.js";
import {x25519} from "@noble/curves/ed25519.js";

import {bytesToBigInt, bytesToHex, FR, hexToBytes, type Hex} from "./field.js";
import {poseidon2} from "./poseidon.js";

/**
 * One wallet signature produces every key Backlit needs. The signature is
 * never stored; the keys live in memory for the session.
 *
 * spendingKey   authorises spending. Never leaves the device.
 * ownerPk       public, registered on chain, addresses notes to this owner.
 * viewingSk/Pk  x25519 pair that decrypts note and offer payloads. The secret
 *               half can be exported to a read-only viewer.
 */
export interface BacklitKeys {
  spendingKey: bigint;
  ownerPk: bigint;
  viewingSk: Uint8Array;
  viewingPk: Uint8Array;
}

export const KEY_PURPOSE = "backlit-keys-v1";

/** The EIP-712 payload the wallet signs. Deterministic per wallet and chain. */
export function keyDerivationTypedData(chainId: number, wallet: Hex) {
  return {
    domain: {name: "Backlit", version: "1", chainId},
    types: {
      KeyDerivation: [
        {name: "purpose", type: "string"},
        {name: "wallet", type: "address"},
      ],
    },
    primaryType: "KeyDerivation" as const,
    message: {purpose: KEY_PURPOSE, wallet},
  };
}

export function deriveKeys(signature: Hex): BacklitKeys {
  const seed = keccak_256(hexToBytes(signature));
  return keysFromSeed(seed);
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
