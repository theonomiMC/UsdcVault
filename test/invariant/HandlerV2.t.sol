// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {UsdcVaultV2} from "../../src/upgradeable/UsdcVaultV2.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract StrategyInvariantHandler is StdInvariant, Test {
    UsdcVaultV2 public vault;
    MockERC20 public usdc;
    MockStrategy public strategy;

    address[] public actors;
    address public feeRecipient;

    modifier userActor(uint256 seed) {
        address actor = getActor(seed);
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    constructor(UsdcVaultV2 _vault, MockStrategy _strategy, address[] memory _actors, address _feeRecipient) {
        vault = _vault;
        strategy = _strategy;
        actors = _actors;
        feeRecipient = _feeRecipient;
        usdc = MockERC20(address(vault.asset()));

        for (uint256 i; i < actors.length; i++) {
            usdc.mint(actors[i], 10_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    function getActor(uint256 seed) public view returns (address) {
        return actors[seed % actors.length];
    }

    function funcDeposit(uint256 amount, uint256 seed) public {
        if (actors.length == 0) return;

        address actor = getActor(seed);

        uint256 bal = usdc.balanceOf(actor);
        if (bal == 0) return;

        amount = bound(amount, 1e6, bal);
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 sharesBefore = vault.balanceOf(actor);

        vm.prank(actor);
        vault.deposit(amount, actor);

        // simple sanity: vault balance increases by amount
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore + amount);
        assertGt(vault.balanceOf(actor), sharesBefore);
    }

    /// withdraw semantics in your vault: user requests NET assets received == `amount`
    function funcWithdraw(uint256 amount, uint256 seed) public userActor(seed) {
        if (actors.length == 0) return;
        address actor = getActor(seed);

        uint256 maxWithdraw = vault.maxWithdraw(actor);
        if (maxWithdraw < 1e6) return;

        amount = bound(amount, 1e6, maxWithdraw);

        uint256 userBalBefore = usdc.balanceOf(actor);
        uint256 feeBefore = vault.getAccumulatedFees();

        vault.withdraw(amount, actor, actor);

        // ✅ user got exactly the requested net amount
        assertEq(usdc.balanceOf(actor), userBalBefore + amount);

        // ✅ fees are monotonic
        assertGe(vault.getAccumulatedFees(), feeBefore);
    }

    /// redeem semantics in your vault: user burns shares, receives NET assets (previewRedeem)
    function funcRedeem(uint256 shares, uint256 seed) public userActor(seed) {
        if (actors.length == 0) return;
        address actor = getActor(seed);

        uint256 maxRedeem = vault.maxRedeem(actor);
        if (maxRedeem == 0) return;

        shares = bound(shares, 1, maxRedeem);

        uint256 expectedNet = vault.previewRedeem(shares);
        uint256 userBalBefore = usdc.balanceOf(actor);

        vault.redeem(shares, actor, actor);

        assertEq(usdc.balanceOf(actor), userBalBefore + expectedNet);
    }

    function funcMint(uint256 shares, uint256 seed) public userActor(seed) {
        if (actors.length == 0) return;
        address actor = getActor(seed);

        // keep shares small-ish to reduce reverts due to maxMint constraints
        shares = bound(shares, 1e3, 1e12);

        uint256 maxMint = vault.maxMint(actor);
        if (maxMint == 0) return;
        if (shares > maxMint) shares = maxMint;

        // mint is pull-based: needs assets, so clamp to user's balance via previewMint
        uint256 assetsNeeded = vault.previewMint(shares);
        uint256 bal = usdc.balanceOf(actor);
        if (assetsNeeded == 0 || assetsNeeded > bal) return;

        uint256 sharesBefore = vault.balanceOf(actor);
        vault.mint(shares, actor);
        assertGt(vault.balanceOf(actor), sharesBefore);
    }

    function funcSimulateYield(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000e6);

        usdc.mint(address(strategy), amount);
        vm.prank(feeRecipient);
        strategy.simulateYield(amount);
    }

    function funcSimulateLoss(uint256 amount) public {
        uint256 strategyBalance = strategy.totalAssets();
        if (strategyBalance == 0) return;

        amount = bound(amount, 1, strategyBalance);
        vm.prank(feeRecipient);
        strategy.simulateLoss(amount);
    }

    function funcInvest(uint256 amount) public {
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        if (vaultBalance == 0) return;

        amount = bound(amount, 1, vaultBalance);
        vm.prank(feeRecipient);
        vault.invest(amount);
    }

    function funcClaimFees(uint256 seed) public {
        // only sometimes try claiming, to avoid wasting runs
        if ((seed % 5) != 0) return;

        uint256 fees = vault.getAccumulatedFees();
        if (fees == 0) return;

        uint256 ownerBalBefore = usdc.balanceOf(feeRecipient);
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        vm.prank(feeRecipient);
        vault.claimFees();

        assertEq(vault.getAccumulatedFees(), 0);
        assertEq(usdc.balanceOf(feeRecipient), ownerBalBefore + fees);
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore - fees);
    }
}
