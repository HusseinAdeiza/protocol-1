// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The shape every generated proof verifier exposes.
/// @dev `publicInputs` carries the circuit's own public inputs only. The
/// pairing point accumulator travels inside `proof`.
interface IVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}
