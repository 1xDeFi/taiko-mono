// SPDX-License-Identifier: MIT
//
// ╭━━━━╮╱╱╭╮╱╱╱╱╱╭╮╱╱╱╱╱╭╮
// ┃╭╮╭╮┃╱╱┃┃╱╱╱╱╱┃┃╱╱╱╱╱┃┃
// ╰╯┃┃┣┻━┳┫┃╭┳━━╮┃┃╱╱╭━━┫╰━┳━━╮
// ╱╱┃┃┃╭╮┣┫╰╯┫╭╮┃┃┃╱╭┫╭╮┃╭╮┃━━┫
// ╱╱┃┃┃╭╮┃┃╭╮┫╰╯┃┃╰━╯┃╭╮┃╰╯┣━━┃
// ╱╱╰╯╰╯╰┻┻╯╰┻━━╯╰━━━┻╯╰┻━━┻━━╯
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";

import "../common/ConfigManager.sol";
import "../common/EssentialContract.sol";
import "../common/IHeaderSync.sol";
import "../libs/LibAnchorSignature.sol";
import "./LibData.sol";
import "./v1/V1Events.sol";
import "./v1/V1Finalizing.sol";
import "./v1/V1Proposing.sol";
import "./v1/V1Proving.sol";
import "./v1/V1Utils.sol";

/**
 * @author dantaik <dan@taiko.xyz>
 */
