import {assertField, MAX_NOTE_AMOUNT, type Hex} from "./field.js";
import {poseidon2, poseidon4} from "./poseidon.js";

/** A private record of value inside a Backlit pool. */
export interface Note {
  /** The ERC-20 the note is denominated in. WETH in v1. */
  asset: Hex;
  amount: bigint;
  ownerPk: bigint;
  salt: bigint;
}

/** A note the wallet has found in the tree and can spend. */
export interface OwnedNote extends Note {
  leafIndex: number;
  commitment: bigint;
}

export function assetField(asset: Hex): bigint {
  return BigInt(asset);
}

export function noteCommitment(note: Note): bigint {
  if (note.amount < 0n || note.amount >= MAX_NOTE_AMOUNT) throw new Error("amount out of range");
  return poseidon4(
    assetField(note.asset),
    note.amount,
    assertField(note.ownerPk, "ownerPk"),
    assertField(note.salt, "salt"),
  );
}

export function noteNullifier(commitment: bigint, spendingKey: bigint): bigint {
  return poseidon2(commitment, spendingKey);
}

/** The public stand-in for a price. Binding, and hiding while the blinding stays secret. */
export function priceCommitment(price: bigint, blinding: bigint): bigint {
  if (price < 0n || price >= MAX_NOTE_AMOUNT) throw new Error("price out of range");
  return poseidon2(price, assertField(blinding, "blinding"));
}

/** ERC-2981 rounds in the creator's favour: the royalty is always rounded up. */
export function royaltyFor(price: bigint, bps: bigint): bigint {
  if (bps < 0n || bps > 10_000n) throw new Error("basis points out of range");
  return (price * bps + 9_999n) / 10_000n;
}
