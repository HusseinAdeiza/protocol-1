// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Whether an address answers as a Safe that has been set up and that
/// the deployer does not control: at least one owner, none of them zero or the
/// deployer, and a threshold between one and the number of owners. The calls
/// are low level and the answers are checked before they are decoded, so an
/// account with no code, a contract without these getters, or one returning
/// malformed data fails the check instead of reverting the script without a
/// reason.
library SafeCheck {
    function isSafe(address account, address deployer) internal view returns (bool) {
        (bool ok, bytes memory owners) = account.staticcall(abi.encodeWithSignature("getOwners()"));
        if (!ok || owners.length < 64) return false;
        // An address[] comes back as an offset (32), a length, then the words.
        uint256 offset = _word(owners, 0);
        uint256 count = _word(owners, 1);
        if (offset != 32 || count == 0 || count > 50 || owners.length != 64 + count * 32) return false;
        for (uint256 i = 0; i < count; i++) {
            uint256 owner = _word(owners, 2 + i);
            if (owner == 0 || owner >> 160 != 0 || address(uint160(owner)) == deployer) return false;
        }

        bytes memory threshold;
        (ok, threshold) = account.staticcall(abi.encodeWithSignature("getThreshold()"));
        if (!ok || threshold.length != 32) return false;
        uint256 required = _word(threshold, 0);
        return required >= 1 && required <= count;
    }

    function _word(bytes memory data, uint256 index) private pure returns (uint256 value) {
        assembly {
            value := mload(add(add(data, 32), mul(index, 32)))
        }
    }
}
