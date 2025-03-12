// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/DSCEngine.sol";
import "../src/DecentralizedStableCoin.sol";
import "../src/libraries/OracleLib.sol";

contract Deploy is Script {
    function run() external {
        address[] memory pricefeeds = new address[](2);
        pricefeeds[0] = address(1);
        pricefeeds[1] = address(2);
        address[] memory collateralTokens = new address[](2);
        collateralTokens[0] = address(3);
        collateralTokens[1] = address(4);

        vm.startBroadcast();

        address oracleLibAddr = deployCode("OracleLib.sol");
        console.log("OracleLib deployed on ", oracleLibAddr);
        
        DecentralizedStableCoin decentralizedStableCoin = new DecentralizedStableCoin();
        DSCEngine dscEngine = new DSCEngine(pricefeeds, collateralTokens, address(decentralizedStableCoin));
        console.log("DecentralizedStableCoin deployed on ", address(decentralizedStableCoin));
        console.log("DSCEngine deployed on ", address(dscEngine));

        vm.stopBroadcast();

    }
}