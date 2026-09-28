import {hashMessage} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {describe, expect, it} from "vitest";

import {
  bytesToHex,
  deriveKeys,
  exportBackup,
  hexToBytes,
  importBackup,
  normalizeSignature,
  seedFromSignature,
  keyDerivationMessage,
  keySite,
  KEY_SITES,
  keysFromSeed,
  ownerPkFrom,
  toHex32,
  FR,
  type Hex,
} from "../src/index.js";

const SIGNATURE =
  "0x2c1b9c7e9a5e2a4f9a72c1e33f0b6d59f1f0b8ab4a4f0d8f9d0c1b2a3948576605c4e3d2a1b0f9e8d7c6b5a4938271605f4e3d2c1b0a9988776655443322110c1b" as Hex;

const PINNED_DIGEST = "0x2502b4861d467fd195497766c7c8bae4d1bad386c28d6b1e3d8ec4568db0726b";
const PINNED_OWNER_PK = "0x2faf4a8e0b1786c1ae8c0bd79b161cdd05796e91845dcab70cfb62b2ceae08c9";
const PINNED_VIEWING_PK = "0x4dbbda348212d006a76485b3a7764fc3629435f0bf51f521d76334efb5854d13";

describe("key derivation", () => {
  it("asks the wallet to sign in to the site, and says what the signature is", () => {
    const message = keyDerivationMessage(keySite("https://backlit.ink"), 4663, "0x1111111111111111111111111111111111111111");
    expect(message).toBe(
      [
        "backlit.ink wants you to sign in with your Ethereum account:",
        "0x1111111111111111111111111111111111111111",
        "",
        "This signature is your Backlit key. Anyone who has it can spend your Backlit balance.",
        "",
        "URI: https://backlit.ink",
        "Version: 1",
        "Chain ID: 4663",
        "Nonce: backlitkeys2",
        "Issued At: 2026-09-28T00:00:00.000Z",
      ].join("\n"),
    );
  });

  it("writes the wallet checksummed, whatever case it is given in", () => {
    const lower = "0x4ea9d905eb88bb7944edf2442578dfe7ad8831be";
    const message = keyDerivationMessage(keySite(KEY_SITES[4663]!), 4663, lower);
    expect(message.split("\n")[1]).toBe("0x4eA9d905eb88bB7944EdF2442578DFE7AD8831Be");
  });

  it("names each chain's own site, so keys differ between them", () => {
    expect(keySite(KEY_SITES[4663]!)).toEqual({domain: "backlit.ink", uri: "https://backlit.ink"});
    expect(keySite(KEY_SITES[46630]!)).toEqual({domain: "testnet.backlit.ink", uri: "https://testnet.backlit.ink"});
    expect(keySite(KEY_SITES[31337]!)).toEqual({domain: "localhost:3080", uri: "http://localhost:3080"});
  });

  // Every registered key hangs off this message. If this test fails, every
  // user's keys have moved.
  it("keeps the message a wallet signs, and the keys it gives, fixed", async () => {
    const account = privateKeyToAccount(`0x${"42".repeat(32)}`);
    const message = keyDerivationMessage(keySite(KEY_SITES[4663]!), 4663, account.address);
    expect(hashMessage(message)).toBe(PINNED_DIGEST);
    const keys = deriveKeys(await account.signMessage({message}));
    expect(toHex32(keys.ownerPk)).toBe(PINNED_OWNER_PK);
    expect(bytesToHex(keys.viewingPk)).toBe(PINNED_VIEWING_PK);
  });

  it("gives the same keys for the same signature", () => {
    const first = deriveKeys(SIGNATURE);
    const second = deriveKeys(SIGNATURE);
    expect(second.spendingKey).toBe(first.spendingKey);
    expect(second.ownerPk).toBe(first.ownerPk);
    expect([...second.viewingPk]).toEqual([...first.viewingPk]);
  });

  it("gives different keys for a different signature", () => {
    const changed = (`${SIGNATURE.slice(0, -2)}1c`) as Hex;
    expect(deriveKeys(changed).spendingKey).not.toBe(deriveKeys(SIGNATURE).spendingKey);
  });

  it("keeps the spending key inside the field", () => {
    for (let i = 0; i < 32; i++) {
      const seed = new Uint8Array(32).fill(i * 7);
      const keys = keysFromSeed(seed);
      expect(keys.spendingKey).toBeLessThan(FR);
      expect(keys.ownerPk).toBe(ownerPkFrom(keys.spendingKey));
    }
  });

  it("derives a 32-byte viewing key pair", () => {
    const keys = keysFromSeed(new Uint8Array(32).fill(3));
    expect(keys.viewingSk).toHaveLength(32);
    expect(keys.viewingPk).toHaveLength(32);
  });
});

