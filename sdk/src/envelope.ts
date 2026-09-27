import {chacha20poly1305} from "@noble/ciphers/chacha.js";
import {x25519} from "@noble/curves/ed25519.js";
import {hkdf} from "@noble/hashes/hkdf.js";
import {sha256} from "@noble/hashes/sha2.js";
import {utf8ToBytes} from "@noble/hashes/utils.js";

import {bigIntToBytes, bytesToBigInt, bytesToHex, FR, hexToBytes, type Hex} from "./field.js";

/**
 * Every note and every offer travels with a payload only its recipient can
 * read. The envelope is a one-shot x25519 exchange: an ephemeral key per
 * payload, HKDF to a ChaCha20-Poly1305 key, and a four-byte view tag so a
 * wallet can skip payloads that are not its own without doing the work.
 *
 *   payload = version(1) ‖ ephemeralPk(32) ‖ viewTag(4) ‖ ciphertext
 */
export const ENVELOPE_VERSION = 1;

const NOTE_INFO = "backlit/note/v1";
const OFFER_INFO = "backlit/offer/v1";

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

function open(viewingSk: Uint8Array, info: string, payload: Uint8Array): Uint8Array | null {
  if (payload.length < 38 || payload[0] !== ENVELOPE_VERSION) return null;
  const ephemeralPk = payload.slice(1, 33);
  const {key, viewTag, nonce} = derive(x25519.getSharedSecret(viewingSk, ephemeralPk), info);
  for (let i = 0; i < 4; i++) if (payload[33 + i] !== viewTag[i]) return null;
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

/** version(1) ‖ price(12, big-endian) ‖ blinding(32) */
export function sealOffer(sellerViewingPk: Uint8Array, offer: OfferPlaintext): Hex {
  const body = new Uint8Array(45);
  body[0] = ENVELOPE_VERSION;
  body.set(bigIntToBytes(offer.price, 12), 1);
  body.set(bigIntToBytes(offer.blinding, 32), 13);
  return bytesToHex(seal(sellerViewingPk, OFFER_INFO, body));
}

export function openOffer(viewingSk: Uint8Array, payload: Hex): OfferPlaintext | null {
  const body = open(viewingSk, OFFER_INFO, hexToBytes(payload));
  if (!body || body.length !== 45 || body[0] !== ENVELOPE_VERSION) return null;
  return {price: bytesToBigInt(body.slice(1, 13)), blinding: bytesToBigInt(body.slice(13, 45))};
}

/** A fresh 32-byte value reduced into the field, for salts and blinding factors. */
export function randomFieldElement(): bigint {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  // Clearing the top byte keeps the value well inside the field with no bias
  // worth arguing about.
  bytes[0] = 0;
  return bytesToBigInt(bytes);
}

// ------------------------------------------------- offers the buyer can reopen

/**
 * An offer's opening is encrypted to the seller, and the buyer needs it back
 * at settlement. Rather than store it, the buyer derives the ephemeral key
 * from their own spending key, so the payload in the event log is readable by
 * both sides and by nobody else.
 */
function offerEphemeralSecret(spendingKey: bigint, listingId: bigint, nonce: number): Uint8Array {
  const material = new Uint8Array(72);
  material.set(bigIntToBytes(spendingKey, 32), 0);
  material.set(bigIntToBytes(listingId, 32), 32);
  material.set(bigIntToBytes(BigInt(nonce), 8), 64);
  return hkdf(sha256, material, undefined, utf8ToBytes("backlit/offer-key/v1"), 32);
}

export function sealOfferFrom(
  spendingKey: bigint,
  listingId: bigint,
  nonce: number,
  sellerViewingPk: Uint8Array,
  offer: OfferPlaintext,
): Hex {
  const ephemeralSk = offerEphemeralSecret(spendingKey, listingId, nonce);
  const ephemeralPk = x25519.getPublicKey(ephemeralSk);
  const {key, viewTag, nonce: chachaNonce} = derive(
    x25519.getSharedSecret(ephemeralSk, sellerViewingPk),
    OFFER_INFO,
  );

  const body = new Uint8Array(45);
  body[0] = ENVELOPE_VERSION;
  body.set(bigIntToBytes(offer.price, 12), 1);
  body.set(bigIntToBytes(offer.blinding, 32), 13);

  const ciphertext = chacha20poly1305(key, nonce12(chachaNonce)).encrypt(body);
  const out = new Uint8Array(1 + 32 + 4 + ciphertext.length);
  out[0] = ENVELOPE_VERSION;
  out.set(ephemeralPk, 1);
  out.set(viewTag, 33);
  out.set(ciphertext, 37);
  return bytesToHex(out);
}

/** Reopens an offer the caller made, by rederiving the ephemeral key. */
export function openOwnOffer(
  spendingKey: bigint,
  listingId: bigint,
  sellerViewingPk: Uint8Array,
  payload: Hex,
  maxNonce = 32,
): {offer: OfferPlaintext; nonce: number} | null {
  const bytes = hexToBytes(payload);
  if (bytes.length < 38 || bytes[0] !== ENVELOPE_VERSION) return null;

  for (let nonce = 0; nonce < maxNonce; nonce++) {
    const ephemeralSk = offerEphemeralSecret(spendingKey, listingId, nonce);
    const {key, viewTag, nonce: chachaNonce} = derive(
      x25519.getSharedSecret(ephemeralSk, sellerViewingPk),
      OFFER_INFO,
    );
    let tagMatches = true;
    for (let i = 0; i < 4; i++) if (bytes[33 + i] !== viewTag[i]) tagMatches = false;
    if (!tagMatches) continue;

    try {
      const body = chacha20poly1305(key, nonce12(chachaNonce)).decrypt(bytes.slice(37));
      if (body.length !== 45 || body[0] !== ENVELOPE_VERSION) return null;
      return {
        offer: {price: bytesToBigInt(body.slice(1, 13)), blinding: bytesToBigInt(body.slice(13, 45))},
        nonce,
      };
    } catch {
      return null;
    }
  }
  return null;
}

/** The blinding a buyer uses for a given listing and nonce. */
export function offerBlinding(spendingKey: bigint, listingId: bigint, nonce: number): bigint {
  const material = offerEphemeralSecret(spendingKey, listingId, nonce + 1_000_000);
  return bytesToBigInt(material) % FR;
}
