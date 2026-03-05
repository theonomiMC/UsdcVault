// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {UsdcVaultUpgradeable} from "../src/UsdcVaultUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) public { _mint(to, amount); }
}

contract UsdcVaultUpgradeableTest is Test {
    UsdcVaultUpgradeable public implementation;
    UsdcVaultUpgradeable public proxyVault;
    ERC1967Proxy public proxy;
    MockToken public asset;
    address public owner = address(1);

    function setUp() public {
        asset = new MockToken();
        implementation = new UsdcVaultUpgradeable();

        bytes memory data = abi.encodeWithSelector(
            UsdcVaultUpgradeable.initialize.selector,
            address(asset),
            "Upgradeable Vault",
            "uVLT",
            owner
        );

        proxy = new ERC1967Proxy(address(implementation), data);
        proxyVault = UsdcVaultUpgradeable(address(proxy));
    }

    function testInitialization() public view {
        assertEq(proxyVault.owner(), owner);
        assertEq(address(proxyVault.asset()), address(asset));
    }

    function testDepositThroughProxy() public {
        address user = address(2);
        asset.mint(user, 1000e18);
        
        vm.startPrank(user);
        asset.approve(address(proxyVault), 1000e18);
        proxyVault.deposit(1000e18, user);
        vm.stopPrank();

        assertEq(proxyVault.balanceOf(user), 1000e18);
    }
}