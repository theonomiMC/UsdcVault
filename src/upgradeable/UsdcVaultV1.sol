// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Thrown when there's no fee yet to claim.
error UsdcVault_ZeroFee();
/// @notice Thrown when a zero address is provided where a valid address is required.
error UsdcVault_ZeroAddress();
/// @notice Thrown when shares convert to zero assets due to rounding.
error UsdcVault_InvalidGross();

/// @title  USDC Vault V1
/// @author theonomiMC - Natalia
/// @notice ERC-4626 upgradeable vault for USDC with withdrawal
///         and performance fees.
contract UsdcVaultV1 is
    Initializable,
    ERC4626Upgradeable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice The fee for withdrawing money (0.5%).
    uint256 public constant WITHDRAW_FEE = 50;
    /// @notice The fee for making a profit (10%).
    uint256 public constant PERFORMANCE_FEE = 1000;
    /// @notice Used for fee math.
    uint256 public constant FEE_DENOMINATOR = 10_000;

    /// @notice Stores the highest price the shares have reached.
    uint256 public highWaterMark;

    /// @notice The total amount of fees waiting to be claimed.
    uint256 internal accumulatedFees;

    /// @dev Storage gap for future variables
    uint256[48] private __gap;

    /// @notice Called when the owner takes the fees out.
    /// @param user The address of the owner who claimed the fees
    /// @param fees The amount of USDC fees claimed
    event ClaimedFees(address indexed user, uint256 indexed fees);
    /// @notice Called when the performance fee is turned into shares.
    /// @param user The owner address receiving the fee shares
    /// @param fees The number of shares minted as fees
    event PerformanceFeeMinted(address indexed user, uint256 indexed fees);
    /// @notice Called when the high water mark changes.
    /// @param oldHwm The previous High Water Mark value
    /// @param newHwm The new High Water Mark value
    event HighWaterMarkUpdated(uint256 indexed oldHwm, uint256 indexed newHwm);

    /// @notice This makes sure the logic contract cannot be used.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the vault with the token and names.
    /// @param _asset The USDC token address.
    /// @param _name The name of our vault token.
    /// @param _symbol The symbol of our vault token.
    function initialize(IERC20 _asset, string calldata _name, string calldata _symbol) public initializer {
        if (address(_asset) == address(0)) revert UsdcVault_ZeroAddress();

        __ERC4626_init(_asset);
        __ERC20_init(_name, _symbol);
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        highWaterMark = 1e18;
    }

    /// @notice The owner calls this to collect the withdrawal fees.
    function claimFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert UsdcVault_ZeroFee();

        accumulatedFees = 0;
        IERC20(asset()).safeTransfer(owner(), amount);

        emit ClaimedFees(owner(), amount);
    }

    /// @notice Stops all deposits and withdrawals.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume all deposits and withdrawals.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Returns the total fees waiting to be claimed by the owner.
    /// @return Accumulated fees in USDC decimals.
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }

    /// @notice Returns the decimal offset used for virtual shares.
    /// @return The offset value (3).
    function getDecimalsOffset() external pure returns (uint8) {
        return _decimalsOffset();
    }

    /// @notice Deposits assets and mints shares
    /// @param assets The amount of assets to deposit
    /// @param receiver The address to receive the shares
    /// @return The amount of shares minted
    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        // first collect any pending performance fees before processing the deposit
        _collectPerformanceFee();
        return super.deposit(assets, receiver);
    }

    /// @notice Gives USDC back to the user based on asset amount.
    /// @param assets The amount of assets to withdraw
    /// @param receiver Who gets the USDC.
    /// @param owner_ Who owns the shares.
    /// @return shares
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        _collectPerformanceFee();

        return super.withdraw(assets, receiver, owner_);
    }

    /// @notice Mints shares and takes USDC from the user.
    /// @param shares shares to mint
    /// @param receiver owner of shares
    /// @return shares
    function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        // check for pending performance fees before minting new shares
        _collectPerformanceFee();
        return super.mint(shares, receiver);
    }

    /// @notice Takes shares and gives USDC back to the user.
    /// @param shares all shares to burn
    /// @param receiver who receives amount
    /// @param owner_ who owns amount
    /// @return assetsOut
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assetsOut)
    {
        _collectPerformanceFee();

        return super.redeem(shares, receiver, owner_);
    }

    /// @notice The maximum assets a user can withdraw after fees.
    /// @param owner_  owner of assets
    /// @return amount Max amount user can withdraw
    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 grossMax = super.maxWithdraw(owner_);
        return grossMax.mulDiv(FEE_DENOMINATOR - WITHDRAW_FEE, FEE_DENOMINATOR, Math.Rounding.Floor);
    }

    /// @notice Returns the current price of one share in assets, scaled to 1e18.
    /// @return Price of one share. Returns 1e18 when supply is zero.
    function sharePrice() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;

        return totalAssets().mulDiv(1e18 * 10 ** _decimalsOffset(), supply);
    }

    /// @notice Shows how many shares you need for an asset amount.
    /// @param assets The amount of USDC you want to receive.
    ///  @return The number of shares that will be burned.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 gross = _grossUp(assets);
        return super.previewWithdraw(gross);
    }

    /// @notice Shows how many assets you get for a share amount.
    /// @param  shares The number of shares to redeem.
    /// @return The net USDC amount after the 0.5% fee.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 gross = super.previewRedeem(shares);
        uint256 fee = _feeFromGross(gross);
        return gross - fee;
    }

    /// @notice Returns total assets managed by the vault.
    ///         Excludes fees accumulated for the owner.
    /// @return Total depositor assets in USDC decimals.
    function totalAssets() public view virtual override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 fees = accumulatedFees;
        unchecked {
            return balance > fees ? balance - fees : 0;
        }
    }

    /// @notice Only the owner can upgrade this contract.
    /// @param newImplementation only owner can upgrade to new implementation
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Adds 3 extra decimals for safety against inflation.
    /// @return The offset value (3).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @notice Calculates the total amount needed to get a certain net amount.
    /// @param net The amount the user wants to receive.
    /// @return gross The total amount (net + fee).
    function _grossUp(uint256 net) internal pure returns (uint256 gross) {
        gross = net.mulDiv(FEE_DENOMINATOR, FEE_DENOMINATOR - WITHDRAW_FEE, Math.Rounding.Ceil);
    }

    /// @notice Calculates the fee from a total amount.
    /// @param gross The total amount.
    /// @return fee The 0.5% fee part.
    function _feeFromGross(uint256 gross) internal pure returns (uint256 fee) {
        fee = gross.mulDiv(WITHDRAW_FEE, FEE_DENOMINATOR, Math.Rounding.Floor);
    }

    /// @notice Checks if we made a profit and mints a 10% fee to the owner.
    function _collectPerformanceFee() internal {
        uint256 supply = totalSupply();
        if (supply == 0) return;

        uint256 hwm = highWaterMark;
        uint256 priceBefore = sharePrice();

        // solhint-disable-line gas-strict-inequalities
        if (priceBefore <= hwm) return;

        uint256 profitPerShare = priceBefore - hwm;

        // assets profit = profitPerShare * supply / (1e18 * 10**offset)
        uint256 totalProfitAssets = Math.mulDiv(profitPerShare, supply, 1e18 * 10 ** _decimalsOffset());

        uint256 feeAssets = Math.mulDiv(totalProfitAssets, PERFORMANCE_FEE, FEE_DENOMINATOR);

        if (feeAssets == 0) return;

        uint256 feeShares = convertToShares(feeAssets);

        if (feeShares > 0) {
            _mint(owner(), feeShares);
            uint256 newHwm = sharePrice(); // post-mint price
            highWaterMark = newHwm;

            emit HighWaterMarkUpdated(hwm, newHwm);
            emit PerformanceFeeMinted(owner(), feeShares);
        }
    }

    /// @notice Internal function to burn shares and take fees.
    /// @param caller Who called the function.
    /// @param receiver Who gets the USDC.
    /// @param owner_ Who owns the shares.
    /// @param assets How much they get.
    /// @param shares How many shares to burn.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        if (assets == 0 && shares > 0) revert UsdcVault_InvalidGross();

        uint256 gross = convertToAssets(shares);
        uint256 fee = gross - assets;

        _burn(owner_, shares);

        // increase accumulated fees first
        accumulatedFees += fee;

        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner_, assets, shares);
    }
}
