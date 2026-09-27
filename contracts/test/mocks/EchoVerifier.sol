// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVerifier} from "../../src/interfaces/IVerifier.sol";

/// @notice Reverts with the public inputs it was handed, so a test can read
/// exactly what a contract built without needing a real proof.
contract EchoVerifier is IVerifier {
    error Echo(bytes32[] publicInputs);

    function verify(bytes calldata, bytes32[] calldata publicInputs) external pure returns (bool) {
        revert Echo(publicInputs);
    }
}
