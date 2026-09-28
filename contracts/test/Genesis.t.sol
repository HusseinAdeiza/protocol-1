// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BacklitGenesis} from "../src/BacklitGenesis.sol";
import {BacklitMarket} from "../src/BacklitMarket.sol";

import {BacklitTest} from "./Base.t.sol";

contract GenesisTest is Test {
    BacklitGenesis genesis;
    address owner = makeAddr("owner");
    address holder = makeAddr("holder");
    address treasury = makeAddr("treasury");

    function setUp() public {
        genesis = new BacklitGenesis(owner, holder, treasury, "https://backlit.ink/genesis/metadata/", "https://backlit.ink/genesis/collection.json");
    }

    function test_mintsTheWholeSupplyToTheHolder() public view {
        assertEq(genesis.balanceOf(holder), 128);
        assertEq(genesis.ownerOf(1), holder);
        assertEq(genesis.ownerOf(128), holder);
        assertEq(genesis.totalSupply(), 128);
    }

    function test_thereIsNoToken129() public {
        vm.expectRevert();
        genesis.ownerOf(129);
        vm.expectRevert();
        genesis.ownerOf(0);
    }

    function test_royaltyIsFivePercentToTheTreasury() public view {
        (address receiver, uint256 amount) = genesis.royaltyInfo(7, 10_000);
        assertEq(receiver, treasury);
        assertEq(amount, 500);
    }

    function test_tokenURI() public view {
        assertEq(genesis.tokenURI(12), "https://backlit.ink/genesis/metadata/12.json");
        assertEq(genesis.contractURI(), "https://backlit.ink/genesis/collection.json");
    }

    function test_answersTheInterfacesMarketsCheck() public view {
        assertTrue(genesis.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(genesis.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(genesis.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(genesis.supportsInterface(0x49064906)); // ERC-4906
    }

    function test_announcesItsOwnerAtDeployment() public {
        vm.expectEmit();
        emit BacklitGenesis.OwnershipTransferred(address(0), owner);
        new BacklitGenesis(owner, holder, treasury, "", "");
    }

    function test_onlyTheOwnerChangesAnything() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(BacklitGenesis.NotOwner.selector);
        genesis.setURIs("x", "y");
        vm.expectRevert(BacklitGenesis.NotOwner.selector);
        genesis.setRoyaltyReceiver(address(1));
        vm.expectRevert(BacklitGenesis.NotOwner.selector);
        genesis.freeze();
        vm.expectRevert(BacklitGenesis.NotOwner.selector);
        genesis.transferOwnership(address(1));
        vm.stopPrank();
    }

    function test_movingTheMetadataTellsMarketplacesToRefresh() public {
        vm.expectEmit(address(genesis));
        emit BacklitGenesis.BatchMetadataUpdate(1, 128);
        vm.expectEmit(address(genesis));
        emit BacklitGenesis.ContractURIUpdated();
        vm.prank(owner);
        genesis.setURIs("ipfs://cid/", "ipfs://cid/collection.json");
    }

    function test_theOwnerMovesMetadataAndRoyaltyUntilFrozen() public {
        address next = makeAddr("next");
        vm.startPrank(owner);
        genesis.setURIs("ipfs://cid/", "ipfs://cid/collection.json");
        genesis.setRoyaltyReceiver(next);
        genesis.freeze();
        vm.expectRevert(BacklitGenesis.IsFrozen.selector);
        genesis.setURIs("x", "y");
        vm.expectRevert(BacklitGenesis.IsFrozen.selector);
        genesis.setRoyaltyReceiver(treasury);
        vm.expectRevert(BacklitGenesis.IsFrozen.selector);
        genesis.freeze();
        // Marketplaces key collection admin to the owner, so it can still move.
        genesis.transferOwnership(next);
        vm.stopPrank();

        assertEq(genesis.tokenURI(3), "ipfs://cid/3.json");
        (address receiver, uint256 amount) = genesis.royaltyInfo(3, 1 ether);
        assertEq(receiver, next);
        assertEq(amount, 0.05 ether);
    }

    function test_ownershipMovesOnlyWhenTheNomineeAccepts() public {
        address next = makeAddr("next");

        vm.expectEmit(address(genesis));
        emit BacklitGenesis.OwnershipTransferStarted(owner, next);
        vm.prank(owner);
        genesis.transferOwnership(next);
        assertEq(genesis.owner(), owner, "moved before the nominee accepted");
        assertEq(genesis.pendingOwner(), next);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BacklitGenesis.NotPendingOwner.selector);
        genesis.acceptOwnership();

        vm.expectEmit(address(genesis));
        emit BacklitGenesis.OwnershipTransferred(owner, next);
        vm.prank(next);
        genesis.acceptOwnership();
        assertEq(genesis.owner(), next);
        assertEq(genesis.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(BacklitGenesis.NotOwner.selector);
        genesis.freeze();
        vm.prank(next);
        genesis.freeze();
    }

    function test_aNominationCanBeWithdrawnOrReplaced() public {
        address mistyped = makeAddr("mistyped");
        address next = makeAddr("next");
        vm.startPrank(owner);
        genesis.transferOwnership(mistyped);
        genesis.transferOwnership(address(0));
        vm.stopPrank();

        vm.prank(mistyped);
        vm.expectRevert(BacklitGenesis.NotPendingOwner.selector);
        genesis.acceptOwnership();

        vm.prank(owner);
        genesis.transferOwnership(next);
        vm.prank(mistyped);
        vm.expectRevert(BacklitGenesis.NotPendingOwner.selector);
        genesis.acceptOwnership();
        assertEq(genesis.owner(), owner);
    }

    function test_refusesZeroAddresses() public {
        vm.expectRevert(BacklitGenesis.ZeroAddress.selector);
        new BacklitGenesis(address(0), holder, treasury, "", "");
        vm.expectRevert(BacklitGenesis.ZeroAddress.selector);
        new BacklitGenesis(owner, address(0), treasury, "", "");
        vm.expectRevert(BacklitGenesis.ZeroAddress.selector);
        new BacklitGenesis(owner, holder, address(0), "", "");
        vm.prank(owner);
        vm.expectRevert(BacklitGenesis.ZeroAddress.selector);
        genesis.setRoyaltyReceiver(address(0));
    }
}

/// @notice Panes on the market they were made for. The royalty is paid into a
/// note, so nothing lists until the receiver has keys.
contract GenesisOnBacklitTest is BacklitTest {
    BacklitGenesis internal genesis;
    address internal treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        genesis = new BacklitGenesis(guardian, seller, treasury, "", "");
    }

    function test_aPaneListsOnlyOnceTheRoyaltyReceiverHasKeys() public {
        vm.startPrank(seller);
        genesis.approve(address(market), 1);
        vm.expectRevert(BacklitMarket.NoKeys.selector);
        market.list(address(genesis), 1);
        vm.stopPrank();

        vm.prank(treasury);
        market.registerKeys(bytes32(uint256(555)), VIEWING_PK);
        vm.prank(seller);
        market.list(address(genesis), 1);

        assertEq(genesis.ownerOf(1), address(market));
        (address receiver, uint256 bps) = market.royaltyOf(address(genesis), 1);
        assertEq(receiver, treasury);
        assertEq(bps, 500);
    }

    function test_aPaneSettlesToTheBuyer() public {
        vm.prank(treasury);
        market.registerKeys(bytes32(uint256(555)), VIEWING_PK);
        depositAs(buyer, 1 ether, BUYER_PK, bytes32(uint256(1)));
        bytes32 root = pool.currentRoot();

        vm.startPrank(seller);
        genesis.approve(address(market), 1);
        bytes32 listingId = market.list(address(genesis), 1);
        vm.stopPrank();
        bytes32 offerId = openOffer(listingId, bytes32(uint256(777)));
        vm.prank(seller);
        market.accept(offerId, bytes32(uint256(777)), 500);

        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());
        assertEq(genesis.ownerOf(1), buyer);
        assertEq(market.receiptOf(offerId).royaltyReceiver, treasury);
    }
}
