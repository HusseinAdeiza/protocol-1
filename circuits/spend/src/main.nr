//! Spend: two input notes in, two output notes out, with an optional public
//! withdrawal. Consolidating dust, sending value inside the pool and cashing
//! out to WETH are all the same proof.
//!
//! `recipient` is only bound, never used in a constraint. The pool fills it
//! with a hash of the withdrawal recipient, the unwrap flag and the output
//! payloads, which ties a proof to exactly one way of paying out.

use backlit::{bind, commit, MerkleProof, MAX_AMOUNT, MAX_DEPTH, owner_pk, spend_note};

fn main(
    pool_id: pub Field,
    asset: pub Field,
    root: pub Field,
    nullifiers: pub [Field; 2],
    out_commitments: pub [Field; 2],
    withdraw_amount: pub u128,
    recipient: pub Field,
    spending_key: Field,
    in_amounts: [u128; 2],
    in_salts: [Field; 2],
    in_siblings: [[Field; MAX_DEPTH]; 2],
    in_indices: [Field; 2],
    in_depths: [u32; 2],
    out_amounts: [u128; 2],
    out_owners: [Field; 2],
    out_salts: [Field; 2],
) {
    bind(pool_id, recipient);

    let owner = owner_pk(spending_key);

    let mut total_in: u128 = 0;
    for i in 0..2 {
        let proof =
            MerkleProof { siblings: in_siblings[i], index: in_indices[i], depth: in_depths[i] };
        let nullifier =
            spend_note(asset, in_amounts[i], in_salts[i], owner, spending_key, proof, root);
        assert(nullifier == nullifiers[i], "wrong nullifier");
        total_in += in_amounts[i];
    }
    assert(nullifiers[0] != nullifiers[1], "the same note twice");

    assert(withdraw_amount < MAX_AMOUNT, "withdrawal out of range");
    let mut total_out: u128 = withdraw_amount;
    for j in 0..2 {
        assert(out_amounts[j] < MAX_AMOUNT, "output amount out of range");
        assert(
            out_commitments[j] == commit(asset, out_amounts[j], out_owners[j], out_salts[j]),
            "wrong output commitment",
        );
        total_out += out_amounts[j];
    }

    assert(total_in == total_out, "value is not conserved");
}

mod tests {
    use super::main;
    use backlit::{commit, hash2, MAX_DEPTH, nullify, owner_pk};

    global WETH: Field = 0x0bd7d308F8e1639FAb988df18a8011f41eaCad73;
    global POOL: Field = 0x1337;
    global KEY: Field = 424242;

    /// A two-leaf tree holding both of the spender's notes, which gives real
    /// membership paths without any tree machinery in the test.
    struct Fixture {
        root: Field,
        owner: Field,
        nullifiers: [Field; 2],
        siblings: [[Field; MAX_DEPTH]; 2],
        indices: [Field; 2],
        depths: [u32; 2],
    }

    fn fixture(amounts: [u128; 2], salts: [Field; 2]) -> Fixture {
        let owner = owner_pk(KEY);
        let left = commit(WETH, amounts[0], owner, salts[0]);
        let right = commit(WETH, amounts[1], owner, salts[1]);
        let root = hash2(left, right);

        let mut siblings: [[Field; MAX_DEPTH]; 2] = [[0; MAX_DEPTH]; 2];
        siblings[0][0] = right;
        siblings[1][0] = left;

        Fixture {
            root,
            owner,
            nullifiers: [nullify(left, KEY), nullify(right, KEY)],
            siblings,
            indices: [0, 1],
            depths: [1, 1],
        }
    }

    fn run(
        withdraw_amount: u128,
        out_amounts: [u128; 2],
        out_commitments: [Field; 2],
        nullifiers: [Field; 2],
        root: Field,
        recipient: Field,
    ) {
        let in_amounts: [u128; 2] = [700, 300];
        let in_salts: [Field; 2] = [11, 22];
        let f = fixture(in_amounts, in_salts);

        main(
            POOL,
            WETH,
            root,
            nullifiers,
            out_commitments,
            withdraw_amount,
            recipient,
            KEY,
            in_amounts,
            in_salts,
            f.siblings,
            f.indices,
            f.depths,
            out_amounts,
            [f.owner, f.owner],
            [33, 44],
        );
    }

