import {MAX_DEPTH} from "./constants.js";
import {toHex32, type Hex} from "./field.js";
import type {MembershipProof} from "./tree.js";

/** What `noir_js` executes against: every value as a decimal or hex string. */
export type WitnessMap = Record<string, unknown>;

export interface CircuitCall {
  /** Input map for `noir_js`. */
  inputs: WitnessMap;
  /** Public inputs in ABI order, which is the order the contracts rebuild. */
  publicInputs: Hex[];
}

export interface SpendInputs {
  poolId: bigint;
  asset: Hex;
  root: bigint;
  spendingKey: bigint;
  inputs: Array<{amount: bigint; salt: bigint; proof: MembershipProof}>;
  outputs: Array<{amount: bigint; ownerPk: bigint; salt: bigint}>;
  outputCommitments: [bigint, bigint];
  nullifiers: [bigint, bigint];
  withdrawAmount: bigint;
  /** `spendBinding(recipient, unwrap, payloads)`, placed in the circuit's `recipient` slot. */
  binding: bigint;
}

export interface SettleInputs {
  poolId: bigint;
  asset: Hex;
  root: bigint;
  spendingKey: bigint;
  inputs: Array<{amount: bigint; salt: bigint; proof: MembershipProof}>;
  nullifiers: [bigint, bigint];
  sellerCommitment: bigint;
  creatorCommitment: bigint;
  changeCommitment: bigint;
  priceCommitment: bigint;
  royaltyBps: number;
  sellerPk: bigint;
  creatorPk: bigint;
  buyerPk: bigint;
  /** `settleBinding(offerId, payloads)`. */
  binding: bigint;
  price: bigint;
  priceBlinding: bigint;
  royaltyAmount: bigint;
  creatorSalt: bigint;
  changeSalt: bigint;
  sellerAmount: bigint;
  changeAmount: bigint;
}

function dec(value: bigint): string {
  return value.toString();
}

function siblings(proof: MembershipProof): string[] {
  if (proof.siblings.length !== MAX_DEPTH) throw new Error("path is not padded to MAX_DEPTH");
  return proof.siblings.map(dec);
}

export function spendCall(input: SpendInputs): CircuitCall {
  const [a, b] = input.inputs;
  const [x, y] = input.outputs;
  if (!a || !b || !x || !y) throw new Error("spend takes exactly two notes in and two out");

  return {
    inputs: {
      pool_id: dec(input.poolId),
      asset: dec(BigInt(input.asset)),
      root: dec(input.root),
      nullifiers: input.nullifiers.map(dec),
      out_commitments: input.outputCommitments.map(dec),
      withdraw_amount: dec(input.withdrawAmount),
      recipient: dec(input.binding),
      spending_key: dec(input.spendingKey),
      in_amounts: [dec(a.amount), dec(b.amount)],
      in_salts: [dec(a.salt), dec(b.salt)],
      in_siblings: [siblings(a.proof), siblings(b.proof)],
      in_indices: [dec(a.proof.index), dec(b.proof.index)],
      in_depths: [a.proof.depth, b.proof.depth],
      out_amounts: [dec(x.amount), dec(y.amount)],
      out_owners: [dec(x.ownerPk), dec(y.ownerPk)],
      out_salts: [dec(x.salt), dec(y.salt)],
    },
    publicInputs: [
      toHex32(input.poolId),
      toHex32(BigInt(input.asset)),
      toHex32(input.root),
      toHex32(input.nullifiers[0]),
      toHex32(input.nullifiers[1]),
      toHex32(input.outputCommitments[0]),
      toHex32(input.outputCommitments[1]),
      toHex32(input.withdrawAmount),
      toHex32(input.binding),
    ],
  };
}

export function settleCall(input: SettleInputs): CircuitCall {
  const [a, b] = input.inputs;
  if (!a || !b) throw new Error("settle takes exactly two notes in");

  return {
    inputs: {
      pool_id: dec(input.poolId),
      asset: dec(BigInt(input.asset)),
      root: dec(input.root),
      nullifiers: input.nullifiers.map(dec),
      seller_commitment: dec(input.sellerCommitment),
      creator_commitment: dec(input.creatorCommitment),
      change_commitment: dec(input.changeCommitment),
      price_commitment: dec(input.priceCommitment),
      royalty_bps: input.royaltyBps,
      seller_pk: dec(input.sellerPk),
      creator_pk: dec(input.creatorPk),
      buyer_pk: dec(input.buyerPk),
      binding: dec(input.binding),
      spending_key: dec(input.spendingKey),
      in_amounts: [dec(a.amount), dec(b.amount)],
      in_salts: [dec(a.salt), dec(b.salt)],
      in_siblings: [siblings(a.proof), siblings(b.proof)],
      in_indices: [dec(a.proof.index), dec(b.proof.index)],
      in_depths: [a.proof.depth, b.proof.depth],
      price: dec(input.price),
      price_blinding: dec(input.priceBlinding),
      royalty_amount: dec(input.royaltyAmount),
      creator_salt: dec(input.creatorSalt),
      change_salt: dec(input.changeSalt),
    },
    publicInputs: [
      toHex32(input.poolId),
      toHex32(BigInt(input.asset)),
      toHex32(input.root),
      toHex32(input.nullifiers[0]),
      toHex32(input.nullifiers[1]),
      toHex32(input.sellerCommitment),
      toHex32(input.creatorCommitment),
      toHex32(input.changeCommitment),
      toHex32(input.priceCommitment),
      toHex32(BigInt(input.royaltyBps)),
      toHex32(input.sellerPk),
      toHex32(input.creatorPk),
      toHex32(input.buyerPk),
      toHex32(input.binding),
    ],
  };
}
