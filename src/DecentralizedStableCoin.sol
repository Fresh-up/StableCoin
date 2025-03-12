// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountMustBeOverZero();
    error DecentralizedStableCoin__BurnAmountOverBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if(_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeOverZero();
        }
        if(_amount > balance) {
            revert DecentralizedStableCoin__BurnAmountOverBalance();
        }
        super.burn(_amount);
    }

    function mint(address _addr, uint256 _amount) public onlyOwner returns (bool) {
        if(_addr == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if(_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeOverZero();
        }
        _mint(_addr, _amount);
        return true;
    }
}