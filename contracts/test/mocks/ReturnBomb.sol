// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A fee recipient that fills its memory until it is nearly out of gas
/// and hands all of it back: as return data when it accepts the ETH, as revert
/// data when it refuses. A caller that copies either needs about as much gas
/// again as the recipient burned, and keeps only 1/64 of it.
contract ReturnBomb {
    bool public refusing;
    uint256 public gasOnEntry;

    constructor(bool refusing_) {
        refusing = refusing_;
    }

    receive() external payable {
        gasOnEntry = gasleft();
        bool refuse = refusing;
        assembly {
            let size := 0
            for {} gt(gas(), 60000) { size := add(size, 32) } { mstore(size, 1) }
            if refuse { revert(0, size) }
            return(0, size)
        }
    }
}
