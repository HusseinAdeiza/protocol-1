// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Answers the two Safe getters the deploy script checks, with
/// whatever owners and threshold a test sets.
contract MockSafe {
    address[] private owners;
    uint256 private threshold;

    function set(address[] calldata owners_, uint256 threshold_) external {
        owners = owners_;
        threshold = threshold_;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }
}
