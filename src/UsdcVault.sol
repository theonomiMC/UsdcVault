// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Custom errors
error UsdcVault_ZeroFee();
error UsdcVault_ZeroAddress();
error UsdcVault_InvalidGross();

contract UsdcVault is ERC4626, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Fees in basis points (10,000 = 100%)
    uint256 public constant WITHDRAW_FEE = 50; // 0.5% withdrawal fee
    uint256 public constant PERFORMANCE_FEE = 1000; // 10% performance fee
    uint256 public constant FEE_DENOMINATOR = 10_000;

    // Highest price reached. Prevents double-charging fees on recovery
    uint256 public highWaterMark;

    // Fees held in contract until claimed by owner.
    uint256 private accumulatedFees;

    /* --- EVENTS --- */
    event ClaimedFees(address indexed user, uint256 indexed fees);
    event PerformanceFeeMinted(address indexed user, uint256 indexed fees);
    event HighWaterMarkUpdated(uint256 indexed oldHwm, uint256 indexed newHwm);

    constructor(IERC20 _asset, string memory _name, string memory _symbol)
        ERC4626(_asset)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
        Ownable2Step()
    {
        if (address(_asset) == address(0)) revert UsdcVault_ZeroAddress();
        // Initial high water mark is 1 (scaled by 1e18 for precision)
        highWaterMark = 1e18;
    }

    // Adds virtual liquidity to prevent 1st depositor inflation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    // Solves for: gross = net / (1 - fee)
    function _grossUp(uint256 net) internal pure returns (uint256 gross) {
        gross = net.mulDiv(FEE_DENOMINATOR, FEE_DENOMINATOR - WITHDRAW_FEE, Math.Rounding.Ceil);
    }

    function _feeFromGross(uint256 gross) internal pure returns (uint256 fee) {
        fee = gross.mulDiv(WITHDRAW_FEE, FEE_DENOMINATOR, Math.Rounding.Floor);
    }

    // Returns price of 1.0 share in assets (scaled to 1e18)
    function sharePrice() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;

        return totalAssets().mulDiv(1e18 * 10 ** _decimalsOffset(), supply);
    }

    // Overridden to extract 0.5% fee before asset transfer
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
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

    /* --- PREVIEWS --- */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 gross = _grossUp(assets);
        return super.previewWithdraw(gross);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 gross = super.previewRedeem(shares);
        uint256 fee = _feeFromGross(gross);
        return gross - fee;
    }

    // Logic for 10% performance fee based on HWM growth
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

    // Excludes protocol fees from depositor asset pool
    function totalAssets() public view override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 fees = accumulatedFees;
        unchecked {
            return balance > fees ? balance - fees : 0;
        }
    }

    /* --- INTERFACE OVERRIDES (Trigger fee collection) --- */
    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        // first collect any pending performance fees before processing the deposit
        _collectPerformanceFee();
        return super.deposit(assets, receiver);
    }

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

    // Limits max withdrawal to account for the 0.5% fee
    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 grossMax = super.maxWithdraw(owner_);
        return grossMax.mulDiv(FEE_DENOMINATOR - WITHDRAW_FEE, FEE_DENOMINATOR, Math.Rounding.Floor);
    }

    function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        // check for pending performance fees before minting new shares
        _collectPerformanceFee();
        return super.mint(shares, receiver);
    }

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

    /* --- ADMIN --- */
    function claimFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert UsdcVault_ZeroFee();

        accumulatedFees = 0;
        IERC20(asset()).safeTransfer(owner(), amount);

        emit ClaimedFees(owner(), amount);
    }

    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }

    function getDecimalsOffset() external pure returns (uint8) {
        return _decimalsOffset();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
