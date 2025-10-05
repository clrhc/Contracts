// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

interface IPetalFactoryV2 {
    function MintWeed(uint256 amount, address recipient) external;
}

interface IPetalTokenV2 {
    function MintToken(uint256 amount, address recipient) external;
}

contract PetalReferral {

    int private index;
    string public baseRef;
    mapping (address => info) public userInfo;
    mapping (string => address) public refStore;
    address immutable factory;
    address immutable petal;
    address immutable virtue;

     struct info {
        int userID;
        int userXp;
        string refString;
        address userAddress;
    }

    constructor(address _factory, address _petal, address _virtue){
        index = 1;
        factory = _factory;
        petal = _petal;
        virtue = _virtue;
        baseRef = _toLowercase("petal");
        userInfo[msg.sender] = info(index, 0, _toLowercase("petal"), msg.sender);
        refStore[_toLowercase("petal")] = msg.sender;
        index++;
    }

    function copyBytes(bytes memory _bytes) private pure returns (bytes memory) {
        bytes memory copy = new bytes(_bytes.length);
        uint256 max = _bytes.length + 31;
        for (uint256 i=32; i<=max; i+=32)
        {
            assembly { mstore(add(copy, i), mload(add(_bytes, i))) }
        }
        return copy;
    }

    function _toLowercase(string memory inputNonModifiable) private pure returns (string memory) {
        bytes memory bytesInput = copyBytes(bytes(inputNonModifiable));

        for (uint i = 0; i < bytesInput.length; i++) {
            // checks for valid ascii characters // will allow unicode after building a string library
            require (uint8(bytesInput[i]) > 31 && uint8(bytesInput[i]) < 127, "Only ASCII characters");
            // Uppercase character...
            if (uint8(bytesInput[i]) > 64 && uint8(bytesInput[i]) < 91) {
                // add 32 to make it lowercase
                bytesInput[i] = bytes1(uint8(bytesInput[i]) + 32);
            }
        }
        return string(bytesInput);
    }

    function compareStrings(string memory a, string memory b) private pure returns (bool) {
    return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

  function strlen(string memory str) private pure returns (uint256) {
        uint256 len;
        uint256 i = 0;
        uint256 bytelength = bytes(str).length;
        for (len = 0; i < bytelength; len++) {
            bytes1 b = bytes(str)[i];
            if (b < 0x80) {
                i += 1;
            } else if (b < 0xE0) {
                i += 2;
            } else if (b < 0xF0) {
                i += 3;
            } else if (b < 0xF8) {
                i += 4;
            } else if (b < 0xFC) {
                i += 5;
            } else {
                i += 6;
            }
        }
        return len;
    }

    function isAlphanumeric(string memory str) private pure returns (bool) {
        bytes memory b = bytes(str);
        for (uint i = 0; i < b.length; i++) {
            bytes1 char = b[i];

            // Only allow [0-9], [A-Z], [a-z]
            if (
                !(char >= 0x30 && char <= 0x39) &&  // 0-9
                !(char >= 0x41 && char <= 0x5A) &&  // A-Z
                !(char >= 0x61 && char <= 0x7A)     // a-z
            ) {
                return false; // found invalid character
            }
        }
        return true;
    }

    function register(string memory referral, string memory newReferral) public {
        if(!isAlphanumeric(_toLowercase(newReferral))) revert();
        if(userInfo[msg.sender].userID > 0) revert();
        if(strlen(_toLowercase(newReferral)) > 20) revert();
        if(compareStrings(_toLowercase(referral), _toLowercase(""))) revert();
        if(compareStrings(_toLowercase(newReferral), _toLowercase(""))) revert();
        if(refStore[_toLowercase(newReferral)] != address(0)) revert();
        if(refStore[_toLowercase(referral)] == address(0)) revert();
        refStore[_toLowercase(newReferral)] = msg.sender;
        userInfo[refStore[_toLowercase(referral)]].userXp = userInfo[refStore[_toLowercase(referral)]].userXp+1;
        userInfo[msg.sender] = info(index, 0, _toLowercase(newReferral), msg.sender);
        IPetalFactoryV2(factory).MintWeed(30*10**18, msg.sender);
        IPetalTokenV2(petal).MintToken(10*10**18, msg.sender);
        IPetalTokenV2(virtue).MintToken(80*10**18, msg.sender);
        index++;
    }

}