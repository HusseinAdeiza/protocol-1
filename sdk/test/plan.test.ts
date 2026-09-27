import {describe, expect, it} from "vitest";

import {
  balanceOf,
  keysFromSeed,
  NoteTree,
  noteCommitment,
  openNote,
  planSettle,
  planSpend,
  randomFieldElement,
  royaltyFor,
  selectNotes,
  sellerNoteFromOffer,
  settleBinding,
  spendBinding,
  toHex32,
  verifyNote,
  type Hex,
  type OwnedNote,
} from "../src/index.js";

const WETH: Hex = "0x0bd7d308F8e1639FAb988df18a8011f41eaCad73";
const POOL_ID = 0x1337n;
const OFFER_ID: Hex = "0x9f1c6b3a0e2d4c5b6a79881726354453627180f9e8d7c6b5a4938271605f4e3d";
const TARGET: Hex = "0x000000000000000000000000000000000000dEaD";

const buyer = keysFromSeed(new Uint8Array(32).fill(11));
const seller = keysFromSeed(new Uint8Array(32).fill(22));
const creator = keysFromSeed(new Uint8Array(32).fill(33));

function scene(amounts: bigint[]) {
  const tree = new NoteTree();
  const notes: OwnedNote[] = amounts.map((amount) => {
    const salt = randomFieldElement();
    const commitment = noteCommitment({asset: WETH, amount, ownerPk: buyer.ownerPk, salt});
    return {leafIndex: tree.insert(commitment), commitment, asset: WETH, amount, ownerPk: buyer.ownerPk, salt};
  });
  return {tree, notes};
}

describe("note selection", () => {
  it("takes one note when it covers the amount", () => {
    const {notes} = scene([10n, 5n]);
    expect(selectNotes(notes, 7n)).toHaveLength(1);
  });

  it("takes two when one is not enough", () => {
    const {notes} = scene([10n, 5n]);
    expect(selectNotes(notes, 12n)).toHaveLength(2);
  });

  it("gives up rather than plan a spend that cannot settle", () => {
    const {notes} = scene([10n, 5n]);
    expect(selectNotes(notes, 20n)).toBeNull();
  });

  it("sums a balance", () => {
    const {notes} = scene([10n, 5n]);
    expect(balanceOf(notes)).toBe(15n);
  });
});

describe("planning a spend", () => {
  it("conserves value and addresses the change back to the spender", () => {
    const {tree, notes} = scene([1_000n, 500n]);
    const plan = planSpend({
      keys: buyer,
      poolId: POOL_ID,
      asset: WETH,
      tree,
      notes,
      withdrawAmount: 400n,
      recipient: TARGET,
    });

    const [sent, change] = plan.outputs;
    expect(sent.note.amount + change.note.amount + plan.withdrawAmount).toBe(1_500n);
    expect(change.note.ownerPk).toBe(buyer.ownerPk);
    expect(plan.call.publicInputs).toHaveLength(9);
    expect(plan.nullifiers[0]).not.toBe(plan.nullifiers[1]);
  });

  it("pads a single note with a zero note", () => {
    const {tree, notes} = scene([1_000n]);
    const plan = planSpend({
      keys: buyer,
      poolId: POOL_ID,
      asset: WETH,
      tree,
      notes,
      withdrawAmount: 100n,
      recipient: TARGET,
    });

    expect(plan.call.inputs.in_amounts).toEqual(["1000", "0"]);
    expect(plan.nullifiers[0]).not.toBe(plan.nullifiers[1]);
  });

  it("seals the change so only the spender can read it", () => {
    const {tree, notes} = scene([1_000n]);
    const plan = planSpend({keys: buyer, poolId: POOL_ID, asset: WETH, tree, notes});

    const opened = openNote(buyer.viewingSk, plan.outputs[1].payload);
    expect(opened?.amount).toBe(1_000n);
    expect(openNote(seller.viewingSk, plan.outputs[1].payload)).toBeNull();
  });

  it("binds the recipient, the unwrap flag and the payloads into the proof", () => {
    const {tree, notes} = scene([1_000n]);
    const plan = planSpend({
      keys: buyer,
      poolId: POOL_ID,
      asset: WETH,
      tree,
      notes,
      withdrawAmount: 100n,
      recipient: TARGET,
      unwrap: true,
    });
    const payloads = [plan.outputs[0].payload, plan.outputs[1].payload] as const;
    const binding = spendBinding(TARGET, true, payloads);

    expect(plan.call.publicInputs[8]).toBe(toHex32(binding));
    expect(plan.call.inputs.recipient).toBe(binding.toString());
    expect(spendBinding(TARGET, false, payloads)).not.toBe(binding);
    expect(spendBinding(TARGET, true, [payloads[1], payloads[0]])).not.toBe(binding);
  });

  it("refuses a withdrawal with nobody to pay", () => {
    const {tree, notes} = scene([1_000n]);
    expect(() =>
      planSpend({keys: buyer, poolId: POOL_ID, asset: WETH, tree, notes, withdrawAmount: 100n}),
    ).toThrow(/recipient/);
  });

  it("refuses to plan a spend the notes cannot cover", () => {
    const {tree, notes} = scene([10n]);
    expect(() =>
      planSpend({keys: buyer, poolId: POOL_ID, asset: WETH, tree, notes, withdrawAmount: 100n, recipient: TARGET}),
    ).toThrow(/not enough/);
  });
});

