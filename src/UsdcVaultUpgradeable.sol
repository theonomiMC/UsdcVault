// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract UsdcVaultUpgradeable is 
    Initializable, 
    ERC4626Upgradeable, 
    UUPSUpgradeable, 
    Ownable2StepUpgradeable 
{
    using SafeERC20 for IERC20;

    uint256 public constant WITHDRAW_FEE = 50;
    uint256 public highWaterMark;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 _asset, 
        string memory _name, 
        string memory _symbol,
        address _initialOwner
    ) public initializer {
        __ERC4626_init(_asset);
        __ERC20_init(_name, _symbol);
        __Ownable_init(_initialOwner);
        __UUPSUpgradeable_init();

        highWaterMark = 1e18;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Storage gap for future variables
    uint256[50] private _gap;
}