contract TaikoL1 is EssentialContract, IHeaderSync, V1Events {
    using LibData for LibData.State;
    using LibTxDecoder for bytes;
    using SafeCastUpgradeable for uint256;

    LibData.State public state;
    uint256[43] private __gap;

    function init(
        address _addressManager,
        bytes32 _genesisBlockHash
    ) external initializer {
        EssentialContract._init(_addressManager);
        V1Finalizing.init(state, _genesisBlockHash);
    }

    /**
     * Write a _commit hash_ so a few blocks later a L2 block can be proposed
     * such that `calculateCommitHash(meta.beneficiary, meta.txListHash)` equals
     * to this commit hash.
     *
     * @param commitHash Calculated with:
     *                  `calculateCommitHash(beneficiary, txListHash)`.
     */
    function commitBlock(bytes32 commitHash) external {
        V1Proposing.commitBlock(state, commitHash);
    }

    /**
     * Propose a Taiko L2 block.
     *
     * @param inputs A list of data input:
     *        - inputs[0] is abi-encoded BlockMetadata that the actual L2 block
     *          header must satisfy.
     *          Note the following fields in the provided meta object must
     *          be zeros -- their actual values will be provisioned by Ethereum.
     *            - id
     *            - l1Height
     *            - l1Hash
     *            - mixHash
     *            - timestamp
     *        - inputs[1] is a list of transactions in this block, encoded with
     *          RLP. Note, in the corresponding L2 block an _anchor transaction_
     *          will be the first transaction in the block -- if there are
     *          n transactions in `txList`, then there will be up to n+1
     *          transactions in the L2 block.
     */
    function proposeBlock(bytes[] calldata inputs) external nonReentrant {
        V1Proposing.proposeBlock(state, inputs);
        V1Finalizing.verifyBlocks(
            state,
            LibConstants.TAIKO_MAX_VERIFICATIONS_PER_TX,
            false
        );
    }

    /**
     * Prove a block is valid with a zero-knowledge proof, a transaction
     * merkel proof, and a receipt merkel proof.
     *
     * @param blockIndex The index of the block to prove. This is also used
     *        to select the right implementation version.
     * @param inputs A list of data input:
     *        - inputs[0] is an abi-encoded object with various information
     *          regarding  the block to be proven and the actual proofs.
     *        - inputs[1] is the actual anchor transaction in this L2 block.
     *          Note that the anchor transaction is always the first transaction
     *          in the block.
     *        - inputs[2] is the receipt of the anchor transaction.
     */

    function proveBlock(
        uint256 blockIndex,
        bytes[] calldata inputs
    ) external nonReentrant {
        V1Proving.proveBlock(state, AddressResolver(this), blockIndex, inputs);
        V1Finalizing.verifyBlocks(
            state,
            LibConstants.TAIKO_MAX_VERIFICATIONS_PER_TX,
            false
        );
    }

    /**
     * Prove a block is invalid with a zero-knowledge proof and a receipt
     * merkel proof.
     *
     * @param blockIndex The index of the block to prove. This is also used to
     *        select the right implementation version.
     * @param inputs A list of data input:
     *        - inputs[0] An Evidence object with various information regarding
     *          the block to be proven and the actual proofs.
     *        - inputs[1] The target block to be proven invalid.
     *        - inputs[2] The receipt for the `invalidBlock` transaction
     *          on L2. Note that the `invalidBlock` transaction is supposed to
     *          be the only transaction in the L2 block.
     */
    function proveBlockInvalid(
        uint256 blockIndex,
        bytes[] calldata inputs
    ) external nonReentrant {
        V1Proving.proveBlockInvalid(
            state,
            AddressResolver(this),
            blockIndex,
            inputs
        );
        V1Finalizing.verifyBlocks(
            state,
            LibConstants.TAIKO_MAX_VERIFICATIONS_PER_TX,
            false
        );
    }

    /**
     * Verify up to N blocks.
     * @param maxBlocks Max number of blocks to verify.
     */
    function verifyBlocks(uint256 maxBlocks) external nonReentrant {
        require(maxBlocks > 0, "L1:maxBlocks");
        V1Finalizing.verifyBlocks(state, maxBlocks, true);
    }

    /* Add or remove a prover from the whitelist.
     *
     * @param prover The prover to be added or removed.
     * @param whitelisted True to add; remove otherwise.
     */
    function whitelistProver(
        address prover,
        bool whitelisted
    ) public onlyOwner {
        V1Proving.whitelistProver(state, prover, whitelisted);
    }

    /**
     * Halt or resume the chain.
     * @param toHalt True to halt, false to resume.
     */
    function halt(bool toHalt) public onlyOwner {
        V1Utils.halt(state, toHalt);
    }

    /**
     * Check whether a prover is whitelisted.
     *
     * @param prover The prover.
     * @return True if the prover is whitelisted, false otherwise.
     */
    function isProverWhitelisted(address prover) public view returns (bool) {
        return V1Proving.isProverWhitelisted(state, prover);
    }

    /**
     * Check if the L1 is halted.
     * @return True if halted, false otherwise.
     */
    function isHalted() public view returns (bool) {
        return V1Utils.isHalted(state);
    }

    function isCommitValid(bytes32 hash) public view returns (bool) {
        return V1Proposing.isCommitValid(state, hash);
    }

    function getCommitHeight(bytes32 commitHash) public view returns (uint256) {
        return state.commits[commitHash];
    }

    function getProposedBlock(
        uint256 id
    ) public view returns (LibData.ProposedBlock memory) {
        return state.getProposedBlock(id);
    }

    function getSyncedHeader(
        uint256 number
    ) public view override returns (bytes32) {
        return state.getL2BlockHash(number);
    }

    function getLatestSyncedHeader() public view override returns (bytes32) {
        return state.getL2BlockHash(state.latestVerifiedHeight);
    }

    function getStateVariables()
        public
        view
        returns (
            uint64 /*genesisHeight*/,
            uint64 /*latestVerifiedHeight*/,
            uint64 /*latestVerifiedId*/,
            uint64 /*nextBlockId*/
        )
    {
        return state.getStateVariables();
    }

    function signWithGoldenTouch(
        bytes32 hash,
        uint8 k
    ) public view returns (uint8 v, uint256 r, uint256 s) {
        return LibAnchorSignature.signTransaction(hash, k);
    }

    function getConstants()
        public
        pure
        returns (
            uint256, // TAIKO_CHAIN_ID
            uint256, // TAIKO_MAX_PROPOSED_BLOCKS
            uint256, // TAIKO_MAX_VERIFICATIONS_PER_TX
            uint256, // TAIKO_COMMIT_DELAY_CONFIRMATIONS
            uint256, // TAIKO_MAX_PROOFS_PER_FORK_CHOICE
            uint256, // TAIKO_BLOCK_MAX_GAS_LIMIT
            uint256, // TAIKO_BLOCK_MAX_TXS
            bytes32, // TAIKO_BLOCK_DEADEND_HASH
            uint256, // TAIKO_TXLIST_MAX_BYTES
            uint256, // TAIKO_TX_MIN_GAS_LIMIT
            uint256, // V1_ANCHOR_TX_GAS_LIMIT
            bytes4, // V1_ANCHOR_TX_SELECTOR
            bytes32 // V1_INVALIDATE_BLOCK_LOG_TOPIC
        )
    {
        return (
            LibConstants.TAIKO_CHAIN_ID,
            LibConstants.TAIKO_MAX_PROPOSED_BLOCKS,
            LibConstants.TAIKO_MAX_VERIFICATIONS_PER_TX,
            LibConstants.TAIKO_COMMIT_DELAY_CONFIRMATIONS,
            LibConstants.TAIKO_MAX_PROOFS_PER_FORK_CHOICE,
            LibConstants.TAIKO_BLOCK_MAX_GAS_LIMIT,
            LibConstants.TAIKO_BLOCK_MAX_TXS,
            LibConstants.TAIKO_BLOCK_DEADEND_HASH,
            LibConstants.TAIKO_TXLIST_MAX_BYTES,
            LibConstants.TAIKO_TX_MIN_GAS_LIMIT,
            LibConstants.V1_ANCHOR_TX_GAS_LIMIT,
            LibConstants.V1_ANCHOR_TX_SELECTOR,
            LibConstants.V1_INVALIDATE_BLOCK_LOG_TOPIC
        );
    }
}
