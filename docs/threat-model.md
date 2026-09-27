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

A proof submitted twice, or against another pool, chain, offer or payout.

Against it: nullifiers are recorded on first use and never accepted again.
`poolId` is `keccak256(chainId, poolAddress)` reduced into the field, and both
contracts rebuild it from their own state. Each circuit has one public input
it only binds, and the contracts fill it with a hash of the call:

- settle: `keccak256(offerId, keccak256(payloads))`. The offer fixes the
  listing, the buyer, the price commitment and the NFT recipient, so a proof
  settles one offer with one set of note payloads.
- spend: `keccak256(recipient, unwrap, keccak256(payloads))`, so a proof pays
  one address, in one form (ETH or WETH), with one set of payloads.

`contracts/test/Replay.t.sol` replays real proofs against a second offer, with
payloads swapped, with the unwrap flag flipped and with the recipient changed,
and expects each to revert while the untouched call lands.

### Front-running a settlement or a withdrawal

Robinhood Chain sequences first come, first served, so a pending transaction
can be seen and copied before it lands.

Against it: every field that decides where value goes is covered by the proof,
including the payloads the recipients need to find their notes. A copied
settle proof can only be submitted for the same offer with the same payloads,
so it pays the same seller, creator and change note and moves the NFT to the
recipient the offer named. A copied spend proof pays the same recipient the
same way. Submitting someone else's proof costs the submitter the fee and gains
them nothing. Anyone may submit a settlement because the proof, not the sender,
is the authority.

### A buyer who attaches unreadable payloads

The payloads are chosen by the prover, and no circuit checks the encryption.
A buyer could settle with a seller payload that does not decrypt, leaving the
seller unable to find the note they were paid.

Against it: the settle circuit derives the seller's salt from the price
blinding, which the seller already holds from the offer. The seller rebuilds
the note with `sellerNoteFromOffer` and finds it by commitment, whatever the
payload says. Wallets check every decrypted note against its leaf with
`verifyNote` and drop any that do not match, and drop any offer whose opening
does not match the commitment on chain.

Residual: the creator never sees the price, so a buyer can make the royalty
note unrecoverable by sealing garbage to the creator. The buyer still pays the
royalty; nobody gains, the creator loses that sale's royalty. Fixing it needs
the creator's salt to be derivable by the creator, which is future work.

### A settlement that waits too long for a root

A proof cites a root. A busy pool could otherwise age that root out before the
transaction lands.

Against it: the pool accepts any root its tree has ever had. Old roots do not
weaken anything: a note can still be spent only once, because of its
nullifier.

### The fee recipient refuses ETH

The flat fee goes to a router the operator runs. If that router reverted, every
settlement would revert with it.

Against it: a failed fee send is held in the market as `feesOwed` with a
`FeeDeferred` event, and the sale completes. `forwardFees` is permissionless
and sends what is owed to the current fee recipient.

### Filling the deposit cap without depositing

Against it: the cap is measured on the pool's own accounting (deposited minus
withdrawn), not on its WETH balance, so WETH sent to the pool directly does not
count towards it.

### The royalty receiver changes between listing and settlement

A collection could point its royalty somewhere else after a listing goes up.

Against it: `royaltyInfo` is read live at settlement, and the receiver must have
registered keys at that moment. A proof built against the old receiver will not
verify against the new public inputs, so the settlement reverts rather than
paying the wrong party.

### A hostile collection contract

A collection controls `royaltyInfo`, `transferFrom` and `tokenURI`.

Against it: escrow and release are guarded against reentrancy, and the market
holds no value beyond the token itself and any deferred fees. `list` checks the
market owns the token after `transferFrom`, and the market does not accept
`safeTransferFrom` from outside `list`, so no token can arrive without a
listing that can return it. Royalties above 100% are rejected.
Metadata is fetched server side, never by the browser, and an inline SVG has
its scripting removed before a page renders it. The metadata fetcher refuses
private and loopback addresses.

Residual: a collection can still make its own royalty unpayable, by pointing it
at an address with no keys. Sales in that collection stop until it is fixed.
That is visible on the collection page.

### Hostile payloads in the event log

Anyone can emit a note or offer payload. Against it: opening a payload never
throws; a low-order x25519 key, a bad tag or a failed decryption all read as
"not mine", so one hostile payload cannot stop a wallet's scan.

### The indexer is compromised

Against it: the indexer holds only what the chain shows everyone. It never sees
a key, a decrypted note or a price. A wallet rebuilds the tree from the note
events and checks the root against the pool before proving, so a lying indexer
produces a proof that fails rather than a loss. The web app falls back to
reading the chain when the indexer is missing or behind.

### Key loss

Keys come from one wallet signature, so a wallet that signs deterministically
reproduces them. Some wallets do not.

Against it: the signature is normalised (low s, `v` in {27, 28}, 64-byte form
expanded) before it is hashed, so encoding differences between wallets do not
change the keys. The app compares derived keys against what is registered on
chain and offers an import path on a mismatch: an encrypted backup of the seed
(Argon2id at 64 MiB and three passes, then XChaCha20-Poly1305 over the seed
with the parameters as associated data). A viewing key export lets an owner
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
deployer, once, then locked. `BacklitMarket.forwardFees` is callable by anyone
and can only pay the current fee recipient.

On chain 4663 the deploy script refuses to run unless WETH is the canonical
`0x0Bd7...AcAD73`, the guardian and fee recipient are set explicitly and are
not the deployer, the guardian is a deployed contract, and fixtures are off. It
checks the pool and market point at each other before it writes the deployment
record.

There is nothing else. No pause on withdrawals, no upgrade, no proxy, no way to
move a note or a token that is not a proof or the owner's own transaction.
