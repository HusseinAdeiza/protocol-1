// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";

import {MockSafe} from "./mocks/MockSafe.sol";

/// @notice Runs the deploy script's configuration under chain 4663. The
/// environment is process-wide, so every case lives in one test and runs in
/// order, each fixing the previous complaint and expecting the next.
contract DeployGuardsTest is Test {
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    Deploy internal script;
    address internal deployer = makeAddr("deployer");
    address internal safe = makeAddr("safe");
    address internal router = makeAddr("router");

    function setUp() public {
        script = new Deploy();
    }

    function _expect(string memory reason) internal {
        vm.expectRevert(bytes(reason));
        script.loadConfig(deployer);
    }

    function test_mainnetRefusesAnythingItWouldRegret() public {
        vm.chainId(4663);

        vm.setEnv("WETH_ADDRESS", vm.toString(address(0xBAD)));
        _expect("mainnet: WETH_ADDRESS must be the canonical WETH");

        vm.setEnv("WETH_ADDRESS", vm.toString(WETH));
        if (!vm.envExists("GUARDIAN")) _expect("mainnet: GUARDIAN must be set");

        vm.setEnv("GUARDIAN", vm.toString(deployer));
        if (!vm.envExists("FEE_RECIPIENT")) _expect("mainnet: FEE_RECIPIENT must be set");

        vm.setEnv("FEE_RECIPIENT", vm.toString(deployer));
        if (!vm.envExists("INITIAL_CAP")) _expect("mainnet: INITIAL_CAP must be set");

        vm.setEnv("INITIAL_CAP", vm.toString(uint256(5 ether)));
        _expect("mainnet: the guardian cannot be the deployer");

        vm.setEnv("GUARDIAN", vm.toString(safe));
        _expect("mainnet: the fee recipient cannot be the deployer");

        // No code, then code that is not a Safe, then a Safe nobody set up.
        vm.setEnv("FEE_RECIPIENT", vm.toString(router));
        _expect("mainnet: the guardian must be a Safe the deployer does not own");
        vm.etch(safe, hex"00");
        _expect("mainnet: the guardian must be a Safe the deployer does not own");
        deployCodeTo("MockSafe.sol:MockSafe", safe);
        _expect("mainnet: the guardian must be a Safe the deployer does not own");

        address[] memory owners = new address[](1);
        owners[0] = makeAddr("owner");
        MockSafe(safe).set(owners, 0);
        _expect("mainnet: the guardian must be a Safe the deployer does not own");

        // A threshold above the owners, a zero owner, the deployer as owner.
        MockSafe(safe).set(owners, 2);
        _expect("mainnet: the guardian must be a Safe the deployer does not own");
        address[] memory zero = new address[](1);
        MockSafe(safe).set(zero, 1);
        _expect("mainnet: the guardian must be a Safe the deployer does not own");
        address[] memory deployerOwned = new address[](1);
        deployerOwned[0] = deployer;
        MockSafe(safe).set(deployerOwned, 1);
        _expect("mainnet: the guardian must be a Safe the deployer does not own");

        MockSafe(safe).set(owners, 1);
        vm.setEnv("FIXTURES", "true");
        _expect("mainnet: FIXTURES must be off");

        vm.setEnv("FIXTURES", "false");
        Deploy.Config memory config = script.loadConfig(deployer);
        assertEq(config.weth, WETH);
        assertEq(config.guardian, safe);
        assertEq(config.feeRecipient, router);
        assertEq(config.initialCap, 5 ether);

        // The same settings are fine on testnet, where none of this applies.
        vm.chainId(46630);
        vm.setEnv("WETH_ADDRESS", vm.toString(address(0xBAD)));
        script.loadConfig(deployer);
    }
}
