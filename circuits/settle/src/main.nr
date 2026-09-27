//! Settle: the buyer spends two notes and creates three — the seller's share,
//! the creator's royalty and their own change — proving they add up to the
//! price the seller accepted and that the royalty is exactly the collection's
//! basis points of it, rounded up.
//!
//! The price itself never appears on chain. Only its commitment does.
//!
//! `binding` is filled by the market with a hash of the offer id and the note
//! payloads, so a proof settles one offer with one set of payloads. The
//! seller's salt is derived from the price blinding rather than chosen by the
//! buyer, so the seller can rebuild their note from the offer alone.

use backlit::{
    bind, BPS_DENOM, commit, commit_price, MerkleProof, MAX_AMOUNT, MAX_DEPTH, owner_pk,
    seller_salt, spend_note,
};

fn main(
    pool_id: pub Field,
    asset: pub Field,
    root: pub Field,
    nullifiers: pub [Field; 2],
    seller_commitment: pub Field,
    creator_commitment: pub Field,
    change_commitment: pub Field,
    price_commitment: pub Field,
    royalty_bps: pub u32,
    seller_pk: pub Field,
    creator_pk: pub Field,
    buyer_pk: pub Field,
    binding: pub Field,
    spending_key: Field,
    in_amounts: [u128; 2],
    in_salts: [Field; 2],
    in_siblings: [[Field; MAX_DEPTH]; 2],
    in_indices: [Field; 2],
    in_depths: [u32; 2],
    price: u128,
    price_blinding: Field,
    royalty_amount: u128,
    creator_salt: Field,
    change_salt: Field,
) {
    bind(pool_id, binding);

    assert(buyer_pk == owner_pk(spending_key), "not the buyer's key");

    let mut total_in: u128 = 0;
    for i in 0..2 {
        let proof =
            MerkleProof { siblings: in_siblings[i], index: in_indices[i], depth: in_depths[i] };
        let nullifier =
            spend_note(asset, in_amounts[i], in_salts[i], buyer_pk, spending_key, proof, root);
        assert(nullifier == nullifiers[i], "wrong nullifier");
        total_in += in_amounts[i];
    }
    assert(nullifiers[0] != nullifiers[1], "the same note twice");

    assert(price < MAX_AMOUNT, "price out of range");
    assert(royalty_amount < MAX_AMOUNT, "royalty out of range");
    assert(
        price_commitment == commit_price(price, price_blinding),
        "price does not open the commitment",
    );

    let bps = royalty_bps as u128;
    assert(bps <= BPS_DENOM, "basis points above 100%");

    // royalty_amount == ceil(price * bps / 10000), in both directions.
    let numerator = price * bps;
    assert(royalty_amount * BPS_DENOM >= numerator, "royalty underpaid");
    assert(royalty_amount * BPS_DENOM < numerator + BPS_DENOM, "royalty overpaid");

    // Both subtractions are checked: the seller's share cannot go negative,
    // and the buyer cannot spend less than the price.
    let seller_amount = price - royalty_amount;
    let change_amount = total_in - price;
    assert(change_amount < MAX_AMOUNT, "change out of range");

    assert(
        seller_commitment == commit(asset, seller_amount, seller_pk, seller_salt(price_blinding)),
        "wrong seller note",
    );
    assert(
        creator_commitment == commit(asset, royalty_amount, creator_pk, creator_salt),
        "wrong creator note",
    );
    assert(
        change_commitment == commit(asset, change_amount, buyer_pk, change_salt),
        "wrong change note",
    );
}

mod tests {
    use super::main;
    use backlit::{commit, commit_price, hash2, MAX_DEPTH, nullify, owner_pk, seller_salt};

    global WETH: Field = 0x0bd7d308F8e1639FAb988df18a8011f41eaCad73;
    global POOL: Field = 0x1337;
    global BINDING: Field = 0x5eed;
    global KEY: Field = 424242;
    global SELLER_PK: Field = 0xabc;
    global CREATOR_PK: Field = 0xdef;

    global IN_A: u128 = 700;
    global IN_B: u128 = 300;
    global BLINDING: Field = 987654;

