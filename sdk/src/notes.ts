import {assertField, FR, MAX_NOTE_AMOUNT, type Hex} from "./field.js";
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

/** "backlit/seller-salt" as a big-endian field element. Matches `SELLER_SALT_TAG` in `circuits/lib`. */
export const SELLER_SALT_TAG = 0x6261636b6c69742f73656c6c65722d73616c74n;

/**
 * The seller's note salt in a settlement. The settle circuit derives it from
 * the price blinding, so the seller never depends on the buyer's payload.
 */
export function sellerSalt(priceBlinding: bigint): bigint {
  return poseidon2(assertField(priceBlinding, "blinding"), SELLER_SALT_TAG);
}

/**
 * Rebuilds the seller's proceeds note from the offer opening the seller
 * already decrypted. Use it to find and spend the note even when the payload
 * the buyer attached does not open: match `commitment` against the
 * `NoteCreated` events of the settlement.
 */
export function sellerNoteFromOffer(
  offer: {price: bigint; blinding: bigint},
  royaltyBps: number | bigint,
  sellerPk: bigint,
  asset: Hex,
): {note: Note; commitment: bigint} {
  const amount = offer.price - royaltyFor(offer.price, BigInt(royaltyBps));
  const note: Note = {asset, amount, ownerPk: sellerPk, salt: sellerSalt(offer.blinding)};
  return {note, commitment: noteCommitment(note)};
}

/**
 * True when a decrypted note really is the leaf it was published with. A
 * payload is not covered by the proof, so a sender can attach one that opens
 * to the wrong amount or salt; a wallet must drop any note that fails this.
 */
export function verifyNote(note: Note, commitment: bigint | Hex, asset: Hex): boolean {
  if (note.asset.toLowerCase() !== asset.toLowerCase()) return false;
  if (note.amount < 0n || note.amount >= MAX_NOTE_AMOUNT) return false;
  if (note.ownerPk < 0n || note.ownerPk >= FR || note.salt < 0n || note.salt >= FR) return false;
  const expected = typeof commitment === "bigint" ? commitment : BigInt(commitment);
  return noteCommitment(note) === expected;
}
