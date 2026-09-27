// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BacklitPool} from "../src/BacklitPool.sol";
import {IVerifier} from "../src/interfaces/IVerifier.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";

import {MockVerifier} from "./mocks/MockVerifier.sol";
import {TestnetWETH} from "./mocks/TestnetWETH.sol";

/// @notice Drives the pool through random deposits, spends and guardian
/// actions. The verifier accepts everything here on purpose: the point is that
/// the pool stays solvent and honest about nullifiers even when the proof
/// system is assumed to pass, so any loss would be the pool's own doing.
contract PoolHandler is Test {
    BacklitPool public pool;
    TestnetWETH public weth;
    address public guardian;

    uint256 public depositedTotal;
    uint256 public withdrawnTotal;
    uint256 public nullifierNonce;
    uint256 public commitmentNonce = 1_000_000;

    bytes32[] public usedNullifiers;
    bytes32[] public roots;

    constructor(BacklitPool pool_, TestnetWETH weth_, address guardian_) {
        pool = pool_;
        weth = weth_;
        guardian = guardian_;
    }

    receive() external payable {}

    function deposit(uint256 amount, uint256 ownerSeed) public {
        amount = bound(amount, 1, 5 ether);
        if (weth.balanceOf(address(pool)) + amount > pool.capWei()) return;
        if (pool.depositsPaused()) return;

        vm.deal(address(this), amount);
        pool.depositETH{value: amount}(
            bytes32(bound(ownerSeed, 1, type(uint128).max)),
            bytes32(++commitmentNonce),
            hex"01"
        );
        depositedTotal += amount;
        roots.push(pool.currentRoot());
    }

    function spend(uint256 withdrawAmount, bool unwrap) public {
        uint256 held = weth.balanceOf(address(pool));
        if (held == 0) return;
        withdrawAmount = bound(withdrawAmount, 0, held);

        bytes32 a = bytes32(++nullifierNonce);
        bytes32 b = bytes32(++nullifierNonce);

        pool.spend(
            hex"00",
            BacklitPool.SpendPublic({
                root: pool.currentRoot(),
                nullifiers: [a, b],
                outputs: [bytes32(++commitmentNonce), bytes32(++commitmentNonce)],
                withdrawAmount: withdrawAmount,
                recipient: address(this),
                unwrap: unwrap
            }),
            [bytes(hex"aa"), bytes(hex"bb")]
        );

        usedNullifiers.push(a);
        usedNullifiers.push(b);
        withdrawnTotal += withdrawAmount;
        roots.push(pool.currentRoot());
    }

    /// @dev Tries to spend a nullifier that has already been published.
    function replay(uint256 pick) public {
        if (usedNullifiers.length == 0) return;
        bytes32 used = usedNullifiers[bound(pick, 0, usedNullifiers.length - 1)];

        try pool.spend(
            hex"00",
            BacklitPool.SpendPublic({
                root: pool.currentRoot(),
                nullifiers: [used, bytes32(++nullifierNonce)],
                outputs: [bytes32(++commitmentNonce), bytes32(++commitmentNonce)],
                withdrawAmount: 0,
                recipient: address(this),
                unwrap: false
            }),
            [bytes(hex"aa"), bytes(hex"bb")]
        ) {
            revert("a spent nullifier was accepted");
        } catch {
            // Expected.
        }
    }

    function raiseCap(uint256 newCap) public {
        newCap = bound(newCap, pool.capWei() + 1, pool.capWei() + 1_000 ether);
        vm.prank(guardian);
        pool.raiseCap(newCap);
    }

    function pauseDeposits(bool paused) public {
        vm.prank(guardian);
        pool.setDepositsPaused(paused);
    }

    function usedNullifierCount() external view returns (uint256) {
        return usedNullifiers.length;
    }

    function rootCount() external view returns (uint256) {
        return roots.length;
    }
}

contract PoolInvariants is Test {
    TestnetWETH internal weth;
    BacklitPool internal pool;
    PoolHandler internal handler;
    address internal guardian = makeAddr("guardian");

    function setUp() public {
        weth = new TestnetWETH();
        MockVerifier verifier = new MockVerifier();
        pool = new BacklitPool(IWETH(address(weth)), IVerifier(address(verifier)), guardian, 50 ether);
        pool.initMarket(address(this));

        handler = new PoolHandler(pool, weth, guardian);
        targetContract(address(handler));
    }

    /// @notice The pool never owes more than it holds.
    function invariant_thePoolHoldsWhatItOwes() public view {
        assertEq(
            weth.balanceOf(address(pool)),
            handler.depositedTotal() - handler.withdrawnTotal(),
            "the pool's balance drifted from deposits minus withdrawals"
        );
    }

    /// @notice A published nullifier stays published.
    function invariant_everyPublishedNullifierIsMarkedSpent() public view {
        uint256 count = handler.usedNullifierCount();
        for (uint256 i = 0; i < count; i++) {
            assertTrue(pool.isSpent(handler.usedNullifiers(i)), "a nullifier was forgotten");
        }
    }

    /// @notice The tree only ever grows, and the root it has now is citable.
    function invariant_theCurrentRootIsAlwaysKnown() public view {
        if (pool.leafCount() == 0) return;
        assertTrue(pool.isKnownRoot(pool.currentRoot()));
    }

    /// @notice No root the tree has had is ever forgotten.
    function invariant_everyRootStaysKnown() public view {
        uint256 count = handler.rootCount();
        for (uint256 i = 0; i < count; i++) {
            assertTrue(pool.isKnownRoot(handler.roots(i)), "a root was forgotten");
        }
    }

    /// @notice The cap never falls, whatever the guardian does.
    function invariant_theCapNeverFalls() public view {
        assertGe(pool.capWei(), 50 ether);
    }

    /// @notice The pool holds no loose ETH; everything is wrapped.
    function invariant_thePoolHoldsNoLooseETH() public view {
        assertEq(address(pool).balance, 0);
    }
}
