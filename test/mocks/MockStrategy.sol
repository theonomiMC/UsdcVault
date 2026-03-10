// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

// CUSTOM ERRORS
error MockStrategy_NotOwner();

contract MockStrategy is IStrategy {
    address private owner;
    address private _asset;
    uint256 private _totalAssets;

    // constructor
    constructor(address asset_) {
        owner = msg.sender;
        _asset = asset_;
    }

    // simulateYield
    function simulateYield(uint256 amount) external {
        if (msg.sender != owner) revert MockStrategy_NotOwner();
        _totalAssets += amount;
    }

    // simulateLoss
    function simulateLoss(uint256 amount) external {
        if (msg.sender != owner) revert MockStrategy_NotOwner();
        uint256 actual = _totalAssets > amount ? amount : _totalAssets;
        _totalAssets -= actual;
        IERC20(_asset).transfer(address(0xdead), actual);
    }

    // all 4 IStrategy functions
    function asset() external view override returns (address) {
        return address(_asset);
    }

    function deposit(uint256 amount) external override {
        _totalAssets += amount;
        emit Deposited(amount);
    }

    function withdraw(uint256 amount) external returns (uint256) {
        uint256 actual = amount > _totalAssets ? _totalAssets : amount;
        _totalAssets -= actual;
        IERC20(_asset).transfer(msg.sender, actual);
        emit Withdrawn(actual);
        return actual;
    }

    function withdrawAll() external returns (uint256) {
        uint256 amount = _totalAssets;
        _totalAssets = 0;
        IERC20(_asset).transfer(msg.sender, amount);
        emit WithdrawnAll(amount);
        return amount;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }
}
