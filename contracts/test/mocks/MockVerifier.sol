// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVerifier} from "../../src/interfaces/IVerifier.sol";

/// @notice Stands in for a generated verifier so the pool and market logic can
/// be tested without a proving stack. Real proofs are exercised in
/// `Verifiers.t.sol` and `Replay.t.sol`, and end to end in `ops/e2e/smoke.ts`;
/// `EchoVerifier` shows what the contracts hand a verifier.
contract MockVerifier is IVerifier {
    bool public accepts = true;

    function setAccepts(bool value) external {
        accepts = value;
    }

    function verify(bytes calldata, bytes32[] calldata) external view returns (bool) {
        return accepts;
    }
}
