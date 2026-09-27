import {LeanIMT} from "@zk-kit/lean-imt";

import {MAX_DEPTH} from "./constants.js";
import {poseidon2} from "./poseidon.js";

/** A membership path in the pool's LeanIMT, padded out to the circuit's depth. */
export interface MembershipProof {
  siblings: bigint[];
  index: bigint;
  depth: number;
}

/** The pool's tree, rebuilt in the browser from `NoteCreated` events. */
export class NoteTree {
  private readonly tree: LeanIMT<bigint>;

  constructor(leaves: bigint[] = []) {
    this.tree = new LeanIMT<bigint>((a, b) => poseidon2(a, b));
    if (leaves.length > 0) this.tree.insertMany(leaves);
  }

  insert(leaf: bigint): number {
    this.tree.insert(leaf);
    return this.tree.size - 1;
  }

  insertMany(leaves: bigint[]): void {
    if (leaves.length > 0) this.tree.insertMany(leaves);
  }

  get size(): number {
    return this.tree.size;
  }

  get depth(): number {
    return this.tree.depth;
  }

  get root(): bigint {
    return this.tree.size === 0 ? 0n : this.tree.root;
  }

  indexOf(leaf: bigint): number {
    return this.tree.indexOf(leaf);
  }

  /** The path the circuits take: real siblings first, zero padding after. */
  proofFor(leafIndex: number): MembershipProof {
    const proof = this.tree.generateProof(leafIndex);
    const siblings = [...proof.siblings];
    if (siblings.length > MAX_DEPTH) throw new Error("tree is deeper than the circuits allow");
    const depth = siblings.length;
    while (siblings.length < MAX_DEPTH) siblings.push(0n);
    return {siblings, index: BigInt(proof.index), depth};
  }

  /** The path a zero note takes: nothing to prove, so everything is zero. */
  static emptyProof(): MembershipProof {
    return {siblings: new Array<bigint>(MAX_DEPTH).fill(0n), index: 0n, depth: 0};
  }
}
