import {chacha20poly1305} from "@noble/ciphers/chacha.js";
import {x25519} from "@noble/curves/ed25519.js";
import {hkdf} from "@noble/hashes/hkdf.js";
import {sha256} from "@noble/hashes/sha2.js";
import {utf8ToBytes} from "@noble/hashes/utils.js";

import {bigIntToBytes, bytesToBigInt, bytesToHex, FR, hexToBytes, MAX_NOTE_AMOUNT, type Hex} from "./field.js";
import {poseidon2} from "./poseidon.js";

/**
 * Every note and every offer travels with a payload only its recipient can
 * read. The envelope is a one-shot x25519 exchange: an ephemeral key per
 * payload, HKDF to a ChaCha20-Poly1305 key, and a four-byte view tag so a
 * wallet can skip payloads that are not its own without doing the work.
 *
 *   payload = version(1) ‖ ephemeralPk(32) ‖ viewTag(4) ‖ ciphertext
 *
 * Offers add the buyer's 16-byte offer nonce in the clear, authenticated as
 * associated data (see `sealOfferFrom`):
 *
 *   offer   = version(1) ‖ ephemeralPk(32) ‖ viewTag(4) ‖ r(16) ‖ ciphertext
 */
export const ENVELOPE_VERSION = 1;

const NOTE_INFO = "backlit/note/v1";
const OFFER_INFO = "backlit/offer/v2";

export interface NotePlaintext {
  asset: Hex;
  amount: bigint;
  salt: bigint;
}

export interface OfferPlaintext {
  price: bigint;
  blinding: bigint;
}

interface Derived {
  key: Uint8Array;
  viewTag: Uint8Array;
  nonce: Uint8Array;
}

function derive(shared: Uint8Array, info: string): Derived {
  const okm = hkdf(sha256, shared, undefined, utf8ToBytes(info), 44);
  return {key: okm.slice(0, 32), viewTag: okm.slice(32, 36), nonce: okm.slice(36, 44)};
}

/** ChaCha20-Poly1305 takes a 12-byte nonce; the last four bytes are fixed at zero. */
function nonce12(nonce8: Uint8Array): Uint8Array {
  const out = new Uint8Array(12);
  out.set(nonce8, 0);
  return out;
}

function seal(recipientViewingPk: Uint8Array, info: string, plaintext: Uint8Array): Uint8Array {
  const ephemeralSk = x25519.utils.randomSecretKey();
  const ephemeralPk = x25519.getPublicKey(ephemeralSk);
  const {key, viewTag, nonce} = derive(x25519.getSharedSecret(ephemeralSk, recipientViewingPk), info);
  const ciphertext = chacha20poly1305(key, nonce12(nonce)).encrypt(plaintext);

  const out = new Uint8Array(1 + 32 + 4 + ciphertext.length);
  out[0] = ENVELOPE_VERSION;
  out.set(ephemeralPk, 1);
  out.set(viewTag, 33);
  out.set(ciphertext, 37);
  return out;
}

/**
 * Anything that goes wrong opening a payload is somebody else's payload or a
 * hostile one, never an error: a low-order ephemeral key makes x25519 throw,
 * and one such payload in the log must not stop a wallet's scan.
 */
function sharedSecret(secretKey: Uint8Array, publicKey: Uint8Array): Uint8Array | null {
  try {
    return x25519.getSharedSecret(secretKey, publicKey);
  } catch {
    return null;
  }
}

function tagMatches(payload: Uint8Array, viewTag: Uint8Array): boolean {
  for (let i = 0; i < 4; i++) if (payload[33 + i] !== viewTag[i]) return false;
  return true;
}

function open(viewingSk: Uint8Array, info: string, payload: Uint8Array): Uint8Array | null {
  if (payload.length < 38 || payload[0] !== ENVELOPE_VERSION) return null;
  const shared = sharedSecret(viewingSk, payload.slice(1, 33));
  if (!shared) return null;
  const {key, viewTag, nonce} = derive(shared, info);
  if (!tagMatches(payload, viewTag)) return null;
  try {
    return chacha20poly1305(key, nonce12(nonce)).decrypt(payload.slice(37));
  } catch {
    return null;
  }
}

