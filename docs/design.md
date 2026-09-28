# Design notes

Choices made while building the protocol, and what each one rests on.

## Poseidon comes from a pinned library, not the Noir standard library

Poseidon left the Noir standard library before 1.0.0-beta.22, so the circuits
depend on `noir-lang/poseidon v0.3.0`. It is the same circomlib-compatible
BN254 Poseidon the design specifies, and the shared vectors check that the
three implementations agree.

## The Merkle path is implemented here rather than imported

`zk-kit.noir`'s `binary-merkle-root` was published against a much older Noir,
so `circuits/lib` walks the LeanIMT path itself in about fifteen lines.
`contracts/test/Parity.t.sol` and `sdk/test/parity.test.ts` hold it to the
same roots as the audited Solidity `InternalLeanIMT` and the JavaScript
`@zk-kit/lean-imt`. The on-chain tree is still the audited zk-kit one.

## `asset` is a public input rather than a constant

The original design's circuit sketch fixed WETH inside the circuit, which would mean a
different circuit and verifier per chain. Making `asset` a public input costs
one field element, and each contract checks it equals its own WETH, so one
circuit and one verifier serve every chain.

## Unused public inputs are bound by a hash

`poolId`, spend's `recipient` and settle's `binding` carry no constraint of
their own. A compiler is free to drop a witness nothing reads, which would
silently remove them from the proof. `bind()` hashes the pair and asserts the
result is non-zero, which cannot be optimised away, for about 240 gates.

## The bound-only slots carry a hash of the call

Because those slots are only bound, the contracts can put anything in them
without a circuit change. They put `keccak256(offerId, keccak256(payloads))`
in settle's and `keccak256(recipient, unwrap, keccak256(payloads))` in spend's,
reduced into the field. That covers the unwrap flag and the payloads, which
were outside the proof before, and the spend verifier did not change. The SDK
computes the same values with `settleBinding` and `spendBinding`, and the
vectors hold viem's `abi.encode` of `bytes[N]` to solc's.

## The seller's salt is derived, not chosen

