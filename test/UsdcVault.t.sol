// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcVault} from "../src/UsdcVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UsdcVault_ZeroAddress, UsdcVault_ZeroFee, UsdcVault_InvalidGross} from "../src/UsdcVault.sol";

contract UsdcVaultTest is Test {
    UsdcVault public vault;
    MockERC20 public usdc;

    address public noa = address(0x123);
    address public toko = address(0x124);
    address public owner = address(0x456);
    uint8 public constant USDC_DECIMAL = 6;
    uint8 public constant OFFSET_DECIMAL = 3;
    uint256 public constant BASIC_SHARE_PRICE = 1e18;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("Mock USDC", "mUSDC", USDC_DECIMAL);
        vault = new UsdcVault(IERC20(address(usdc)), "Vault Token", "vUSDC");
        vm.stopPrank();

        usdc.mint(noa, 10_000e6);
        usdc.mint(toko, 10_000e6);

        vm.prank(noa);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(toko);
        usdc.approve(address(vault), type(uint256).max);
    }
    // reusable deposit shortcut — keeps individual tests shorter
    modifier userDeposit(uint256 _amount, address _user) {
        vm.prank(_user);
        vault.deposit(_amount, _user);
        _;
    }

    // --- Initial state ---
    function test_InitialState() public view {
        assertEq(vault.name(), "Vault Token");
        assertEq(vault.symbol(), "vUSDC");
        // decimals = asset decimals + virtual offset (6 + 3 = 9)
        assertEq(vault.decimals(), USDC_DECIMAL + OFFSET_DECIMAL);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        // share price is defined as 1.0 before anyone deposits
        assertEq(vault.highWaterMark(), 1e18);
    }

    function test_constructorRevertZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(UsdcVault_ZeroAddress.selector));
        new UsdcVault(IERC20(address(0)), "VaultToken", "vUSDC");
    }

    // --- Deposit ---
    function test_Deposit() public {
        uint256 depositAmt = 1000e6;
        vm.prank(noa);
        vault.deposit(depositAmt, noa);

        // with a 3-decimal offset each USDC becomes 1000 shares
        uint256 noaShares = depositAmt * 10 ** OFFSET_DECIMAL;

        assertEq(vault.totalSupply(), noaShares);
        assertEq(vault.balanceOf(noa), noaShares);
        assertEq(vault.totalAssets(), depositAmt);
    }

    // --- Withdrawal fee ---
    function test_WithdrawFee() public userDeposit(1000e6, noa) {
        uint256 noaShares = 1000e9;
        uint256 initialNoaBalance = usdc.balanceOf(noa);

        vm.prank(noa);
        vault.redeem(noaShares, noa, noa);

        // fee = 0.5% of gross (the full 1000 USDC that left the vault)
        uint256 expectedFee = (1000e6 * 50) / 10000;
        uint256 expectedNet = 1000e6 - expectedFee;

        assertEq(vault.getAccumulatedFees(), expectedFee);
        assertEq(vault.balanceOf(noa), 0);
        assertEq(usdc.balanceOf(noa), initialNoaBalance + expectedNet);
    }

    // --- Performance fee ---
    // 200 USDC yield on 1000 deposit = 20% gain, fee = 10% of that = ~20 USDC
    function test_ProfitAccounting() public userDeposit(1000e6, noa) {
        usdc.mint(address(vault), 200e6);

        // toko's deposit triggers _collectPerformanceFee
        vm.prank(toko);
        vault.deposit(1e6, toko);

        uint256 ownerBalance = vault.balanceOf(owner);
        uint256 ownerAssets = vault.convertToAssets(ownerBalance);

        assertGt(vault.highWaterMark(), BASIC_SHARE_PRICE);
        // HWM is post-mint price, so slightly below 1.2
        assertLt(vault.highWaterMark(), 1.2e18);
        // owner received ~20 USDC worth of shares (0.5 tolerance for dilution)
        assertApproxEqAbs(ownerAssets, 20e6, 0.5e6);
    }

    // 1 wei yield on a small deposit — profit rounds to zero shares
    function test_PerfFee_ZeroShares() public {
        vm.prank(noa);
        vault.deposit(1e6, noa);

        usdc.mint(address(vault), 1);

        uint256 ownerSharesBefore = vault.balanceOf(owner);

        vm.prank(toko);
        vault.deposit(1e6, toko);

        // feeShares rounded to zero — owner gets nothing, HWM not updated
        assertEq(ownerSharesBefore, vault.balanceOf(owner));
    }

    function test_PerformanceFeeOnDeposit() public userDeposit(500e6, toko) {
        usdc.mint(address(vault), 500 * 1e6); // Profit
        uint256 ownerInitialBalance = vault.balanceOf(owner);

        vm.prank(toko);
        vault.deposit(100e6, toko);

        assertGt(vault.balanceOf(owner), ownerInitialBalance);
    }

    function test_PerformanceFeeOnMint() public userDeposit(500e6, toko) {
        usdc.mint(address(vault), 200 * 1e6);
        uint256 ownerInitialBalance = vault.balanceOf(owner);

        vm.prank(toko);
        vault.mint(100e9, toko);

        assertGt(vault.balanceOf(owner), ownerInitialBalance);
    }

    // Preview consistency — preview must match actual execution exactly
    function test_PreviewWithdraw_returnsCorrectShares() public userDeposit(1000e6, noa) {
        // more net requested = more shares burned
        uint256 shares = vault.previewWithdraw(100e6);
        assertGt(shares, vault.previewWithdraw(99e6));

        uint256 sharesBefore = vault.balanceOf(noa);

        vm.prank(noa);
        vault.withdraw(100e6, noa, noa);

        assertEq(sharesBefore - vault.balanceOf(noa), shares);
    }

    function test_PreviewRedeem_returnsNetAssets() public userDeposit(1000e6, noa) {
        uint256 shares = vault.balanceOf(noa);
        uint256 expected = vault.previewRedeem(shares);

        vm.prank(noa);
        uint256 actual = vault.redeem(shares, noa, noa);

        assertEq(actual, expected);
    }

    // --- maxWithdraw ---
    function test_maxWithdraw_returnsNetAmount() public userDeposit(1000e6, noa) {
        uint256 max = vault.maxWithdraw(noa);
        uint256 gross = vault.convertToAssets(vault.balanceOf(noa));

        // max is net — always less than gross
        assertLt(max, gross);

        // calling withdraw(max) must not revert
        vm.prank(noa);
        vault.withdraw(max, noa, noa);
    }

    // --- Fees — claim access control ---
    function test_clameFeesWithOrWithoutOwner() public userDeposit(1000e6, noa) {
        vm.prank(noa);
        vault.withdraw(500e6, noa, noa);

        assertGt(vault.getAccumulatedFees(), 0);

        vm.expectRevert();

        vm.prank(toko);
        vault.claimFees();

        vm.prank(owner);
        vault.claimFees();

        assertEq(vault.getAccumulatedFees(), 0);
    }

    function test_ClaimZerroFees_reverts() public userDeposit(1000e6, toko) {
        // nobody withdrew yet so no fees accumulated
        vm.expectRevert(UsdcVault_ZeroFee.selector);
        vm.prank(owner);
        vault.claimFees();
    }

    // Edge cases
    function test_SharePriceWhenSupplyZero() public view {
        // price is 1.0 by definition before anyone deposits
        assertEq(vault.sharePrice(), BASIC_SHARE_PRICE);
    }

    // --- Pause ---
    function test_PauseUnpauseOperations() public userDeposit(500e6, noa) {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert();
        vm.prank(noa);
        vault.deposit(100e6, noa);

        vm.expectRevert();
        vm.prank(noa);
        vault.mint(100e6, noa);

        vm.expectRevert();
        vm.prank(noa);
        vault.withdraw(100e6, noa, noa);

        vm.prank(owner);
        vault.unpause();

        vm.prank(noa);
        vault.deposit(100e6, noa);
        assertEq(vault.balanceOf(noa), 600e9);
    }

    // If the vault loses funds (e.g. a strategy gets slashed), redeeming
    // large share amounts will revert because gross > vault balance.
    // This protects users from getting less than expected silently.
    function test_RevertIf_InvalidGross() public userDeposit(1000e6, noa) {
        // drain the vault down to 1 wei to simulate a total loss
        deal(address(usdc), address(vault), 1);

        vm.expectRevert(UsdcVault_InvalidGross.selector);
        vm.prank(noa);
        vault.redeem(500e6, noa, noa);
    }
}
