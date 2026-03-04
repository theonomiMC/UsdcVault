// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {UsdcVault} from "../../src/UsdcVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UsdcInvariantHandler is StdInvariant, Test {
    UsdcVault public vault;
    MockERC20 public usdc;
    address[] public actors;
    address public feeRecipient;

    modifier userActor(uint256 seed) {
        address actor = getActor(seed);
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    constructor(UsdcVault _vault, address[] memory _actors, address _feeRecipient) {
        vault = _vault;
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

    function func_deposit(uint256 amount, uint256 seed) public {
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
    function func_withdraw(uint256 amount, uint256 seed) public userActor(seed) {
        if (actors.length == 0) return;
        address actor = getActor(seed);

        uint256 maxWithdraw = vault.maxWithdraw(actor);
        if (maxWithdraw < 1e6) return;

        amount = bound(amount, 1e6, maxWithdraw);

        uint256 userBalBefore = usdc.balanceOf(actor);
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 feeBefore = vault.getAccumulatedFees();

        vault.withdraw(amount, actor, actor);

        // ✅ user got exactly the requested net amount
        assertEq(usdc.balanceOf(actor), userBalBefore + amount);

        // ✅ vault balance decreased by at least amount (gross could be > amount)
        assertLt(usdc.balanceOf(address(vault)), vaultBalBefore);

        // ✅ fees are monotonic
        assertGe(vault.getAccumulatedFees(), feeBefore);
    }

    /// redeem semantics in your vault: user burns shares, receives NET assets (previewRedeem)
    function func_redeem(uint256 shares, uint256 seed) public userActor(seed) {
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

    function func_mint(uint256 shares, uint256 seed) public userActor(seed) {
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

    function func_simulate_profit(uint256 amount) public {
        amount = bound(amount, 1, 1000e6);
        usdc.mint(address(vault), amount);
    }

    function func_claimFees(uint256 seed) public {
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