describe("planning a settlement", () => {
  it("splits the price into the seller's share, the royalty and the change", () => {
    const {tree, notes} = scene([1_000n, 500n]);
    const price = 800n;
    const plan = planSettle({
      keys: buyer,
      poolId: POOL_ID,
      asset: WETH,
      tree,
      notes,
      price,
      priceBlinding: randomFieldElement(),
      royaltyBps: 500,
      offerId: OFFER_ID,
      seller: {ownerPk: seller.ownerPk, viewingPk: seller.viewingPk},
      creator: {ownerPk: creator.ownerPk, viewingPk: creator.viewingPk},
    });

    expect(plan.royaltyAmount).toBe(royaltyFor(price, 500n));
    expect(plan.seller.note.amount + plan.creator.note.amount).toBe(price);
    expect(plan.change.note.amount).toBe(1_500n - price);
    expect(plan.call.publicInputs).toHaveLength(14);
  });

  it("seals each note to the party it belongs to", () => {
    const {tree, notes} = scene([1_000n]);
    const plan = planSettle({
      keys: buyer,
      poolId: POOL_ID,
      asset: WETH,
      tree,
      notes,
      price: 400n,
      priceBlinding: randomFieldElement(),
      royaltyBps: 250,
      offerId: OFFER_ID,
      seller: {ownerPk: seller.ownerPk, viewingPk: seller.viewingPk},
      creator: {ownerPk: creator.ownerPk, viewingPk: creator.viewingPk},
    });

    expect(openNote(seller.viewingSk, plan.seller.payload)?.amount).toBe(plan.seller.note.amount);
    expect(openNote(creator.viewingSk, plan.creator.payload)?.amount).toBe(plan.royaltyAmount);
    expect(openNote(buyer.viewingSk, plan.change.payload)?.amount).toBe(600n);
    expect(openNote(creator.viewingSk, plan.seller.payload)).toBeNull();
  });

  it("rounds the royalty up, in the creator's favour", () => {
    const {tree, notes} = scene([10_000n]);
    const plan = planSettle({
      keys: buyer,
      poolId: POOL_ID,
      asset: WETH,
      tree,
      notes,
      price: 999n,
      priceBlinding: 1n,
      royaltyBps: 250,
      offerId: OFFER_ID,
      seller: {ownerPk: seller.ownerPk, viewingPk: seller.viewingPk},
      creator: {ownerPk: creator.ownerPk, viewingPk: creator.viewingPk},
    });

    expect(plan.royaltyAmount).toBe(25n);
    expect(plan.seller.note.amount).toBe(974n);
  });

  it("binds the proof to the offer and the payloads", () => {
    const {tree, notes} = scene([1_000n]);
    const plan = planSettle({
      keys: buyer,
      poolId: POOL_ID,
      asset: WETH,
      tree,
      notes,
      price: 400n,
      priceBlinding: randomFieldElement(),
      royaltyBps: 250,
      offerId: OFFER_ID,
      seller: {ownerPk: seller.ownerPk, viewingPk: seller.viewingPk},
      creator: {ownerPk: creator.ownerPk, viewingPk: creator.viewingPk},
    });
    const payloads = [plan.seller.payload, plan.creator.payload, plan.change.payload] as const;

    expect(plan.call.publicInputs[13]).toBe(toHex32(settleBinding(OFFER_ID, payloads)));
    expect(plan.call.inputs.binding).toBe(settleBinding(OFFER_ID, payloads).toString());
    expect(plan.call.inputs).not.toHaveProperty("seller_salt");
    expect(settleBinding(OFFER_ID, [payloads[1], payloads[0], payloads[2]])).not.toBe(
      settleBinding(OFFER_ID, payloads),
    );
  });

  it("lets the seller rebuild their note from the offer alone", () => {
    const {tree, notes} = scene([1_000n]);
    const offer = {price: 999n, blinding: randomFieldElement()};
    const plan = planSettle({
      keys: buyer,
      poolId: POOL_ID,
      asset: WETH,
      tree,
      notes,
      price: offer.price,
      priceBlinding: offer.blinding,
      royaltyBps: 250,
      offerId: OFFER_ID,
      seller: {ownerPk: seller.ownerPk, viewingPk: seller.viewingPk},
      creator: {ownerPk: creator.ownerPk, viewingPk: creator.viewingPk},
    });

    const rebuilt = sellerNoteFromOffer(offer, 250, seller.ownerPk, WETH);
    expect(rebuilt.commitment).toBe(plan.seller.commitment);
    expect(rebuilt.note).toEqual(plan.seller.note);
    expect(verifyNote(rebuilt.note, toHex32(plan.seller.commitment), WETH)).toBe(true);
  });
});
