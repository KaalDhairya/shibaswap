// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

// BuryBone is the coolest bar in town. You come in with some Bone, and leave with more! The longer you stay, the more Bone you get.
//
// This contract handles swapping to and from tBone, BoneSwap's staking token.
contract BuryBone is ERC20("tBone Staked Bone Dogecoin Killer", "tBONE"){
    using SafeMath for uint256;
    IERC20 public bone;

    // Define the Bone token contract
    constructor(IERC20 _bone) public {
        bone = _bone;
    }

    // Enter the bar. Pay some BONEs. Earn some shares.
    // Locks Bone and mints tBone
    function enter(uint256 _amount) public {
        // Gets the amount of Bone locked in the contract
        uint256 totalBone = bone.balanceOf(address(this));
        // Gets the amount of tBone in existence
        uint256 totalShares = totalSupply();
        // If no tBone exists, mint it 1:1 to the amount put in
        if (totalShares == 0 || totalBone == 0) {
            _mint(msg.sender, _amount);
        } 
        // Calculate and mint the amount of tBone the Bone is worth. The ratio will change overtime, as tBone is burned/minted and Bone deposited + gained from fees / withdrawn.
        else {
            uint256 what = _amount.mul(totalShares).div(totalBone);
            _mint(msg.sender, what);
        }
        // Lock the Bone in the contract
        bone.transferFrom(msg.sender, address(this), _amount);
    }

    // Leave the bar. Claim back your BONEs.
    // Unlocks the staked + gained Bone and burns tBone
    function leave(uint256 _share) public {
        // Gets the amount of tBone in existence
        uint256 totalShares = totalSupply();
        // Calculates the amount of Bone the tBone is worth
        uint256 what = _share.mul(bone.balanceOf(address(this))).div(totalShares);
        _burn(msg.sender, _share);
        bone.transfer(msg.sender, what);
    }
}
