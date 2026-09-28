// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {BacklitMarket} from "../src/BacklitMarket.sol";
import {BacklitPool} from "../src/BacklitPool.sol";
import {SettleVerifier} from "../src/verifiers/SettleVerifier.sol";
import {SpendVerifier} from "../src/verifiers/SpendVerifier.sol";

import {TestCollection} from "./mocks/TestCollection.sol";

/// @notice Replays the proofs from `ops/scripts/generate-proof-fixtures.ts`
/// through the real verifiers, pool and market. The fixtures pin the addresses
/// and deposits, so this rebuilds the exact pool id, listing, offer and root
/// each proof was made for. Tampering with anything a proof is bound to must
/// then fail, and the untouched call must still land. The settle fixture also
/// carries a proof for the same offer at a 100% royalty: valid, and exactly
/// what a collection owner who raised the rate after acceptance would submit.
contract ReplayTest is Test {
    using stdJson for string;

    uint256 internal constant FEE = 0.0002 ether;

    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal depositor = makeAddr("depositor");

    BacklitPool internal pool;
    BacklitMarket internal market;
    TestCollection internal collection;

    function _scene(string memory json) internal {
        assertEq(block.chainid, json.readUint(".chainId"), "fixtures were made for another chain");

        address weth = json.readAddress(".weth");
        deployCodeTo("TestnetWETH.sol:TestnetWETH", weth);

        deployCodeTo(
            "BacklitPool.sol:BacklitPool",
            abi.encode(weth, address(new SpendVerifier()), guardian, 100 ether),
            json.readAddress(".pool")
        );
        pool = BacklitPool(payable(json.readAddress(".pool")));
        assertEq(pool.poolId(), json.readBytes32(".poolId"), "pool id drifted");

        deployCodeTo(
            "BacklitMarket.sol:BacklitMarket",
            abi.encode(address(pool), address(new SettleVerifier()), feeRecipient, FEE, guardian),
            json.readAddress(".market")
        );
        market = BacklitMarket(json.readAddress(".market"));
        pool.initMarket(address(market));

        deployCodeTo(
            "TestCollection.sol:TestCollection",
            abi.encode("Panes", "PANE", json.readAddress(".creator.wallet"), uint96(json.readUint(".royaltyBps"))),
            json.readAddress(".collection")
        );
        collection = TestCollection(json.readAddress(".collection"));

        uint256[] memory amounts = json.readUintArray(".depositAmounts");
        bytes32[] memory owners = json.readBytes32Array(".depositOwners");
        bytes32[] memory salts = json.readBytes32Array(".depositSalts");
        bytes[] memory payloads = json.readBytesArray(".depositPayloads");
        for (uint256 i = 0; i < amounts.length; i++) {
            vm.deal(depositor, amounts[i]);
            vm.prank(depositor);
            pool.depositETH{value: amounts[i]}(owners[i], salts[i], payloads[i]);
        }

        _register(json, ".seller");
        _register(json, ".buyer");
        _register(json, ".creator");
    }

    function _register(string memory json, string memory who) internal {
        vm.prank(json.readAddress(string.concat(who, ".wallet")));
        market.registerKeys(
            json.readBytes32(string.concat(who, ".ownerPk")), json.readBytes32(string.concat(who, ".viewingPk"))
        );
    }

    /// Deposits, keys, listing #1 and the fixture's offer on it, not yet accepted.
    function _offerScene() internal returns (string memory json, bytes32 offerId) {
        json = vm.readFile("test/fixtures/settle-proof.json");
        _scene(json);
        assertEq(pool.currentRoot(), json.readBytes32(".root"), "root drifted");

        address seller = json.readAddress(".seller.wallet");

        vm.startPrank(seller);
        uint256 tokenId = collection.mint(seller);
        collection.approve(address(market), tokenId);
        bytes32 listingId = market.list(address(collection), tokenId);
        vm.stopPrank();
        assertEq(listingId, json.readBytes32(".listingId"), "listing id drifted");

        offerId = _offer(json, listingId);
        assertEq(offerId, json.readBytes32(".offerId"), "offer id drifted");
    }

    function _settleScene() internal returns (string memory json, bytes32 offerId) {
        (json, offerId) = _offerScene();
        _accept(json, offerId, json.readUint(".royaltyBps"));
    }

    function _offer(string memory json, bytes32 listingId) internal returns (bytes32 offerId) {
        address buyer = json.readAddress(".buyer.wallet");
        vm.prank(buyer);
        offerId = market.offer(
            listingId,
            json.readBytes32(".priceCommitment"),
            buyer,
            json.readBytes(".offerPayload"),
            uint64(block.timestamp + 7 days)
        );
    }

    function _accept(string memory json, bytes32 offerId, uint256 maxRoyaltyBps) internal {
        vm.prank(json.readAddress(".seller.wallet"));
        market.accept(offerId, json.readBytes32(".priceCommitment"), maxRoyaltyBps);
    }

    /// The proof at the fixture's own rate under "", the one at 100% under ".raised".
    function _settleCall(string memory json, string memory key)
        internal
        pure
        returns (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads)
    {
        bytes32[] memory nullifiers = json.readBytes32Array(string.concat(key, ".nullifiers"));
        bytes[] memory raw = json.readBytesArray(string.concat(key, ".payloads"));
        p = BacklitMarket.SettlePublic({
            root: json.readBytes32(string.concat(key, ".root")),
            nullifiers: [nullifiers[0], nullifiers[1]],
            sellerCommitment: json.readBytes32(string.concat(key, ".sellerCommitment")),
            creatorCommitment: json.readBytes32(string.concat(key, ".creatorCommitment")),
            changeCommitment: json.readBytes32(string.concat(key, ".changeCommitment"))
        });
        payloads = [raw[0], raw[1], raw[2]];
        proof = json.readBytes(string.concat(key, ".proof"));
    }

    function test_aRealSettlementLands() public {
        (string memory json, bytes32 offerId) = _settleScene();
        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json, "");

        market.settle{value: FEE}(offerId, proof, p, payloads);

        assertEq(IERC721(address(collection)).ownerOf(1), json.readAddress(".buyer.wallet"));
        assertEq(feeRecipient.balance, FEE);
        assertEq(pool.leafCount(), 7, "four deposits and three settlement notes");
    }

    function test_aSettleProofCannotBeReplayedAgainstAnotherOffer() public {
        (string memory json, bytes32 offerId) = _settleScene();

        // Same listing, same buyer, same price commitment: only the offer differs.
        bytes32 other = _offer(json, json.readBytes32(".listingId"));
        _accept(json, other, json.readUint(".royaltyBps"));
        assertTrue(other != offerId);

        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json, "");

        vm.expectRevert();
        market.settle{value: FEE}(other, proof, p, payloads);

        market.settle{value: FEE}(offerId, proof, p, payloads);
    }

    function test_aSettleProofCannotCarrySwappedPayloads() public {
        (string memory json, bytes32 offerId) = _settleScene();

        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json, "");
        bytes[3] memory swapped = [payloads[1], payloads[0], payloads[2]];
        bytes[3] memory garbage = [bytes(hex"00"), payloads[1], payloads[2]];

        vm.expectRevert();
        market.settle{value: FEE}(offerId, proof, p, swapped);
        vm.expectRevert();
        market.settle{value: FEE}(offerId, proof, p, garbage);

        market.settle{value: FEE}(offerId, proof, p, payloads);
    }

    /// The seller accepted 5%; the collection's owner raises the rate to 100%.
    /// The proof at 100% would leave the seller an empty note and the royalty
    /// receiver the whole price. The market refuses it, and the honest proof
    /// too, until the rate is back where the seller accepted it.
    function test_aRoyaltyRaisedAfterAcceptanceCannotTakeTheSale() public {
        (string memory json, bytes32 offerId) = _settleScene();
        address creator = json.readAddress(".creator.wallet");
        assertEq(json.readUint(".raised.sellerAmount"), 0, "the raised proof pays the seller nothing");

        collection.setRoyalty(creator, 10_000);
        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json, ".raised");
        // Valid and bound to this offer: only the pinned rate stands in its way.
        bytes32[] memory inputs = json.readBytes32Array(".raised.publicInputs");
        assertTrue(market.settleVerifier().verify(proof, inputs), "the raised proof is invalid");
        assertEq(inputs[13], market.settleBinding(offerId, payloads), "bound to another offer");
        vm.expectRevert(BacklitMarket.RoyaltyRaised.selector);
        market.settle{value: FEE}(offerId, proof, p, payloads);

        (proof, p, payloads) = _settleCall(json, "");
        vm.expectRevert(BacklitMarket.RoyaltyRaised.selector);
        market.settle{value: FEE}(offerId, proof, p, payloads);
        assertEq(IERC721(address(collection)).ownerOf(1), address(market), "the token left escrow");
        assertFalse(pool.isSpent(p.nullifiers[0]) || pool.isSpent(p.nullifiers[1]), "the notes were spent");

        collection.setRoyalty(creator, uint96(json.readUint(".royaltyBps")));
        market.settle{value: FEE}(offerId, proof, p, payloads);
        assertEq(market.receiptOf(offerId).royaltyBps, json.readUint(".royaltyBps"));
    }

    /// The same raise, settlement and restore in one transaction, as a
    /// collection owner who also holds the buyer's keys would send it, so the
    /// collection reports 5% again afterwards. The settlement reverts, and the
    /// whole transaction with it.
    function test_aRaiseSettleAndRestoreInOneTransactionReverts() public {
        (string memory json, bytes32 offerId) = _settleScene();
        address creator = json.readAddress(".creator.wallet");
        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json, ".raised");
        RaiseSettleRestore bundle = new RaiseSettleRestore();
        vm.deal(address(bundle), FEE);

        vm.expectRevert(BacklitMarket.RoyaltyRaised.selector);
        bundle.run(collection, market, creator, offerId, proof, p, payloads, FEE);

        assertEq(IERC721(address(collection)).ownerOf(1), address(market), "the token left escrow");
        assertFalse(market.offerOf(offerId).settled);
        (, uint256 bps) = market.royaltyOf(address(collection), 1);
        assertEq(bps, json.readUint(".royaltyBps"));
    }

    /// A seller who accepted at 100% is held to nothing worse. The collection
    /// lowering its rate to 5% leaves them more, and the proof built at the
    /// live rate lands.
    function test_aRoyaltyLoweredAfterAcceptanceStillSettles() public {
        (string memory json, bytes32 offerId) = _offerScene();
        address creator = json.readAddress(".creator.wallet");

        collection.setRoyalty(creator, 10_000);
        _accept(json, offerId, 10_000);
        assertEq(market.offerOf(offerId).acceptedRoyaltyBps, 10_000);

        collection.setRoyalty(creator, uint96(json.readUint(".royaltyBps")));
        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json, "");
        market.settle{value: FEE}(offerId, proof, p, payloads);

        assertEq(IERC721(address(collection)).ownerOf(1), json.readAddress(".buyer.wallet"));
        assertEq(market.receiptOf(offerId).royaltyBps, json.readUint(".royaltyBps"));
    }

    function _spendScene()
        internal
        returns (string memory json, BacklitPool.SpendPublic memory p, bytes[2] memory payloads)
    {
        json = vm.readFile("test/fixtures/spend-proof.json");
        _scene(json);

        bytes32[] memory nullifiers = json.readBytes32Array(".nullifiers");
        bytes32[] memory outputs = json.readBytes32Array(".outputs");
        p = BacklitPool.SpendPublic({
            root: json.readBytes32(".root"),
            nullifiers: [nullifiers[0], nullifiers[1]],
            outputs: [outputs[0], outputs[1]],
            withdrawAmount: json.readUint(".withdrawAmount"),
            recipient: json.readAddress(".recipient"),
            unwrap: json.readBool(".unwrap")
        });
        bytes[] memory raw = json.readBytesArray(".payloads");
        payloads = [raw[0], raw[1]];
    }

    function test_aRealSpendLands() public {
        (string memory json, BacklitPool.SpendPublic memory p, bytes[2] memory payloads) = _spendScene();

        pool.spend(json.readBytes(".proof"), p, payloads);

        assertEq(p.recipient.balance, p.withdrawAmount, "paid out as ETH");
        assertEq(pool.leafCount(), 6);
    }

    function test_aSpendProofCannotFlipTheUnwrapFlag() public {
        (string memory json, BacklitPool.SpendPublic memory p, bytes[2] memory payloads) = _spendScene();
        bytes memory proof = json.readBytes(".proof");

        p.unwrap = !p.unwrap;
        vm.expectRevert();
        pool.spend(proof, p, payloads);

        p.unwrap = !p.unwrap;
        pool.spend(proof, p, payloads);
    }

    function test_aSpendProofCannotCarrySwappedPayloads() public {
        (string memory json, BacklitPool.SpendPublic memory p, bytes[2] memory payloads) = _spendScene();
        bytes memory proof = json.readBytes(".proof");

        vm.expectRevert();
        pool.spend(proof, p, [payloads[1], payloads[0]]);

        pool.spend(proof, p, payloads);
    }

    function test_aSpendProofCannotBeRedirected() public {
        (string memory json, BacklitPool.SpendPublic memory p, bytes[2] memory payloads) = _spendScene();
        bytes memory proof = json.readBytes(".proof");
        address intended = p.recipient;

        p.recipient = makeAddr("thief");
        vm.expectRevert();
        pool.spend(proof, p, payloads);

        p.recipient = intended;
        pool.spend(proof, p, payloads);
    }
}

/// Raises the rate, settles and puts the rate back, in one call. The test
/// collection lets anyone set its royalty; on a real one this is the owner.
contract RaiseSettleRestore {
    function run(
        TestCollection collection,
        BacklitMarket market,
        address receiver,
        bytes32 offerId,
        bytes calldata proof,
        BacklitMarket.SettlePublic calldata p,
        bytes[3] calldata payloads,
        uint256 fee
    ) external {
        (, uint256 bps) = market.royaltyOf(address(collection), 1);
        collection.setRoyalty(receiver, 10_000);
        market.settle{value: fee}(offerId, proof, p, payloads);
        collection.setRoyalty(receiver, uint96(bps));
    }
}
