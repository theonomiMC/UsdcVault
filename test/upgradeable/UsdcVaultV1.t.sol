// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcVaultV1} from "../../src/upgradeable/UsdcVaultV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract UsdcVaultV1Test is Test {
    UsdcVaultV1 public proxy; // what users interact with
    UsdcVaultV1 public implementation; // raw logic, no state
    MockERC20 public usdc;

    address public owner = makeAddr("owner");
    address public toko = makeAddr("toko");
    address public noa = makeAddr("noa");
    address public attacker = makeAddr("attacker");

    uint8 public constant USDC_DECIMAL = 6;
    uint8 public constant OFFSET_DECIMAL = 3;
    uint256 public constant BASIC_SHARE_PRICE = 1e18;
    uint256 public constant VIRTUAL_SHARES = 1000;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        // deploy implementation
        vm.prank(owner);
        implementation = new UsdcVaultV1();

        // deploy proxy pointing to implementation
        bytes memory data = abi.encodeWithSelector(
            UsdcVaultV1.initialize.selector, IERC20(address(usdc)), "Upgradeable USDC Vault", "uUSDC"
        );

        vm.prank(owner);
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), data);
        proxy = UsdcVaultV1(address(proxyContract));

        usdc.mint(toko, 10_000e6);
        usdc.mint(noa, 10_000e6);

        vm.prank(toko);
        usdc.approve(address(proxy), type(uint256).max);

        vm.prank(noa);
        usdc.approve(address(proxy), type(uint256).max);
    }

    modifier userDeposit(uint256 amount, address user) {
        vm.prank(user);
        proxy.deposit(amount, user);
        _;
    }

    // -----------------------------------------------------------------------
    // 1. Initialization
    // -----------------------------------------------------------------------
    function test_initialize_setsCorrectState() public view {
        assertEq(proxy.name(), "Upgradeable USDC Vault");
        assertEq(proxy.symbol(), "uUSDC");
        assertEq(proxy.decimals(), USDC_DECIMAL + OFFSET_DECIMAL);
        assertEq(proxy.totalAssets(), 0);
        assertEq(proxy.highWaterMark(), 1e18);
        assertEq(usdc.balanceOf(address(proxy)), 0);
    }

    function test_initialize_cannotCallTwice() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        proxy.initialize(IERC20(address(usdc)), "name", "symbol");
    }

    function test_initialize_zeroAddressReverts() public {
        UsdcVaultV1 impl = new UsdcVaultV1();
        bytes memory data =
            abi.encodeWithSelector(UsdcVaultV1.initialize.selector, IERC20(address(0)), "name", "symbol");
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    // -----------------------------------------------------------------------
    // 2. Implementation is blocked
    // -----------------------------------------------------------------------
    function test_implementation_disablesInitializers() public {
        vm.expectRevert();
        vm.prank(attacker);
        implementation.initialize(usdc, "name", "symbol");
    }

    // -----------------------------------------------------------------------
    // 3. Deposit
    // -----------------------------------------------------------------------
    function test_Deposit() public {
        uint256 depositAmt = 1000e6;
        vm.prank(toko);
        proxy.deposit(depositAmt, toko);

        uint256 tokoShares = depositAmt * 10 ** OFFSET_DECIMAL;
        assertEq(proxy.totalSupply(), tokoShares);
        assertEq(proxy.balanceOf(toko), tokoShares);
        assertEq(proxy.totalAssets(), depositAmt);
    }

    // -----------------------------------------------------------------------
    // 4. Withdrawal fee
    // -----------------------------------------------------------------------
    function test_WithdrawFee() public userDeposit(1000e6, toko) {
        uint256 tokoShares = 1000e9;
        uint256 initialTokoBalance = usdc.balanceOf(toko);

        vm.prank(toko);
        proxy.redeem(tokoShares, toko, toko);

        uint256 expectedFee = (1000e6 * 50) / 10_000;
        uint256 expectedNet = 1000e6 - expectedFee;

        assertEq(proxy.getAccumulatedFees(), expectedFee);
        assertEq(proxy.balanceOf(toko), 0);
        assertEq(usdc.balanceOf(toko), initialTokoBalance + expectedNet);
    }

    // -----------------------------------------------------------------------
    // 5. Performance fee
    // -----------------------------------------------------------------------

    function test_ProfitAccounting() public userDeposit(1000e6, toko) {
        usdc.mint(address(proxy), 200e6);

        vm.prank(noa);
        proxy.deposit(1e6, noa);

        uint256 ownerBalance = proxy.balanceOf(owner);
        uint256 ownerAssets = proxy.convertToAssets(ownerBalance);

        assertGt(proxy.highWaterMark(), BASIC_SHARE_PRICE);
        assertLt(proxy.highWaterMark(), 1.2e18);
        assertApproxEqAbs(ownerAssets, 20e6, 0.5e6);
    }

    function test_PerfFee_ZeroShares() public {
        vm.prank(toko);
        proxy.deposit(1e6, toko);

        usdc.mint(address(proxy), 1);

        uint256 ownerSharesBefore = proxy.balanceOf(owner);

        vm.prank(noa);
        proxy.deposit(1e6, noa);

        assertEq(ownerSharesBefore, proxy.balanceOf(owner));
    }

    function test_PerformanceFeeOnMint() public userDeposit(500e6, toko) {
        usdc.mint(address(proxy), 200e6);
        uint256 ownerInitialBalance = proxy.balanceOf(owner);

        vm.prank(toko);
        proxy.mint(100e9, toko);

        assertGt(proxy.balanceOf(owner), ownerInitialBalance);
    }

    // -----------------------------------------------------------------------
    // 6. Previews
    // -----------------------------------------------------------------------

    function test_PreviewWithdraw_returnsCorrectShares() public userDeposit(1000e6, toko) {
        uint256 shares = proxy.previewWithdraw(100e6);
        assertGt(shares, proxy.previewWithdraw(99e6));

        uint256 sharesBefore = proxy.balanceOf(toko);

        vm.prank(toko);
        proxy.withdraw(100e6, toko, toko);

        assertEq(sharesBefore - proxy.balanceOf(toko), shares);
    }

    function test_PreviewRedeem_returnsNetAssets() public userDeposit(1000e6, toko) {
        uint256 shares = proxy.balanceOf(toko);
        uint256 expected = proxy.previewRedeem(shares);

        vm.prank(toko);
        uint256 actual = proxy.redeem(shares, toko, toko);

        assertEq(actual, expected);
    }

    // -----------------------------------------------------------------------
    // 7. maxWithdraw
    // -----------------------------------------------------------------------

    function test_maxWithdraw_returnsNetAmount() public userDeposit(1000e6, toko) {
        uint256 max = proxy.maxWithdraw(toko);
        uint256 gross = proxy.convertToAssets(proxy.balanceOf(toko));

        assertLt(max, gross);

        vm.prank(toko);
        proxy.withdraw(max, toko, toko);
    }

    // -----------------------------------------------------------------------
    // 8. Claim fees
    // -----------------------------------------------------------------------

    function test_claimFees_ownerOnly() public userDeposit(1000e6, toko) {
        vm.prank(toko);
        proxy.withdraw(500e6, toko, toko);

        assertGt(proxy.getAccumulatedFees(), 0);

        vm.expectRevert();
        vm.prank(noa);
        proxy.claimFees();

        vm.prank(owner);
        proxy.claimFees();

        assertEq(proxy.getAccumulatedFees(), 0);
    }

    function test_claimZeroFees_reverts() public userDeposit(1000e6, toko) {
        vm.expectRevert();
        vm.prank(owner);
        proxy.claimFees();
    }

    // -----------------------------------------------------------------------
    // 9. Pause
    // -----------------------------------------------------------------------

    function test_PauseUnpauseOperations() public userDeposit(500e6, toko) {
        vm.prank(owner);
        proxy.pause();

        vm.expectRevert();
        vm.prank(toko);
        proxy.deposit(100e6, toko);

        vm.expectRevert();
        vm.prank(toko);
        proxy.mint(100e9, toko);

        vm.expectRevert();
        vm.prank(toko);
        proxy.withdraw(100e6, toko, toko);

        vm.prank(owner);
        proxy.unpause();

        vm.prank(toko);
        proxy.deposit(100e6, toko);
        assertEq(proxy.balanceOf(toko), 600e9);
    }

    function test_upgrade_onlyOwnerCanUpgrade() public {
        UsdcVaultV1 newImpl = new UsdcVaultV1();

        vm.expectRevert();
        vm.prank(attacker);
        proxy.upgradeToAndCall(address(newImpl), "");

        vm.prank(owner);
        proxy.upgradeToAndCall(address(newImpl), "");

        vm.prank(toko);
        proxy.deposit(1000e6, toko);
        assertGt(proxy.balanceOf(toko), 0);
    }

    // -----------------------------------------------------------------------
    // 5. State survives upgrade  ← most important test
    // -----------------------------------------------------------------------
    function test_upgrade_statePreservedAfterUpgrade() public {
        vm.prank(toko);
        proxy.deposit(1000e6, toko);

        uint256 tokoSharesOnOldProxy = proxy.balanceOf(toko);

        // upgrade implementation
        vm.startPrank(owner);
        UsdcVaultV1 newImpl = new UsdcVaultV1();
        proxy.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        assertEq(proxy.balanceOf(toko), tokoSharesOnOldProxy);
        assertEq(proxy.totalAssets(), 1000e6);
    }

    function test_SharePriceWhenSupplyZero() public view {
        assertEq(proxy.sharePrice(), BASIC_SHARE_PRICE);
    }

    function test_getDecimalsOffset() public view {
        assertEq(proxy.getDecimalsOffset(), 3);
    }
}
