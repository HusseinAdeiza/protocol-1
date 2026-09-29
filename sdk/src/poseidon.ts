// The package index pulls in the constants for all sixteen widths. Only two are used.
import {poseidon2 as p2} from "poseidon-lite/poseidon2";
import {poseidon4 as p4} from "poseidon-lite/poseidon4";

/**
 * The circomlib-compatible BN254 Poseidon, the one hash the whole system
 * agrees on: `poseidon-solidity` on chain, `noir-lang/poseidon` in the
 * circuits, this in the browser. `sdk/test/parity.test.ts` pins all three to
 * the same vectors.
 */
export function poseidon2(a: bigint, b: bigint): bigint {
  return p2([a, b]);
}

export function poseidon4(a: bigint, b: bigint, c: bigint, d: bigint): bigint {
  return p4([a, b, c, d]);
}
