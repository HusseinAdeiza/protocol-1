// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {BacklitGenesis} from "../../src/BacklitGenesis.sol";
import {BacklitMarket} from "../../src/BacklitMarket.sol";
import {BacklitPool} from "../../src/BacklitPool.sol";
import {IVerifier} from "../../src/interfaces/IVerifier.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {HollowCollection} from "../mocks/HollowCollection.sol";
import {ReturnBomb} from "../mocks/ReturnBomb.sol";

/// @notice Exercises the Robinhood Chain deployment that deployments/4663.json
/// records, on a fork: its pool, market and verifiers, the canonical aeWETH,
/// and the fee recipient as they are on chain. Skipped unless FORK_RPC is set.
///
///   anvil --fork-url https://rpc.mainnet.chain.robinhood.com --hardfork shanghai --port 8561
///   FORK_RPC=http://127.0.0.1:8561 forge test --match-path test/fork/MainnetFork.t.sol -vv
///
/// Anvil only serves state; forge executes with the profile's cancun rules,
/// which the contracts were compiled for. The public RPC keeps no historical
/// state, so start anvil right before a run: it fetches storage lazily, and
/// once the RPC has dropped the fork block, reading a slot nothing has touched
/// yet fails. FORK_RPC may also be the public RPC itself, in which case the
/// fork is taken at the latest block unless FORK_BLOCK names a recent one.
///
/// The real proofs in `mainnet-proofs.json` are bound to the pool and market
/// they were cut for, so the tests that use them skip when deployments/4663.json
/// names others. After a deployment, regenerate them from the repository root:
///
///   ops/node_modules/.bin/tsx contracts/test/fork/generate-mainnet-proofs.mts
///
/// They assume the pool's tree empty and the market's nonces at zero, as at
/// deployment. If mainnet has moved on, `_rebase` resets exactly those words
/// on the fork and logs it; the bytecode and all other state stay as they are.
///
/// FORK_LOCAL_BUILD=true puts this checkout's pool and market at the recorded
/// addresses, built with the live constructor arguments, so the code about to
/// be deployed meets mainnet state and the real proofs before it goes live.
contract MainnetForkTest is Test {
    using stdJson for string;

    uint256 internal constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257438548091551002212100084086427780313373464577;

    string internal constant DEPLOYMENT = "deployments/4663.json";
    string internal constant PROOFS = "test/fork/mainnet-proofs.json";
    string internal constant REGENERATE =
        "ops/node_modules/.bin/tsx contracts/test/fork/generate-mainnet-proofs.mts";

    // From `forge inspect <contract> storageLayout`. `_rebase` checks the pool's
    // pair against its getters before it writes anything.
    bytes32 internal constant POOL_TREE_SIZE = bytes32(uint256(5));
    bytes32 internal constant POOL_TREE_DEPTH = bytes32(uint256(6));
    bytes32 internal constant MARKET_LISTING_NONCE = bytes32(uint256(7));
    bytes32 internal constant MARKET_OFFER_NONCE = bytes32(uint256(8));

    uint256 internal chainId;
    BacklitPool internal pool;
    BacklitMarket internal market;
    IWETH internal weth;
    address internal spendVerifier;
    address internal settleVerifier;
    address internal guardian;
    address internal deployer;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        vm.skip(bytes(rpc).length == 0, "FORK_RPC is unset; the header of this file says how to run it");

        string memory deployment = vm.readFile(DEPLOYMENT);
        chainId = deployment.readUint(".chainId");
        pool = BacklitPool(payable(deployment.readAddress(".pool")));
        market = BacklitMarket(deployment.readAddress(".market"));
        weth = IWETH(deployment.readAddress(".weth"));
        spendVerifier = deployment.readAddress(".spendVerifier");
        settleVerifier = deployment.readAddress(".settleVerifier");
        guardian = deployment.readAddress(".guardian");
        deployer = deployment.readAddress(".deployer");

        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, chainId, "FORK_RPC is not the chain deployments/4663.json records");
        // On an Arbitrum chain block.number is the parent chain's number.
        console.log("forked", chainId, "at parent-chain block", block.number);

        if (vm.envOr("FORK_LOCAL_BUILD", false)) _swapInThisBuild();
    }

    function test_theDeploymentIsWiredAsRecorded() public {
        assertEq(pool.market(), address(market), "pool -> market");
        assertEq(address(market.pool()), address(pool), "market -> pool");
        assertEq(address(pool.weth()), address(weth), "pool weth");
        assertEq(address(pool.spendVerifier()), spendVerifier, "spend verifier");
        assertEq(address(market.settleVerifier()), settleVerifier, "settle verifier");
        assertEq(pool.guardian(), guardian, "pool guardian");
        assertEq(market.guardian(), guardian, "market guardian");
        assertEq(pool.deployer(), deployer, "deployer");

        bytes32 poolId = bytes32(uint256(keccak256(abi.encode(chainId, address(pool)))) % SNARK_SCALAR_FIELD);
        assertEq(pool.poolId(), poolId, "pool id");
        assertEq(market.poolId(), poolId, "market pool id");
        assertEq(market.assetField(), bytes32(uint256(uint160(address(weth)))), "asset field");
        assertGt(guardian.code.length, 0, "guardian has no code");

        console.log("capWei        ", pool.capWei());
        console.log("totalDeposited", pool.totalDeposited());
        console.log("totalWithdrawn", pool.totalWithdrawn());
        console.log("leafCount     ", pool.leafCount());
        console.log("depositsPaused", pool.depositsPaused());
        console.log("feeWei        ", market.feeWei());
        console.log("feeRecipient  ", market.feeRecipient());
        console.log("feesOwed      ", market.feesOwed());

        // The deployer kept nothing.
        vm.startPrank(deployer);
        vm.expectRevert(BacklitPool.AlreadyInitialised.selector);
        pool.initMarket(deployer);
        vm.expectRevert(BacklitPool.NotTheGuardian.selector);
        pool.raiseCap(type(uint256).max);
        vm.expectRevert(BacklitPool.NotTheGuardian.selector);
        pool.setDepositsPaused(true);
        vm.expectRevert(BacklitMarket.NotTheGuardian.selector);
        market.setFeeWei(0);
        vm.expectRevert(BacklitMarket.NotTheGuardian.selector);
        market.setFeeRecipient(deployer);
        vm.stopPrank();
    }

    /// The committed fixtures are bound to a local pool, but a verifier is not
    /// bound to anything: the deployed ones must accept them as they stand.
    function test_theDeployedVerifiersAcceptTheCommittedProofs() public view {
        _assertVerifies(spendVerifier, "test/fixtures/spend-proof.json");
        _assertVerifies(settleVerifier, "test/fixtures/settle-proof.json");
    }

    function test_theDeployedVerifiersRejectTamperedAndNonCanonicalInputs() public view {
        string memory json = vm.readFile("test/fixtures/spend-proof.json");
        bytes memory proof = json.readBytes(".proof");
        bytes32[] memory inputs = json.readBytes32Array(".publicInputs");

        // One unit more withdrawn than was proved.
        inputs[7] = bytes32(uint256(inputs[7]) + 1);
        assertFalse(_verifies(spendVerifier, proof, inputs), "tampered withdrawal verified");
        inputs[7] = bytes32(uint256(inputs[7]) - 1);

        // The same nullifier written as x + p must not verify: that alias is
        // how a note would get spent twice.
        inputs[3] = bytes32(uint256(inputs[3]) + SNARK_SCALAR_FIELD);
        assertFalse(_verifies(spendVerifier, proof, inputs), "aliased nullifier verified");
        inputs[3] = bytes32(uint256(inputs[3]) - SNARK_SCALAR_FIELD);

        // A spend proof is not a settle proof.
        assertFalse(_verifies(settleVerifier, proof, inputs), "spend proof verified as settle");
        assertTrue(_verifies(spendVerifier, proof, inputs), "untouched proof stopped verifying");
    }

    function test_depositETHWrapsIntoTheRealWeth() public {
        _openForDeposits(1 ether);
        address depositor = makeAddr("eth-depositor");
        vm.deal(depositor, 1 ether);

        uint256 wethBefore = weth.balanceOf(address(pool));
        uint256 depositedBefore = pool.totalDeposited();
        uint256 leavesBefore = pool.leafCount();

        vm.expectEmit(address(pool));
        emit BacklitPool.Deposited(depositor, 1 ether, leavesBefore);
        vm.prank(depositor);
        pool.depositETH{value: 1 ether}(bytes32(uint256(11)), bytes32(uint256(12)), hex"01");

        assertEq(weth.balanceOf(address(pool)), wethBefore + 1 ether, "pool WETH");
        assertEq(address(pool).balance, 0, "pool kept ETH");
        assertEq(pool.totalDeposited(), depositedBefore + 1 ether, "totalDeposited");
        assertEq(pool.leafCount(), leavesBefore + 1, "leaf");
        assertTrue(pool.isKnownRoot(pool.currentRoot()), "root not recorded");
    }

    function test_depositWETHPullsApprovedWeth() public {
        _openForDeposits(1 ether);
        address depositor = makeAddr("weth-depositor");
        vm.deal(depositor, 1 ether);
        vm.startPrank(depositor);
        weth.deposit{value: 1 ether}();

        // Nothing approved yet: aeWETH refuses the pull.
        vm.expectRevert();
        pool.depositWETH(1 ether, bytes32(uint256(21)), bytes32(uint256(22)), "");

        weth.approve(address(pool), 1 ether);
        uint256 wethBefore = weth.balanceOf(address(pool));
        uint256 depositedBefore = pool.totalDeposited();
        pool.depositWETH(1 ether, bytes32(uint256(21)), bytes32(uint256(22)), "");
        vm.stopPrank();

        assertEq(weth.balanceOf(depositor), 0, "depositor WETH");
        assertEq(weth.balanceOf(address(pool)), wethBefore + 1 ether, "pool WETH");
        assertEq(pool.totalDeposited(), depositedBefore + 1 ether, "totalDeposited");
    }

    function test_theCapBoundsNetDepositsAndIgnoresDonations() public {
        _openForDeposits(1);
        uint256 room = _headroom();

        // WETH sent straight to the pool does not use up the cap.
        address donor = makeAddr("donor");
        vm.deal(donor, 3 ether);
        vm.startPrank(donor);
        weth.deposit{value: 3 ether}();
        weth.transfer(address(pool), 3 ether);
        vm.stopPrank();
        assertEq(_headroom(), room, "a donation moved the cap");

        address whale = makeAddr("whale");
        vm.deal(whale, room + 2);
        vm.prank(whale);
        pool.depositETH{value: room}(bytes32(uint256(31)), bytes32(uint256(32)), "");
        assertEq(_headroom(), 0, "cap not filled exactly");

        vm.prank(whale);
        vm.expectRevert(BacklitPool.CapExceeded.selector);
        pool.depositETH{value: 1}(bytes32(uint256(31)), bytes32(uint256(33)), "");

        vm.startPrank(whale);
        weth.deposit{value: 1}();
        weth.approve(address(pool), 1);
        vm.expectRevert(BacklitPool.CapExceeded.selector);
        pool.depositWETH(1, bytes32(uint256(31)), bytes32(uint256(34)), "");
        vm.stopPrank();
    }

    function test_theGuardianCanRaiseTheCapTo20EtherAndOnlyUp() public {
        uint256 target = 20 ether;
        if (pool.capWei() >= target) {
            console.log("cap is already at or above 20 ETH; raising by 1 ETH instead");
            target = pool.capWei() + 1 ether;
        }
        vm.prank(guardian);
        pool.raiseCap(target);
        assertEq(pool.capWei(), target);

        vm.startPrank(guardian);
        vm.expectRevert(BacklitPool.CapNotRaised.selector);
        pool.raiseCap(target);
        vm.expectRevert(BacklitPool.CapNotRaised.selector);
        pool.raiseCap(target - 1);
        vm.stopPrank();

        _openForDeposits(0);
        uint256 room = _headroom();
        address whale = makeAddr("whale");
        vm.deal(whale, room + 1);
        vm.prank(whale);
        pool.depositETH{value: room}(bytes32(uint256(41)), bytes32(uint256(42)), "");
        vm.prank(whale);
        vm.expectRevert(BacklitPool.CapExceeded.selector);
        pool.depositETH{value: 1}(bytes32(uint256(41)), bytes32(uint256(43)), "");
    }

    function test_onlyTheGuardianHoldsTheSwitchesAndPauseStopsOnlyDeposits() public {
        address[3] memory outsiders = [makeAddr("stranger"), deployer, market.feeRecipient()];
        uint256 higherCap = pool.capWei() + 1;
        for (uint256 i = 0; i < outsiders.length; i++) {
            vm.startPrank(outsiders[i]);
            vm.expectRevert(BacklitPool.NotTheGuardian.selector);
            pool.setDepositsPaused(true);
            vm.expectRevert(BacklitPool.NotTheGuardian.selector);
            pool.raiseCap(higherCap);
            vm.expectRevert(BacklitMarket.NotTheGuardian.selector);
            market.setFeeWei(0);
            vm.expectRevert(BacklitMarket.NotTheGuardian.selector);
            market.setFeeRecipient(outsiders[i]);
            vm.stopPrank();
        }

        _openForDeposits(2);
        vm.prank(guardian);
        pool.setDepositsPaused(true);

        address depositor = makeAddr("paused-depositor");
        vm.deal(depositor, 2);
        vm.startPrank(depositor);
        vm.expectRevert(BacklitPool.DepositsArePaused.selector);
        pool.depositETH{value: 1}(bytes32(uint256(51)), bytes32(uint256(52)), "");
        weth.deposit{value: 1}();
        weth.approve(address(pool), 1);
        vm.expectRevert(BacklitPool.DepositsArePaused.selector);
        pool.depositWETH(1, bytes32(uint256(51)), bytes32(uint256(53)), "");
        vm.stopPrank();

        vm.prank(guardian);
        pool.setDepositsPaused(false);
        vm.prank(depositor);
        pool.depositETH{value: 1}(bytes32(uint256(51)), bytes32(uint256(52)), "");

        // The fee ceiling holds even for the guardian.
        uint256 ceiling = market.MAX_FEE_WEI();
        vm.startPrank(guardian);
        vm.expectRevert(BacklitMarket.FeeTooHigh.selector);
        market.setFeeWei(ceiling + 1);
        market.setFeeWei(ceiling);
        vm.stopPrank();
        assertEq(market.feeWei(), ceiling);
        // Settlement and withdrawal under a pause: see the lifecycle test.
    }

    /// The ETH hop of an unwrap, seen from the pool: aeWETH pays the pool from
    /// the proxy's address, which the pool's receive() accepts, while plain
    /// ETH from anyone else is refused.
    function test_aeWethPaysTheUnwrapIntoThePool() public {
        _openForDeposits(0.1 ether);
        address depositor = makeAddr("hop-depositor");
        vm.deal(depositor, 0.1 ether);
        vm.prank(depositor);
        pool.depositETH{value: 0.1 ether}(bytes32(uint256(61)), bytes32(uint256(62)), "");

        uint256 ethBefore = address(pool).balance;
        vm.prank(address(pool));
        weth.withdraw(0.05 ether);
        assertEq(address(pool).balance, ethBefore + 0.05 ether, "aeWETH did not pay the pool");

        vm.deal(depositor, 1 ether);
        vm.prank(depositor);
        (bool sent,) = address(pool).call{value: 1 ether}("");
        assertFalse(sent, "the pool took plain ETH");

        vm.prank(depositor);
        (sent,) = address(market).call{value: 1 ether}("");
        assertFalse(sent, "the market took plain ETH");
    }

    function test_onlyTheMarketMovesNotesWithoutAProof() public {
        bytes32[2] memory nullifiers = [bytes32(uint256(1)), bytes32(uint256(2))];
        bytes32[3] memory outputs = [bytes32(uint256(3)), bytes32(uint256(4)), bytes32(uint256(5))];
        bytes[3] memory payloads;
        vm.expectRevert(BacklitPool.NotTheMarket.selector);
        pool.spendFromMarket(bytes32(0), nullifiers, outputs, payloads);
        vm.prank(guardian);
        vm.expectRevert(BacklitPool.NotTheMarket.selector);
        pool.spendFromMarket(bytes32(0), nullifiers, outputs, payloads);
    }

    function test_aRealProofWithdrawsAsEth() public {
        string memory json = _proofs();
        _replayDeposits(json);

        (bytes memory proof, BacklitPool.SpendPublic memory p, bytes[2] memory payloads) =
            _spendCall(json, ".spendEth");
        assertTrue(p.unwrap);

        // Tampering with anything the proof covers fails.
        p.unwrap = false;
        vm.expectRevert();
        pool.spend(proof, p, payloads);
        p.unwrap = true;
        address intended = p.recipient;
        p.recipient = makeAddr("thief");
        vm.expectRevert();
        pool.spend(proof, p, payloads);
        p.recipient = intended;
        vm.expectRevert();
        pool.spend(proof, p, [payloads[1], payloads[0]]);

        uint256 ethBefore = intended.balance;
        uint256 wethBefore = weth.balanceOf(address(pool));
        uint256 withdrawnBefore = pool.totalWithdrawn();
        uint256 leavesBefore = pool.leafCount();

        // Anyone may submit it; the proof is the authority.
        vm.prank(makeAddr("relayer"));
        pool.spend(proof, p, payloads);

        assertEq(intended.balance, ethBefore + 0.25 ether, "ETH not paid");
        assertEq(weth.balanceOf(address(pool)), wethBefore - 0.25 ether, "pool WETH");
        assertEq(address(pool).balance, 0, "pool kept ETH");
        assertEq(pool.totalWithdrawn(), withdrawnBefore + 0.25 ether, "totalWithdrawn");
        assertEq(pool.leafCount(), leavesBefore + 2, "change notes");
        assertTrue(pool.isSpent(p.nullifiers[0]) && pool.isSpent(p.nullifiers[1]), "not nullified");

        vm.expectRevert(BacklitPool.NoteAlreadySpent.selector);
        pool.spend(proof, p, payloads);
    }

    function test_aRealProofWithdrawsAsWethAndTheSameNotesCannotPayTwice() public {
        string memory json = _proofs();
        _replayDeposits(json);

        (bytes memory proof, BacklitPool.SpendPublic memory p, bytes[2] memory payloads) =
            _spendCall(json, ".spendWeth");
        assertFalse(p.unwrap);

        uint256 wethBefore = weth.balanceOf(p.recipient);
        pool.spend(proof, p, payloads);
        assertEq(weth.balanceOf(p.recipient), wethBefore + 0.25 ether, "WETH not paid");

        // A second, different proof over the same two notes.
        (bytes memory other, BacklitPool.SpendPublic memory q, bytes[2] memory otherPayloads) =
            _spendCall(json, ".spendEth");
        vm.expectRevert(BacklitPool.NoteAlreadySpent.selector);
        pool.spend(other, q, otherPayloads);
    }

    /// Deposits, a Genesis sale settled through the market, and all three
    /// resulting notes cashed out, every step with a real proof and with
    /// deposits paused once the scene is funded.
    function test_aGenesisSaleSettlesAndEveryPartyCashesOut() public {
        string memory json = _proofs();
        uint256[3] memory start =
            [weth.balanceOf(address(pool)), pool.totalDeposited(), pool.totalWithdrawn()];

        bytes32 offerId = _listOfferAccept(json);

        // The emergency brake must not trap anyone.
        vm.prank(guardian);
        pool.setDepositsPaused(true);

        address feeRecipient = market.feeRecipient();
        uint256[2] memory feeBefore = [feeRecipient.balance, market.feesOwed()];
        uint256 fee = market.feeWei();

        _settle(json, offerId);

        assertEq(
            IERC721(json.readAddress(".collection")).ownerOf(1),
            json.readAddress(".buyer.wallet"),
            "NFT not delivered"
        );
        assertEq(
            pool.currentRoot(), json.readBytes32(".rootAfterSettle"), "settle root disagrees with the SDK"
        );
        assertFalse(market.listingOf(json.readBytes32(".listingId")).active, "listing still open");
        assertTrue(market.offerOf(offerId).settled, "offer not settled");

        bool forwarded = feeRecipient.balance == feeBefore[0] + fee;
        bool deferred = market.feesOwed() == feeBefore[1] + fee;
        assertTrue(forwarded || deferred, "fee neither paid nor held");
        console.log(forwarded ? "fee forwarded to the fee recipient" : "fee deferred into feesOwed");

        _checkReceipt(json, offerId, fee);
        _cashOutEveryParty(json);

        // What is left is exactly the two bystander notes.
        assertEq(weth.balanceOf(address(pool)), start[0] + 0.01 ether, "pool WETH");
        assertEq(pool.totalDeposited(), start[1] + 1.51 ether, "totalDeposited");
        assertEq(pool.totalWithdrawn(), start[2] + 1.5 ether, "totalWithdrawn");
    }

    /// The genesis owner can move the royalty while a listing is open. A
    /// receiver with no keys stops the sale; a receiver with other keys breaks
    /// the buyer's proof; moving it back lets the same proof land. Freezing
    /// ends all of it.
    function test_movingTheGenesisRoyaltyDuringAnOpenSale() public {
        string memory json = _proofs();
        bytes32 offerId = _listOfferAccept(json);
        BacklitGenesis genesis = BacklitGenesis(json.readAddress(".collection"));
        address owner = json.readAddress(".genesisOwner");
        address creator = json.readAddress(".creator.wallet");

        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json);
        uint256 fee = market.feeWei();
        address relayer = makeAddr("relayer");
        vm.deal(relayer, 3 * fee);

        vm.prank(owner);
        genesis.setRoyaltyReceiver(makeAddr("keyless"));
        vm.expectRevert(BacklitMarket.NoKeys.selector);
        vm.prank(relayer);
        market.settle{value: fee}(offerId, proof, p, payloads);

        address other = makeAddr("other-creator");
        vm.prank(other);
        market.registerKeys(bytes32(uint256(71)), bytes32(uint256(72)));
        vm.prank(owner);
        genesis.setRoyaltyReceiver(other);
        vm.expectRevert();
        vm.prank(relayer);
        market.settle{value: fee}(offerId, proof, p, payloads);

        vm.prank(owner);
        genesis.setRoyaltyReceiver(creator);
        vm.prank(relayer);
        market.settle{value: fee}(offerId, proof, p, payloads);
        assertEq(IERC721(address(genesis)).ownerOf(1), json.readAddress(".buyer.wallet"));

        vm.startPrank(owner);
        genesis.freeze();
        vm.expectRevert(BacklitGenesis.IsFrozen.selector);
        genesis.setRoyaltyReceiver(other);
        vm.expectRevert(BacklitGenesis.IsFrozen.selector);
        genesis.setURIs("x", "y");
        vm.stopPrank();
    }

    /// A collection that behaves at listing and turns hollow before settlement
    /// cannot take the buyer's notes: the market checks the token arrived.
    function test_aCollectionThatTurnsHollowAfterListingCannotTakeThePayment() public {
        _requireHardened();
        string memory json = _proofs();
        _replayDeposits(json);
        address collection = json.readAddress(".collection");
        deployCodeTo(
            "HollowCollection.sol:HollowCollection",
            abi.encode(json.readAddress(".creator.wallet"), uint96(500)),
            collection
        );
        HollowCollection(collection).setHollow(false);
        HollowCollection(collection).mint(json.readAddress(".seller.wallet"));
        bytes32 offerId = _registerListOfferAccept(json);

        HollowCollection(collection).setHollow(true);
        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json);
        uint256 fee = market.feeWei();
        address relayer = makeAddr("relayer");
        vm.deal(relayer, fee);
        vm.prank(relayer);
        vm.expectRevert(BacklitMarket.NotDelivered.selector);
        market.settle{value: fee}(offerId, proof, p, payloads);

        assertFalse(
            pool.isSpent(p.nullifiers[0]) || pool.isSpent(p.nullifiers[1]), "the buyer's notes were spent"
        );
        assertTrue(market.listingOf(json.readBytes32(".listingId")).active, "the listing closed");
    }

    /// aeWETH credits ETH it receives to the sender, so an unwrapped payout to
    /// it would land back in the pool outside every note. The pool refuses it,
    /// and a payout to the market, before it looks at the proof.
    function test_aPayoutToWethOrTheMarketIsRefused() public {
        _requireHardened();
        string memory json = _proofs();
        _replayDeposits(json);
        (bytes memory proof, BacklitPool.SpendPublic memory p, bytes[2] memory payloads) =
            _spendCall(json, ".spendToWeth");
        assertEq(p.recipient, address(weth));
        assertTrue(p.unwrap);

        vm.expectRevert(BacklitPool.BadRecipient.selector);
        pool.spend(proof, p, payloads);
        p.unwrap = false;
        vm.expectRevert(BacklitPool.BadRecipient.selector);
        pool.spend(proof, p, payloads);
        p.recipient = address(market);
        vm.expectRevert(BacklitPool.BadRecipient.selector);
        pool.spend(proof, p, payloads);
    }

    /// A fee recipient that refuses with a huge revert payload costs the sale
    /// nothing: the market copies nothing back, and holds the fee.
    function test_aFeeRecipientThatRevertsWithAHugePayloadCannotStopASale() public {
        _requireHardened();
        string memory json = _proofs();
        bytes32 offerId = _listOfferAccept(json);
        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json);
        uint256 fee = market.feeWei();
        address relayer = makeAddr("relayer");
        vm.deal(relayer, fee);

        ReturnBomb bomb = new ReturnBomb(true);
        vm.prank(guardian);
        market.setFeeRecipient(address(bomb));
        uint256 owed = market.feesOwed();

        vm.prank(relayer);
        market.settle{value: fee, gas: 30_000_000}(offerId, proof, p, payloads);

        assertEq(IERC721(json.readAddress(".collection")).ownerOf(1), json.readAddress(".buyer.wallet"));
        assertEq(market.feesOwed(), owed + fee, "the fee was not held");
    }

    /// The same sale and cash-out once mainnet has leaves and listings of its
    /// own, which is what `_rebase` is for.
    function test_theProofsStillLandAfterMainnetMovesOn() public {
        string memory json = _proofs();
        _openForDeposits(1 ether);
        address someone = makeAddr("someone");
        vm.deal(someone, 1 ether);
        vm.prank(someone);
        pool.depositETH{value: 1 ether}(bytes32(uint256(81)), bytes32(uint256(82)), "");
        vm.store(address(market), MARKET_LISTING_NONCE, bytes32(uint256(3)));
        vm.store(address(market), MARKET_OFFER_NONCE, bytes32(uint256(5)));

        bytes32 offerId = _listOfferAccept(json);
        _settle(json, offerId);
        _cashOutEveryParty(json);
    }

    function _checkReceipt(string memory json, bytes32 offerId, uint256 fee) internal view {
        BacklitMarket.Receipt memory r = market.receiptOf(offerId);
        assertEq(r.collection, json.readAddress(".collection"));
        assertEq(r.tokenId, 1);
        assertEq(r.seller, json.readAddress(".seller.wallet"));
        assertEq(r.nftRecipient, json.readAddress(".buyer.wallet"));
        assertEq(r.royaltyReceiver, json.readAddress(".creator.wallet"));
        assertEq(r.royaltyBps, 500);
        assertEq(r.feeWei, fee);
        assertEq(r.priceCommitment, json.readBytes32(".settle.priceCommitment"));
        assertEq(r.creatorCommitment, json.readBytes32(".settle.creatorCommitment"));
    }

    /// Every note the settlement made is spendable, against the post-settle
    /// root, even as later spends grow the tree past it.
    function _cashOutEveryParty(string memory json) internal {
        address seller = json.readAddress(".seller.wallet");
        address creator = json.readAddress(".creator.wallet");
        address buyer = json.readAddress(".buyer.wallet");
        uint256[3] memory before = [seller.balance, weth.balanceOf(creator), buyer.balance];

        _spend(json, ".sellerOut");
        _spend(json, ".creatorOut");
        _spend(json, ".changeOut");

        assertEq(seller.balance, before[0] + json.readUint(".settle.sellerAmount"), "seller not paid in ETH");
        assertEq(
            weth.balanceOf(creator), before[1] + json.readUint(".settle.royaltyAmount"), "creator not paid"
        );
        assertEq(buyer.balance, before[2] + json.readUint(".settle.changeAmount"), "change not paid in ETH");
    }

    function _verifies(address verifier, bytes memory proof, bytes32[] memory inputs)
        internal
        view
        returns (bool)
    {
        try IVerifier(verifier).verify(proof, inputs) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _assertVerifies(address verifier, string memory file) internal view {
        string memory json = vm.readFile(file);
        assertTrue(
            _verifies(verifier, json.readBytes(".proof"), json.readBytes32Array(".publicInputs")),
            string.concat("deployed verifier rejected ", file)
        );
    }

    /// The real proofs, or a skip naming the command that recuts them when
    /// they were made for another deployment.
    function _proofs() internal returns (string memory json) {
        json = vm.readFile(PROOFS);
        bool current = json.readUint(".chainId") == chainId && json.readAddress(".pool") == address(pool)
            && json.readAddress(".market") == address(market) && json.readAddress(".weth") == address(weth);
        vm.skip(
            !current,
            string.concat(
                "mainnet-proofs.json was cut for pool ",
                vm.toString(json.readAddress(".pool")),
                " and market ",
                vm.toString(json.readAddress(".market")),
                ", not the deployment in deployments/4663.json; regenerate with ",
                REGENERATE
            )
        );
    }

    /// The first 4663 deployment predates the delivery check, the recipient
    /// guard, the copy-free fee send, the payload caps and the `accept` that
    /// pins the royalty. The release that brings them is the first whose market
    /// answers MAX_PAYLOAD_BYTES, so the tests that need any of them skip on
    /// anything older rather than report the old behaviour as a failure.
    function _requireHardened() internal {
        (bool hardened,) = address(market).staticcall(abi.encodeWithSignature("MAX_PAYLOAD_BYTES()"));
        vm.skip(
            !hardened,
            "the market in deployments/4663.json predates MAX_PAYLOAD_BYTES and the fixes that came with it"
        );
    }

    /// Replaces the recorded pool and market with this checkout's build, keeping
    /// the addresses (and with them the pool id the proofs are bound to), the
    /// storage, and every constructor argument the live contracts report.
    function _swapInThisBuild() internal {
        uint256 cap = pool.capWei();
        address feeRecipient = market.feeRecipient();
        uint256 feeWei = market.feeWei();
        vm.startPrank(deployer);
        deployCodeTo(
            "BacklitPool.sol:BacklitPool",
            abi.encode(address(weth), spendVerifier, guardian, cap),
            address(pool)
        );
        deployCodeTo(
            "BacklitMarket.sol:BacklitMarket",
            abi.encode(address(pool), settleVerifier, feeRecipient, feeWei, guardian),
            address(market)
        );
        vm.stopPrank();
        console.log("running this checkout's pool and market at the recorded addresses");
    }

    function _headroom() internal view returns (uint256) {
        return pool.capWei() + pool.totalWithdrawn() - pool.totalDeposited();
    }

    /// Makes room for `needed` wei of deposits, through the guardian, when
    /// mainnet is paused or closer to the cap than the scene needs.
    function _openForDeposits(uint256 needed) internal {
        if (pool.depositsPaused()) {
            console.log("mainnet deposits are paused; unpausing on the fork");
            vm.prank(guardian);
            pool.setDepositsPaused(false);
        }
        uint256 room = _headroom();
        if (room < needed) {
            console.log("raising the cap on the fork by", needed - room);
            vm.prank(guardian);
            pool.raiseCap(pool.capWei() + needed - room);
        }
    }

    /// Resets the pool's tree to empty and the market's nonces to zero when
    /// mainnet has moved past the state the proofs were cut for.
    function _rebase() internal {
        assertEq(
            uint256(vm.load(address(pool), POOL_TREE_SIZE)), pool.leafCount(), "pool layout moved: tree.size"
        );
        assertEq(
            uint256(vm.load(address(pool), POOL_TREE_DEPTH)),
            pool.treeDepth(),
            "pool layout moved: tree.depth"
        );
        if (pool.leafCount() != 0) {
            console.log("mainnet pool has leaves; rebasing the tree on the fork");
            vm.store(address(pool), POOL_TREE_SIZE, bytes32(0));
            vm.store(address(pool), POOL_TREE_DEPTH, bytes32(0));
        }
        if (
            vm.load(address(market), MARKET_LISTING_NONCE) != bytes32(0)
                || vm.load(address(market), MARKET_OFFER_NONCE) != bytes32(0)
        ) {
            console.log("mainnet market has listings or offers; rebasing its nonces on the fork");
            vm.store(address(market), MARKET_LISTING_NONCE, bytes32(0));
            vm.store(address(market), MARKET_OFFER_NONCE, bytes32(0));
        }
    }

    function _replayDeposits(string memory json) internal {
        _rebase();
        uint256[] memory amounts = json.readUintArray(".depositAmounts");
        bytes32[] memory owners = json.readBytes32Array(".depositOwners");
        bytes32[] memory salts = json.readBytes32Array(".depositSalts");
        bytes[] memory payloads = json.readBytesArray(".depositPayloads");
        bool[] memory viaWeth = json.readBoolArray(".depositViaWeth");
        address depositor = json.readAddress(".depositor");

        uint256 total = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        _openForDeposits(total);

        for (uint256 i = 0; i < amounts.length; i++) {
            vm.deal(depositor, amounts[i]);
            vm.startPrank(depositor);
            if (viaWeth[i]) {
                weth.deposit{value: amounts[i]}();
                weth.approve(address(pool), amounts[i]);
                pool.depositWETH(amounts[i], owners[i], salts[i], payloads[i]);
            } else {
                pool.depositETH{value: amounts[i]}(owners[i], salts[i], payloads[i]);
            }
            vm.stopPrank();
        }
        // The deployed PoseidonT3/T5 and LeanIMT agree with the SDK's tree.
        assertEq(
            pool.currentRoot(), json.readBytes32(".rootAfterDeposits"), "deposit root disagrees with the SDK"
        );
    }

    function _spendCall(string memory json, string memory key)
        internal
        pure
        returns (bytes memory proof, BacklitPool.SpendPublic memory p, bytes[2] memory payloads)
    {
        bytes32[] memory nullifiers = json.readBytes32Array(string.concat(key, ".nullifiers"));
        bytes32[] memory outputs = json.readBytes32Array(string.concat(key, ".outputs"));
        bytes[] memory raw = json.readBytesArray(string.concat(key, ".payloads"));
        p = BacklitPool.SpendPublic({
            root: json.readBytes32(string.concat(key, ".root")),
            nullifiers: [nullifiers[0], nullifiers[1]],
            outputs: [outputs[0], outputs[1]],
            withdrawAmount: json.readUint(string.concat(key, ".withdrawAmount")),
            recipient: json.readAddress(string.concat(key, ".recipient")),
            unwrap: json.readBool(string.concat(key, ".unwrap"))
        });
        payloads = [raw[0], raw[1]];
        proof = json.readBytes(string.concat(key, ".proof"));
    }

    function _spend(string memory json, string memory key) internal {
        (bytes memory proof, BacklitPool.SpendPublic memory p, bytes[2] memory payloads) =
            _spendCall(json, key);
        vm.prank(makeAddr("relayer"));
        pool.spend(proof, p, payloads);
    }

    function _settleCall(string memory json)
        internal
        pure
        returns (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads)
    {
        bytes32[] memory nullifiers = json.readBytes32Array(".settle.nullifiers");
        bytes[] memory raw = json.readBytesArray(".settle.payloads");
        p = BacklitMarket.SettlePublic({
            root: json.readBytes32(".settle.root"),
            nullifiers: [nullifiers[0], nullifiers[1]],
            sellerCommitment: json.readBytes32(".settle.sellerCommitment"),
            creatorCommitment: json.readBytes32(".settle.creatorCommitment"),
            changeCommitment: json.readBytes32(".settle.changeCommitment")
        });
        payloads = [raw[0], raw[1], raw[2]];
        proof = json.readBytes(".settle.proof");
    }

    function _settle(string memory json, bytes32 offerId) internal {
        (bytes memory proof, BacklitMarket.SettlePublic memory p, bytes[3] memory payloads) =
            _settleCall(json);
        uint256 fee = market.feeWei();
        address relayer = makeAddr("relayer");
        vm.deal(relayer, fee);
        vm.prank(relayer);
        market.settle{value: fee}(offerId, proof, p, payloads);
    }

    function _register(string memory json, string memory who) internal {
        address wallet = json.readAddress(string.concat(who, ".wallet"));
        assertEq(wallet.code.length, 0, "party wallet has code on mainnet");
        vm.prank(wallet);
        market.registerKeys(
            json.readBytes32(string.concat(who, ".ownerPk")),
            json.readBytes32(string.concat(who, ".viewingPk"))
        );
    }

    /// Funds the buyer, deploys Genesis where the proofs expect it, registers
    /// every party's keys, lists #1, offers and accepts.
    function _listOfferAccept(string memory json) internal returns (bytes32 offerId) {
        _replayDeposits(json);
        address collection = json.readAddress(".collection");
        assertEq(collection.code.length, 0, "the Genesis address is taken on mainnet");
        deployCodeTo(
            "BacklitGenesis.sol:BacklitGenesis",
            abi.encode(
                json.readAddress(".genesisOwner"),
                json.readAddress(".seller.wallet"),
                json.readAddress(".creator.wallet"),
                "ipfs://panes/",
                "ipfs://panes/c.json"
            ),
            collection
        );
        offerId = _registerListOfferAccept(json);
    }

    /// Everything after the collection exists: keys, listing #1, offer, accept.
    function _registerListOfferAccept(string memory json) internal returns (bytes32 offerId) {
        _requireHardened();
        address collection = json.readAddress(".collection");
        address seller = json.readAddress(".seller.wallet");
        address buyer = json.readAddress(".buyer.wallet");

        _register(json, ".seller");
        _register(json, ".buyer");
        _register(json, ".creator");

        vm.startPrank(seller);
        IERC721(collection).approve(address(market), 1);
        bytes32 listingId = market.list(collection, 1);
        vm.stopPrank();
        assertEq(listingId, json.readBytes32(".listingId"), "listing id drifted");
        assertEq(IERC721(collection).ownerOf(1), address(market), "not escrowed");

        vm.prank(buyer);
        offerId = market.offer(
            listingId,
            json.readBytes32(".settle.priceCommitment"),
            buyer,
            json.readBytes(".settle.offerPayload"),
            uint64(block.timestamp + 7 days)
        );
        assertEq(offerId, json.readBytes32(".offerId"), "offer id drifted");

        vm.prank(seller);
        market.accept(offerId, json.readBytes32(".settle.priceCommitment"), json.readUint(".royaltyBps"));
        assertEq(market.offerOf(offerId).acceptedRoyaltyBps, json.readUint(".royaltyBps"), "rate not pinned");
    }
}
