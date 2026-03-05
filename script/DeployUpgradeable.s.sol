// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {UsdcVaultUpgradeable} from "../src/UsdcVaultUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUpgradeable is Script {
    function run() external returns (address) {
        address usdc = 0x1c7d4b196cB02348377D40a0f4F1C74347788C94; 

        vm.startBroadcast();
        UsdcVaultUpgradeable implementation = new UsdcVaultUpgradeable();
        
        bytes memory data = abi.encodeWithSelector(
            UsdcVaultUpgradeable.initialize.selector,
            usdc,
            "Upgradeable USDC Vault",
            "uUSDC",
            msg.sender
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), data);
        vm.stopBroadcast();
        
        return address(proxy);
    }
}