// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVerifier} from "../../src/interfaces/IVerifier.sol";

/// @notice Stands in for a generated verifier so the pool and market logic can
/// be tested without a proving stack. Real proofs are exercised in
/// `Verifiers.t.sol` and end to end in `ops/e2e/smoke.ts`.
contract MockVerifier is IVerifier {
    bool public accepts = true;

    /// @notice The public inputs of the last call, so tests can assert on
    /// exactly what the contracts hand a verifier.
    bytes32[] public lastPublicInputs;

    function setAccepts(bool value) external {
        accepts = value;
    }

    function verify(bytes calldata, bytes32[] calldata publicInputs) external view returns (bool) {
        // `verify` is a view function on the real verifier, so the recording
        // below happens through a helper the tests call directly.
        publicInputs;
        return accepts;
    }

    function record(bytes32[] calldata publicInputs) external {
        delete lastPublicInputs;
        for (uint256 i = 0; i < publicInputs.length; i++) {
            lastPublicInputs.push(publicInputs[i]);
        }
    }

    function lastPublicInputsLength() external view returns (uint256) {
        return lastPublicInputs.length;
    }
}
