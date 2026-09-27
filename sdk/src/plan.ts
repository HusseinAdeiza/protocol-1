import {settleBinding, spendBinding} from "./binding.js";
import {settleCall, spendCall, type CircuitCall} from "./circuits.js";
import {randomFieldElement, sealNote} from "./envelope.js";
import {MAX_NOTE_AMOUNT, type Hex} from "./field.js";
import type {BacklitKeys} from "./keys.js";
import {
  noteCommitment,
  noteNullifier,
  priceCommitment,
  royaltyFor,
  sellerSalt,
  type Note,
  type OwnedNote,
} from "./notes.js";
import {NoteTree, type MembershipProof} from "./tree.js";

/** Where a new note is going: whose it is, and who can read it. */
export interface Payee {
  ownerPk: bigint;
  viewingPk: Uint8Array;
}

export interface PlannedNote {
  note: Note;
  commitment: bigint;
  payload: Hex;
}

export interface SpendPlan {
  call: CircuitCall;
  root: bigint;
  nullifiers: [bigint, bigint];
  outputs: [PlannedNote, PlannedNote];
  withdrawAmount: bigint;
  recipient: Hex;
  unwrap: boolean;
  /** The notes this plan consumes, so the wallet can mark them pending. */
  spent: OwnedNote[];
}

export interface SettlePlan {
  call: CircuitCall;
  root: bigint;
  nullifiers: [bigint, bigint];
  seller: PlannedNote;
  creator: PlannedNote;
  change: PlannedNote;
  price: bigint;
  royaltyAmount: bigint;
  spent: OwnedNote[];
}

/**
 * Picks the notes to spend: largest first, at most two, stopping as soon as
 * they cover the amount. Returns null when the balance is not there.
 */
export function selectNotes(notes: OwnedNote[], needed: bigint): OwnedNote[] | null {
  const sorted = [...notes].sort((a, b) => (b.amount > a.amount ? 1 : b.amount < a.amount ? -1 : 0));
  const first = sorted[0];
  if (!first) return needed === 0n ? [] : null;
  if (first.amount >= needed) return [first];
  const second = sorted[1];
  if (!second) return null;
  if (first.amount + second.amount >= needed) return [first, second];
  return null;
}

/** Sum of everything the wallet can spend right now. */
export function balanceOf(notes: OwnedNote[]): bigint {
  return notes.reduce((total, note) => total + note.amount, 0n);
}

function zeroInput(asset: Hex, ownerPk: bigint) {
  const salt = randomFieldElement();
  return {amount: 0n, salt, proof: NoteTree.emptyProof(), commitment: noteCommitment({asset, amount: 0n, ownerPk, salt})};
}

function inputsFor(
  keys: BacklitKeys,
  asset: Hex,
  tree: NoteTree,
  notes: OwnedNote[],
): {
  entries: Array<{amount: bigint; salt: bigint; proof: MembershipProof}>;
  nullifiers: [bigint, bigint];
  total: bigint;
} {
  if (notes.length === 0 || notes.length > 2) throw new Error("a spend takes one or two notes");

  const entries: Array<{amount: bigint; salt: bigint; proof: MembershipProof}> = [];
  const nullifiers: bigint[] = [];
  let total = 0n;

  for (const note of notes) {
    const proof = tree.proofFor(note.leafIndex);
    entries.push({amount: note.amount, salt: note.salt, proof});
    nullifiers.push(noteNullifier(note.commitment, keys.spendingKey));
    total += note.amount;
  }

  while (entries.length < 2) {
    const filler = zeroInput(asset, keys.ownerPk);
    entries.push({amount: 0n, salt: filler.salt, proof: filler.proof});
    nullifiers.push(noteNullifier(filler.commitment, keys.spendingKey));
  }

  if (nullifiers[0] === nullifiers[1]) throw new Error("the same note twice");
  return {entries, nullifiers: [nullifiers[0]!, nullifiers[1]!], total};
}

function mint(asset: Hex, amount: bigint, to: Payee, salt = randomFieldElement()): PlannedNote {
  const note: Note = {asset, amount, ownerPk: to.ownerPk, salt};
  return {
    note,
    commitment: noteCommitment(note),
    payload: sealNote(to.viewingPk, {asset, amount, salt: note.salt}),
  };
}

