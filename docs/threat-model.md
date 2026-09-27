# Threat model

What Backlit protects, what it does not, and what each defence actually rests
on. Written for a reviewer, and kept honest rather than reassuring.

## What the system claims

Backlit hides the sale price and the funding trail behind a payment. The
listing, the settlement and the NFT's new owner are public. The royalty rate
and the fact it was paid are public. Nothing else is claimed.

## Assets

| Asset | Held by | Loss looks like |
| --- | --- | --- |
| WETH in the pool | `BacklitPool` | Someone withdraws value they never deposited |
| A note's amount and owner | The note's owner, in their browser | Somebody else learns what a sale was worth |
| An NFT in escrow | `BacklitMarket` | A token leaves without a settled sale or a cancel |
| A creator's royalty | The settle circuit | A sale settles paying less than the collection charges |
| Spending keys | The owner's device, for the session | Theft of everything a wallet holds in the pool |

## Threats and what stands against them

### Counterfeit notes through a circuit bug

A flaw in `settle` or `spend` that lets a prover create value would drain the
pool. This is the one failure that loses other people's money.

Against it: every constraint has a tamper test in `circuits/*/src/main.nr`,
including a royalty one wei short in both directions, a swapped rate, a
replayed nullifier, a sum that does not balance and an amount at the 2^96
ceiling. The three Poseidon implementations are pinned to shared vectors. An
external review is booked before mainnet. The deposit cap bounds the loss while
the contracts are young.

Residual: a circuit bug is still the largest risk in the system, and the cap is
the only thing that bounds it.

### Proof replay

A proof submitted twice, or against another pool, chain or listing.

Against it: nullifiers are recorded on first use and never accepted again.
`poolId` is `keccak256(chainId, poolAddress)` reduced into the field, and both
contracts rebuild it from their own state. `settle` binds `listingId`, so a
proof is good for one listing and no other. The smoke test replays a settled
proof and expects a revert.

### Front-running a settlement

Robinhood Chain sequences first come, first served, so a settlement can be seen
before it lands.

Against it: a copied settle proof pays the same seller, the same creator and
the same change note, and moves the NFT to the recipient the original offer
named. Submitting someone else's proof costs the submitter the fee and gains
them nothing. Anyone may submit a settlement precisely because the proof, not
the sender, is the authority.

### The royalty receiver changes between listing and settlement

A collection could point its royalty somewhere else after a listing goes up.

Against it: `royaltyInfo` is read live at settlement, and the receiver must have
registered keys at that moment. A proof built against the old receiver will not
verify against the new public inputs, so the settlement reverts rather than
paying the wrong party.

### A hostile collection contract

A collection controls `royaltyInfo`, `transferFrom` and `tokenURI`.

Against it: escrow and release are guarded against reentrancy, and the market
holds no value beyond the token itself. Royalties above 100% are rejected.
Metadata is fetched server side, never by the browser, and an inline SVG has
its scripting removed before a page renders it. The metadata fetcher refuses
private and loopback addresses.

Residual: a collection can still make its own royalty unpayable, by pointing it
at an address with no keys. Sales in that collection stop until it is fixed.
That is visible on the collection page.

### The indexer is compromised

Against it: the indexer holds only what the chain shows everyone. It never sees
a key, a decrypted note or a price. A wallet rebuilds the tree from the note
events and checks the root against the pool before proving, so a lying indexer
produces a proof that fails rather than a loss. The web app falls back to
reading the chain when the indexer is missing or behind.

### Key loss

Keys come from one wallet signature, so a wallet that signs deterministically
reproduces them. Some wallets do not.

Against it: the app compares derived keys against what is registered on chain
and offers an import path on a mismatch. A viewing key export lets an owner
read their notes from another device.

Residual: losing both the wallet and the backup means losing the notes. There
is no recovery, by design.

### Phishing

Against it: the EIP-712 message names its purpose and the wallet it belongs to,
and Reown's allow-list keeps the wallet connection tied to known domains. A
signature taken on another site derives keys for that site's chain id and
wallet, not Backlit's.

## What Backlit does not defend against

- **A small anonymity set.** Early on, few notes exist. Timing and amounts can
  narrow a guess. The app steers deposits and withdrawals to round numbers, and
  the docs say this plainly.
- **Anyone watching the buyer's screen.** The price is on the buyer's and the
  seller's devices in plain text, because they both need to read it.
- **The NFT's new owner staying private.** It is public, deliberately.
- **A collection lying about its own royalty terms.** Backlit pays what the
  collection says it charges.

## Privileged functions, in full

`BacklitPool.raiseCap` and `BacklitPool.setDepositsPaused`, both guardian only.
`BacklitMarket.setFeeWei` (capped at 0.01 ETH) and
`BacklitMarket.setFeeRecipient`, both guardian only. `BacklitPool.initMarket`,
deployer, once, then locked.

There is nothing else. No pause on withdrawals, no upgrade, no proxy, no way to
move a note or a token that is not a proof or the owner's own transaction.
