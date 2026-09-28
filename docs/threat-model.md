# Threat model

What Backlit protects, what it does not, and what each defence rests on.
Written for a reviewer.

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
| A seller's share | The rate pinned at acceptance | A sale settles at a higher royalty than the seller accepted |
| Spending keys | The owner's device, for the session | Theft of everything a wallet holds in the pool |

## Threats and what stands against them

### Counterfeit notes through a circuit bug

A flaw in `settle` or `spend` that lets a prover create value would drain the
pool. This is the one failure that loses other people's money.

Against it: every constraint has a tamper test in `circuits/*/src/main.nr`,
including a royalty one wei short in both directions, a swapped rate, a
replayed nullifier, a sum that does not balance and an amount at the 2^96
ceiling. The three Poseidon implementations are pinned to shared vectors. Two
internal audits have reviewed the contracts and circuits; an external review
comes before the deposit cap goes above 20 ETH. The cap bounds the loss while
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

### A withdrawal to an address that would lose it

A spend pays its withdrawal wherever the proof says. Four addresses would lose
the value: zero; the pool, where it would sit outside every note; the WETH
contract, which credits ETH it receives back to the pool and keeps WETH sent to
it; and the market, which has no way to move WETH out.

Against it: `spend` refuses a withdrawal to any of them with `BadRecipient`,
before the proof is checked. Any other address is the owner's choice.

### A settlement that waits too long for a root

A proof cites a root. A busy pool could otherwise age that root out before the
transaction lands.

Against it: the pool accepts any root its tree has ever had. Old roots do not
weaken anything: a note can still be spent only once, because of its
nullifier.

### A hostile or broken fee recipient

The flat fee goes to a router the operator runs. If that router reverted, every
settlement would revert with it. A contract recipient could also make
settlement too expensive to finish, by burning the gas it is handed or by
returning more data than the market can afford to copy back.

Against it: `settle` sends the fee with at most 100,000 gas (`FEE_GAS`) and
copies nothing the recipient returns. A send that fails for any reason,
including a submitter leaving it too little gas, is held in the market as
`feesOwed` with a `FeeDeferred` event, and the sale completes. `forwardFees` is
permissionless, passes on all its gas, copies nothing back, and can only pay
the current fee recipient.

Residual: a recipient that needs more than 100,000 gas to accept ETH has every
fee held until someone calls `forwardFees`.

### Filling the deposit cap without depositing

Against it: the cap is measured on the pool's own accounting (deposited minus
withdrawn), not on its WETH balance, so WETH sent to the pool directly does not
count towards it.

### The royalty receiver changes between listing and settlement

A collection could point its royalty somewhere else after a listing goes up.

Against it: `royaltyInfo` is read live at settlement, and the receiver must have
registered keys at that moment. A proof built against the old receiver will not
verify against the new public inputs, so the settlement reverts rather than
paying the wrong party. The rate is read live too, but it can only have fallen
since the seller accepted; the next section covers a rise.

### A royalty raised after the seller accepts

A collection's owner can usually change its ERC-2981 rate at will. With the
rate read only at settlement, an owner could wait for a seller to accept, raise
the rate to 100% and settle a proof built at that rate: the seller's note would
be worth nothing and the whole price would go to the royalty receiver. An owner
who also held the buyer's keys could raise the rate, settle and restore it in
one transaction, leaving the collection showing its usual rate afterwards.

Against it: `accept` takes the price commitment the seller opened and the
highest rate they agree to, normally the one they were shown. It reverts if the
commitment is not the offer's, or if the collection's rate is above that
ceiling, which catches a raise sent just ahead of the acceptance. The rate it
reads is pinned to the offer as `acceptedRoyaltyBps`. `settle` reverts with
`RoyaltyRaised` when the live rate is above the pinned one, before it looks at
the proof; a lower rate settles at the lower rate, which only leaves the seller
more. `unaccept` clears the pin and a later `accept` sets it again.
`contracts/test/Replay.t.sol` submits a real proof at 100% for an offer
accepted at 5%, on its own and inside a raise, settle and restore transaction,
and expects both to revert.

Residual: a collection can still stop an accepted sale by raising its rate.
Nobody is paid less than they agreed to; the seller can accept again at the
new rate, or let the offer close.

### A hostile collection contract

A collection controls `royaltyInfo`, `transferFrom` and `tokenURI`.

Against it: escrow and release are guarded against reentrancy, and the market
holds no value beyond the token itself and any deferred fees. `list` checks the
market owns the token after `transferFrom`, and the market does not accept
`safeTransferFrom` from outside `list`, so no token can arrive without a
listing that can return it. The same check runs on the way out: `settle`
confirms the offer's recipient owns the token and `cancelListing` that the
seller does, or they revert with `NotDelivered`. A collection that reports a
transfer it did not make cannot keep a buyer's notes or close a listing on a
token still in escrow. A recipient that passes the token on from
`onERC721Received` fails the check too, so an offer should name the wallet
that keeps the token. Royalties above 100% are rejected, and a rate raised
after acceptance stops the sale rather than taking the seller's share.
Metadata is fetched server side, never by the browser, and an inline SVG has
its scripting removed before a page renders it. The metadata fetcher refuses
private and loopback addresses.

