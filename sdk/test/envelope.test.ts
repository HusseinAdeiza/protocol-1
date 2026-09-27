import {describe, expect, it} from "vitest";

import {
  bytesToHex,
  hexToBytes,
  keysFromSeed,
  noteCommitment,
  offerBlinding,
  openNote,
  openOffer,
  openOwnOffer,
  priceCommitment,
  randomFieldElement,
  sealNote,
  sealOfferFrom,
  toHex32,
  verifyNote,
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

  it("returns null for a low-order ephemeral key instead of throwing", () => {
    const payload = hexToBytes(sealNote(alice.viewingPk, {asset: WETH, amount: 5n, salt: 6n}));
    payload.fill(0, 1, 33);
    expect(openNote(alice.viewingSk, bytesToHex(payload))).toBeNull();
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

describe("checking a note against its leaf", () => {
  const note = {asset: WETH, amount: 1_000n, ownerPk: alice.ownerPk, salt: 77n};
  const leaf = noteCommitment(note);

  it("accepts the note the leaf commits to", () => {
    expect(verifyNote(note, leaf, WETH)).toBe(true);
    expect(verifyNote(note, toHex32(leaf), WETH.toLowerCase() as Hex)).toBe(true);
  });

  it("drops a payload that lies about the amount or the salt", () => {
    expect(verifyNote({...note, amount: 2_000n}, leaf, WETH)).toBe(false);
    expect(verifyNote({...note, salt: 78n}, leaf, WETH)).toBe(false);
  });

  it("drops a note in another asset", () => {
    expect(verifyNote(note, leaf, "0x0000000000000000000000000000000000000001")).toBe(false);
  });
});

describe("offer payloads", () => {
  const listingId = 0x5eedn;
  const price = 250_000_000_000_000_000n;

  it("gives the seller an opening of the on-chain commitment", () => {
    const sealed = sealOfferFrom(bob.spendingKey, listingId, alice.viewingPk, price);
    expect(sealed.priceCommitment).toBe(priceCommitment(price, sealed.blinding));
    expect(openOffer(alice.viewingSk, sealed.payload, sealed.priceCommitment)).toEqual({
      price,
      blinding: sealed.blinding,
    });
    expect(openOffer(alice.viewingSk, sealed.payload, toHex32(sealed.priceCommitment))?.price).toBe(price);
  });

  it("lets the buyer reopen their own offer without stored state or a search", () => {
    const sealed = sealOfferFrom(bob.spendingKey, listingId, alice.viewingPk, price);
    expect(openOwnOffer(bob.spendingKey, listingId, alice.viewingPk, sealed.payload, sealed.priceCommitment)).toEqual({
      price,
      blinding: sealed.blinding,
    });
  });

  it("rejects an opening that does not match the commitment on chain", () => {
    const sealed = sealOfferFrom(bob.spendingKey, listingId, alice.viewingPk, price);
    const other = priceCommitment(price + 1n, sealed.blinding);
    expect(openOffer(alice.viewingSk, sealed.payload, other)).toBeNull();
    expect(openOwnOffer(bob.spendingKey, listingId, alice.viewingPk, sealed.payload, other)).toBeNull();
  });

  it("uses a fresh nonce per offer, so two offers never share a key or a blinding", () => {
    const first = sealOfferFrom(bob.spendingKey, listingId, alice.viewingPk, price);
    const second = sealOfferFrom(bob.spendingKey, listingId, alice.viewingPk, price);
    expect(second.blinding).not.toBe(first.blinding);
    expect(second.payload.slice(4, 68)).not.toBe(first.payload.slice(4, 68));
    expect(openOwnOffer(bob.spendingKey, listingId, alice.viewingPk, second.payload, second.priceCommitment)?.blinding).toBe(
      second.blinding,
    );
  });

  it("derives the blinding from the nonce in the payload", () => {
    const r = new Uint8Array(16).fill(9);
    const sealed = sealOfferFrom(bob.spendingKey, listingId, alice.viewingPk, price, r);
    expect(sealed.blinding).toBe(offerBlinding(bob.spendingKey, listingId, r));
    expect(offerBlinding(bob.spendingKey, listingId + 1n, r)).not.toBe(sealed.blinding);
    expect(sealed.blinding).toBeLessThan(FR);
  });

  it("rejects an edited nonce", () => {
    const sealed = sealOfferFrom(bob.spendingKey, listingId, alice.viewingPk, price);
    const bytes = hexToBytes(sealed.payload);
    bytes[40] = bytes[40]! ^ 1;
    expect(openOffer(alice.viewingSk, bytesToHex(bytes), sealed.priceCommitment)).toBeNull();
  });

  it("does not open for another buyer or a third party", () => {
    const sealed = sealOfferFrom(bob.spendingKey, listingId, alice.viewingPk, price);
    expect(openOffer(bob.viewingSk, sealed.payload, sealed.priceCommitment)).toBeNull();
    expect(openOwnOffer(alice.spendingKey, listingId, alice.viewingPk, sealed.payload, sealed.priceCommitment)).toBeNull();
  });

  it("returns null for low-order keys instead of throwing", () => {
    const sealed = sealOfferFrom(bob.spendingKey, listingId, alice.viewingPk, price);
    const bytes = hexToBytes(sealed.payload);
    bytes.fill(0, 1, 33);
    expect(openOffer(alice.viewingSk, bytesToHex(bytes), sealed.priceCommitment)).toBeNull();

    const lowOrder = new Uint8Array(32);
    lowOrder[0] = 1;
    expect(openOwnOffer(bob.spendingKey, listingId, lowOrder, sealed.payload, sealed.priceCommitment)).toBeNull();
  });
});

describe("salts and blindings", () => {
  it("stay inside the field", () => {
    for (let i = 0; i < 16; i++) expect(randomFieldElement()).toBeLessThan(FR);
  });
});
