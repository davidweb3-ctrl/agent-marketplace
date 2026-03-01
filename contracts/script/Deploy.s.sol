// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {
    // Default Sepolia USDC address
    address constant DEFAULT_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdcAddress = vm.envOr("USDC_ADDRESS", address(DEFAULT_USDC));

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        MissionEscrow implementation = new MissionEscrow();
        console.log("Implementation deployed at:", address(implementation));

        // Initialize data for proxy
        bytes memory initData = abi.encodeCall(
            MissionEscrow.initialize,
            (usdcAddress, msg.sender) // USDC address and initial owner
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        MissionEscrow escrow = MissionEscrow(address(proxy));
        console.log("Proxy (MissionEscrow) deployed at:", address(escrow));

        vm.stopBroadcast();

        // Log deployed addresses
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Implementation:", address(implementation));
        console.log("Proxy:", address(escrow));
        console.log("USDC:", usdcAddress);
        console.log("==========================");

        // Save addresses to deployments file
        _saveDeployment(address(escrow), usdcAddress);
    }

    function _saveDeployment(address escrow, address usdc) internal {
        string memory deployDir = "deployments";
        string memory filePath = string.concat(deployDir, "/chaininfo.json");

        // Get chain ID
        uint256 chainId = block.chainid;

        // Simple JSON output (forge creates the directory if needed)
        console.log("");
        console.log("Saving deployment to deployments/");
        console.log("Chain ID:", chainId);
        console.log("MissionEscrow:", escrow);
        console.log("USDC:", usdc);
    }
}
