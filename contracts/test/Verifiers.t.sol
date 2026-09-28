// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IVerifier} from "../src/interfaces/IVerifier.sol";
import {SNARK_SCALAR_FIELD} from "../src/libs/Field.sol";
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

    function test_spendVerifierRejectsEveryMutant() public {
        _rejectsEveryMutant(IVerifier(address(spendVerifier)), "spend");
    }

    function test_settleVerifierRejectsEveryMutant() public {
        _rejectsEveryMutant(IVerifier(address(settleVerifier)), "settle");
    }

    /// @dev Changes every public input twice (one bit, and the same value plus
    /// the field modulus) and every 32-byte word of the proof once, one at a
    /// time. Each mutant must fail, by reverting or returning false, and the
    /// untouched proof must still pass afterwards.
    function _rejectsEveryMutant(IVerifier verifier, string memory name) internal {
        vm.pauseGasMetering();
        (bytes memory proof, bytes32[] memory pub) = _load(name);
        assertTrue(_accepts(verifier, proof, pub), "untouched proof must verify");

        for (uint256 i = 0; i < pub.length; i++) {
            bytes32 saved = pub[i];
            pub[i] = bytes32(uint256(saved) ^ 1);
            assertFalse(_accepts(verifier, proof, pub), string.concat("input ", vm.toString(i), " flipped"));
            pub[i] = bytes32(uint256(saved) + SNARK_SCALAR_FIELD);
            assertFalse(_accepts(verifier, proof, pub), string.concat("input ", vm.toString(i), " plus p"));
            pub[i] = saved;
        }

        for (uint256 w = 0; w < proof.length / 32; w++) {
            uint256 at = w * 32 + 31;
            bytes1 saved = proof[at];
            proof[at] = saved ^ 0x01;
            assertFalse(_accepts(verifier, proof, pub), string.concat("proof word ", vm.toString(w)));
            proof[at] = saved;
        }
        assertTrue(_accepts(verifier, proof, pub), "restored proof must verify");
    }

    function _accepts(IVerifier verifier, bytes memory proof, bytes32[] memory pub)
        internal
        view
        returns (bool)
    {
        try verifier.verify(proof, pub) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
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