    fn honest_outputs(out_amounts: [u128; 2]) -> [Field; 2] {
        let owner = owner_pk(KEY);
        [commit(WETH, out_amounts[0], owner, 33), commit(WETH, out_amounts[1], owner, 44)]
    }

    #[test]
    fn an_honest_spend_passes() {
        let f = fixture([700, 300], [11, 22]);
        let outs: [u128; 2] = [600, 200];
        run(200, outs, honest_outputs(outs), f.nullifiers, f.root, 0xdead);
    }

    #[test]
    fn a_spend_with_no_withdrawal_passes() {
        let f = fixture([700, 300], [11, 22]);
        let outs: [u128; 2] = [1000, 0];
        run(0, outs, honest_outputs(outs), f.nullifiers, f.root, 0);
    }

    #[test(should_fail_with = "note is not in the tree")]
    fn a_wrong_root_fails() {
        let f = fixture([700, 300], [11, 22]);
        let outs: [u128; 2] = [600, 200];
        run(200, outs, honest_outputs(outs), f.nullifiers, f.root + 1, 0xdead);
    }

    #[test(should_fail_with = "wrong nullifier")]
    fn a_wrong_nullifier_fails() {
        let f = fixture([700, 300], [11, 22]);
        let outs: [u128; 2] = [600, 200];
        run(200, outs, honest_outputs(outs), [f.nullifiers[0] + 1, f.nullifiers[1]], f.root, 0xdead);
    }

    /// Feeding the same note in twice is the cheapest way to try to double
    /// an amount, so it gets its own fixture rather than a reused one.
    #[test(should_fail_with = "the same note twice")]
    fn spending_one_note_twice_fails() {
        let owner = owner_pk(KEY);
        let amount: u128 = 500;
        let leaf = commit(WETH, amount, owner, 11);
        let root = hash2(leaf, leaf);

        let mut siblings: [[Field; MAX_DEPTH]; 2] = [[0; MAX_DEPTH]; 2];
        siblings[0][0] = leaf;
        siblings[1][0] = leaf;

        let nullifier = nullify(leaf, KEY);
        let outs: [u128; 2] = [1000, 0];

        main(
            POOL,
            WETH,
            root,
            [nullifier, nullifier],
            [commit(WETH, outs[0], owner, 33), commit(WETH, outs[1], owner, 44)],
            0,
            0xdead,
            KEY,
            [amount, amount],
            [11, 11],
            siblings,
            [0, 1],
            [1, 1],
            outs,
            [owner, owner],
            [33, 44],
        );
    }

    #[test(should_fail_with = "value is not conserved")]
    fn minting_value_fails() {
        let f = fixture([700, 300], [11, 22]);
        let outs: [u128; 2] = [900, 200];
        run(200, outs, honest_outputs(outs), f.nullifiers, f.root, 0xdead);
    }

    #[test(should_fail_with = "value is not conserved")]
    fn withdrawing_more_than_the_notes_hold_fails() {
        let f = fixture([700, 300], [11, 22]);
        let outs: [u128; 2] = [600, 200];
        run(500, outs, honest_outputs(outs), f.nullifiers, f.root, 0xdead);
    }

    #[test(should_fail_with = "wrong output commitment")]
    fn an_output_commitment_that_does_not_match_its_note_fails() {
        let f = fixture([700, 300], [11, 22]);
        let outs: [u128; 2] = [600, 200];
        let mut commitments = honest_outputs(outs);
        commitments[1] = commitments[1] + 1;
        run(200, outs, commitments, f.nullifiers, f.root, 0xdead);
    }

    #[test(should_fail_with = "output amount out of range")]
    fn an_output_at_the_amount_ceiling_fails() {
        let f = fixture([700, 300], [11, 22]);
        let owner = owner_pk(KEY);
        let huge: u128 = 79228162514264337593543950336; // 2^96
        let outs: [u128; 2] = [huge, 0];
        let commitments = [commit(WETH, huge, owner, 33), commit(WETH, 0, owner, 44)];
        run(0, outs, commitments, f.nullifiers, f.root, 0xdead);
    }
}
