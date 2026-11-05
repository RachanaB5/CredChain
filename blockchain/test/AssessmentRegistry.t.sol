// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AssessmentRegistry.sol";

contract AssessmentRegistryTest is Test {
    AssessmentRegistry registry;

    address admin = address(1);
    address recorder = address(2);
    address borrower = address(3);
    address unauthorized = address(4);

    bytes32 assessmentId1 = keccak256("assessment-1");
    bytes32 assessmentId2 = keccak256("assessment-2");
    bytes32 assessmentId3 = keccak256("assessment-3");
    bytes32 assessmentHash1 = keccak256("assessment-snapshot-1");
    bytes32 assessmentHash2 = keccak256("assessment-snapshot-2");
    bytes32 assessmentHash3 = keccak256("assessment-snapshot-3");

    event AssessmentRecorded(
        bytes32 indexed assessmentId,
        address indexed borrower,
        bytes32 assessmentHash,
        bytes32 previousAssessmentHash,
        string modelVersion,
        uint256 timestamp,
        IAssessmentRegistry.VerificationStatus verificationStatus,
        string riskCategory,
        uint256 version
    );

    function setUp() public {
        vm.startPrank(admin);
        registry = new AssessmentRegistry(admin);
        registry.grantRole(registry.RECORDER_ROLE(), recorder);
        vm.stopPrank();
    }

    // ============================
    //  1. Successful Recording
    // ============================

    function test_RecordAssessment_ByAuthorizedRecorder() public {
        vm.prank(recorder);
        vm.expectEmit(true, true, false, true);
        emit AssessmentRecorded(
            assessmentId1,
            borrower,
            assessmentHash1,
            bytes32(0),
            "1.0.0",
            block.timestamp,
            IAssessmentRegistry.VerificationStatus.EvidenceChecked,
            "LOW",
            1
        );
        registry.recordAssessment(
            assessmentId1,
            borrower,
            assessmentHash1,
            bytes32(0),
            "1.0.0",
            IAssessmentRegistry.VerificationStatus.EvidenceChecked,
            "LOW"
        );

        IAssessmentRegistry.AssessmentRecord memory rec = registry.getAssessment(assessmentId1);
        assertEq(rec.assessmentHash, assessmentHash1);
        assertEq(rec.previousAssessmentHash, bytes32(0));
        assertEq(rec.borrower, borrower);
        assertEq(rec.modelVersion, "1.0.0");
        assertEq(rec.timestamp, block.timestamp);
        assertEq(uint256(rec.verificationStatus), uint256(IAssessmentRegistry.VerificationStatus.EvidenceChecked));
        assertEq(rec.riskCategory, "LOW");
        assertEq(rec.version, 1);
    }

    function test_RecordAssessment_ByAdmin() public {
        vm.prank(admin);
        registry.recordAssessment(
            assessmentId1,
            borrower,
            assessmentHash1,
            bytes32(0),
            "1.0.0",
            IAssessmentRegistry.VerificationStatus.SourceVerified,
            "MEDIUM"
        );

        IAssessmentRegistry.AssessmentRecord memory rec = registry.getAssessment(assessmentId1);
        assertEq(rec.borrower, borrower);
        assertEq(rec.version, 1);
    }

    // ============================
    //  2. Reject Unauthorized
    // ============================

    function test_Revert_UnauthorizedAddress() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(AssessmentRegistry.UnauthorizedRecorder.selector, unauthorized)
        );
        registry.recordAssessment(
            assessmentId1,
            borrower,
            assessmentHash1,
            bytes32(0),
            "1.0.0",
            IAssessmentRegistry.VerificationStatus.Unverified,
            "LOW"
        );
    }

    // ============================
    //  3. Reject Borrower Self-Recording
    // ============================

    function test_Revert_BorrowerCannotSelfRecord() public {
        // Grant recorder role to borrower, but they still can't record for themselves
        vm.startPrank(admin);
        registry.grantRole(registry.RECORDER_ROLE(), borrower);
        vm.stopPrank();

        vm.prank(borrower);
        vm.expectRevert(AssessmentRegistry.BorrowerCannotSelfRecord.selector);
        registry.recordAssessment(
            assessmentId1,
            borrower,
            assessmentHash1,
            bytes32(0),
            "1.0.0",
            IAssessmentRegistry.VerificationStatus.EvidenceChecked,
            "LOW"
        );
    }

    function test_AdminCanRecordForSelf() public {
        // Admin IS allowed to record even if admin == borrower
        vm.prank(admin);
        registry.recordAssessment(
            assessmentId1,
            admin,
            assessmentHash1,
            bytes32(0),
            "1.0.0",
            IAssessmentRegistry.VerificationStatus.EvidenceChecked,
            "LOW"
        );

        IAssessmentRegistry.AssessmentRecord memory rec = registry.getAssessment(assessmentId1);
        assertEq(rec.borrower, admin);
    }

    // ============================
    //  4. Reject Duplicate Assessment ID
    // ============================

    function test_Revert_DuplicateAssessmentId() public {
        vm.startPrank(recorder);
        registry.recordAssessment(
            assessmentId1,
            borrower,
            assessmentHash1,
            bytes32(0),
            "1.0.0",
            IAssessmentRegistry.VerificationStatus.Unverified,
            "LOW"
        );

        vm.expectRevert(
            abi.encodeWithSelector(AssessmentRegistry.AssessmentAlreadyExists.selector, assessmentId1)
        );
        registry.recordAssessment(
            assessmentId1,
            borrower,
            assessmentHash2,
            assessmentHash1,
            "1.1.0",
            IAssessmentRegistry.VerificationStatus.EvidenceChecked,
            "MEDIUM"
        );
        vm.stopPrank();
    }

    // ============================
    //  5. Verify Assessment Hash
    // ============================

    function test_VerifyAssessmentHash_Matching() public {
        vm.prank(recorder);
        registry.recordAssessment(
            assessmentId1,
            borrower,
            assessmentHash1,
            bytes32(0),
            "1.0.0",
            IAssessmentRegistry.VerificationStatus.EvidenceChecked,
            "LOW"
        );

        assertTrue(registry.verifyAssessmentHash(assessmentId1, assessmentHash1));
        assertFalse(registry.verifyAssessmentHash(assessmentId1, assessmentHash2));
    }

    function test_Revert_VerifyAssessmentHash_NotFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(AssessmentRegistry.AssessmentNotFound.selector, assessmentId1)
        );
        registry.verifyAssessmentHash(assessmentId1, assessmentHash1);
    }

    // ============================
    //  6. Version Chain (v1 → v2 → v3)
    // ============================

    function test_VersionChain_LinkedCorrectly() public {
        vm.startPrank(recorder);

        // v1
        registry.recordAssessment(
            assessmentId1,
            borrower,
            assessmentHash1,
            bytes32(0),
            "1.0.0",
            IAssessmentRegistry.VerificationStatus.Unverified,
            "HIGH"
        );

        // v2
        registry.recordAssessment(
            assessmentId2,
            borrower,
            assessmentHash2,
            assessmentHash1,
            "1.1.0",
            IAssessmentRegistry.VerificationStatus.EvidenceChecked,
            "MEDIUM"
        );

        // v3
        registry.recordAssessment(
            assessmentId3,
            borrower,
            assessmentHash3,
            assessmentHash2,
            "2.0.0",
            IAssessmentRegistry.VerificationStatus.SourceVerified,
            "LOW"
        );

        vm.stopPrank();

        IAssessmentRegistry.AssessmentRecord memory v1 = registry.getAssessment(assessmentId1);
        IAssessmentRegistry.AssessmentRecord memory v2 = registry.getAssessment(assessmentId2);
        IAssessmentRegistry.AssessmentRecord memory v3 = registry.getAssessment(assessmentId3);

        // Version numbers are sequential
        assertEq(v1.version, 1);
        assertEq(v2.version, 2);
        assertEq(v3.version, 3);

        // Chain links
        assertEq(v1.previousAssessmentHash, bytes32(0));
        assertEq(v2.previousAssessmentHash, assessmentHash1);
        assertEq(v3.previousAssessmentHash, assessmentHash2);

        // Count
        assertEq(registry.getBorrowerAssessmentCount(borrower), 3);
    }

    // ============================
    //  7. Assessment History Retrieval
    // ============================

    function test_GetBorrowerAssessmentHistory() public {
        vm.startPrank(recorder);
        registry.recordAssessment(
            assessmentId1, borrower, assessmentHash1, bytes32(0),
            "1.0.0", IAssessmentRegistry.VerificationStatus.Unverified, "LOW"
        );
        registry.recordAssessment(
            assessmentId2, borrower, assessmentHash2, assessmentHash1,
            "1.1.0", IAssessmentRegistry.VerificationStatus.EvidenceChecked, "MEDIUM"
        );
        vm.stopPrank();

        bytes32[] memory history = registry.getBorrowerAssessmentHistory(borrower);
        assertEq(history.length, 2);
        assertEq(history[0], assessmentId1);
        assertEq(history[1], assessmentId2);
    }

    function test_GetLatestAssessment() public {
        vm.startPrank(recorder);
        registry.recordAssessment(
            assessmentId1, borrower, assessmentHash1, bytes32(0),
            "1.0.0", IAssessmentRegistry.VerificationStatus.Unverified, "HIGH"
        );
        registry.recordAssessment(
            assessmentId2, borrower, assessmentHash2, assessmentHash1,
            "2.0.0", IAssessmentRegistry.VerificationStatus.SourceVerified, "LOW"
        );
        vm.stopPrank();

        IAssessmentRegistry.AssessmentRecord memory latest = registry.getLatestAssessment(borrower);
        assertEq(latest.assessmentHash, assessmentHash2);
        assertEq(latest.version, 2);
        assertEq(latest.modelVersion, "2.0.0");
    }

    function test_Revert_GetLatestAssessment_NoneExist() public {
        vm.expectRevert(
            abi.encodeWithSelector(AssessmentRegistry.AssessmentNotFound.selector, bytes32(0))
        );
        registry.getLatestAssessment(borrower);
    }

    function test_GetBorrowerAssessmentCount_Empty() public view {
        assertEq(registry.getBorrowerAssessmentCount(borrower), 0);
    }

    // ============================
    //  8. Immutability
    // ============================

    function test_Immutability_CannotOverwrite() public {
        vm.startPrank(recorder);
        registry.recordAssessment(
            assessmentId1, borrower, assessmentHash1, bytes32(0),
            "1.0.0", IAssessmentRegistry.VerificationStatus.Unverified, "LOW"
        );

        // Attempting to use the same assessmentId must revert
        vm.expectRevert(
            abi.encodeWithSelector(AssessmentRegistry.AssessmentAlreadyExists.selector, assessmentId1)
        );
        registry.recordAssessment(
            assessmentId1, borrower, assessmentHash2, assessmentHash1,
            "2.0.0", IAssessmentRegistry.VerificationStatus.SourceVerified, "HIGH"
        );
        vm.stopPrank();

        // Original record is untouched
        IAssessmentRegistry.AssessmentRecord memory rec = registry.getAssessment(assessmentId1);
        assertEq(rec.assessmentHash, assessmentHash1);
        assertEq(rec.riskCategory, "LOW");
        assertEq(rec.version, 1);
    }

    // ============================
    //  9. Pause / Unpause
    // ============================

    function test_Pause_PreventsRecording() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        registry.recordAssessment(
            assessmentId1, borrower, assessmentHash1, bytes32(0),
            "1.0.0", IAssessmentRegistry.VerificationStatus.Unverified, "LOW"
        );
    }

    function test_Unpause_AllowsRecording() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(admin);
        registry.unpause();

        vm.prank(recorder);
        registry.recordAssessment(
            assessmentId1, borrower, assessmentHash1, bytes32(0),
            "1.0.0", IAssessmentRegistry.VerificationStatus.EvidenceChecked, "LOW"
        );

        IAssessmentRegistry.AssessmentRecord memory rec = registry.getAssessment(assessmentId1);
        assertEq(rec.borrower, borrower);
    }

    function test_Revert_PauseByNonPauser() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        registry.pause();
    }

    // ============================
    //  Input Validation
    // ============================

    function test_Revert_ZeroAssessmentId() public {
        vm.prank(recorder);
        vm.expectRevert(AssessmentRegistry.ZeroAssessmentId.selector);
        registry.recordAssessment(
            bytes32(0), borrower, assessmentHash1, bytes32(0),
            "1.0.0", IAssessmentRegistry.VerificationStatus.Unverified, "LOW"
        );
    }

    function test_Revert_ZeroAssessmentHash() public {
        vm.prank(recorder);
        vm.expectRevert(AssessmentRegistry.ZeroAssessmentHash.selector);
        registry.recordAssessment(
            assessmentId1, borrower, bytes32(0), bytes32(0),
            "1.0.0", IAssessmentRegistry.VerificationStatus.Unverified, "LOW"
        );
    }

    function test_Revert_ZeroAddress() public {
        vm.prank(recorder);
        vm.expectRevert(AssessmentRegistry.ZeroAddress.selector);
        registry.recordAssessment(
            assessmentId1, address(0), assessmentHash1, bytes32(0),
            "1.0.0", IAssessmentRegistry.VerificationStatus.Unverified, "LOW"
        );
    }

    function test_Revert_Constructor_ZeroAdmin() public {
        vm.expectRevert(AssessmentRegistry.ZeroAddress.selector);
        new AssessmentRegistry(address(0));
    }

    function test_Revert_GetAssessment_NotFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(AssessmentRegistry.AssessmentNotFound.selector, assessmentId1)
        );
        registry.getAssessment(assessmentId1);
    }
}
