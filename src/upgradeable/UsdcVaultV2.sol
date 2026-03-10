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
        uint256 gross = _grossUp(assets); // This is Assets + Fee
        if (gross > vaultBalance && address(strategy) != address(0)) {
            uint256 shortfall = gross - vaultBalance;
            uint256 received = strategy.withdraw(shortfall);

            // Safety net — in practice unreachable via normal flow because
            // maxWithdraw() accounts for available assets before _withdraw runs.
            // Kept as defensive programming for direct contract calls.
            if (received < shortfall) {
                uint256 totalAvailable = vaultBalance + received;
                assets = (totalAvailable * FEE_DENOMINATOR) / (FEE_DENOMINATOR + WITHDRAW_FEE);
                gross = totalAvailable;
            }
        }

        uint256 fee = gross - assets;
        shares = convertToShares(gross);

        // increase accumulated fees first
        accumulatedFees += fee;

        _burn(owner_, shares);

        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner_, assets, shares);
    }
}
