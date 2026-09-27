import {readFileSync} from "node:fs";
import {describe, expect, it} from "vitest";

import {
  MAX_DEPTH,
  NoteTree,
  noteCommitment,
  noteNullifier,
  poseidon2,
  poseidon4,
  priceCommitment,
  royaltyFor,
  sellerSalt,
  settleBinding,
  spendBinding,
  toHex32,
  type Hex,
} from "../src/index.js";

const vectors = JSON.parse(
  readFileSync(new URL("../../circuits/tests/vectors/vectors.json", import.meta.url), "utf8"),
) as {
  poseidon2: Array<{in: [string, string]; out: string}>;
  poseidon4: Array<{in: [string, string, string, string]; out: string}>;
  keys: {spendingKey: string; ownerPk: string};
  notes: Array<{asset: Hex; amount: string; ownerPk: string; salt: string; commitment: string; nullifier: string}>;
  tree: {
    leaves: string[];
    roots: string[];
    membership: {leafIndex: number; leaf: string; index: string; depth: number; siblings: string[]; root: string};
  };
  priceCommitment: {price: string; blinding: string; out: string};
  royalties: Array<{price: string; bps: number; royalty: string}>;
  sellerSalt: {blinding: string; out: string};
  spendBinding: {recipient: Hex; unwrap: boolean; payloads: [Hex, Hex]; out: string};
  settleBinding: {offerId: Hex; payloads: [Hex, Hex, Hex]; out: string};
};

describe("the vectors the contracts and circuits are held to", () => {
  it("reproduces every poseidon2 case", () => {
    for (const {in: [a, b], out} of vectors.poseidon2) {
      expect(toHex32(poseidon2(BigInt(a), BigInt(b)))).toBe(out);
    }
  });

  it("reproduces every poseidon4 case", () => {
    for (const {in: [a, b, c, d], out} of vectors.poseidon4) {
      expect(toHex32(poseidon4(BigInt(a), BigInt(b), BigInt(c), BigInt(d)))).toBe(out);
    }
  });

  it("reproduces every note commitment and nullifier", () => {
    const spendingKey = BigInt(vectors.keys.spendingKey);
    for (const note of vectors.notes) {
      const commitment = noteCommitment({
        asset: note.asset,
        amount: BigInt(note.amount),
        ownerPk: BigInt(note.ownerPk),
        salt: BigInt(note.salt),
      });
      expect(toHex32(commitment)).toBe(note.commitment);
      expect(toHex32(noteNullifier(commitment, spendingKey))).toBe(note.nullifier);
    }
  });

  it("reproduces the price commitment", () => {
    const {price, blinding, out} = vectors.priceCommitment;
    expect(toHex32(priceCommitment(BigInt(price), BigInt(blinding)))).toBe(out);
  });

  it("rounds royalties the way the circuit does", () => {
    for (const {price, bps, royalty} of vectors.royalties) {
      expect(royaltyFor(BigInt(price), BigInt(bps)).toString()).toBe(royalty);
    }
  });

  it("produces the same root after every insert", () => {
    const tree = new NoteTree();
    vectors.tree.leaves.forEach((leaf, i) => {
      tree.insert(BigInt(leaf));
      expect(toHex32(tree.root)).toBe(vectors.tree.roots[i]);
    });
  });

  it("produces a membership path that rebuilds the root", () => {
    const tree = new NoteTree(vectors.tree.leaves.map(BigInt));
    const proof = tree.proofFor(vectors.tree.membership.leafIndex);

    expect(proof.depth).toBe(vectors.tree.membership.depth);
    expect(proof.siblings).toHaveLength(MAX_DEPTH);
    expect(toHex32(proof.index)).toBe(vectors.tree.membership.index);

    let node = BigInt(vectors.tree.membership.leaf);
    for (let level = 0; level < proof.depth; level++) {
      const onTheRight = (proof.index >> BigInt(level)) & 1n;
      const sibling = proof.siblings[level]!;
      node = onTheRight ? poseidon2(sibling, node) : poseidon2(node, sibling);
    }
    expect(toHex32(node)).toBe(vectors.tree.membership.root);
  });

  it("derives the seller salt the circuit derives", () => {
    expect(toHex32(sellerSalt(BigInt(vectors.sellerSalt.blinding)))).toBe(vectors.sellerSalt.out);
  });

  it("hashes the call context the way the contracts do", () => {
    const spend = vectors.spendBinding;
    expect(toHex32(spendBinding(spend.recipient, spend.unwrap, spend.payloads))).toBe(spend.out);
    const settle = vectors.settleBinding;
    expect(toHex32(settleBinding(settle.offerId, settle.payloads))).toBe(settle.out);
  });
});
