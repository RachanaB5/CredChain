// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/LoanEscrow.sol";
import "../src/CredToken.sol";

contract LoanEscrowTest is Test {
    LoanEscrow public escrow;
    CredToken public token;

    address public admin = makeAddr("admin");
    address public operator = makeAddr("operator");
    address public borrower = makeAddr("borrower");
    address public lender = makeAddr("lender");
    address public outsider = makeAddr("outsider");

    uint256 public constant LOAN_ID = 1;
    uint256 public constant COLLATERAL_AMOUNT = 500 * 1e18;
    uint256 public constant PRINCIPAL_AMOUNT = 1000 * 1e18;

    function setUp() public {
        vm.startPrank(admin);
        token = new CredToken(admin);
        escrow = new LoanEscrow(address(token), admin);

        escrow.grantRole(escrow.OPERATOR_ROLE(), operator);

        // Mint test tokens to participants
        token.mint(borrower, 5000 * 1e18);
        token.mint(lender, 5000 * 1e18);
        vm.stopPrank();

        vm.prank(operator);
        escrow.registerBorrower(LOAN_ID, borrower);

        // Approve escrow to pull tokens
        vm.prank(borrower);
        token.approve(address(escrow), type(uint256).max);

        vm.prank(lender);
        token.approve(address(escrow), type(uint256).max);
    }

    function test_DepositCollateral_Success() public {
        vm.prank(operator);
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);

        assertEq(escrow.getCollateralBalance(LOAN_ID), COLLATERAL_AMOUNT);
        assertEq(token.balanceOf(address(escrow)), COLLATERAL_AMOUNT);
    }

    function test_RegisterBorrower_RevertDuplicateRegistration() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(LoanEscrow.LoanAlreadyRegistered.selector, LOAN_ID));
        escrow.registerBorrower(LOAN_ID, outsider);
    }

    function test_RegisterBorrower_RevertZeroAddress() public {
        vm.prank(operator);
        vm.expectRevert(LoanEscrow.ZeroAddress.selector);
        escrow.registerBorrower(2, address(0));
    }

    function test_DepositCollateral_RevertZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(LoanEscrow.ZeroAmount.selector);
        escrow.depositCollateral(LOAN_ID, borrower, 0);
    }

    function test_DepositCollateral_RevertUnauthorized() public {
        vm.prank(outsider);
        vm.expectRevert();
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);
    }

    function test_DepositCollateral_RevertWrongBorrower() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanEscrow.BorrowerMismatch.selector,
                LOAN_ID,
                borrower,
                outsider
            )
        );
        escrow.depositCollateral(LOAN_ID, outsider, COLLATERAL_AMOUNT);
    }

    function test_DepositCollateral_RevertInsufficientAllowanceWithoutAccounting() public {
        vm.prank(borrower);
        token.approve(address(escrow), 0);

        vm.prank(operator);
        vm.expectRevert();
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);

        assertEq(escrow.getCollateralBalance(LOAN_ID), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_DepositCollateral_RevertDuplicateDeposit() public {
        vm.startPrank(operator);
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(LoanEscrow.CollateralAlreadyDeposited.selector, LOAN_ID)
        );
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_ReleaseCollateral_Success() public {
        vm.startPrank(operator);
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);

        uint256 balBefore = token.balanceOf(borrower);
        escrow.releaseCollateral(LOAN_ID, borrower);
        uint256 balAfter = token.balanceOf(borrower);

        assertEq(balAfter - balBefore, COLLATERAL_AMOUNT);
        assertEq(escrow.getCollateralBalance(LOAN_ID), 0);
        vm.stopPrank();
    }

    function test_ReleaseCollateral_RevertWrongBorrower() public {
        vm.startPrank(operator);
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                LoanEscrow.BorrowerMismatch.selector,
                LOAN_ID,
                borrower,
                outsider
            )
        );
        escrow.releaseCollateral(LOAN_ID, outsider);
        vm.stopPrank();
    }

    function test_ReleaseCollateral_DoubleReleaseFails() public {
        vm.startPrank(operator);
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);
        escrow.releaseCollateral(LOAN_ID, borrower);

        vm.expectRevert(abi.encodeWithSelector(LoanEscrow.CollateralAlreadyReleased.selector, LOAN_ID));
        escrow.releaseCollateral(LOAN_ID, borrower);
        vm.stopPrank();
    }

    function test_SeizeCollateral_Success() public {
        vm.startPrank(operator);
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);
        escrow.disburseLoanFunds(LOAN_ID, borrower);

        uint256 lenderBalBefore = token.balanceOf(lender);
        escrow.seizeCollateral(LOAN_ID);
        uint256 lenderBalAfter = token.balanceOf(lender);

        assertEq(lenderBalAfter - lenderBalBefore, COLLATERAL_AMOUNT);
        assertEq(escrow.getCollateralBalance(LOAN_ID), 0);
        vm.stopPrank();
    }

    function test_SeizeCollateral_RevertBeforeFundsDisbursed() public {
        vm.startPrank(operator);
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(LoanEscrow.NoFundsDeposited.selector, LOAN_ID));
        escrow.seizeCollateral(LOAN_ID);
        vm.stopPrank();
    }

    function test_DepositAndDisburseLoanFunds_Success() public {
        vm.startPrank(operator);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);
        assertEq(escrow.getLoanFundBalance(LOAN_ID), PRINCIPAL_AMOUNT);

        uint256 borrowerBalBefore = token.balanceOf(borrower);
        escrow.disburseLoanFunds(LOAN_ID, borrower);
        uint256 borrowerBalAfter = token.balanceOf(borrower);

        assertEq(borrowerBalAfter - borrowerBalBefore, PRINCIPAL_AMOUNT);
        assertEq(escrow.getLoanFundBalance(LOAN_ID), 0);
        vm.stopPrank();
    }

    function test_DepositLoanFunds_RevertDuplicateFunding() public {
        vm.startPrank(operator);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(LoanEscrow.FundsAlreadyDeposited.selector, LOAN_ID));
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);
        vm.stopPrank();
    }

    function test_DepositLoanFunds_RevertInsufficientAllowanceWithoutAccounting() public {
        vm.prank(lender);
        token.approve(address(escrow), 0);

        vm.prank(operator);
        vm.expectRevert();
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);

        assertEq(escrow.getLoanFundBalance(LOAN_ID), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_DisburseLoanFunds_DoubleDisburseFails() public {
        vm.startPrank(operator);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);
        escrow.disburseLoanFunds(LOAN_ID, borrower);

        vm.expectRevert(abi.encodeWithSelector(LoanEscrow.FundsAlreadyDisbursed.selector, LOAN_ID));
        escrow.disburseLoanFunds(LOAN_ID, borrower);
        vm.stopPrank();
    }

    function test_DisburseLoanFunds_RevertWrongBorrower() public {
        vm.startPrank(operator);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                LoanEscrow.BorrowerMismatch.selector,
                LOAN_ID,
                borrower,
                outsider
            )
        );
        escrow.disburseLoanFunds(LOAN_ID, outsider);
        vm.stopPrank();
    }

    function test_RepaymentWorkflow() public {
        vm.startPrank(operator);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);
        escrow.disburseLoanFunds(LOAN_ID, borrower);
        uint256 repayAmount = 1050 * 1e18; // principal + interest
        escrow.receiveRepayment(LOAN_ID, borrower, repayAmount);

        uint256 lenderBalBefore = token.balanceOf(lender);
        escrow.forwardRepaymentToLender(LOAN_ID, lender, repayAmount);
        uint256 lenderBalAfter = token.balanceOf(lender);

        assertEq(lenderBalAfter - lenderBalBefore, repayAmount);
        vm.stopPrank();
    }

    function test_ReceiveRepayment_RevertWrongBorrower() public {
        vm.startPrank(operator);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);
        escrow.disburseLoanFunds(LOAN_ID, borrower);

        vm.expectRevert(
            abi.encodeWithSelector(
                LoanEscrow.BorrowerMismatch.selector,
                LOAN_ID,
                borrower,
                outsider
            )
        );
        escrow.receiveRepayment(LOAN_ID, outsider, 100 * 1e18);
        vm.stopPrank();
    }

    function test_ForwardRepayment_RevertWrongLender() public {
        vm.startPrank(operator);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);
        escrow.disburseLoanFunds(LOAN_ID, borrower);
        escrow.receiveRepayment(LOAN_ID, borrower, 100 * 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                LoanEscrow.LenderMismatch.selector,
                LOAN_ID,
                lender,
                outsider
            )
        );
        escrow.forwardRepaymentToLender(LOAN_ID, outsider, 100 * 1e18);
        vm.stopPrank();
    }

    function test_ForwardRepayment_RevertAboveRecordedBalance() public {
        vm.startPrank(operator);
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);
        escrow.disburseLoanFunds(LOAN_ID, borrower);
        escrow.receiveRepayment(LOAN_ID, borrower, 100 * 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                LoanEscrow.InsufficientBalance.selector,
                100 * 1e18,
                100 * 1e18 + 1
            )
        );
        escrow.forwardRepaymentToLender(LOAN_ID, lender, 100 * 1e18 + 1);
        vm.stopPrank();
    }

    function test_OnlyOperatorCanOperateEscrow() public {
        vm.startPrank(outsider);
        vm.expectRevert();
        escrow.registerBorrower(2, borrower);
        vm.expectRevert();
        escrow.releaseCollateral(LOAN_ID, borrower);
        vm.expectRevert();
        escrow.seizeCollateral(LOAN_ID);
        vm.expectRevert();
        escrow.depositLoanFunds(LOAN_ID, lender, PRINCIPAL_AMOUNT);
        vm.expectRevert();
        escrow.disburseLoanFunds(LOAN_ID, borrower);
        vm.expectRevert();
        escrow.receiveRepayment(LOAN_ID, borrower, 1);
        vm.expectRevert();
        escrow.forwardRepaymentToLender(LOAN_ID, lender, 1);
        vm.stopPrank();
    }

    function test_PausePreventsOperations() public {
        vm.prank(admin);
        escrow.pause();

        vm.prank(operator);
        vm.expectRevert();
        escrow.depositCollateral(LOAN_ID, borrower, COLLATERAL_AMOUNT);
    }
}
