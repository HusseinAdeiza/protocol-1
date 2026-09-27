# Circuits

Two Noir circuits and the note scheme they share.

| | inputs | outputs | public inputs | gates |
| --- | --- | --- | --- | --- |
| `spend` | 2 notes | 2 notes, optional withdrawal | 9 | 71,505 |
| `settle` | 2 notes | 3 notes (seller, creator, change) | 14 | 73,739 |

## Toolchain

Pinned, because a verifier is only reproducible with the toolchain that made
it. The versions that produced the checked-in verifiers are in
`circuits/versions.json` and repeated in each generated `.sol` header.

```
nargo     1.0.0-beta.22
bb        5.0.0-nightly.20260522
```

The browser and the scripts must use the matching npm packages:
`@noir-lang/noir_js@1.0.0-beta.22` and `@aztec/bb.js@5.0.0-nightly.20260522`.

Install with `noirup --version 1.0.0-beta.22` and
`bbup --version 5.0.0-nightly.20260522`.

## Building

```
circuits/scripts/build.sh
```

Compiles both circuits, writes verification keys against the `evm` target
(keccak transcript, zero knowledge), generates the Solidity verifiers into
`contracts/src/verifiers/`, and copies the circuit artifacts to
`web/public/circuits/` under a content hash so a stale artifact cannot be
served.

## Testing

```
nargo test
```

Thirty-four tests. The library covers the hashes and the Merkle walk; each
circuit covers its honest path and every tamper case: a wrong root, a wrong
nullifier, the same note twice, value that does not balance, a royalty one wei
short and one wei over, a swapped rate, a price that does not open its
commitment, a payment redirected to another key, and an amount at the 2^96
ceiling.

## The note scheme

```
note        = (asset, amount, ownerPk, salt)
commitment  = poseidon4(asset, amount, ownerPk, salt)
nullifier   = poseidon2(commitment, spendingKey)
ownerPk     = poseidon2(spendingKey, 0)
priceCommit = poseidon2(price, blinding)
```

`amount < 2^96`. A zero note is a valid input to any spend and skips the
membership check, which is what lets a single real note be spent through the
fixed two-input shape.

Poseidon is the circomlib-compatible BN254 one, from `noir-lang/poseidon`.
`circuits/tests/vectors/vectors.json` holds Noir, Solidity and JavaScript to
the same answers.