    /// Everything a settlement needs, wired to a real two-leaf tree.
    struct Scene {
        root: Field,
        buyer_pk: Field,
        nullifiers: [Field; 2],
        siblings: [[Field; MAX_DEPTH]; 2],
    }

    fn scene() -> Scene {
        let buyer_pk = owner_pk(KEY);
        let left = commit(WETH, IN_A, buyer_pk, 11);
        let right = commit(WETH, IN_B, buyer_pk, 22);

        let mut siblings: [[Field; MAX_DEPTH]; 2] = [[0; MAX_DEPTH]; 2];
        siblings[0][0] = right;
        siblings[1][0] = left;

        Scene {
            root: hash2(left, right),
            buyer_pk,
            nullifiers: [nullify(left, KEY), nullify(right, KEY)],
            siblings,
        }
    }

    /// Runs a settlement with every knob exposed, so each tamper case changes
    /// exactly one thing.
    fn settle(
        price: u128,
        royalty_bps: u32,
        royalty_amount: u128,
        seller_amount: u128,
        change_amount: u128,
        price_commitment: Field,
        binding: Field,
        seller_pk: Field,
        creator_pk: Field,
    ) {
        let s = scene();
        main(
            POOL,
            WETH,
            s.root,
            s.nullifiers,
            commit(WETH, seller_amount, seller_pk, seller_salt(BLINDING)),
            commit(WETH, royalty_amount, creator_pk, 52),
            commit(WETH, change_amount, s.buyer_pk, 53),
            price_commitment,
            royalty_bps,
            seller_pk,
            creator_pk,
            s.buyer_pk,
            binding,
            KEY,
            [IN_A, IN_B],
            [11, 22],
            s.siblings,
            [0, 1],
            [1, 1],
            price,
            BLINDING,
            royalty_amount,
            52,
            53,
        );
    }

