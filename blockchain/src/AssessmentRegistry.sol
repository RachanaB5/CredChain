// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IAssessmentRegistry.sol";

/**
 * @title AssessmentRegistry
 * @author CredChain Team
 * @notice Immutable on-chain registry for anchoring AI credit assessment records
 * @dev Stores cryptographic assessment hashes, risk categories, and version chains
 *      per borrower. Records are append-only — once written they cannot be updated
 *      or deleted. Only authorized recorders (RECORDER_ROLE) or governance admins
 *      may submit assessment records. Borrowers cannot self-record.
 */
contract AssessmentRegistry is IAssessmentRegistry, AccessControl, Pausable {
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice assessmentId => AssessmentRecord
    mapping(bytes32 => AssessmentRecord) private _assessments;

    /// @notice borrower wallet address => ordered list of assessment IDs
    mapping(address => bytes32[]) private _borrowerAssessments;

    /// @notice borrower wallet address => sequential version counter
    mapping(address => uint256) private _borrowerVersionCounter;

    // Custom Errors
    error ZeroAssessmentId();
    error ZeroAssessmentHash();
    error ZeroAddress();
    error AssessmentAlreadyExists(bytes32 assessmentId);
    error AssessmentNotFound(bytes32 assessmentId);
    error UnauthorizedRecorder(address caller);
    error BorrowerCannotSelfRecord();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RECORDER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /**
     * @notice Record a new immutable AI assessment on-chain
     * @dev Restricted to RECORDER_ROLE or DEFAULT_ADMIN_ROLE.
     *      Borrowers are strictly forbidden from self-recording to prevent fraud.
     *      Each call increments the borrower's version counter and links to the
     *      previous assessment hash for chain-of-custody traceability.
     * @param assessmentId Unique identifier for this assessment
     * @param borrower Target borrower wallet address
     * @param assessmentHash SHA-256 hash of the full assessment snapshot
     * @param previousAssessmentHash Hash linking to prior assessment (bytes32(0) if first)
     * @param modelVersion AI model version string (e.g. "1.0.0")
     * @param verificationStatus Verification status at assessment time
     * @param riskCategory Risk classification ("LOW", "MEDIUM", "HIGH")
     */
    function recordAssessment(
        bytes32 assessmentId,
        address borrower,
        bytes32 assessmentHash,
        bytes32 previousAssessmentHash,
        string calldata modelVersion,
        VerificationStatus verificationStatus,
        string calldata riskCategory
    ) external whenNotPaused {
        if (assessmentId == bytes32(0)) revert ZeroAssessmentId();
        if (assessmentHash == bytes32(0)) revert ZeroAssessmentHash();
        if (borrower == address(0)) revert ZeroAddress();

        if (!hasRole(RECORDER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedRecorder(msg.sender);
        }

        // Borrowers can never submit their own assessment records
        if (msg.sender == borrower && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert BorrowerCannotSelfRecord();
        }

        // Prevent overwriting an existing assessment record (immutability)
        if (_assessments[assessmentId].timestamp != 0) {
            revert AssessmentAlreadyExists(assessmentId);
        }

        // Increment version counter for borrower
        uint256 newVersion = ++_borrowerVersionCounter[borrower];

        _assessments[assessmentId] = AssessmentRecord({
            assessmentHash: assessmentHash,
            previousAssessmentHash: previousAssessmentHash,
            borrower: borrower,
            modelVersion: modelVersion,
            timestamp: block.timestamp,
            verificationStatus: verificationStatus,
            riskCategory: riskCategory,
            version: newVersion
        });

        _borrowerAssessments[borrower].push(assessmentId);

        emit AssessmentRecorded(
            assessmentId,
            borrower,
            assessmentHash,
            previousAssessmentHash,
            modelVersion,
            block.timestamp,
            verificationStatus,
            riskCategory,
            newVersion
        );
    }

    /**
     * @notice Retrieve the full assessment record by its unique ID
     * @param assessmentId The assessment identifier to look up
     * @return The AssessmentRecord struct
     */
    function getAssessment(bytes32 assessmentId) external view returns (AssessmentRecord memory) {
        if (_assessments[assessmentId].timestamp == 0) {
            revert AssessmentNotFound(assessmentId);
        }
        return _assessments[assessmentId];
    }

    /**
     * @notice Retrieve the most recent assessment for a borrower
     * @param borrower The borrower wallet address
     * @return The latest AssessmentRecord struct
     */
    function getLatestAssessment(address borrower) external view returns (AssessmentRecord memory) {
        uint256 count = _borrowerAssessments[borrower].length;
        if (count == 0) {
            revert AssessmentNotFound(bytes32(0));
        }
        bytes32 latestId = _borrowerAssessments[borrower][count - 1];
        return _assessments[latestId];
    }

    /**
     * @notice Get the ordered list of assessment IDs for a borrower
     * @param borrower The borrower wallet address
     * @return Array of assessment IDs in chronological order
     */
    function getBorrowerAssessmentHistory(address borrower) external view returns (bytes32[] memory) {
        return _borrowerAssessments[borrower];
    }

    /**
     * @notice Get the number of assessments recorded for a borrower
     * @param borrower The borrower wallet address
     * @return The assessment count
     */
    function getBorrowerAssessmentCount(address borrower) external view returns (uint256) {
        return _borrowerAssessments[borrower].length;
    }

    /**
     * @notice Verify that an assessment's stored hash matches an expected hash
     * @param assessmentId The assessment identifier to check
     * @param expectedHash The hash to compare against
     * @return True if the stored hash matches the expected hash
     */
    function verifyAssessmentHash(bytes32 assessmentId, bytes32 expectedHash) external view returns (bool) {
        if (_assessments[assessmentId].timestamp == 0) {
            revert AssessmentNotFound(assessmentId);
        }
        return _assessments[assessmentId].assessmentHash == expectedHash;
    }

    // ============================
    //  Emergency Controls
    // ============================

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
