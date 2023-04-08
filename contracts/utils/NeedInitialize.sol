// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

contract NeedInitialize {
    bool public initialized;

    modifier onlyInitializeOnce() {
        require(!initialized, "NeedInitialize: already initialized");
        _;
        initialized = true;
    }
}
