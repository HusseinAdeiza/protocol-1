// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// The BN254 scalar field the circuits work in. Anything handed to a verifier
// as a public input has to be smaller than this.
uint256 constant SNARK_SCALAR_FIELD =
    21888242871839275222246405745257438548091551002212100084086427780313373464577;

// Note amounts are uint96 on chain and in the circuits.
uint256 constant MAX_NOTE_AMOUNT = 2 ** 96;

library Field {
    error NotAFieldElement();

    /// @dev Reverts on anything a verifier would reject anyway, so the failure
    /// names itself instead of surfacing as a bad proof.
    function check(bytes32 value) internal pure returns (bytes32) {
        if (uint256(value) >= SNARK_SCALAR_FIELD) revert NotAFieldElement();
        return value;
    }

    function fromAddress(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    /// @dev Folds a 256-bit identifier into the field. Used for ids the
    /// circuits take as public inputs.
    function reduce(bytes32 value) internal pure returns (bytes32) {
        return bytes32(uint256(value) % SNARK_SCALAR_FIELD);
    }
}
