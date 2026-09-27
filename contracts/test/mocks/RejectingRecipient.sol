// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A fee recipient that can be switched to refuse ETH, the way a
/// paused or broken router would.
contract RejectingRecipient {
    bool public refusing = true;

    function setRefusing(bool value) external {
        refusing = value;
    }

    receive() external payable {
        require(!refusing, "refusing");
    }
}
