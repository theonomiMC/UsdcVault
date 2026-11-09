// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UsdcVaultV1, UsdcVault_InvalidGross, UsdcVault_ZeroAddress} from "./UsdcVaultV1.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Thrown when invest or withdraw is called with no strategy set.
error UsdcVaultV2_NoStrategy();
/// @notice Thrown when invest amount exceeds available idle balance.
error UsdcVaultV2_InvestExceedsAvailable();
/// @notice Thrown when strategy asset doesn't match vault asset.
error UsdcVaultV2_WrongAsset();
/// @notice Thrown when trying to set a new strategy while the old one still holds assets.
error UsdcVaultV2_StrategyNotEmpty();
/// @notice Thrown when liquidity is insufficient.
error UsdcVaultV2_InsufficientLiquidity();

/// @title USDC Vault V2 with Strategy
/// @author theonomiMC - Natalia
/// @notice ERC-4626 upgraded vault for USDC with strategy implemented
contract UsdcVaultV2 is UsdcVaultV1 {
    using SafeERC20 for IERC20;
    /// @notice The active yield strategy receiving idle vault funds.
    IStrategy public strategy;

    /// @dev Storage gap for future variables
    uint256[47] private __gap;

    /// @notice Only owner can set a new strategy
    /// @param newStrategy strategy interface to set
    function setStrategy(IStrategy newStrategy) external onlyOwner {
        if (address(newStrategy) == address(0)) revert UsdcVault_ZeroAddress();
        if (newStrategy.asset() != asset()) revert UsdcVaultV2_WrongAsset();
        if (address(strategy) != address(0)) {
            // Slither unused-return: reviewed.
            // The strategy is trusted. Instead of relying on the returned
            // amount, we verify that no assets remain in the old strategy.
            // slither-disable-next-line unused-return
            strategy.withdrawAll();
            if (strategy.totalAssets() != 0) revert UsdcVaultV2_StrategyNotEmpty();
        }
        strategy = newStrategy;
    }

    /// @notice owner can invest amount into strategy from idle balance
    /// @param amount invest amount
    function invest(uint256 amount) external onlyOwner {
        if (address(strategy) == address(0)) revert UsdcVaultV2_NoStrategy();
        uint256 investable = IERC20(asset()).balanceOf(address(this)) - accumulatedFees;
        if (amount > investable) revert UsdcVaultV2_InvestExceedsAvailable();
        IERC20(asset()).safeTransfer(address(strategy), amount);
        strategy.deposit(amount);
    }

    /// @notice Returns total assets in vault plus strategy, minus accumulated fees.
    /// @return Total depositor assets in USDC decimals.
    function totalAssets() public view override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));

        if (address(strategy) != address(0)) {
            balance += strategy.totalAssets();
        }
        uint256 fees = accumulatedFees;
        unchecked {
            return balance > fees ? balance - fees : 0;
        }
    }

    /// @notice Overrides V1 withdraw
    /// to pull funds from strategy if vault balance is insufficient.
    /// @param caller Who called the function.
    /// @param receiver Who gets the USDC.
    /// @param owner_ Who owns the shares.
    /// @param assets How much they get.
    /// @param shares How many shares to burn.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets == 0 && shares > 0) revert UsdcVault_InvalidGross();

        // Step 1: figure out where funds come from
        uint256 rawBalance = IERC20(asset()).balanceOf(address(this));
        uint256 vaultBalance = rawBalance > accumulatedFees ? rawBalance - accumulatedFees : 0;

        uint256 gross = convertToAssets(shares);
        if (gross > vaultBalance && address(strategy) != address(0)) {
            uint256 shortfall = gross - vaultBalance;
            // Slither reentrancy-balance: reviewed.
            // All external entry points reaching _withdraw() (withdraw/redeem)
            // are protected by nonReentrant in UsdcVaultV1.
            // A Foundry PoC confirmed that reentrant withdrawal is blocked.
            // The strategy is trusted, and the withdrawal accounting
            // intentionally uses values calculated before the strategy call.
            // slither-disable-next-line reentrancy-balance
            if (strategy.withdraw(shortfall) < shortfall) {
                revert UsdcVaultV2_InsufficientLiquidity();
            }
        }

        uint256 fee = gross - assets;

        // increase accumulated fees first
        accumulatedFees += fee;

        if (caller != owner_) _spendAllowance(owner_, caller, shares);

        _burn(owner_, shares);

        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner_, assets, shares);
    }
}
