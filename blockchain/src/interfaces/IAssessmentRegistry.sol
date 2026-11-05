// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAssessmentRegistry {
    enum VerificationStatus {
        Unverified,      // 0
        EvidenceChecked, // 1
        SourceVerified,  // 2
        ManualReview     // 3
    }

    struct AssessmentRecord {
        bytes32 assessmentHash;        // SHA-256 hash of the full assessment snapshot
        bytes32 previousAssessmentHash;// Link to prior version (bytes32(0) if first)
        address borrower;              // Borrower wallet address
        string modelVersion;           // AI model version (e.g. "1.0.0")
        uint256 timestamp;             // Block timestamp when recorded
        VerificationStatus verificationStatus; // Status at assessment time
        string riskCategory;           // "LOW", "MEDIUM", "HIGH"
        uint256 version;               // Sequential version number per borrower
    }

    event AssessmentRecorded(
        bytes32 indexed assessmentId,
        address indexed borrower,
        bytes32 assessmentHash,
        bytes32 previousAssessmentHash,
        string modelVersion,
        uint256 timestamp,
        VerificationStatus verificationStatus,
        string riskCategory,
        uint256 version
    );

    function recordAssessment(
        bytes32 assessmentId,
        address borrower,
        bytes32 assessmentHash,
        bytes32 previousAssessmentHash,
        string calldata modelVersion,
        VerificationStatus verificationStatus,
        string calldata riskCategory
    ) external;

    function getAssessment(bytes32 assessmentId) external view returns (AssessmentRecord memory);
    function getLatestAssessment(address borrower) external view returns (AssessmentRecord memory);
    function getBorrowerAssessmentHistory(address borrower) external view returns (bytes32[] memory);
    function getBorrowerAssessmentCount(address borrower) external view returns (uint256);
    function verifyAssessmentHash(bytes32 assessmentId, bytes32 expectedHash) external view returns (bool);
}
