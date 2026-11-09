// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcVaultV2, UsdcVaultV2_InsufficientLiquidity} from "../../src/upgradeable/UsdcVaultV2.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract SepoliaUpgradeCheck is Test {
    UsdcVaultV2 constant VAULT = UsdcVaultV2(0x3D0dDdCCdCA542AB2aB1D1d328F4e4344a330589);
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address constant LIVE_IMPL = 0xEb19A187346f4f2343E83249652377dD3eD9D038;
    address holder = makeAddr("holder");
    address attacker = makeAddr("attacker");
    address admin;
    IERC20 usdc;

    function setUp() public {
        assertEq(block.chainid, 11155111);
        assertEq(address(uint160(uint256(vm.load(address(VAULT), IMPL_SLOT)))), LIVE_IMPL);
        admin = VAULT.owner();
        usdc = IERC20(VAULT.asset());
    }

    function upgrade() internal {
        uint256 supply = VAULT.totalSupply();
        uint256 assets = VAULT.totalAssets();
        uint256 fees = VAULT.getAccumulatedFees();
        uint256 hwm = VAULT.highWaterMark();
        address strategy = address(VAULT.strategy());
        uint256 holderShares = VAULT.balanceOf(holder);
        UsdcVaultV2 candidate = new UsdcVaultV2();
        vm.prank(admin);
        VAULT.upgradeToAndCall(address(candidate), "");
        assertEq(address(uint160(uint256(vm.load(address(VAULT), IMPL_SLOT)))), address(candidate));
        assertEq(VAULT.owner(), admin);
        assertEq(VAULT.asset(), address(usdc));
        assertEq(address(VAULT.strategy()), strategy);
        assertEq(VAULT.totalAssets(), assets);
        assertEq(VAULT.totalSupply(), supply);
        assertEq(VAULT.getAccumulatedFees(), fees);
        assertEq(VAULT.highWaterMark(), hwm);
        assertEq(VAULT.balanceOf(holder), holderShares);
    }

    function depositForHolder() internal returns (uint256 shares) {
        deal(address(usdc), holder, 100e6);
        vm.startPrank(holder);
        usdc.approve(address(VAULT), 100e6);
        shares = VAULT.deposit(100e6, holder);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    /// @notice Verifies that the upgrade blocks third-party withdrawals without a share allowance.
    /// @dev Confirms that the old implementation allows the withdrawal and that the upgraded
    ///      implementation still allows it after the holder grants sufficient allowance.
    function test_Fork_WithdrawRequiresAllowanceAfterUpgrade() public {
        uint256 holderShares = depositForHolder();
        uint256 beforeBalance = usdc.balanceOf(attacker);
        uint256 snapshot = vm.snapshotState();
        assertEq(VAULT.allowance(holder, attacker), 0);
        vm.prank(attacker);
        VAULT.withdraw(1e6, attacker, holder);
        assertEq(usdc.balanceOf(attacker), beforeBalance + 1e6);
        assertLt(VAULT.balanceOf(holder), holderShares);
        assertTrue(vm.revertToState(snapshot));

        upgrade();
        uint256 shares = VAULT.previewWithdraw(1e6);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, shares));
        vm.prank(attacker);
        VAULT.withdraw(1e6, attacker, holder);
        assertEq(usdc.balanceOf(attacker), beforeBalance);
        assertEq(VAULT.balanceOf(holder), holderShares);

        vm.prank(holder);
        VAULT.approve(attacker, shares);
        vm.prank(attacker);
        assertEq(VAULT.withdraw(1e6, attacker, holder), shares);
        assertEq(VAULT.allowance(holder, attacker), 0);
        assertEq(usdc.balanceOf(attacker), beforeBalance + 1e6);
    }

    /// @notice Verifies that the upgrade blocks third-party redemptions without a share allowance.
    /// @dev Confirms that the same redemption succeeds before the upgrade.
    function test_fork_redeemRequiresAllowanceAfterUpgrade() public {
        uint256 holderShares = depositForHolder();
        uint256 shares = holderShares / 2;
        uint256 beforeBalance = usdc.balanceOf(attacker);
        uint256 snapshot = vm.snapshotState();
        assertEq(VAULT.allowance(holder, attacker), 0);
        vm.prank(attacker);
        uint256 stolen = VAULT.redeem(shares, attacker, holder);
        assertGt(stolen, 0);
        assertEq(usdc.balanceOf(attacker), beforeBalance + stolen);
        assertLt(VAULT.balanceOf(holder), holderShares);
        assertTrue(vm.revertToState(snapshot));

        upgrade();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, shares));
        vm.prank(attacker);
        VAULT.redeem(shares, attacker, holder);
        assertEq(usdc.balanceOf(attacker), beforeBalance);
        assertEq(VAULT.balanceOf(holder), holderShares);
    }

    /// @notice Verifies that a withdrawal reverts when the strategy returns less than requested.
    /// @dev Mocks the strategy response and checks that USDC balances, holder shares, and fees remain unchanged.
    function test_Fork_ShortfallRevertsWithoutChangingBalances() public {
        uint256 holderShares = depositForHolder();
        upgrade();
        uint256 idle = VAULT.totalAssets();
        uint256 assets = 10e6;
        assertGe(VAULT.maxWithdraw(holder), assets); /// @notice Checks that a withdrawal reverts if the strategy returns too little.
        /// @dev Mocks the strategy response and verifies that balances and fees stay unchanged.
        vm.startPrank(admin);
        MockStrategy strategy = new MockStrategy(address(usdc));
        VAULT.setStrategy(strategy);
        VAULT.invest(idle);
        vm.stopPrank();
        uint256 vaultBalance = usdc.balanceOf(address(VAULT));
        uint256 strategyBalance = usdc.balanceOf(address(strategy));
        uint256 holderBalance = usdc.balanceOf(holder);
        uint256 fees = VAULT.getAccumulatedFees();
        // Model a strategy that reports assets but can only return part of the requested amount.
        vm.mockCall(address(strategy), abi.encodePacked(iStrategyWithdrawSelector()), abi.encode(uint256(1)));
        vm.expectRevert(UsdcVaultV2_InsufficientLiquidity.selector);
        vm.prank(holder);
        VAULT.withdraw(assets, holder, holder);
        assertEq(usdc.balanceOf(holder), holderBalance);
        assertEq(usdc.balanceOf(address(VAULT)), vaultBalance);
        assertEq(usdc.balanceOf(address(strategy)), strategyBalance);
        assertEq(VAULT.getAccumulatedFees(), fees);
        assertEq(VAULT.balanceOf(holder), holderShares);
    }

    function iStrategyWithdrawSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("withdraw(uint256)"));
    }
}
