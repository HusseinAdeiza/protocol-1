import {describe, expect, it} from "vitest";

import {
  deriveKeys,
  keyDerivationTypedData,
  keysFromSeed,
  ownerPkFrom,
  FR,
  type Hex,
} from "../src/index.js";

const SIGNATURE =
  "0x2c1b9c7e9a5e2a4f9a72c1e33f0b6d59f1f0b8ab4a4f0d8f9d0c1b2a3948576605c4e3d2a1b0f9e8d7c6b5a4938271605f4e3d2c1b0a9988776655443322110c1b" as Hex;

describe("key derivation", () => {
  it("binds the signed message to the wallet and chain", () => {
    const typed = keyDerivationTypedData(4663, "0x1111111111111111111111111111111111111111");
    expect(typed.domain).toEqual({name: "Backlit", version: "1", chainId: 4663});
    expect(typed.message.purpose).toBe("backlit-keys-v1");
    expect(typed.primaryType).toBe("KeyDerivation");
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
