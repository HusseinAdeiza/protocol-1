import {xchacha20poly1305} from "@noble/ciphers/chacha.js";
import {argon2idAsync} from "@noble/hashes/argon2.js";
import {utf8ToBytes} from "@noble/hashes/utils.js";

import {bytesToHex, hexToBytes, type Hex} from "./field.js";

/**
 * The encrypted backup offered at first registration (HANDOVER §5.1). It
 * holds the 32-byte seed, so importing it rebuilds every key with
 * `keysFromSeed` even when the wallet no longer signs the same bytes.
 *
 *   { v: 1, kdf: { name: "argon2id", m, t, p }, salt, nonce, ciphertext }
 *
 * Argon2id stretches the passphrase; XChaCha20-Poly1305 seals the seed with
 * the whole header as associated data, so the parameters cannot be edited
 * without the passphrase check failing.
 */
export interface BacklitBackup {
  v: 1;
  kdf: {name: "argon2id"; m: number; t: number; p: number};
  salt: Hex;
  nonce: Hex;
  ciphertext: Hex;
}

/** 64 MiB, three passes, one lane: the RFC 9106 second recommended option. */
export const BACKUP_KDF = {name: "argon2id", m: 65_536, t: 3, p: 1} as const;

// A backup file is untrusted input: bound the work it can ask for.
const MAX_M = 1_048_576;
const MAX_T = 16;
const MAX_P = 4;

function header(kdf: BacklitBackup["kdf"], salt: Hex): Uint8Array {
  return utf8ToBytes(`backlit-backup/v1|${kdf.name}|${kdf.m}|${kdf.t}|${kdf.p}|${salt.toLowerCase()}`);
}

async function stretch(passphrase: string, salt: Uint8Array, kdf: BacklitBackup["kdf"]): Promise<Uint8Array> {
  return argon2idAsync(utf8ToBytes(passphrase.normalize("NFKC")), salt, {
    m: kdf.m,
    t: kdf.t,
    p: kdf.p,
    dkLen: 32,
    maxmem: (MAX_M + 1) * 1024,
  });
}

/** Encrypts `seed` under `passphrase` and returns the JSON to download. */
export async function exportBackup(seed: Uint8Array, passphrase: string): Promise<string> {
  if (seed.length !== 32) throw new Error("a seed is 32 bytes");
  if (passphrase.length === 0) throw new Error("a backup needs a passphrase");

  const salt = crypto.getRandomValues(new Uint8Array(16));
  const nonce = crypto.getRandomValues(new Uint8Array(24));
  const kdf = {...BACKUP_KDF};
  const saltHex = bytesToHex(salt);
  const key = await stretch(passphrase, salt, kdf);
  const ciphertext = xchacha20poly1305(key, nonce, header(kdf, saltHex)).encrypt(seed);

  const backup: BacklitBackup = {v: 1, kdf, salt: saltHex, nonce: bytesToHex(nonce), ciphertext: bytesToHex(ciphertext)};
  return JSON.stringify(backup);
}

function isHex(value: unknown, bytes: number): value is Hex {
  return typeof value === "string" && new RegExp(`^0x[0-9a-fA-F]{${bytes * 2}}$`).test(value);
}

function parse(json: string): BacklitBackup {
  let raw: unknown;
  try {
    raw = JSON.parse(json);
  } catch {
    throw new Error("this is not a Backlit backup");
  }
  const b = raw as Partial<BacklitBackup> | null;
  const kdf = b?.kdf;
  if (
    !b ||
    b.v !== 1 ||
    !kdf ||
    kdf.name !== "argon2id" ||
    !Number.isInteger(kdf.m) ||
    !Number.isInteger(kdf.t) ||
    !Number.isInteger(kdf.p) ||
    kdf.m < BACKUP_KDF.m ||
    kdf.m > MAX_M ||
    kdf.t < BACKUP_KDF.t ||
    kdf.t > MAX_T ||
    kdf.p < 1 ||
    kdf.p > MAX_P ||
    !isHex(b.salt, 16) ||
    !isHex(b.nonce, 24) ||
    !isHex(b.ciphertext, 48)
  ) {
    throw new Error("this is not a Backlit backup");
  }
  return b as BacklitBackup;
}

/** Decrypts a backup and returns the seed. Throws on a wrong passphrase or a damaged file. */
export async function importBackup(json: string, passphrase: string): Promise<Uint8Array> {
  const backup = parse(json);
  const key = await stretch(passphrase, hexToBytes(backup.salt), backup.kdf);
  try {
    return xchacha20poly1305(key, hexToBytes(backup.nonce), header(backup.kdf, backup.salt)).decrypt(
      hexToBytes(backup.ciphertext),
    );
  } catch {
    throw new Error("wrong passphrase, or the backup is damaged");
  }
}