The settle circuit sets the seller's salt to `poseidon2(priceBlinding,
"backlit/seller-salt")`. The seller already has the blinding from the offer,
so their note can be rebuilt from the offer alone, and a buyer cannot strand it
behind an unreadable payload. The creator never learns the blinding, so the
same trick does not work for the royalty note; that residual is in the threat
model.

## Every root stays valid

The original design asked for the last 64 roots. A ring that size lets a burst of
deposits invalidate a proof that is already in flight, and buys nothing, since
nullifiers already stop double spends. The pool keeps a mapping of every root
it has produced, which is one extra storage write per insert.

## A fee that cannot be sent is held, not reverted

The original design had the fee send revert on failure. That makes the operator's
router a switch that halts every sale. A failed send is now held as
`feesOwed` and anyone can forward it later; the `msg.value == feeWei` check is
unchanged.

## The deposit cap counts deposits, not the balance

`weth.balanceOf(pool)` includes WETH anyone can send, so a donation could fill
the cap and block deposits. The cap now compares deposited minus withdrawn.

## The market does not implement `onERC721Received`

`list` pulls with `transferFrom` and never needed it. Implementing it only let
a `safeTransferFrom` from outside `list` park a token with no listing and no
way back. `list` also checks `ownerOf` after the transfer, so a collection that
reports a transfer it did not make cannot create a listing.

## Mainnet deploys are guarded in the script

The contracts are immutable, so a wrong constructor argument on 4663 is
permanent. `Deploy.s.sol` refuses mainnet unless WETH is canonical, the
guardian, the fee recipient and the deposit cap are explicit, neither address
is the deployer, the guardian answers as a Safe that has been set up (at least
one owner from `getOwners`, a threshold of at least one from `getThreshold`),
and fixtures are off. The cap used to fall back to 20 ETH without a word; it
bounds what a circuit bug could take, so on mainnet it is now a number the
operator types. The Safe check uses low-level calls, so an ordinary account or
some other contract fails with the script's message rather than a bare revert.
`contracts/test/Deploy.t.sol` runs each refusal.

## A collection that charges no royalty still creates three notes

The settle circuit has a fixed shape. When the rate is zero the third note is
worth nothing, and the market addresses it to the seller's key so it stays
spendable. `list` does not ask for the receiver's keys when the rate is zero,
because there is nothing to pay.

## Offers are readable by both sides, with no stored state

A buyer needs the price and the blinding factor back at settlement, and the
seller needs them to decide. The buyer keeps no record of them: the ephemeral
key and the blinding of the offer envelope are derived with HKDF from the
buyer's own spending key, the listing id and a random 16-byte `r`, with
separate info strings. `r` travels in the clear in the payload and is
authenticated as associated data. The seller opens it with their viewing key;
the buyer reopens it by rederiving, with no search. A counter nonce would
collide when a buyer bids twice from two devices; a random one does not. Both
sides only accept an opening that matches the price commitment on chain.

## The key backup stores the seed

`exportBackup` encrypts the 32-byte seed rather than the derived keys, so one
format rebuilds every key through `keysFromSeed`, including any added later.
Argon2id runs at 64 MiB, three passes, one lane; `importBackup` refuses weaker
or absurdly heavy parameters before doing any work, and the parameters and
salt are the cipher's associated data.

## Contract tests use a stand-in verifier, plus one pinned replay

Real proofs are bound to a pool address and an offer id, which are only known
after deployment, so the pool and market tests use a stand-in verifier.
`Replay.t.sol` runs real proofs end to end: the fixture generator fixes the
addresses and deposits, and the test deploys to those addresses with
`deployCodeTo`, so the proofs verify through the pool and market themselves.
`Verifiers.t.sol` replays the same proofs against the verifiers directly, and
`test/fork/MainnetFork.t.sol` runs real proofs through the contracts on a fork
of mainnet. `EchoVerifier`
reverts with the public inputs it was given, so the tests can assert on
exactly what each contract builds. The settle fixture also holds a second
valid proof for its offer, at a 100% royalty, which `Replay.t.sol` uses to
show that a rate raised after acceptance cannot take a sale.
`Verifiers.t.sol` changes every public input and every word of both proofs,
one at a time, and expects each change to fail.

## The fee is sent with a gas cap and nothing copied back

Solidity's `.call` copies whatever the callee returns, so a fee recipient could
return more than settlement had gas left to copy and stop every sale at any
gas limit; holding the fee only covered a recipient that reverted cheaply.
`settle` now sends with a bare `call` that copies nothing and passes 100,000
gas: a Safe needs about 7,000, a contract wrapping the fee into aeWETH about
40,000. Any failure, a starved send included, is held as before.
`forwardFees` copies nothing either but passes all its gas, so a recipient too
heavy for the cap still gets paid.

## Settlement checks the token arrived

`list` already checked `ownerOf` after pulling a token in. `settle` and
`cancelListing` now check it after sending one out, and revert with
`NotDelivered`. Otherwise a collection that turned hollow after listing could
take the buyer's notes and leave the token behind a closed listing. The price
is that an `nftRecipient` which forwards the token from `onERC721Received`
cannot be used.

## Withdrawals to WETH and the market are refused

Zero and the pool were already refused. An unwrapped payout to aeWETH is
credited back to the pool outside every note, WETH sent to its own contract is
stuck, and the market cannot move WETH. Reading `market` costs one storage
read per withdrawal.

## Receipts do not store `block.number`

On an Arbitrum chain it is the parent chain's block, not a usable reference,
and nothing read it; the indexer takes the block from the `Settled` log. The
receipt count is now the length of the settled list rather than a second
counter written on every sale.

## Genesis ownership moves in two steps

`transferOwnership` only nominates; the nominee takes over with
`acceptOwnership`, and nominating zero withdraws a nomination. Marketplaces
key collection admin to `owner()`, so a mistyped owner would otherwise be
permanent. The events are OpenZeppelin's `OwnershipTransferStarted` and
`OwnershipTransferred`, which indexers already know, and `setURIs` also emits
ERC-7572's `ContractURIUpdated` for the collection metadata.

## The genesis deploy checks the royalty receiver's keys

Every Pane pays a royalty, so a market refuses to list or settle one until the
receiver has keys with it. On 4663 `DeployGenesis.s.sol` requires `MARKET`,
requires it to be the market in `deployments/4663.json` and requires `hasKeys`
for the receiver there. Keys live in one market, so a registration with an
earlier deployment proves nothing. `contracts/test/DeployGenesis.t.sol` runs
each refusal.

## The mainnet fork test follows the deployment record

`contracts/test/fork/MainnetFork.t.sol` reads every address from
`deployments/4663.json`. Its real proofs are bound to one pool and market, so
the tests that use them skip, naming the command that recuts them, whenever
the record names another deployment. Tests for fixes the first 4663 deployment
lacks, the pinned royalty among them, skip against a market that does not
answer `MAX_PAYLOAD_BYTES`.
`FORK_LOCAL_BUILD=true` puts this checkout's pool and market at the recorded
addresses, so a build meets mainnet state and the real proofs before it is
deployed.

## Acceptance pins the royalty rate

`settle` reads the collection's rate live and `accept` recorded only a time,
so a collection's owner could raise the rate after a seller accepted, up to
100%, and settle a proof built at that rate. The seller's share went to the
royalty receiver, and an owner who also held the buyer's keys could raise,
settle and restore the rate in one transaction. `accept` now takes the price
commitment the seller opened and the highest rate they agree to, refuses an
offer with another commitment or a rate above that ceiling, and pins the rate
it read as `acceptedRoyaltyBps`. `settle` refuses a live rate above the pin
with `RoyaltyRaised` and otherwise settles at the live rate. A lower rate only
leaves the seller more. Settling at the live rate also keeps the receipt's
rate the collection's own, and needs no change to the circuit or to how the
app builds a proof. `unaccept` clears the pin. The commitment check means an
index that pairs one offer's id with another offer's payload cannot get the
wrong offer accepted. The field is appended to `Offer`, so the `offers` getter
keeps its positions, and it shares `acceptedAt`'s storage slot.

## Payloads are capped at 160 bytes

Every wallet that scans the pool downloads every note payload, and the
indexer and sellers download every offer payload. Nothing bounded them, so
publishing megabytes of junk cost only calldata. The pool refuses a note
payload over `MAX_PAYLOAD_BYTES` in `_insert`, which every note passes
through: deposits, spends and the three outputs of a settlement. The market
refuses an offer payload over its own `MAX_PAYLOAD_BYTES`. Both are 160. The
SDK's payloads are 118 and 114 bytes; the difference leaves room for a
slightly longer envelope without a redeploy. `sdk/test/envelope.test.ts` holds
the SDK's sizes under the cap.

## The key message is a Sign-In with Ethereum message

Keys come from one signature, and the text signed used to be the same on every
site. EIP-712 cannot tie a signature to a website, so the message moved to
Sign-In with Ethereum (EIP-4361), which names its site: wallets that
understand it compare that domain with the site asking and warn on a mismatch.
Its statement says what the signature is. The nonce and issue time are fixed
rather than fresh, because the signature has to come out the same every time
for the keys to; the wallet still signs it with its own deterministic
signature. The site comes from the chain (`KEY_SITES`: backlit.ink,
testnet.backlit.ink, localhost:3080), so each chain's keys belong to its own
site. Changing the message changes every key, which costs nothing before the
redeploy: keys are registered per market, and everyone registers again with the
new one. `sdk/test/keys.test.ts` pins the message, its digest (checked against
`cast hash-message`) and the keys it gives for a fixed wallet.
