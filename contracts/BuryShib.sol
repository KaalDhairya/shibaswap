// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

// BuryShib is the coolest bar in town. You come in with some Shib, and leave with more! The longer you stay, the more Shib you get.
//
// This contract handles swapping to and from xSHIB, ShibaSwap's staking token.
contract BuryShib is ERC20("xShib Staked Shiba Inu", "xSHIB"){
    using SafeMath for uint256;
    IERC20 public shib;

    // Define the Shib token contract
    constructor(IERC20 _shib) public {
        shib = _shib;
    }

    // Enter the bar. Pay some SHIBs. Earn some shares.
    // Locks Shib and mints xSHIB
    function enter(uint256 _amount) public {
        // Gets the amount of Shib locked in the contract
        uint256 totalShib = shib.balanceOf(address(this));
        // Gets the amount of xSHIB in existence
        uint256 totalShares = totalSupply();
        // If no xSHIB exists, mint it 1:1 to the amount put in
        if (totalShares == 0 || totalShib == 0) {
            _mint(msg.sender, _amount);
        } 
        // Calculate and mint the amount of xSHIB the Shib is worth. The ratio will change overtime, as xSHIB is burned/minted and Shib deposited + gained from fees / withdrawn.
        else {
            uint256 what = _amount.mul(totalShares).div(totalShib);
            _mint(msg.sender, what);
        }
        // Lock the Shib in the contract
        shib.transferFrom(msg.sender, address(this), _amount);
    }

    // Leave the bar. Claim back your SHIBs.
    // Unlocks the staked + gained Shib and burns xSHIB
    function leave(uint256 _share) public {
        // Gets the amount of xSHIB in existence
        uint256 totalShares = totalSupply();
        // Calculates the amount of Shib the xSHIB is worth
        uint256 what = _share.mul(shib.balanceOf(address(this))).div(totalShares);
        _burn(msg.sender, _share);
        shib.transfer(msg.sender, what);
    }
}
