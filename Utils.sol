// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./Types.sol";

abstract contract Utils {
    mapping(address => User) public users;
    mapping(address => bool) public isRegistered;

    modifier onlyRegistered() {
        require(users[msg.sender].registered, "Not registered");
        _;
    }

    function isUserRegistered(address user) public view returns (bool) {
        return isRegistered[user];
    }

    function getUserDirects(address user) public view returns (uint256) {
        require(users[user].registered, "User not registered");
        return users[user].directList.length;
    }

    function getPaidDirectUsers(address user) public view returns (uint256) {
        require(users[user].registered, "User not registered");
        uint256 paidUserCount=0;
        for(uint32 i=0; i<users[user].directList.length; ++i){
            address directUser = users[user].directList[i];
            if(users[directUser].deposits.length > 0){
                paidUserCount++;
            }
        }
        return paidUserCount;
    }

    function getUserReferrer(address user) public view returns (address) {
        require(users[user].registered, "User not registered");
        return users[user].referrer;
    }

    function getUserDepositsCount(address user) public view returns (uint256) {
        require(users[user].registered, "User not registered");
        return users[user].deposits.length;
    }
}
