/** The BN254 scalar field. Everything a circuit sees is a residue mod this. */
export const FR = 21888242871839275222246405745257438548091551002212100084086427780313373464577n;

/** Note amounts are uint96 on chain and in the circuits. */
export const MAX_NOTE_AMOUNT = 1n << 96n;

export type Hex = `0x${string}`;

export function toHex32(value: bigint | string): Hex {
  const n = typeof value === "bigint" ? value : BigInt(value);
  if (n < 0n) throw new Error("negative field element");
  return `0x${n.toString(16).padStart(64, "0")}`;
}

export function isFieldElement(value: bigint | string): boolean {
  const n = typeof value === "bigint" ? value : BigInt(value);
  return n >= 0n && n < FR;
}

export function assertField(value: bigint, what = "value"): bigint {
  if (!isFieldElement(value)) throw new Error(`${what} is not a field element`);
  return value;
}

/** Folds a 256-bit identifier into the field, exactly as `Field.reduce` does. */
export function reduce(value: bigint | Hex): bigint {
  return (typeof value === "bigint" ? value : BigInt(value)) % FR;
}

export function bytesToBigInt(bytes: Uint8Array): bigint {
  let n = 0n;
  for (const byte of bytes) n = (n << 8n) | BigInt(byte);
  return n;
}

export function bigIntToBytes(value: bigint, length: number): Uint8Array {
  const out = new Uint8Array(length);
  let n = value;
  for (let i = length - 1; i >= 0; i--) {
    out[i] = Number(n & 0xffn);
    n >>= 8n;
  }
  if (n !== 0n) throw new Error("value does not fit");
  return out;
}

export function hexToBytes(hex: string): Uint8Array {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export function bytesToHex(bytes: Uint8Array): Hex {
  let out = "";
  for (const byte of bytes) out += byte.toString(16).padStart(2, "0");
  return `0x${out}`;
}
