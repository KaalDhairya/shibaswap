// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "@boringcrypto/boring-solidity/contracts/libraries/BoringERC20.sol";
interface IRewarderTDog {
    using BoringERC20 for IERC20;
    function onBoneReward(uint256 pid, address user, address recipient, uint256 boneAmount, uint256 newLpAmount) external;
    function pendingTokens(uint256 pid, address user, uint256 boneAmount) external view returns (IERC20[] memory, uint256[] memory);
}
