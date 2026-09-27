// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeanIMTData, InternalLeanIMT} from "@zk-kit/lean-imt.sol/InternalLeanIMT.sol";
import {PoseidonT5} from "poseidon-solidity/PoseidonT5.sol";

import {IVerifier} from "./interfaces/IVerifier.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {Field, MAX_NOTE_AMOUNT, SNARK_SCALAR_FIELD} from "./libs/Field.sol";

/// @title BacklitPool
/// @notice Holds WETH against private notes. A note is a commitment in the
/// pool's Merkle tree; spending one reveals a nullifier and nothing else.
///
/// The contract is immutable. The guardian can raise the deposit cap and stop
/// new deposits; it can never stop a withdrawal, move a note, or change a
/// verifier.
contract BacklitPool {
    using InternalLeanIMT for LeanIMTData;
    using Field for bytes32;

    /// @notice How many past roots a proof may cite.
    uint256 public constant ROOT_HISTORY = 64;

    IWETH public immutable weth;
    IVerifier public immutable spendVerifier;
    address public immutable guardian;
    address public immutable deployer;

    /// @notice Binds a proof to this deployment, so it cannot be replayed
    /// against another pool or another chain.
    bytes32 public immutable poolId;

    /// @notice Set once, by the deployer, to the market that settles sales.
    address public market;

    uint256 public capWei;
    bool public depositsPaused;

    /// @notice Cumulative deposits. The live balance is `weth.balanceOf(pool)`.
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    LeanIMTData private tree;
    bytes32[ROOT_HISTORY] private roots;
    uint256 private rootCursor;
    uint256 private rootsWritten;

    mapping(bytes32 nullifier => bool) public isSpent;

    event NoteCreated(uint256 indexed leafIndex, bytes32 commitment, bytes payload);
    event Nullified(bytes32 indexed nullifier);
    event Deposited(address indexed from, uint256 amount, uint256 leafIndex);
    event Withdrawn(address indexed to, uint256 amount);
    event MarketSet(address indexed market);
    event CapRaised(uint256 capWei);
    event DepositsPaused(bool paused);

    error AlreadyInitialised();
    error BadProof();
    error CapExceeded();
    error DepositsArePaused();
    error DuplicateNullifier();
    error NoteAlreadySpent();
    error NotTheDeployer();
    error NotTheGuardian();
    error NotTheMarket();
    error AmountOutOfRange();
    error CapNotRaised();
    error UnknownRoot();
    error Reentered();
    error TransferFailed();
    error WithdrawalFailed();
    error ZeroAddress();

    struct SpendPublic {
        bytes32 root;
        bytes32[2] nullifiers;
        bytes32[2] outputs;
        uint256 withdrawAmount;
        address recipient;
        bool unwrap;
    }

    uint256 private locked = 1;

    modifier nonReentrant() {
        if (locked != 1) revert Reentered();
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotTheGuardian();
        _;
    }

    constructor(IWETH weth_, IVerifier spendVerifier_, address guardian_, uint256 initialCapWei) {
        if (address(weth_) == address(0) || address(spendVerifier_) == address(0) || guardian_ == address(0))
        {
            revert ZeroAddress();
        }
        weth = weth_;
        spendVerifier = spendVerifier_;
        guardian = guardian_;
        deployer = msg.sender;
        capWei = initialCapWei;
        poolId = keccak256(abi.encode(block.chainid, address(this))).reduce();
        emit CapRaised(initialCapWei);
    }

    /// @notice Points the pool at its market. Callable once, by the deployer.
    function initMarket(address market_) external {
        if (msg.sender != deployer) revert NotTheDeployer();
        if (market != address(0)) revert AlreadyInitialised();
        if (market_ == address(0)) revert ZeroAddress();
        market = market_;
        emit MarketSet(market_);
    }

    // ---------------------------------------------------------------- deposits

    /// @notice Wraps ETH and turns it into a note owned by `ownerPk`.
    function depositETH(bytes32 ownerPk, bytes32 salt, bytes calldata payload) external payable {
        weth.deposit{value: msg.value}();
        _deposit(msg.value, ownerPk, salt, payload);
    }

    /// @notice Pulls WETH the caller has already approved and turns it into a note.
    function depositWETH(uint256 amount, bytes32 ownerPk, bytes32 salt, bytes calldata payload)
        external
    {
        if (!weth.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        _deposit(amount, ownerPk, salt, payload);
    }

    function _deposit(uint256 amount, bytes32 ownerPk, bytes32 salt, bytes calldata payload) private {
        if (depositsPaused) revert DepositsArePaused();
        if (amount == 0 || amount >= MAX_NOTE_AMOUNT) revert AmountOutOfRange();
        // The funds are already in by the time we get here, so this bounds
        // what the pool holds rather than what any one deposit adds.
        if (weth.balanceOf(address(this)) > capWei) revert CapExceeded();

        bytes32 commitment = bytes32(
            PoseidonT5.hash(
                [uint256(uint160(address(weth))), amount, uint256(ownerPk.check()), uint256(salt.check())]
            )
        );

        totalDeposited += amount;
        uint256 leafIndex = _insert(commitment, payload);
        emit Deposited(msg.sender, amount, leafIndex);
    }

    // ------------------------------------------------------------------ spends

    /// @notice Spends two notes into two notes, optionally paying part of the
    /// value out to `recipient`. This is transfer, consolidation and withdrawal.
    function spend(bytes calldata proof, SpendPublic calldata p, bytes[2] calldata payloads)
        external
        nonReentrant
    {
        if (!isKnownRoot(p.root)) revert UnknownRoot();
        if (p.withdrawAmount >= MAX_NOTE_AMOUNT) revert AmountOutOfRange();

        bytes32[] memory publicInputs = new bytes32[](9);
        publicInputs[0] = poolId;
        publicInputs[1] = Field.fromAddress(address(weth));
        publicInputs[2] = p.root;
        publicInputs[3] = p.nullifiers[0].check();
        publicInputs[4] = p.nullifiers[1].check();
        publicInputs[5] = p.outputs[0].check();
        publicInputs[6] = p.outputs[1].check();
        publicInputs[7] = bytes32(p.withdrawAmount);
        publicInputs[8] = Field.fromAddress(p.recipient);

        if (!spendVerifier.verify(proof, publicInputs)) revert BadProof();

        _nullify(p.nullifiers[0], p.nullifiers[1]);
        _insert(p.outputs[0], payloads[0]);
        _insert(p.outputs[1], payloads[1]);

        if (p.withdrawAmount > 0) {
            totalWithdrawn += p.withdrawAmount;
            if (p.unwrap) {
                weth.withdraw(p.withdrawAmount);
                (bool sent,) = p.recipient.call{value: p.withdrawAmount}("");
                if (!sent) revert WithdrawalFailed();
            } else {
                if (!weth.transfer(p.recipient, p.withdrawAmount)) revert TransferFailed();
            }
            emit Withdrawn(p.recipient, p.withdrawAmount);
        }
    }

    /// @notice Applies the note movement of a settled sale. The market has
    /// already verified the settle proof against these exact values.
    function spendFromMarket(
        bytes32 root,
        bytes32[2] calldata nullifiers,
        bytes32[3] calldata outputs,
        bytes[3] calldata payloads
    ) external {
        if (msg.sender != market) revert NotTheMarket();
        if (!isKnownRoot(root)) revert UnknownRoot();

        _nullify(nullifiers[0], nullifiers[1]);
        for (uint256 i = 0; i < 3; i++) {
            _insert(outputs[i], payloads[i]);
        }
    }

    // ------------------------------------------------------------------- views

    function currentRoot() external view returns (bytes32) {
        return bytes32(tree._root());
    }

    function leafCount() external view returns (uint256) {
        return tree.size;
    }

    function treeDepth() external view returns (uint256) {
        return tree.depth;
    }

    /// @notice True for any of the last `ROOT_HISTORY` roots. Walks backwards
    /// from the newest, so a fresh proof costs one read.
    function isKnownRoot(bytes32 root) public view returns (bool) {
        if (root == bytes32(0)) return false;
        uint256 checks = rootsWritten < ROOT_HISTORY ? rootsWritten : ROOT_HISTORY;
        uint256 cursor = rootCursor;
        for (uint256 i = 0; i < checks; i++) {
            cursor = cursor == 0 ? ROOT_HISTORY - 1 : cursor - 1;
            if (roots[cursor] == root) return true;
        }
        return false;
    }

    function knownRoots() external view returns (bytes32[] memory out) {
        uint256 checks = rootsWritten < ROOT_HISTORY ? rootsWritten : ROOT_HISTORY;
        out = new bytes32[](checks);
        uint256 cursor = rootCursor;
        for (uint256 i = 0; i < checks; i++) {
            cursor = cursor == 0 ? ROOT_HISTORY - 1 : cursor - 1;
            out[i] = roots[cursor];
        }
    }

    // -------------------------------------------------------------- guardian

    /// @notice Raises the deposit cap. It can only go up.
    function raiseCap(uint256 newCapWei) external onlyGuardian {
        if (newCapWei <= capWei) revert CapNotRaised();
        capWei = newCapWei;
        emit CapRaised(newCapWei);
    }

    /// @notice Stops new deposits. Withdrawals and settlement are unaffected
    /// and there is no function that can stop them.
    function setDepositsPaused(bool paused) external onlyGuardian {
        depositsPaused = paused;
        emit DepositsPaused(paused);
    }

    // -------------------------------------------------------------- internals

    function _insert(bytes32 commitment, bytes calldata payload) private returns (uint256 leafIndex) {
        leafIndex = tree.size;
        bytes32 root = bytes32(tree._insert(uint256(commitment.check())));
        roots[rootCursor] = root;
        rootCursor = (rootCursor + 1) % ROOT_HISTORY;
        unchecked {
            rootsWritten++;
        }
        emit NoteCreated(leafIndex, commitment, payload);
    }

    function _nullify(bytes32 a, bytes32 b) private {
        if (a == b) revert DuplicateNullifier();
        if (isSpent[a] || isSpent[b]) revert NoteAlreadySpent();
        isSpent[a] = true;
        isSpent[b] = true;
        emit Nullified(a);
        emit Nullified(b);
    }

    /// @dev Only the WETH contract pays ETH in, when a withdrawal unwraps.
    receive() external payable {
        if (msg.sender != address(weth)) revert TransferFailed();
    }
}
