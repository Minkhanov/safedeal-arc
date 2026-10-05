// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SafeDeal, IStablecoin} from "../src/SafeDeal.sol";
import {MockStablecoin} from "../test/mocks/MockStablecoin.sol";

/// @notice LOCAL ONLY (anvil): deploys mock USDC and EURC, funds anvil's dev accounts 1..5 with
///         10,000 of each and deploys SafeDeal.
///         anvil &  forge script script/DeployLocal.s.sol:DeployLocal --rpc-url local \
///           --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
contract DeployLocal is Script {
    function run() external returns (SafeDeal sd, MockStablecoin usdc, MockStablecoin eurc) {
        require(block.chainid == 31337, "DeployLocal: anvil only");
        vm.startBroadcast();
        usdc = new MockStablecoin("USDC");
        eurc = new MockStablecoin("EURC");
        sd = new SafeDeal(IStablecoin(address(usdc)), IStablecoin(address(eurc)));
        address[5] memory devs = [
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,
            0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
        ];
        for (uint256 i = 0; i < devs.length; i++) {
            usdc.mint(devs[i], 10_000e6);
            eurc.mint(devs[i], 10_000e6);
        }
        vm.stopBroadcast();
        console2.log("MockUSDC deployed at:", address(usdc));
        console2.log("MockEURC deployed at:", address(eurc));
        console2.log("SafeDeal deployed at:", address(sd));
    }
}
