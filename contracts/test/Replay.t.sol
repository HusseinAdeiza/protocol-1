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

/// @notice Replays the real proofs from `ops/scripts/generate-proof-fixtures.ts`
/// through the real verifiers and the real pool and market. The fixtures pin
/// the addresses and deposits, so this rebuilds the exact pool id, listing,
/// offer and root each proof was made for. Tampering with anything the proof
/// is bound to must then fail, and the untouched call must still land.
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

    // ---------------------------------------------------------------- settle

    function _settleScene() internal returns (string memory json, bytes32 offerId) {
        json = vm.readFile("test/fixtures/settle-proof.json");
        _scene(json);
        assertEq(pool.currentRoot(), json.readBytes32(".root"), "root drifted");

        address seller = json.readAddress(".seller.wallet");
        address buyer = json.readAddress(".buyer.wallet");

        vm.startPrank(seller);
        uint256 tokenId = collection.mint(seller);
        collection.approve(address(market), tokenId);
        bytes32 listingId = market.list(address(collection), tokenId);
        vm.stopPrank();
        assertEq(listingId, json.readBytes32(".listingId"), "listing id drifted");

        offerId = _offer(json, listingId, buyer);
        assertEq(offerId, json.readBytes32(".offerId"), "offer id drifted");
    }

    function _offer(string memory json, bytes32 listingId, address buyer) internal returns (bytes32 offerId) {
        vm.prank(buyer);
        offerId = market.offer(
            listingId,
            json.readBytes32(".priceCommitment"),
            buyer,
            json.readBytes(".offerPayload"),
            uint64(block.timestamp + 7 days)
        );
        vm.prank(json.readAddress(".seller.wallet"));
        market.accept(offerId);
    }

    function _settlePublic(string memory json) internal pure returns (BacklitMarket.SettlePublic memory p) {
        bytes32[] memory nullifiers = json.readBytes32Array(".nullifiers");
        p = BacklitMarket.SettlePublic({
            root: json.readBytes32(".root"),
            nullifiers: [nullifiers[0], nullifiers[1]],
            sellerCommitment: json.readBytes32(".sellerCommitment"),
            creatorCommitment: json.readBytes32(".creatorCommitment"),
            changeCommitment: json.readBytes32(".changeCommitment")
        });
    }

    function _settlePayloads(string memory json) internal pure returns (bytes[3] memory out) {
        bytes[] memory payloads = json.readBytesArray(".payloads");
        out = [payloads[0], payloads[1], payloads[2]];
    }

    function test_aRealSettlementLands() public {
        (string memory json, bytes32 offerId) = _settleScene();

        market.settle{value: FEE}(offerId, json.readBytes(".proof"), _settlePublic(json), _settlePayloads(json));

        assertEq(IERC721(address(collection)).ownerOf(1), json.readAddress(".buyer.wallet"));
        assertEq(feeRecipient.balance, FEE);
        assertEq(pool.leafCount(), 7, "four deposits and three settlement notes");
    }

    function test_aSettleProofCannotBeReplayedAgainstAnotherOffer() public {
        (string memory json, bytes32 offerId) = _settleScene();

        // Same listing, same buyer, same price commitment: only the offer differs.
        bytes32 other = _offer(json, json.readBytes32(".listingId"), json.readAddress(".buyer.wallet"));
        assertTrue(other != offerId);

        bytes memory proof = json.readBytes(".proof");
        BacklitMarket.SettlePublic memory p = _settlePublic(json);
        bytes[3] memory payloads = _settlePayloads(json);

        vm.expectRevert();
        market.settle{value: FEE}(other, proof, p, payloads);

        market.settle{value: FEE}(offerId, proof, p, payloads);
    }

    function test_aSettleProofCannotCarrySwappedPayloads() public {
        (string memory json, bytes32 offerId) = _settleScene();

        bytes memory proof = json.readBytes(".proof");
        BacklitMarket.SettlePublic memory p = _settlePublic(json);
        bytes[3] memory payloads = _settlePayloads(json);
        bytes[3] memory swapped = [payloads[1], payloads[0], payloads[2]];
        bytes[3] memory garbage = [bytes(hex"00"), payloads[1], payloads[2]];

        vm.expectRevert();
        market.settle{value: FEE}(offerId, proof, p, swapped);
        vm.expectRevert();
        market.settle{value: FEE}(offerId, proof, p, garbage);

        market.settle{value: FEE}(offerId, proof, p, payloads);
    }

    // ----------------------------------------------------------------- spend

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
