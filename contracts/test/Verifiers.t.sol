// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {SpendVerifier} from "../src/verifiers/SpendVerifier.sol";
import {SettleVerifier} from "../src/verifiers/SettleVerifier.sol";

/// @notice Replays proofs produced by `pnpm --filter @backlit/ops prove`
/// against the generated verifiers. This is the seam where the circuits, the
/// proving stack and the chain have to agree.
contract VerifiersTest is Test {
    using stdJson for string;

    SpendVerifier internal spendVerifier;
    SettleVerifier internal settleVerifier;

    function setUp() public {
        spendVerifier = new SpendVerifier();
        settleVerifier = new SettleVerifier();
    }

    function _load(string memory name) internal view returns (bytes memory proof, bytes32[] memory pub) {
        string memory json = vm.readFile(string.concat("test/fixtures/", name, "-proof.json"));
        proof = json.readBytes(".proof");
        pub = json.readBytes32Array(".publicInputs");
    }

    function test_spendProofVerifies() public view {
        (bytes memory proof, bytes32[] memory pub) = _load("spend");
        assertEq(pub.length, 9, "spend takes nine public inputs");
        assertTrue(spendVerifier.verify(proof, pub));
    }

    function test_settleProofVerifies() public view {
        (bytes memory proof, bytes32[] memory pub) = _load("settle");
        assertEq(pub.length, 14, "settle takes fourteen public inputs");
        assertTrue(settleVerifier.verify(proof, pub));
    }

    function test_spendProofRejectsATamperedPublicInput() public {
        (bytes memory proof, bytes32[] memory pub) = _load("spend");
        // Any other recipient, unwrap flag or payload set moves the binding.
        pub[8] = bytes32(uint256(pub[8]) ^ 1);
        vm.expectRevert();
        spendVerifier.verify(proof, pub);
    }

    function test_settleProofRejectsATamperedRoyalty() public {
        (bytes memory proof, bytes32[] memory pub) = _load("settle");
        pub[9] = bytes32(uint256(250));
        vm.expectRevert();
        settleVerifier.verify(proof, pub);
    }

    function test_settleProofRejectsAnotherBinding() public {
        (bytes memory proof, bytes32[] memory pub) = _load("settle");
        pub[13] = bytes32(uint256(pub[13]) ^ 1);
        vm.expectRevert();
        settleVerifier.verify(proof, pub);
    }

    function test_spendVerifyGas() public {
        (bytes memory proof, bytes32[] memory pub) = _load("spend");
        uint256 before = gasleft();
        spendVerifier.verify(proof, pub);
        emit log_named_uint("spend verify gas", before - gasleft());
    }

    function test_settleVerifyGas() public {
        (bytes memory proof, bytes32[] memory pub) = _load("settle");
        uint256 before = gasleft();
        settleVerifier.verify(proof, pub);
        emit log_named_uint("settle verify gas", before - gasleft());
    }
}
