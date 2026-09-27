// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {LeanIMTData, InternalLeanIMT} from "@zk-kit/lean-imt.sol/InternalLeanIMT.sol";
import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {PoseidonT5} from "poseidon-solidity/PoseidonT5.sol";

import {SNARK_SCALAR_FIELD} from "../src/libs/Field.sol";

/// @notice Holds Solidity to the same answers as the circuits and the browser.
/// The vectors come from the ops package's `vectors` script, which produces
/// them with the same libraries the web app ships.
contract ParityTest is Test {
    using stdJson for string;
    using InternalLeanIMT for LeanIMTData;

    LeanIMTData internal tree;
    string internal vectors;

    function setUp() public {
        vectors = vm.readFile("test/fixtures/vectors.json");
    }

    function test_poseidon2MatchesTheVectors() public view {
        uint256[] memory a = vectors.readUintArray(".flat.poseidon2A");
        uint256[] memory b = vectors.readUintArray(".flat.poseidon2B");
        uint256[] memory out = vectors.readUintArray(".flat.poseidon2Out");

        for (uint256 i = 0; i < out.length; i++) {
            assertEq(PoseidonT3.hash([a[i], b[i]]), out[i], "poseidon2 drifted");
        }
    }

    function test_poseidon4MatchesTheVectors() public view {
        uint256[] memory a = vectors.readUintArray(".flat.poseidon4A");
        uint256[] memory b = vectors.readUintArray(".flat.poseidon4B");
        uint256[] memory c = vectors.readUintArray(".flat.poseidon4C");
        uint256[] memory d = vectors.readUintArray(".flat.poseidon4D");
        uint256[] memory out = vectors.readUintArray(".flat.poseidon4Out");

        for (uint256 i = 0; i < out.length; i++) {
            assertEq(PoseidonT5.hash([a[i], b[i], c[i], d[i]]), out[i], "poseidon4 drifted");
        }
    }

    function test_noteCommitmentsMatchTheVectors() public view {
        address[] memory asset = vectors.readAddressArray(".flat.noteAsset");
        uint256[] memory amount = vectors.readUintArray(".flat.noteAmount");
        uint256[] memory ownerPk = vectors.readUintArray(".flat.noteOwnerPk");
        uint256[] memory salt = vectors.readUintArray(".flat.noteSalt");
        uint256[] memory commitment = vectors.readUintArray(".flat.noteCommitment");

        for (uint256 i = 0; i < commitment.length; i++) {
            assertEq(
                PoseidonT5.hash([uint256(uint160(asset[i])), amount[i], ownerPk[i], salt[i]]),
                commitment[i],
                "commitment drifted"
            );
        }
    }

    function test_nullifiersMatchTheVectors() public view {
        uint256 spendingKey = vectors.readUint(".keys.spendingKey");
        uint256[] memory commitment = vectors.readUintArray(".flat.noteCommitment");
        uint256[] memory nullifier = vectors.readUintArray(".flat.noteNullifier");

        for (uint256 i = 0; i < nullifier.length; i++) {
            assertEq(PoseidonT3.hash([commitment[i], spendingKey]), nullifier[i], "nullifier drifted");
        }
    }

    function test_ownerPkIsPoseidonOfTheSpendingKey() public view {
        uint256 spendingKey = vectors.readUint(".keys.spendingKey");
        assertEq(PoseidonT3.hash([spendingKey, 0]), vectors.readUint(".keys.ownerPk"));
    }

    function test_priceCommitmentMatchesTheVectors() public view {
        assertEq(
            PoseidonT3.hash(
                [vectors.readUint(".priceCommitment.price"), vectors.readUint(".priceCommitment.blinding")]
            ),
            vectors.readUint(".priceCommitment.out")
        );
    }

    /// @dev The tree is the piece most likely to drift, because the JavaScript
    /// and Solidity implementations are separate code. Every intermediate root
    /// is checked, not just the last one.
    function test_treeRootsMatchAfterEveryInsert() public {
        uint256[] memory leaves = vectors.readUintArray(".tree.leaves");
        uint256[] memory roots = vectors.readUintArray(".tree.roots");
        assertEq(leaves.length, roots.length, "vectors are inconsistent");

        for (uint256 i = 0; i < leaves.length; i++) {
            uint256 root = tree._insert(leaves[i]);
            assertEq(root, roots[i], string.concat("root drifted at leaf ", vm.toString(i)));
        }
        assertEq(tree._root(), vectors.readUint(".tree.membership.root"));
    }

    /// @dev Walks the membership path the circuits walk, with the same rule:
    /// a sibling above the proof's depth is not hashed.
    function test_membershipPathRebuildsTheRoot() public {
        uint256[] memory leaves = vectors.readUintArray(".tree.leaves");
        for (uint256 i = 0; i < leaves.length; i++) {
            tree._insert(leaves[i]);
        }

        uint256[] memory siblings = vectors.readUintArray(".tree.membership.siblings");
        uint256 index = vectors.readUint(".tree.membership.index");
        uint256 depth = vectors.readUint(".tree.membership.depth");
        uint256 node = vectors.readUint(".tree.membership.leaf");

        for (uint256 level = 0; level < depth; level++) {
            bool onTheRight = (index >> level) & 1 == 1;
            node = onTheRight
                ? PoseidonT3.hash([siblings[level], node])
                : PoseidonT3.hash([node, siblings[level]]);
        }

        assertEq(node, vectors.readUint(".tree.membership.root"), "the path does not reach the root");
    }

    function test_royaltyRoundingMatchesTheVectors() public view {
        uint256[] memory price = vectors.readUintArray(".flat.royaltyPrice");
        uint256[] memory basisPoints = vectors.readUintArray(".flat.royaltyBps");
        uint256[] memory royalty = vectors.readUintArray(".flat.royaltyAmount");

        for (uint256 i = 0; i < royalty.length; i++) {
            assertEq((price[i] * basisPoints[i] + 9_999) / 10_000, royalty[i], "rounding drifted");
        }
    }

    function test_sellerSaltMatchesTheVectors() public view {
        assertEq(
            PoseidonT3.hash([vectors.readUint(".sellerSalt.blinding"), vectors.readUint(".sellerSalt.tag")]),
            vectors.readUint(".sellerSalt.out")
        );
    }

    /// @dev `abi.encode` of a fixed-size array of `bytes` is the part most
    /// likely to differ between viem and solc, so the SDK's binding hashes are
    /// held to the same expression the pool and the market use.
    function test_bindingsMatchTheVectors() public view {
        bytes[] memory spendPayloads = vectors.readBytesArray(".spendBinding.payloads");
        bytes[2] memory two = [spendPayloads[0], spendPayloads[1]];
        bytes32 spend = keccak256(
            abi.encode(
                vectors.readAddress(".spendBinding.recipient"),
                vectors.readBool(".spendBinding.unwrap"),
                keccak256(abi.encode(two))
            )
        );
        assertEq(uint256(spend) % SNARK_SCALAR_FIELD, vectors.readUint(".spendBinding.out"));

        bytes[] memory settlePayloads = vectors.readBytesArray(".settleBinding.payloads");
        bytes[3] memory three = [settlePayloads[0], settlePayloads[1], settlePayloads[2]];
        bytes32 settle =
            keccak256(abi.encode(vectors.readBytes32(".settleBinding.offerId"), keccak256(abi.encode(three))));
        assertEq(uint256(settle) % SNARK_SCALAR_FIELD, vectors.readUint(".settleBinding.out"));
    }
}