describe("signature normalisation", () => {
  const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
  const account = privateKeyToAccount(`0x${"42".repeat(32)}`);

  async function variants() {
    const signature = await account.signMessage({message: "backlit"});
    const bytes = hexToBytes(signature);
    const r = bytes.slice(0, 32);
    const s = BigInt(bytesToHex(bytes.slice(32, 64)));
    const v = bytes[64]!;

    const highS = new Uint8Array(65);
    highS.set(r, 0);
    highS.set(hexToBytes(`0x${(N - s).toString(16).padStart(64, "0")}`), 32);
    highS[64] = v === 27 ? 28 : 27;

    const zeroBased = bytes.slice();
    zeroBased[64] = v - 27;

    const compact = bytes.slice(0, 64);
    if (v === 28) compact[32] = compact[32]! | 0x80;

    return {signature, highS: bytesToHex(highS), zeroBased: bytesToHex(zeroBased), compact: bytesToHex(compact)};
  }

  it("gives the same keys for every encoding of one signature", async () => {
    const {signature, highS, zeroBased, compact} = await variants();
    const expected = deriveKeys(signature).spendingKey;
    for (const variant of [highS, zeroBased, compact]) {
      expect(deriveKeys(variant).spendingKey).toBe(expected);
    }
  });

  it("leaves a canonical signature as it is", async () => {
    const {signature} = await variants();
    expect(bytesToHex(normalizeSignature(signature))).toBe(signature);
  });

  it("refuses malformed signatures", () => {
    expect(() => normalizeSignature(`0x${"11".repeat(63)}`)).toThrow();
    expect(() => normalizeSignature(`0x${"11".repeat(64)}1d`)).toThrow();
    expect(() => normalizeSignature(`0x${"11".repeat(32)}${"00".repeat(32)}1b`)).toThrow();
  });
});

describe("backups", () => {
  const seed = seedFromSignature(SIGNATURE);

  it("round trips the seed and rebuilds the same keys", async () => {
    const json = await exportBackup(seed, "correct horse battery staple");
    const parsed = JSON.parse(json);
    expect(parsed.v).toBe(1);
    expect(parsed.kdf).toEqual({name: "argon2id", m: 65_536, t: 3, p: 1});
    expect(hexToBytes(parsed.salt)).toHaveLength(16);
    expect(hexToBytes(parsed.nonce)).toHaveLength(24);

    const restored = await importBackup(json, "correct horse battery staple");
    expect([...restored]).toEqual([...seed]);
    expect(keysFromSeed(restored).ownerPk).toBe(deriveKeys(SIGNATURE).ownerPk);
  }, 30_000);

  it("refuses a wrong passphrase and edited parameters", async () => {
    const json = await exportBackup(seed, "correct horse battery staple");
    await expect(importBackup(json, "wrong")).rejects.toThrow(/passphrase/);

    const edited = JSON.parse(json);
    edited.kdf.t = 4;
    await expect(importBackup(JSON.stringify(edited), "correct horse battery staple")).rejects.toThrow(
      /passphrase/,
    );
  }, 30_000);

  it("refuses weak parameters and malformed files before doing any work", async () => {
    const json = await exportBackup(seed, "pw");
    const weak = JSON.parse(json);
    weak.kdf.m = 8;
    await expect(importBackup(JSON.stringify(weak), "pw")).rejects.toThrow(/not a Backlit backup/);
    await expect(importBackup("{}", "pw")).rejects.toThrow(/not a Backlit backup/);
    await expect(importBackup("not json", "pw")).rejects.toThrow(/not a Backlit backup/);
  }, 30_000);
});
