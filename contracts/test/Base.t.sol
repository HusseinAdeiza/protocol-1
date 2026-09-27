// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoseidonT5} from "poseidon-solidity/PoseidonT5.sol";

import {BacklitMarket} from "../src/BacklitMarket.sol";
import {BacklitPool} from "../src/BacklitPool.sol";
import {IVerifier} from "../src/interfaces/IVerifier.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";

import {MockVerifier} from "./mocks/MockVerifier.sol";
import {TestCollection} from "./mocks/TestCollection.sol";
import {TestnetWETH} from "./mocks/TestnetWETH.sol";

/// @notice Shared setup. The verifier is a stand-in here; real proofs are
/// covered in `Verifiers.t.sol` and end to end by the ops smoke test.
abstract contract BacklitTest is Test {
    TestnetWETH internal weth;
    MockVerifier internal spendVerifier;
    MockVerifier internal settleVerifier;
    BacklitPool internal pool;
    BacklitMarket internal market;
    TestCollection internal collection;

    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal creator = makeAddr("creator");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant CAP = 100 ether;
    uint256 internal constant FEE = 0.0002 ether;
    uint256 internal constant ROYALTY_BPS = 500;

    // Stand-in key material. The contracts only check that keys are field
    // elements and non-zero; the maths is the circuits' job.
    bytes32 internal constant SELLER_PK = bytes32(uint256(111));
    bytes32 internal constant BUYER_PK = bytes32(uint256(222));
    bytes32 internal constant CREATOR_PK = bytes32(uint256(333));
    bytes32 internal constant VIEWING_PK = bytes32(uint256(444));

    function setUp() public virtual {
        weth = new TestnetWETH();
        spendVerifier = new MockVerifier();
        settleVerifier = new MockVerifier();

        pool = new BacklitPool(IWETH(address(weth)), IVerifier(address(spendVerifier)), guardian, CAP);
        market = new BacklitMarket(pool, IVerifier(address(settleVerifier)), feeRecipient, FEE, guardian);
        pool.initMarket(address(market));

        collection = new TestCollection("Panes", "PANE", creator, uint96(ROYALTY_BPS));

        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(creator, 1 ether);
        vm.deal(stranger, 10 ether);

        vm.prank(seller);
        market.registerKeys(SELLER_PK, VIEWING_PK);
        vm.prank(buyer);
        market.registerKeys(BUYER_PK, VIEWING_PK);
        vm.prank(creator);
        market.registerKeys(CREATOR_PK, VIEWING_PK);
    }

    function commitmentOf(uint256 amount, bytes32 ownerPk, bytes32 salt) internal view returns (bytes32) {
        return bytes32(
            PoseidonT5.hash(
                [uint256(uint160(address(weth))), amount, uint256(ownerPk), uint256(salt)]
            )
        );
    }

    function depositAs(address who, uint256 amount, bytes32 ownerPk, bytes32 salt) internal {
        vm.prank(who);
        pool.depositETH{value: amount}(ownerPk, salt, hex"01");
    }

    function mintAndList(uint256 tokenId) internal returns (bytes32 listingId) {
        vm.startPrank(seller);
        collection.mint(seller);
        collection.approve(address(market), tokenId);
        listingId = market.list(address(collection), tokenId);
        vm.stopPrank();
    }

    function openOffer(bytes32 listingId, bytes32 priceCommitment) internal returns (bytes32 offerId) {
        vm.prank(buyer);
        offerId = market.offer(
            listingId, priceCommitment, buyer, hex"02", uint64(block.timestamp + 7 days)
        );
    }

    function settlePublic(bytes32 root)
        internal
        pure
        returns (BacklitMarket.SettlePublic memory)
    {
        return BacklitMarket.SettlePublic({
            root: root,
            nullifiers: [bytes32(uint256(901)), bytes32(uint256(902))],
            sellerCommitment: bytes32(uint256(911)),
            creatorCommitment: bytes32(uint256(912)),
            changeCommitment: bytes32(uint256(913))
        });
    }

    function emptyPayloads() internal pure returns (bytes[3] memory payloads) {
        payloads = [bytes(hex"03"), bytes(hex"04"), bytes(hex"05")];
    }
}