// ------------------------------------------------------------------- notes

/** version(1) ‖ asset(20) ‖ amount(12, big-endian) ‖ salt(32) */
export function sealNote(recipientViewingPk: Uint8Array, note: NotePlaintext): Hex {
  const body = new Uint8Array(65);
  body[0] = ENVELOPE_VERSION;
  body.set(hexToBytes(note.asset), 1);
  body.set(bigIntToBytes(note.amount, 12), 21);
  body.set(bigIntToBytes(note.salt, 32), 33);
  return bytesToHex(seal(recipientViewingPk, NOTE_INFO, body));
}

/**
 * Decrypts a note payload. The payload is not covered by any proof, so check
 * the result against the leaf with `verifyNote` before trusting it.
 */
export function openNote(viewingSk: Uint8Array, payload: Hex): NotePlaintext | null {
  const body = open(viewingSk, NOTE_INFO, hexToBytes(payload));
  if (!body || body.length !== 65 || body[0] !== ENVELOPE_VERSION) return null;
  return {
    asset: bytesToHex(body.slice(1, 21)),
    amount: bytesToBigInt(body.slice(21, 33)),
    salt: bytesToBigInt(body.slice(33, 65)),
  };
}

// ------------------------------------------------------------------ offers

/** A fresh 32-byte value reduced into the field, for salts and blinding factors. */
export function randomFieldElement(): bigint {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  // Clearing the top byte keeps the value well inside the field with no bias
  // worth arguing about.
  bytes[0] = 0;
  return bytesToBigInt(bytes);
}

/**
 * An offer's opening is encrypted to the seller, and the buyer needs it back
 * at settlement. Rather than store it, the buyer derives the ephemeral key and
 * the blinding from their spending key, the listing and a random 16-byte `r`
 * carried in the clear, so the payload in the event log is readable by both
 * sides and by nobody else. `r` is random rather than a counter, so two offers
 * never share a key and reopening needs no search.
 */
export const OFFER_NONCE_BYTES = 16;
const OFFER_HEADER = 1 + 32 + 4 + OFFER_NONCE_BYTES;
const OFFER_BODY = 45;

function offerMaterial(spendingKey: bigint, listingId: bigint, r: Uint8Array): Uint8Array {
  if (r.length !== OFFER_NONCE_BYTES) throw new Error("offer nonce must be 16 bytes");
  const material = new Uint8Array(64 + OFFER_NONCE_BYTES);
  material.set(bigIntToBytes(spendingKey, 32), 0);
  material.set(bigIntToBytes(listingId, 32), 32);
  material.set(r, 64);
  return material;
}

function offerEphemeralSecret(spendingKey: bigint, listingId: bigint, r: Uint8Array): Uint8Array {
  return hkdf(sha256, offerMaterial(spendingKey, listingId, r), undefined, utf8ToBytes("backlit/offer-key/v2"), 32);
}

/** The blinding a buyer uses for a given listing and offer nonce. */
export function offerBlinding(spendingKey: bigint, listingId: bigint, r: Uint8Array): bigint {
  const wide = hkdf(sha256, offerMaterial(spendingKey, listingId, r), undefined, utf8ToBytes("backlit/offer-blinding/v2"), 64);
  return bytesToBigInt(wide) % FR;
}

export interface SealedOffer {
  /** `payloadToSeller` for `BacklitMarket.offer`. */
  payload: Hex;
  /** `priceCommitment` for `BacklitMarket.offer`. */
  priceCommitment: bigint;
  blinding: bigint;
}

