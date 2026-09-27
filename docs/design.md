# Design notes

Choices made while building the protocol, and what each one rests on.

## Poseidon comes from a pinned library, not the Noir standard library

Poseidon left the Noir standard library before 1.0.0-beta.22, so the circuits
depend on `noir-lang/poseidon v0.3.0`. It is the same circomlib-compatible
BN254 Poseidon the specification names, and the shared vectors prove the three
implementations agree.

## The Merkle path is implemented here rather than imported

`zk-kit.noir`'s `binary-merkle-root` was published against a much older Noir.
Rather than pin a dependency that may not compile, `circuits/lib` walks the
LeanIMT path in about fifteen lines, and `contracts/test/Parity.t.sol` and
`sdk/test/parity.test.ts` hold it to the same roots as the audited Solidity
`InternalLeanIMT` and the JavaScript `@zk-kit/lean-imt`. The on-chain tree is
still the audited zk-kit one.

## `asset` is a public input rather than a constant

An early circuit sketch fixed WETH inside the circuit, which would mean a
different circuit and verifier per chain. Making `asset` a public input costs
one field element; each contract checks it equals its own WETH. One circuit,
one verifier, every chain.

## Unused public inputs are bound by a hash

`poolId`, `recipient` and `listingId` carry no constraint of their own. A
compiler is free to drop a witness nothing reads, which would silently remove
them from the proof. `bind()` hashes the pair and asserts the result is
non-zero, which cannot be optimised away, for about 240 gates.

## A collection that charges no royalty still creates three notes

The settle circuit has a fixed shape. When the rate is zero the third note is
worth nothing, and the market addresses it to the seller's key so it stays
spendable rather than stranded. `list` does not ask for the receiver's keys
when the rate is zero, because there is nothing to pay.

## Offers are readable by both sides, with no stored state

A buyer needs the price and the blinding factor back at settlement, and the
seller needs them to decide. Rather than have the buyer keep a local record,
the ephemeral key of the offer envelope is derived from the buyer's own
spending key, the listing id and a small nonce. The seller opens it with their
viewing key; the buyer reopens it by rederiving. A third party gets nothing.
The nonce is found by trying the first thirty-two values.

## Contract tests use a stand-in verifier

Real proofs are bound to a pool address, and a pool address is only known after
deployment. Rather than contort the tests around that, `Verifiers.t.sol`
replays real proofs against the verifiers directly, the pool and market tests
use a stand-in and an end-to-end run exercises the whole thing against a live
chain with real proofs. `EchoVerifier` reverts with the public inputs it was
given, so the tests can assert on exactly what each contract builds.

## Metadata is read on the server

A collection controls its own `tokenURI`. Fetching it in the browser would let
a collection point a visitor's browser anywhere. The app reads it server side,
refuses private and loopback addresses, drops everything but the fields a page
shows, and strips scripting out of an inline SVG.
