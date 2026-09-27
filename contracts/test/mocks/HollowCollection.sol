// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestCollection} from "./TestCollection.sol";

/// @notice Reports a successful `transferFrom` without moving the token.
contract HollowCollection is TestCollection {
    constructor(address royaltyReceiver, uint96 bps) TestCollection("Hollow", "HOLE", royaltyReceiver, bps) {}

    function transferFrom(address, address, uint256) public pure override {}
}
