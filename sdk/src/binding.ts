import {encodeAbiParameters, keccak256} from "viem";

import {FR, type Hex} from "./field.js";

/**
 * Each circuit has one public input it only binds: `recipient` in spend and
 * `binding` in settle. The contracts fill that slot with a hash of the call's
 * context, so a proof is valid for exactly one call. These reproduce the
 * contracts' `spendBinding` and `settleBinding` byte for byte.
 */

function payloadsHash(payloads: readonly Hex[]): Hex {
  // `abi.encode(bytes[N])` for a fixed N, which differs from `bytes[]`.
  return keccak256(encodeAbiParameters([{type: `bytes[${payloads.length}]`}], [payloads] as never));
}

/** `BacklitPool.spendBinding`: recipient, unwrap flag and both output payloads. */
export function spendBinding(recipient: Hex, unwrap: boolean, payloads: readonly [Hex, Hex]): bigint {
  const encoded = encodeAbiParameters(
    [{type: "address"}, {type: "bool"}, {type: "bytes32"}],
    [recipient, unwrap, payloadsHash(payloads)],
  );
  return BigInt(keccak256(encoded)) % FR;
}

/** `BacklitMarket.settleBinding`: the offer id and the seller, creator and change payloads, in that order. */
export function settleBinding(offerId: Hex, payloads: readonly [Hex, Hex, Hex]): bigint {
  const encoded = encodeAbiParameters(
    [{type: "bytes32"}, {type: "bytes32"}],
    [offerId, payloadsHash(payloads)],
  );
  return BigInt(keccak256(encoded)) % FR;
}
