// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {BacklitMarket} from "../src/BacklitMarket.sol";
import {BacklitPool} from "../src/BacklitPool.sol";
import {IVerifier} from "../src/interfaces/IVerifier.sol";
import {SNARK_SCALAR_FIELD} from "../src/libs/Field.sol";

import {BacklitTest} from "./Base.t.sol";
import {EchoVerifier} from "./mocks/EchoVerifier.sol";
import {HollowCollection} from "./mocks/HollowCollection.sol";
import {PlainCollection} from "./mocks/PlainCollection.sol";
import {RejectingRecipient} from "./mocks/RejectingRecipient.sol";
import {TestCollection} from "./mocks/TestCollection.sol";

contract MarketTest is BacklitTest {
    bytes32 internal constant PRICE_COMMITMENT = bytes32(uint256(555));

    function _fund() internal returns (bytes32 root) {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));
        return pool.currentRoot();
    }

    // ----------------------------------------------------------------- keys

    function test_keysAreReadableAndReplaceable() public {
        (bytes32 ownerPk, bytes32 viewingPk) = market.keysOf(seller);
        assertEq(ownerPk, SELLER_PK);
        assertEq(viewingPk, VIEWING_PK);
        assertTrue(market.hasKeys(seller));
        assertFalse(market.hasKeys(stranger));

        vm.prank(seller);
        market.registerKeys(bytes32(uint256(777)), bytes32(uint256(888)));
        (ownerPk,) = market.keysOf(seller);
        assertEq(ownerPk, bytes32(uint256(777)));
    }

    function test_keysCannotBeZero() public {
        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.ZeroAddress.selector);
        market.registerKeys(bytes32(0), VIEWING_PK);
    }

    // -------------------------------------------------------------- listing

    function test_listEscrowsTheToken() public {
        bytes32 listingId = mintAndList(1);
        assertEq(IERC721(address(collection)).ownerOf(1), address(market));

        BacklitMarket.Listing memory listing = market.listingOf(listingId);
        assertEq(listing.collection, address(collection));
        assertEq(listing.tokenId, 1);
        assertEq(listing.seller, seller);
        assertTrue(listing.active);
    }

    function test_listRefusesATransferThatDidNotHappen() public {
        HollowCollection hollow = new HollowCollection(creator, uint96(ROYALTY_BPS));
        vm.startPrank(seller);
        hollow.mint(seller);
        vm.expectRevert(BacklitMarket.NotEscrowed.selector);
        market.list(address(hollow), 1);
        vm.stopPrank();
    }

    /// @dev Only `list` may put a token in escrow. A safe transfer from outside
    /// would create no listing and could never be returned.
    function test_theMarketRefusesSafeTransfers() public {
        vm.startPrank(seller);
        collection.mint(seller);
        vm.expectRevert();
        collection.safeTransferFrom(seller, address(market), 1);
        vm.stopPrank();
        assertEq(IERC721(address(collection)).ownerOf(1), seller);
    }

    function test_listRefusesACollectionWithoutRoyaltyTerms() public {
        PlainCollection plain = new PlainCollection();
        vm.startPrank(seller);
        plain.mint(seller);
        plain.approve(address(market), 1);
        vm.expectRevert(BacklitMarket.CollectionNotSupported.selector);
        market.list(address(plain), 1);
        vm.stopPrank();
    }

    function test_listRefusesACreatorWithoutKeys() public {
        TestCollection orphan = new TestCollection("Orphan", "ORPH", stranger, 500);
        vm.startPrank(seller);
        orphan.mint(seller);
        orphan.approve(address(market), 1);
        vm.expectRevert(BacklitMarket.NoKeys.selector);
        market.list(address(orphan), 1);
        vm.stopPrank();
    }

    function test_listRefusesASellerWithoutKeys() public {
        vm.startPrank(stranger);
        collection.mint(stranger);
        collection.approve(address(market), 1);
        vm.expectRevert(BacklitMarket.NoKeys.selector);
        market.list(address(collection), 1);
        vm.stopPrank();
    }

    function test_cancelListingReturnsTheToken() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(seller);
        market.cancelListing(listingId);

        assertEq(IERC721(address(collection)).ownerOf(1), seller);
        assertFalse(market.listingOf(listingId).active);
    }

    function test_onlyTheSellerCancelsAListing() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NotTheSeller.selector);
        market.cancelListing(listingId);
    }

    function test_royaltyOfReadsTheCollection() public view {
        (address receiver, uint256 basisPoints) = market.royaltyOf(address(collection), 1);
        assertEq(receiver, creator);
        assertEq(basisPoints, ROYALTY_BPS);
    }

    // --------------------------------------------------------------- offers

    function test_offerStoresTheBuyersKeyAtTheTime() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        BacklitMarket.Offer memory offer = market.offerOf(offerId);
        assertEq(offer.buyer, buyer);
        assertEq(offer.buyerPk, BUYER_PK);
        assertEq(offer.priceCommitment, PRICE_COMMITMENT);
    }

    function test_offerNeedsKeys() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NoKeys.selector);
        market.offer(listingId, PRICE_COMMITMENT, stranger, hex"", uint64(block.timestamp + 1 days));
    }

    function test_offerNeedsAnExpiryInTheFuture() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(buyer);
        vm.expectRevert(BacklitMarket.OutOfRange.selector);
        market.offer(listingId, PRICE_COMMITMENT, buyer, hex"", uint64(block.timestamp));
    }

    function test_theBuyerCancelsTheirOwnOffer() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NotTheBuyer.selector);
        market.cancelOffer(offerId);

        vm.prank(buyer);
        market.cancelOffer(offerId);
        assertTrue(market.offerOf(offerId).cancelled);
    }

    function test_acceptAndUnaccept() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NotTheSeller.selector);
        market.accept(offerId);

        vm.prank(seller);
        market.accept(offerId);
        assertGt(market.offerOf(offerId).acceptedAt, 0);

        vm.prank(seller);
        market.unaccept(offerId);
        assertEq(market.offerOf(offerId).acceptedAt, 0);
    }

    function test_anExpiredOfferCanBeClosedByAnyone() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        vm.expectRevert(BacklitMarket.OfferNotExpired.selector);
        market.expireOffer(offerId);

        vm.warp(block.timestamp + 8 days);
        vm.prank(stranger);
        market.expireOffer(offerId);

        assertTrue(market.offerOf(offerId).cancelled);
    }

    function test_anAcceptedOfferExpiresAfterTheSettlementWindow() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);
        vm.prank(seller);
        market.accept(offerId);

        vm.warp(block.timestamp + market.ACCEPT_WINDOW() + 1);
        market.expireOffer(offerId);
        assertTrue(market.offerOf(offerId).cancelled);
    }

    // ------------------------------------------------------------ settling

    function _accepted() internal returns (bytes32 listingId, bytes32 offerId) {
        listingId = mintAndList(1);
        offerId = openOffer(listingId, PRICE_COMMITMENT);
        vm.prank(seller);
        market.accept(offerId);
    }

    function test_settleMovesTheNFTPaysTheFeeAndWritesAReceipt() public {
        bytes32 root = _fund();
        (bytes32 listingId, bytes32 offerId) = _accepted();

        uint256 feeBefore = feeRecipient.balance;

        vm.prank(stranger);
        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());

        assertEq(IERC721(address(collection)).ownerOf(1), buyer, "the NFT went to the offer's recipient");
        assertEq(feeRecipient.balance - feeBefore, FEE);
        assertEq(pool.leafCount(), 4, "one deposit plus three settlement notes");
        assertEq(market.receiptCount(), 1);

        BacklitMarket.Receipt memory receipt = market.receiptOf(offerId);
        assertEq(receipt.listingId, listingId);
        assertEq(receipt.collection, address(collection));
        assertEq(receipt.tokenId, 1);
        assertEq(receipt.seller, seller);
        assertEq(receipt.nftRecipient, buyer);
        assertEq(receipt.royaltyReceiver, creator);
        assertEq(receipt.royaltyBps, ROYALTY_BPS);
        assertEq(receipt.feeWei, FEE);
        assertEq(
            receipt.priceCommitment, PRICE_COMMITMENT, "the receipt carries the commitment, not the price"
        );
    }

    function test_settleNeedsAnAcceptedOffer() public {
        bytes32 root = _fund();
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        vm.expectRevert(BacklitMarket.NotAccepted.selector);
        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());
    }

    function test_settleNeedsTheExactFee() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        vm.expectRevert(BacklitMarket.FeeMismatch.selector);
        market.settle{value: FEE - 1}(offerId, hex"00", settlePublic(root), emptyPayloads());
    }

    function test_settleRejectsABadProof() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();
        BacklitMarket.SettlePublic memory p = settlePublic(root);
        settleVerifier.setAccepts(false);

        vm.expectRevert(BacklitMarket.BadProof.selector);
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
    }

    function test_anOfferCannotSettleTwice() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());

        BacklitMarket.SettlePublic memory again = settlePublic(root);
        vm.expectRevert(BacklitMarket.OfferClosed.selector);
        market.settle{value: FEE}(offerId, hex"00", again, emptyPayloads());
    }

    function test_settleFailsAfterTheSettlementWindow() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        vm.warp(block.timestamp + market.ACCEPT_WINDOW() + 1);
        BacklitMarket.SettlePublic memory p = settlePublic(root);

        vm.expectRevert(BacklitMarket.OfferClosed.selector);
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
    }

    function test_settleFailsIfTheCreatorDropsTheirKeys() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        // The collection points its royalty somewhere with no keys.
        collection.setRoyalty(stranger, uint96(ROYALTY_BPS));
        BacklitMarket.SettlePublic memory p = settlePublic(root);

        vm.expectRevert(BacklitMarket.NoKeys.selector);
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
    }

    function test_settleBuildsThePublicInputsTheCircuitExpects() public {
        BacklitMarket echoed = new BacklitMarket(
            pool, IVerifier(address(new EchoVerifier())), feeRecipient, FEE, guardian
        );

        vm.prank(seller);
        echoed.registerKeys(SELLER_PK, VIEWING_PK);
        vm.prank(buyer);
        echoed.registerKeys(BUYER_PK, VIEWING_PK);
        vm.prank(creator);
        echoed.registerKeys(CREATOR_PK, VIEWING_PK);

        vm.startPrank(seller);
        collection.mint(seller);
        collection.approve(address(echoed), 1);
        bytes32 listingId = echoed.list(address(collection), 1);
        vm.stopPrank();

        vm.prank(buyer);
        bytes32 offerId = echoed.offer(
            listingId, PRICE_COMMITMENT, buyer, hex"", uint64(block.timestamp + 1 days)
        );
        vm.prank(seller);
        echoed.accept(offerId);

        bytes32 root = _fund();
        BacklitMarket.SettlePublic memory p = settlePublic(root);

        try echoed.settle{value: FEE}(offerId, hex"00", p, emptyPayloads()) {
            revert("the echo verifier always reverts");
        } catch (bytes memory reason) {
            bytes32[] memory publicInputs = abi.decode(_stripSelector(reason), (bytes32[]));

            assertEq(publicInputs.length, 14, "settle takes fourteen public inputs");
            assertEq(publicInputs[0], pool.poolId());
            assertEq(publicInputs[1], bytes32(uint256(uint160(address(weth)))));
            assertEq(publicInputs[2], root);
            assertEq(publicInputs[3], p.nullifiers[0]);
            assertEq(publicInputs[4], p.nullifiers[1]);
            assertEq(publicInputs[5], p.sellerCommitment);
            assertEq(publicInputs[6], p.creatorCommitment);
            assertEq(publicInputs[7], p.changeCommitment);
            assertEq(publicInputs[8], PRICE_COMMITMENT);
            assertEq(publicInputs[9], bytes32(ROYALTY_BPS));
            assertEq(publicInputs[10], SELLER_PK);
            assertEq(publicInputs[11], CREATOR_PK);
            assertEq(publicInputs[12], BUYER_PK);
            bytes32 binding = keccak256(abi.encode(offerId, keccak256(abi.encode(emptyPayloads()))));
            assertEq(publicInputs[13], bytes32(uint256(binding) % SNARK_SCALAR_FIELD), "binding slot");
            assertTrue(publicInputs[13] != listingId);
        }
    }

    function test_theSettleBindingCoversTheOfferAndEveryPayload() public view {
        bytes[3] memory payloads = emptyPayloads();
        bytes32 honest = market.settleBinding(bytes32(uint256(1)), payloads);

        assertTrue(market.settleBinding(bytes32(uint256(2)), payloads) != honest, "offer");
        assertTrue(
            market.settleBinding(bytes32(uint256(1)), [payloads[1], payloads[0], payloads[2]]) != honest, "order"
        );
        assertTrue(
            market.settleBinding(bytes32(uint256(1)), [payloads[0], payloads[1], bytes(hex"06")]) != honest,
            "payload"
        );
        assertLt(uint256(honest), SNARK_SCALAR_FIELD);
    }

    function test_aFeeRecipientThatRefusesETHDoesNotBlockASale() public {
        RejectingRecipient router = new RejectingRecipient();
        vm.prank(guardian);
        market.setFeeRecipient(address(router));

        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        vm.expectEmit(true, false, false, true, address(market));
        emit BacklitMarket.FeeDeferred(address(router), FEE);
        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());

        assertEq(IERC721(address(collection)).ownerOf(1), buyer, "the sale went through");
        assertEq(market.feesOwed(), FEE);
        assertEq(address(market).balance, FEE);

        vm.expectRevert(BacklitMarket.FeeTransferFailed.selector);
        market.forwardFees();

        router.setRefusing(false);
        vm.prank(stranger);
        market.forwardFees();
        assertEq(address(router).balance, FEE);
        assertEq(market.feesOwed(), 0);
        assertEq(address(market).balance, 0);
    }

    function test_forwardingNothingIsANoOp() public {
        market.forwardFees();
        assertEq(market.feesOwed(), 0);
    }

    function test_aCollectionWithNoRoyaltyPaysTheThirdNoteToTheSeller() public {
        collection.setRoyalty(creator, 0);
        bytes32 root = _fund();

        BacklitMarket echoed = new BacklitMarket(
            pool, IVerifier(address(new EchoVerifier())), feeRecipient, FEE, guardian
        );
        vm.prank(seller);
        echoed.registerKeys(SELLER_PK, VIEWING_PK);
        vm.prank(buyer);
        echoed.registerKeys(BUYER_PK, VIEWING_PK);

        vm.startPrank(seller);
        collection.mint(seller);
        collection.approve(address(echoed), 1);
        bytes32 listingId = echoed.list(address(collection), 1);
        vm.stopPrank();

        vm.prank(buyer);
        bytes32 offerId = echoed.offer(
            listingId, PRICE_COMMITMENT, buyer, hex"", uint64(block.timestamp + 1 days)
        );
        vm.prank(seller);
        echoed.accept(offerId);

        BacklitMarket.SettlePublic memory zeroRoyalty = settlePublic(root);
        try echoed.settle{value: FEE}(offerId, hex"00", zeroRoyalty, emptyPayloads()) {
            revert("the echo verifier always reverts");
        } catch (bytes memory reason) {
            bytes32[] memory publicInputs = abi.decode(_stripSelector(reason), (bytes32[]));
            assertEq(publicInputs[9], bytes32(uint256(0)), "no royalty");
            assertEq(publicInputs[11], SELLER_PK, "the empty creator note stays spendable");
        }
    }

    // ------------------------------------------------------------- guardian

    function test_theGuardianSetsTheFeeWithinBounds() public {
        vm.prank(guardian);
        market.setFeeWei(0.001 ether);
        assertEq(market.feeWei(), 0.001 ether);

        uint256 tooHigh = market.MAX_FEE_WEI() + 1;
        vm.prank(guardian);
        vm.expectRevert(BacklitMarket.FeeTooHigh.selector);
        market.setFeeWei(tooHigh);

        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NotTheGuardian.selector);
        market.setFeeWei(0);
    }

    function test_theGuardianSetsTheFeeRecipient() public {
        vm.prank(guardian);
        market.setFeeRecipient(stranger);
        assertEq(market.feeRecipient(), stranger);

        vm.prank(guardian);
        vm.expectRevert(BacklitMarket.ZeroAddress.selector);
        market.setFeeRecipient(address(0));
    }

    function test_theGuardianHasNoRouteToATokenOrANote() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(guardian);
        vm.expectRevert(BacklitMarket.NotTheSeller.selector);
        market.cancelListing(listingId);
    }

    function _stripSelector(bytes memory reason) private pure returns (bytes memory out) {
        out = new bytes(reason.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = reason[i + 4];
        }
    }
}