/** Builds an offer: the commitment the chain sees and the opening only the seller (and this buyer) can read. */
export function sealOfferFrom(
  spendingKey: bigint,
  listingId: bigint,
  sellerViewingPk: Uint8Array,
  price: bigint,
  r: Uint8Array = crypto.getRandomValues(new Uint8Array(OFFER_NONCE_BYTES)),
): SealedOffer {
  if (price <= 0n || price >= MAX_NOTE_AMOUNT) throw new Error("price out of range");
  const blinding = offerBlinding(spendingKey, listingId, r);
  const ephemeralSk = offerEphemeralSecret(spendingKey, listingId, r);
  const {key, viewTag, nonce} = derive(x25519.getSharedSecret(ephemeralSk, sellerViewingPk), OFFER_INFO);

  const body = new Uint8Array(OFFER_BODY);
  body[0] = ENVELOPE_VERSION;
  body.set(bigIntToBytes(price, 12), 1);
  body.set(bigIntToBytes(blinding, 32), 13);

  const ciphertext = chacha20poly1305(key, nonce12(nonce), r).encrypt(body);
  const out = new Uint8Array(OFFER_HEADER + ciphertext.length);
  out[0] = ENVELOPE_VERSION;
  out.set(x25519.getPublicKey(ephemeralSk), 1);
  out.set(viewTag, 33);
  out.set(r, 37);
  out.set(ciphertext, OFFER_HEADER);
  return {payload: bytesToHex(out), priceCommitment: poseidon2(price, blinding), blinding};
}

function decryptOffer(shared: Uint8Array, bytes: Uint8Array): OfferPlaintext | null {
  const {key, viewTag, nonce} = derive(shared, OFFER_INFO);
  if (!tagMatches(bytes, viewTag)) return null;
  let body: Uint8Array;
  try {
    body = chacha20poly1305(key, nonce12(nonce), bytes.slice(37, OFFER_HEADER)).decrypt(bytes.slice(OFFER_HEADER));
  } catch {
    return null;
  }
  if (body.length !== OFFER_BODY || body[0] !== ENVELOPE_VERSION) return null;
  return {price: bytesToBigInt(body.slice(1, 13)), blinding: bytesToBigInt(body.slice(13, 45))};
}

/** Only an opening of the commitment the chain recorded is worth anything. */
function opens(offer: OfferPlaintext | null, priceCommitment: bigint | Hex): OfferPlaintext | null {
  if (!offer) return null;
  if (offer.price >= MAX_NOTE_AMOUNT || offer.blinding >= FR) return null;
  const expected = typeof priceCommitment === "bigint" ? priceCommitment : BigInt(priceCommitment);
  return poseidon2(offer.price, offer.blinding) === expected ? offer : null;
}

function offerBytes(payload: Hex): Uint8Array | null {
  const bytes = hexToBytes(payload);
  if (bytes.length !== OFFER_HEADER + OFFER_BODY + 16 || bytes[0] !== ENVELOPE_VERSION) return null;
  return bytes;
}

/**
 * The seller's side: decrypts an offer and returns it only if it opens the
 * on-chain `priceCommitment`. An offer that does not is unsettleable, so it
 * reads as no offer at all.
 */
export function openOffer(viewingSk: Uint8Array, payload: Hex, priceCommitment: bigint | Hex): OfferPlaintext | null {
  const bytes = offerBytes(payload);
  if (!bytes) return null;
  const shared = sharedSecret(viewingSk, bytes.slice(1, 33));
  if (!shared) return null;
  return opens(decryptOffer(shared, bytes), priceCommitment);
}

/** The buyer's side: reopens an offer the caller made, from the spending key alone. */
export function openOwnOffer(
  spendingKey: bigint,
  listingId: bigint,
  sellerViewingPk: Uint8Array,
  payload: Hex,
  priceCommitment: bigint | Hex,
): OfferPlaintext | null {
  const bytes = offerBytes(payload);
  if (!bytes) return null;
  const r = bytes.slice(37, OFFER_HEADER);
  const ephemeralSk = offerEphemeralSecret(spendingKey, listingId, r);
  const ephemeralPk = x25519.getPublicKey(ephemeralSk);
  for (let i = 0; i < 32; i++) if (bytes[1 + i] !== ephemeralPk[i]) return null;

  const shared = sharedSecret(ephemeralSk, sellerViewingPk);
  if (!shared) return null;
  const offer = opens(decryptOffer(shared, bytes), priceCommitment);
  if (!offer || offer.blinding !== offerBlinding(spendingKey, listingId, r)) return null;
  return offer;
}
