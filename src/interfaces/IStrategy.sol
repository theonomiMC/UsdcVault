// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Istrategy
/// @author theonomiMC - Natalia
/// @notice Interface that any yield strategy must implement to integrate
///         with the USDC Vault. The vault uses this to deposit idle funds,
///         withdraw on demand, and read current balance.
interface IStrategy {
    /// @notice Emitted when funds are deposited into the strategy.
    /// @param amount The amount of assets deposited.
    event Deposited(uint256 indexed amount);
    /// @notice Emitted when funds are Withdrawn from the strategy.
    /// @param amount The amount of assets Withdrawn.
    event Withdrawn(uint256 indexed amount);
    /// @notice Emitted when All funds are Withdrawn from the strategy.
    /// @param amount The amount of assets Withdrawn.
    event WithdrawnAll(uint256 indexed amount);

    /// @notice Thrown when deposit or withdraw amount is zero or invalid.
    error StrategyInvalidAmount();
    /// @notice Thrown when a withdrawal from the underlying protocol fails.
    error StrategyWithdrawFailed();

    /// @notice Deposits assets into the underlying protocol.
    /// @dev    Caller must approve strategy before calling.
    ///         Only the vault should call this.
    /// @param amount Amount to deposit in asset decimals.
    function deposit(uint256 amount) external;

    /// @notice Withdraws assets from the underlying protocol.
    /// @dev    Returned amount may be less than requested if strategy has losses.
    /// @param amount Amount requested in asset decimals.
    /// @return actual Actual amount withdrawn — may differ on loss.
    function withdraw(uint256 amount) external returns (uint256);

    /// @notice Withdraws all assets from strategy — used in emergencies.
    /// @return total Total amount returned to caller.
    function withdrawAll() external returns (uint256);

    /// @notice Returns the address of the token this strategy operates on.
    /// @return Address of the underlying asset token.
    function asset() external view returns (address);

    /// @notice Returns total assets currently managed by the strategy.
    /// @dev    Includes any yield accrued but not yet harvested.
    /// @return Total asset balance in token decimals.
    function totalAssets() external view returns (uint256);
}
