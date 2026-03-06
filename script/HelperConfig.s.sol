// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address usdcAddress;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            usdcAddress: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 // Sepolia USDC
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.usdcAddress != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockERC20 mockUsdc = new MockERC20("Mock USDC", "mUSDC", 6);
        vm.stopBroadcast();

        return NetworkConfig({usdcAddress: address(mockUsdc)});
    }
}
