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
  type Hex,
  type OwnedNote,
} from "../src/index.js";

const WETH: Hex = "0x0bd7d308F8e1639FAb988df18a8011f41eaCad73";
const POOL_ID = 0x1337n;

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
    });

    const [sent, change] = plan.outputs;
    expect(sent.note.amount + change.note.amount + plan.withdrawAmount).toBe(1_500n);
    expect(change.note.ownerPk).toBe(buyer.ownerPk);
    expect(plan.call.publicInputs).toHaveLength(9);
    expect(plan.nullifiers[0]).not.toBe(plan.nullifiers[1]);
  });

  it("pads a single note with a zero note", () => {
    const {tree, notes} = scene([1_000n]);
    const plan = planSpend({keys: buyer, poolId: POOL_ID, asset: WETH, tree, notes, withdrawAmount: 100n});

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

  it("refuses to plan a spend the notes cannot cover", () => {
    const {tree, notes} = scene([10n]);
    expect(() =>
      planSpend({keys: buyer, poolId: POOL_ID, asset: WETH, tree, notes, withdrawAmount: 100n}),
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
      listingId: 0x5eedn,
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
      listingId: 1n,
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
      listingId: 1n,
      seller: {ownerPk: seller.ownerPk, viewingPk: seller.viewingPk},
      creator: {ownerPk: creator.ownerPk, viewingPk: creator.viewingPk},
    });

    expect(plan.royaltyAmount).toBe(25n);
    expect(plan.seller.note.amount).toBe(974n);
  });
});