Residual: a collection can still make its own royalty unpayable, by pointing it
at an address with no keys. Sales in that collection stop until it is fixed,
and for good if the collection can no longer move its royalty. That is visible
on the collection page.

### Hostile payloads in the event log

Anyone can emit a note or offer payload, and every wallet downloads every note
payload to find its own. Against it: opening a payload never throws; a
low-order x25519 key, a bad tag or a failed decryption all read as "not mine",
so one hostile payload cannot stop a wallet's scan. The pool and the market
refuse any note or offer payload longer than 160 bytes (`MAX_PAYLOAD_BYTES`;
the SDK's are 118 and 114), so nobody can make a scan download arbitrarily
large blobs.

### The indexer is compromised

The indexer holds only what the chain shows everyone, so there is no key, note
or price in it to steal. What a compromised indexer can do is lie: hide or
invent notes, listings and offers, or pair one offer's id with another offer's
payload.

Against it: the contracts check everything that decides where value goes
against their own state. A proof must cite a root the pool has had, so a tree
built from invented leaves gives a proof the pool refuses. Settlement takes the
offer, the royalty and every key the proof is checked against from the chain,
not from the caller, and `accept` takes the price commitment the seller opened,
so a seller shown one offer's payload under another offer's id cannot be made
to accept the other offer. On top of that, the web app confirms a listing and
an offer against the market before it asks for a signature, reads keys and the
royalty from the chain, and before proving checks with `isKnownRoot` that its
tree's root is one the pool has had, rebuilding the tree from the pool's own
logs when it is not. It falls back to reading the chain when the indexer is
missing or behind.

Residual: a lying indexer can still show a wrong balance or history, and hide
offers, listings or sales from the people they concern, until the app reads the
chain directly. It cannot move value on its own; a user who signs something
the chain does not back is protected only by the checks above.

### Key loss

Keys come from one wallet signature, so a wallet that signs deterministically
reproduces them. Some wallets do not.

Against it: the signature is normalised (low s, `v` in {27, 28}, 64-byte form
expanded) before it is hashed, so encoding differences between wallets do not
change the keys. The app compares derived keys against what is registered on
chain and offers an import path on a mismatch: an encrypted backup of the seed
(Argon2id at 64 MiB and three passes, then XChaCha20-Poly1305 over the seed
with the parameters as associated data). Restoring that backup on another
device is how an owner reads and spends their notes there.

Residual: losing both the wallet and the backup means losing the notes. There
is no recovery, by design.

### Phishing

Backlit keys come from one wallet signature, and whoever holds that signature
can derive the spending key and spend every note the owner has. Any site can
ask a wallet to sign the same text Backlit asks for.

Against it: the text is a Sign-In with Ethereum (EIP-4361) message naming the
site it belongs to (`backlit.ink` on mainnet). Wallets that understand the
format, MetaMask among them, compare that domain with the site actually asking
and warn when they differ. The message also says what it is: "This signature
is your Backlit key. Anyone who has it can spend your Backlit balance."

Residual: a wallet that does not check the domain, or a user who signs past
its warning, hands the asking site their Backlit balance. A signature cannot
be revoked; the only remedy is to withdraw the notes, or send them to another
wallet's keys, before the other side spends them.

## What Backlit does not defend against

- **A small anonymity set.** Early on, few notes exist. Timing and amounts can
  narrow a guess. The app steers deposits and withdrawals to round numbers, and
  the docs say this plainly.
- **Anyone watching the buyer's screen.** The price is on the buyer's and the
  seller's devices in plain text, because they both need to read it.
- **The NFT's new owner staying private.** It is public, deliberately.
- **A collection lying about its own royalty terms.** Backlit pays what the
  collection says it charges.
- **What the page's hosts learn.** The site's host sees visits like any
  website. Building the first proof downloads Aztec's public proving parameters
  (the universal setup) from Aztec's CDN, so that host sees an address that is
  about to prove, never the proof's contents. Token images load from wherever a
  collection's metadata points, so that host sees who views which token.

## Privileged functions, in full

`BacklitPool.raiseCap` and `BacklitPool.setDepositsPaused`, both guardian only.
`BacklitMarket.setFeeWei` (capped at 0.01 ETH) and
`BacklitMarket.setFeeRecipient`, both guardian only. `BacklitPool.initMarket`,
deployer, once, then locked. `BacklitMarket.forwardFees` is callable by anyone
and can only pay the current fee recipient.

On chain 4663 the deploy script refuses to run unless WETH is the canonical
`0x0Bd7...AcAD73`, the guardian, the fee recipient and the deposit cap are set
explicitly, neither address is the deployer, the guardian answers as a Safe
with at least one owner and a threshold of at least one, and fixtures are off.
It checks the pool and market point at each other before it writes the
deployment record.

`BacklitGenesis`, the genesis collection, has an owner (a Safe on 4663) that
can move the metadata and the royalty receiver until `freeze`, and can
nominate a new owner, who takes over only by accepting. On 4663 its deploy
script refuses an owner that is not a Safe or is the deployer, and refuses to
deploy until the royalty receiver has keys on the market in the deployment
record, because no Pane can be listed before then.

There is nothing else. No pause on withdrawals, no upgrade, no proxy, no way to
move a note or a token that is not a proof or the owner's own transaction.