    /// Price 800 at 5% is a royalty of 40, leaving 760 to the seller and 200
    /// in change.
    fn honest() {
        settle(800, 500, 40, 760, 200, commit_price(800, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test]
    fn an_honest_settlement_passes() {
        honest();
    }

    #[test]
    fn a_collection_with_no_royalty_pays_the_whole_price_to_the_seller() {
        settle(800, 0, 0, 800, 200, commit_price(800, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test]
    fn a_full_royalty_pays_the_whole_price_to_the_creator() {
        settle(800, 10000, 800, 0, 200, commit_price(800, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test]
    fn a_royalty_that_does_not_divide_evenly_rounds_up() {
        // 999 at 2.5% is 24.975, so the creator gets 25.
        settle(999, 250, 25, 974, 1, commit_price(999, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test(should_fail_with = "royalty underpaid")]
    fn a_royalty_one_wei_short_fails() {
        settle(999, 250, 24, 975, 1, commit_price(999, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test(should_fail_with = "royalty overpaid")]
    fn a_royalty_one_wei_over_fails() {
        settle(999, 250, 26, 973, 1, commit_price(999, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test(should_fail_with = "royalty underpaid")]
    fn skipping_the_royalty_entirely_fails() {
        settle(800, 500, 0, 800, 200, commit_price(800, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test(should_fail_with = "royalty overpaid")]
    fn quoting_a_lower_rate_than_the_notes_pay_fails() {
        // The notes carry a 5% royalty while the chain says 2.5%.
        settle(800, 250, 40, 760, 200, commit_price(800, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test(should_fail_with = "price does not open the commitment")]
    fn a_price_that_does_not_open_the_commitment_fails() {
        settle(800, 500, 40, 760, 200, commit_price(700, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test(should_fail_with = "wrong seller note")]
    fn shorting_the_seller_fails() {
        settle(800, 500, 40, 700, 200, commit_price(800, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test(should_fail_with = "wrong change note")]
    fn taking_more_change_than_is_left_fails() {
        settle(800, 500, 40, 760, 300, commit_price(800, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test(should_fail_with = "attempt to subtract with overflow")]
    fn spending_more_than_the_notes_hold_fails() {
        settle(1500, 500, 75, 1425, 0, commit_price(1500, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    #[test(should_fail_with = "basis points above 100%")]
    fn a_rate_above_one_hundred_percent_fails() {
        settle(800, 10001, 801, 0, 200, commit_price(800, BLINDING), BINDING, SELLER_PK, CREATOR_PK);
    }

    /// The seller and the creator are named in the proof, so a settlement
    /// cannot be redirected by swapping who gets paid.
    #[test(should_fail_with = "wrong seller note")]
    fn paying_the_seller_into_somebody_elses_key_fails() {
        let s = scene();
        main(
            POOL,
            WETH,
            s.root,
            s.nullifiers,
            commit(WETH, 760, 0x999, seller_salt(BLINDING)),
            commit(WETH, 40, CREATOR_PK, 52),
            commit(WETH, 200, s.buyer_pk, 53),
            commit_price(800, BLINDING),
            500,
            SELLER_PK,
            CREATOR_PK,
            s.buyer_pk,
            BINDING,
            KEY,
            [IN_A, IN_B],
            [11, 22],
            s.siblings,
            [0, 1],
            [1, 1],
            800,
            BLINDING,
            40,
            52,
            53,
        );
    }

    /// The seller's salt is not the buyer's to choose: a seller note under any
    /// other salt is one the seller could not rebuild from the offer.
    #[test(should_fail_with = "wrong seller note")]
    fn a_seller_note_under_a_salt_the_buyer_picked_fails() {
        let s = scene();
        main(
            POOL,
            WETH,
            s.root,
            s.nullifiers,
            commit(WETH, 760, SELLER_PK, 51),
            commit(WETH, 40, CREATOR_PK, 52),
            commit(WETH, 200, s.buyer_pk, 53),
            commit_price(800, BLINDING),
            500,
            SELLER_PK,
            CREATOR_PK,
            s.buyer_pk,
            BINDING,
            KEY,
            [IN_A, IN_B],
            [11, 22],
            s.siblings,
            [0, 1],
            [1, 1],
            800,
            BLINDING,
            40,
            52,
            53,
        );
    }

    /// The seller rebuilds their note from the offer opening alone: amount
    /// from the price and the rate, salt from the blinding.
    #[test]
    fn the_seller_note_is_rebuildable_from_the_offer_opening() {
        let rebuilt = commit(WETH, 800 - 40, SELLER_PK, seller_salt(BLINDING));
        let s = scene();
        main(
            POOL,
            WETH,
            s.root,
            s.nullifiers,
            rebuilt,
            commit(WETH, 40, CREATOR_PK, 52),
            commit(WETH, 200, s.buyer_pk, 53),
            commit_price(800, BLINDING),
            500,
            SELLER_PK,
            CREATOR_PK,
            s.buyer_pk,
            BINDING,
            KEY,
            [IN_A, IN_B],
            [11, 22],
            s.siblings,
            [0, 1],
            [1, 1],
            800,
            BLINDING,
            40,
            52,
            53,
        );
    }

    #[test(should_fail_with = "not the buyer's key")]
    fn proving_with_somebody_elses_spending_key_fails() {
        let s = scene();
        main(
            POOL,
            WETH,
            s.root,
            s.nullifiers,
            commit(WETH, 760, SELLER_PK, seller_salt(BLINDING)),
            commit(WETH, 40, CREATOR_PK, 52),
            commit(WETH, 200, s.buyer_pk, 53),
            commit_price(800, BLINDING),
            500,
            SELLER_PK,
            CREATOR_PK,
            owner_pk(KEY + 1),
            BINDING,
            KEY,
            [IN_A, IN_B],
            [11, 22],
            s.siblings,
            [0, 1],
            [1, 1],
            800,
            BLINDING,
            40,
            52,
            53,
        );
    }

    #[test(should_fail_with = "note is not in the tree")]
    fn a_wrong_root_fails() {
        let s = scene();
        main(
            POOL,
            WETH,
            s.root + 1,
            s.nullifiers,
            commit(WETH, 760, SELLER_PK, seller_salt(BLINDING)),
            commit(WETH, 40, CREATOR_PK, 52),
            commit(WETH, 200, s.buyer_pk, 53),
            commit_price(800, BLINDING),
            500,
            SELLER_PK,
            CREATOR_PK,
            s.buyer_pk,
            BINDING,
            KEY,
            [IN_A, IN_B],
            [11, 22],
            s.siblings,
            [0, 1],
            [1, 1],
            800,
            BLINDING,
            40,
            52,
            53,
        );
    }
}