export interface SpendRequest {
  keys: BacklitKeys;
  poolId: bigint;
  asset: Hex;
  tree: NoteTree;
  notes: OwnedNote[];
  /** Value leaving the pool as plain WETH or ETH. */
  withdrawAmount?: bigint;
  recipient?: Hex;
  /** Pay the withdrawal out as ETH rather than WETH. The proof commits to this. */
  unwrap?: boolean;
  /** Value staying in the pool as somebody else's note. */
  sendAmount?: bigint;
  sendTo?: Payee;
}

/**
 * Builds a spend: two notes in, two notes out, with whatever leaves the pool
 * paid to `recipient`. Change always comes back to the spender.
 */
export function planSpend(request: SpendRequest): SpendPlan {
  const {keys, asset, tree, notes} = request;
  const withdrawAmount = request.withdrawAmount ?? 0n;
  const sendAmount = request.sendAmount ?? 0n;
  const recipient = request.recipient ?? "0x0000000000000000000000000000000000000000";
  const unwrap = request.unwrap ?? false;

  if (sendAmount > 0n && !request.sendTo) throw new Error("no recipient key for the note being sent");
  if (withdrawAmount >= MAX_NOTE_AMOUNT) throw new Error("withdrawal out of range");
  if (withdrawAmount > 0n && BigInt(recipient) === 0n) throw new Error("a withdrawal needs a recipient");

  const {entries, nullifiers, total} = inputsFor(keys, asset, tree, notes);
  if (total < withdrawAmount + sendAmount) throw new Error("not enough in these notes");

  const self: Payee = {ownerPk: keys.ownerPk, viewingPk: keys.viewingPk};
  const sent = mint(asset, sendAmount, request.sendTo ?? self);
  const change = mint(asset, total - withdrawAmount - sendAmount, self);

  const call = spendCall({
    poolId: request.poolId,
    asset,
    root: tree.root,
    spendingKey: keys.spendingKey,
    inputs: entries,
    outputs: [sent.note, change.note].map((n) => ({amount: n.amount, ownerPk: n.ownerPk, salt: n.salt})),
    outputCommitments: [sent.commitment, change.commitment],
    nullifiers,
    withdrawAmount,
    binding: spendBinding(recipient, unwrap, [sent.payload, change.payload]),
  });

  return {
    call,
    root: tree.root,
    nullifiers,
    outputs: [sent, change],
    withdrawAmount,
    recipient,
    unwrap,
    spent: notes,
  };
}

export interface SettleRequest {
  keys: BacklitKeys;
  poolId: bigint;
  asset: Hex;
  tree: NoteTree;
  notes: OwnedNote[];
  price: bigint;
  priceBlinding: bigint;
  royaltyBps: number;
  /** The offer being settled. The proof is valid for this offer only. */
  offerId: Hex;
  seller: Payee;
  creator: Payee;
}

/**
 * Builds the settlement: the buyer's notes pay the seller and the creator,
 * the change comes back, and the proof ties all three to a price only the
 * commitment records.
 */
export function planSettle(request: SettleRequest): SettlePlan {
  const {keys, asset, tree, notes, price, royaltyBps} = request;

  const {entries, nullifiers, total} = inputsFor(keys, asset, tree, notes);
  if (total < price) throw new Error("not enough in these notes");

  const royaltyAmount = royaltyFor(price, BigInt(royaltyBps));
  const sellerAmount = price - royaltyAmount;

  // The circuit fixes the seller's salt, so the seller can rebuild this note
  // from the offer with `sellerNoteFromOffer` whatever the payload says.
  const seller = mint(asset, sellerAmount, request.seller, sellerSalt(request.priceBlinding));
  const creator = mint(asset, royaltyAmount, request.creator);
  const change = mint(asset, total - price, {ownerPk: keys.ownerPk, viewingPk: keys.viewingPk});

  const call = settleCall({
    poolId: request.poolId,
    asset,
    root: tree.root,
    spendingKey: keys.spendingKey,
    inputs: entries,
    nullifiers,
    sellerCommitment: seller.commitment,
    creatorCommitment: creator.commitment,
    changeCommitment: change.commitment,
    priceCommitment: priceCommitment(price, request.priceBlinding),
    royaltyBps,
    sellerPk: request.seller.ownerPk,
    creatorPk: request.creator.ownerPk,
    buyerPk: keys.ownerPk,
    binding: settleBinding(request.offerId, [seller.payload, creator.payload, change.payload]),
    price,
    priceBlinding: request.priceBlinding,
    royaltyAmount,
    creatorSalt: creator.note.salt,
    changeSalt: change.note.salt,
    sellerAmount,
    changeAmount: total - price,
  });

  return {call, root: tree.root, nullifiers, seller, creator, change, price, royaltyAmount, spent: notes};
}
