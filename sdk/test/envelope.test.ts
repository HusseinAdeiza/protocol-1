import {describe, expect, it} from "vitest";

import {
  keysFromSeed,
  offerBlinding,
  openNote,
  openOffer,
  openOwnOffer,
  randomFieldElement,
  sealNote,
  sealOffer,
  sealOfferFrom,
  FR,
  type Hex,
} from "../src/index.js";

const WETH: Hex = "0x0bd7d308F8e1639FAb988df18a8011f41eaCad73";
const alice = keysFromSeed(new Uint8Array(32).fill(1));
const bob = keysFromSeed(new Uint8Array(32).fill(2));

describe("note payloads", () => {
  it("round trips for the recipient", () => {
    const note = {asset: WETH, amount: 123_456_789n, salt: randomFieldElement()};
    const opened = openNote(alice.viewingSk, sealNote(alice.viewingPk, note));

    expect(opened).not.toBeNull();
    expect(opened!.amount).toBe(note.amount);
    expect(opened!.salt).toBe(note.salt);
    expect(opened!.asset.toLowerCase()).toBe(WETH.toLowerCase());
  });

  it("stays closed to anybody else", () => {
    const payload = sealNote(alice.viewingPk, {asset: WETH, amount: 1n, salt: 2n});
    expect(openNote(bob.viewingSk, payload)).toBeNull();
  });

  it("carries a zero amount and the largest amount a note can hold", () => {
    for (const amount of [0n, (1n << 96n) - 1n]) {
      const opened = openNote(alice.viewingSk, sealNote(alice.viewingPk, {asset: WETH, amount, salt: 7n}));
      expect(opened!.amount).toBe(amount);
    }
  });

  it("rejects a payload that has been altered", () => {
    const payload = sealNote(alice.viewingPk, {asset: WETH, amount: 5n, salt: 6n});
    const tampered = `${payload.slice(0, -2)}${payload.slice(-2) === "00" ? "01" : "00"}` as Hex;
    expect(openNote(alice.viewingSk, tampered)).toBeNull();
  });

  it("skips foreign payloads cheaply", () => {
    // The view tag is four bytes, so roughly one in 4.3 billion foreign
    // payloads costs a full decryption attempt. None of these should even
    // reach that point, and none of them should open.
    let opened = 0;
    for (let i = 0; i < 200; i++) {
      const payload = sealNote(bob.viewingPk, {asset: WETH, amount: BigInt(i), salt: BigInt(i)});
      if (openNote(alice.viewingSk, payload)) opened++;
    }
    expect(opened).toBe(0);
  });
});

describe("offer payloads", () => {
  it("round trips to the seller", () => {
    const offer = {price: 400_000_000_000_000_000n, blinding: randomFieldElement()};
    const opened = openOffer(alice.viewingSk, sealOffer(alice.viewingPk, offer));
    expect(opened).toEqual(offer);
  });

  it("lets the buyer reopen their own offer without stored state", () => {
    const listingId = 0x5eedn;
    const blinding = offerBlinding(bob.spendingKey, listingId, 0);
    const price = 250_000_000_000_000_000n;
    const payload = sealOfferFrom(bob.spendingKey, listingId, 0, alice.viewingPk, {price, blinding});

    expect(openOffer(alice.viewingSk, payload)).toEqual({price, blinding});

    const reopened = openOwnOffer(bob.spendingKey, listingId, alice.viewingPk, payload);
    expect(reopened?.offer.price).toBe(price);
    expect(reopened?.offer.blinding).toBe(blinding);
    expect(reopened?.nonce).toBe(0);
  });

  it("finds the right nonce when a buyer has bid before", () => {
    const listingId = 0x5eedn;
    const blinding = offerBlinding(bob.spendingKey, listingId, 3);
    const payload = sealOfferFrom(bob.spendingKey, listingId, 3, alice.viewingPk, {price: 9n, blinding});
    expect(openOwnOffer(bob.spendingKey, listingId, alice.viewingPk, payload)?.nonce).toBe(3);
  });

  it("gives a different blinding per listing", () => {
    expect(offerBlinding(bob.spendingKey, 1n, 0)).not.toBe(offerBlinding(bob.spendingKey, 2n, 0));
    expect(offerBlinding(bob.spendingKey, 1n, 0)).toBeLessThan(FR);
  });

  it("stays closed to a third party", () => {
    const payload = sealOffer(alice.viewingPk, {price: 1n, blinding: 2n});
    expect(openOffer(bob.viewingSk, payload)).toBeNull();
  });
});
