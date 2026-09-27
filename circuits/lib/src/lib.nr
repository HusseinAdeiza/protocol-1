//! Shared pieces of the Backlit note scheme: commitments, nullifiers and
//! membership in the pool's LeanIMT.
//!
//! Every hash here is the circomlib-compatible BN254 Poseidon, so the same
//! values come out of `poseidon-solidity` on chain and `poseidon-lite` in the
//! browser. `circuits/tests` pins that with shared vectors.

use poseidon::poseidon::bn254::{hash_2, hash_4};

/// Deepest tree the circuits accept. The pool caps its own tree at the same
/// number, so a proof can always cite any leaf the pool holds.
pub global MAX_DEPTH: u32 = 32;

/// Note amounts are uint96 on chain, so 2^96 is the exclusive upper bound.
pub global MAX_AMOUNT: u128 = 79228162514264337593543950336;

/// Basis points denominator, matching ERC-2981.
pub global BPS_DENOM: u128 = 10000;

/// A LeanIMT membership path. `depth` is the number of levels actually walked;
/// siblings past that point are ignored, which is how a LeanIMT proof shrinks
/// for a tree that is not yet full.
pub struct MerkleProof {
    pub siblings: [Field; MAX_DEPTH],
    pub index: Field,
    pub depth: u32,
}

/// The public half of a spending key. Registered on chain so other people can
/// address notes to this owner.
pub fn owner_pk(spending_key: Field) -> Field {
    hash_2([spending_key, 0])
}

/// The leaf a note occupies in the pool's tree.
pub fn commit(asset: Field, amount: u128, owner: Field, salt: Field) -> Field {
    hash_4([asset, amount as Field, owner, salt])
}

/// The value published when a note is spent. Reveals nothing about the note.
pub fn nullify(commitment: Field, spending_key: Field) -> Field {
    hash_2([commitment, spending_key])
}

/// Walks a LeanIMT path and returns the root it implies.
pub fn lean_imt_root(leaf: Field, proof: MerkleProof) -> Field {
    assert(proof.depth <= MAX_DEPTH, "path is deeper than the tree");
    let bits: [bool; MAX_DEPTH] = proof.index.to_le_bits();
    let mut node = leaf;
    for level in 0..MAX_DEPTH {
        if level < proof.depth {
            let sibling = proof.siblings[level];
            let on_the_right = bits[level];
            let left = if on_the_right { sibling } else { node };
            let right = if on_the_right { node } else { sibling };
            node = hash_2([left, right]);
        }
    }
    node
}

/// Consumes one input note and returns its nullifier.
///
/// A zero note (amount 0) skips the membership check. That is what lets a
/// single real note be spent through the fixed two-input shape; it can create
/// no value, since its amount is zero everywhere it is used.
pub fn spend_note(
    asset: Field,
    amount: u128,
    salt: Field,
    owner: Field,
    spending_key: Field,
    proof: MerkleProof,
    root: Field,
) -> Field {
    assert(amount < MAX_AMOUNT, "input amount out of range");
    let commitment = commit(asset, amount, owner, salt);
    let implied_root = lean_imt_root(commitment, proof);
    let is_zero_note = (amount == 0) as Field;
    assert((implied_root - root) * (1 - is_zero_note) == 0, "note is not in the tree");
    nullify(commitment, spending_key)
}

/// Keeps a public input that carries no constraint of its own inside the
/// proof, so a proof cannot be replayed against a different pool, recipient or
/// listing. The hash cannot be optimised away because its output is asserted.
pub fn bind(a: Field, b: Field) {
    assert(hash_2([a, b]) != 0);
}

/// The one hash the whole system agrees on, re-exported so the circuits do not
/// each need their own dependency on the Poseidon library.
pub fn hash2(a: Field, b: Field) -> Field {
    hash_2([a, b])
}

/// The public stand-in for a price: binding, and hiding as long as the
/// blinding factor stays secret.
pub fn commit_price(price: u128, blinding: Field) -> Field {
    hash_2([price as Field, blinding])
}

mod tests {
    use super::{
        commit, commit_price, lean_imt_root, MerkleProof, MAX_DEPTH, nullify, owner_pk,
    };
    use poseidon::poseidon::bn254::{hash_2, hash_4};

    global WETH: Field = 0x0bd7d308F8e1639FAb988df18a8011f41eaCad73;

    #[test]
    fn commitment_is_poseidon4_of_the_note() {
        let expected = hash_4([WETH, 1000, 42, 7]);
        assert(commit(WETH, 1000, 42, 7) == expected);
    }

    #[test]
    fn nullifier_is_poseidon2_of_commitment_and_key() {
        let commitment = commit(WETH, 1000, 42, 7);
        assert(nullify(commitment, 99) == hash_2([commitment, 99]));
    }

    #[test]
    fn owner_key_is_poseidon2_of_the_spending_key_and_zero() {
        assert(owner_pk(5) == hash_2([5, 0]));
    }

    #[test]
    fn price_commitment_is_poseidon2_of_price_and_blinding() {
        assert(commit_price(400, 12345) == hash_2([400, 12345]));
    }

    #[test]
    fn a_depth_zero_path_is_the_leaf_itself() {
        let proof = MerkleProof { siblings: [0; MAX_DEPTH], index: 0, depth: 0 };
        assert(lean_imt_root(77, proof) == 77);
    }

    #[test]
    fn a_left_leaf_hashes_with_its_right_sibling() {
        let mut siblings = [0; MAX_DEPTH];
        siblings[0] = 22;
        let proof = MerkleProof { siblings, index: 0, depth: 1 };
        assert(lean_imt_root(11, proof) == hash_2([11, 22]));
    }

    #[test]
    fn a_right_leaf_hashes_the_other_way_round() {
        let mut siblings = [0; MAX_DEPTH];
        siblings[0] = 11;
        let proof = MerkleProof { siblings, index: 1, depth: 1 };
        assert(lean_imt_root(22, proof) == hash_2([11, 22]));
    }

    #[test]
    fn two_levels_walk_in_order() {
        let level_one = hash_2([11, 22]);
        let mut siblings = [0; MAX_DEPTH];
        siblings[0] = 22;
        siblings[1] = 33;
        let proof = MerkleProof { siblings, index: 0, depth: 2 };
        assert(lean_imt_root(11, proof) == hash_2([level_one, 33]));
    }

    #[test]
    fn siblings_above_the_depth_are_ignored() {
        let mut siblings = [0; MAX_DEPTH];
        siblings[0] = 22;
        siblings[1] = 999;
        let shallow = MerkleProof { siblings, index: 0, depth: 1 };
        assert(lean_imt_root(11, shallow) == hash_2([11, 22]));
    }
}
