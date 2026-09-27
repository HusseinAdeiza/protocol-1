# Backlit protocol

The contracts, circuits and client cryptography behind [backlit.ink](https://backlit.ink),
an NFT market on Robinhood Chain where the sale price stays private and the
creator's royalty is paid in the same transaction.

The contracts, circuits and SDK are all here. The contracts cannot be
upgraded, the verifiers are generated from these circuits, and the SDK is the
code the app uses to derive keys and encrypt notes in your browser.

## What is private

A sale on Backlit publishes the listing, the NFT's new owner, the royalty rate
and the fact that it was paid in full. It does not publish the price, and the
notes that paid are not linked to the wallet that deposited them.
[`docs/threat-model.md`](docs/threat-model.md) sets out what each guarantee
rests on and what it does not cover.

## Layout

```
contracts/   Foundry. BacklitPool, BacklitMarket and the generated verifiers.
circuits/    Noir. spend and settle, and the note scheme they share.
sdk/         Keys, notes, envelopes, the Merkle tree and circuit inputs.
docs/        Threat model and design notes.
```

## How it works

Value inside the pool is a **note**: a private record of an amount and its
owner, stored as a Poseidon commitment in a Merkle tree. Spending a note
publishes a nullifier and nothing else.

`spend` takes two notes in and two out, with an optional public withdrawal.
`settle` takes two notes in and three out: the seller's share, the creator's
royalty and the buyer's change. The proof shows they add up to the committed
price and that the royalty is exactly the collection's ERC-2981 rate, rounded
up.

Keys come from one wallet signature and never leave the device. Note payloads
are encrypted to the owner's viewing key with a four-byte view tag, so a wallet
can skip notes that are not its own cheaply.

Proofs are UltraHonk over BN254, with no trusted setup. Verifying one on chain
costs about 2.5M gas.

## Building and testing

Needs Node 22 or later, pnpm, Foundry, and `nargo` and `bb` at the versions in
[`circuits/versions.json`](circuits/versions.json).

```
git clone --recursive https://github.com/backlit-ink/protocol
pnpm install

(cd circuits && nargo test)      # constraints and every tamper case
(cd contracts && forge test)     # units, invariants, recorded real proofs
pnpm --filter @backlit/sdk test  # crypto, notes, parity with the contracts
```

Run each command from the directory shown; Foundry and Nargo look for their
project file in the current directory.

Deployed addresses, with the block, commit and toolchain that produced them,
are in `contracts/deployments/<chainId>.json`.

`circuits/scripts/build.sh` recompiles the circuits and regenerates the
Solidity verifiers. Run it after any circuit change and commit the result.

## Admin controls

The contracts have no proxy and no upgrade path. A guardian can raise the
deposit cap and pause new deposits. Nothing in these contracts can pause a
withdrawal. Balances are held in the chain's WETH contract, which has its own
upgrade administrator.

## Security

Please report vulnerabilities privately. See [SECURITY.md](SECURITY.md).

## Licence

MIT. See [LICENSE](LICENSE).
