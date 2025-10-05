// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts@4.9.6/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts@4.9.6/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

error Unauthorized();

contract VirtueSekai is ERC721, ERC721Enumerable, ERC721URIStorage, Ownable, ReentrancyGuard{

    address public VIRTUE;
    address public TREASURY;
    string baseURI_;
    uint nonce;
    uint public maxSupply;
    uint public maxWallet;
    uint public maxMint;
    uint public minted;
    uint256 public mintPrice;
    bool public isClaimLive;
    bool public isMintLive;
    mapping (uint => string) private _tokenURIs;
    mapping (uint256 => bool) public claimed;
    mapping (address => uint) public claims;
    mapping (uint => uint256) public tokenPower;
    mapping(uint => bool) tokenMinted;

    constructor() ERC721("VirtueSekai", "VIRTUE") {
         baseURI_ = "http://virtue.wtf/api/json/";
         TREASURY = 0xa6102095A55fC7004759D7D2281B30887623D96D;
         maxSupply = 5555;
         maxWallet = 30;
         maxMint = 1000;
         nonce = 0;
         minted = 0;
         mintPrice = 4*10**15;
         isClaimLive = false;
         isMintLive = false;
    }

    function _multiMint(address recipient, uint quantity) private{
        if(totalSupply() + quantity > maxSupply) revert Unauthorized();
        uint count = quantity;
        uint tokenId = randomNumber()+1;
        for(uint i; i < count; i++){
            if(tokenMinted[tokenId] == true){
                count++;
                nonce++;
                tokenId = randomNumber()+1;
            }else{
                _mint(recipient, tokenId);
                _setTokenURI(tokenId, Strings.toString(tokenId));
                tokenMinted[tokenId] = true;
                tokenPower[tokenId] = 30000*10**18;
                nonce++;
            }
        }
    }

    function paidMint(uint quantity) public payable{
        if(!isMintLive) revert Unauthorized();
        if(claims[msg.sender] + quantity > maxMint) revert Unauthorized();
        if(claims[msg.sender] + quantity > maxWallet) revert Unauthorized();
        if(msg.value < quantity*mintPrice) revert Unauthorized();
        payable(TREASURY).transfer(msg.value);
        _multiMint(msg.sender, quantity);
        claims[msg.sender] += quantity;
        minted = minted + quantity;
    }

    function claimTokens() public nonReentrant{
        if(!isClaimLive) revert Unauthorized();
        uint[] memory userTokens = WalletTokens(msg.sender);
        if(userTokens.length < 1) revert Unauthorized();
        uint256 tokens = 0;
        for(uint i = 0; i < userTokens.length; i++){
            if(tokenPower[userTokens[i]] > 0){
            tokens += tokenPower[userTokens[i]];
            tokenPower[userTokens[i]] = 0;}
        }
        if(tokens == 0) revert Unauthorized();
        IERC20(VIRTUE).transfer(msg.sender, tokens);
    }

     function _baseURI() internal view override returns (string memory) {
        return baseURI_;
    }

     function tokenURI(uint tokenId) public view virtual override(ERC721, ERC721URIStorage) returns (string memory) {
        if(!_exists(tokenId)) revert Unauthorized();

        string memory _tokenURI = _tokenURIs[tokenId];
        string memory base = _baseURI();
        
        // If there is no base URI, return the token URI.
        if (bytes(base).length == 0) {
            return _tokenURI;
        }
        // If both are set, concatenate the baseURI and tokenURI (via abi.encodePacked).
        if (bytes(_tokenURI).length > 0) {
            return string(abi.encodePacked(base, _tokenURI));
        }
        // If there is a baseURI but no tokenURI, concatenate the tokenID to the baseURI.
        return string(abi.encodePacked(base, Strings.toString(tokenId)));
    }

     function randomNumber() public view returns(uint)
    {
        return uint(keccak256(abi.encodePacked(block.timestamp,msg.sender,nonce))) % maxSupply;
    }

     function WalletTokens(address wallet) public view returns(uint[] memory) {
        if(balanceOf(wallet) < 1) revert Unauthorized();
        uint tokenCount = balanceOf(wallet);
        uint[] memory result = new uint[](tokenCount);
        uint tokenIndex = 0;

        for(uint i = 0; i < tokenCount; i++){
        result[tokenIndex] = tokenOfOwnerByIndex(wallet, i);
        tokenIndex++;
        }
        return result;
    }

    function switchClaimLive() external onlyOwner{
        if(!isClaimLive){
            isClaimLive = true;
        }else{
            isClaimLive = false;
        }
    }

    function switchMintLive() external onlyOwner{
        if(!isMintLive){
            isMintLive = true;
        }else{
            isMintLive = false;
        }
    }

    function adminMint(address recipient, uint quantity) external onlyOwner{
        _multiMint(recipient, quantity);
    }

    function massAdminMint(address[] memory recipients, uint quantity) external onlyOwner{
        for(uint i = 0; i < recipients.length; i++){
            _multiMint(recipients[i], quantity);
        }
    }

    function changeBaseURI(string memory newURI) external onlyOwner{
        baseURI_ = newURI;
    }

    function setVirtue(address newAddress) external onlyOwner{
        VIRTUE = newAddress;
    }

    function retrieveVirtue() external onlyOwner{
        IERC20(VIRTUE).transfer(msg.sender, IERC20(VIRTUE).balanceOf(address(this)));
    }

    function changeSupply(uint newSupply) external onlyOwner{
        maxSupply = newSupply;
    }

    function massUpdateMetadata() external onlyOwner{
         emit BatchMetadataUpdate(1, maxSupply);
    }

    function changeMintPrice(uint newPrice) external onlyOwner{
        mintPrice = newPrice;
    }

    function changeMaxWallet(uint newWalletAmount) external onlyOwner{
        maxWallet = newWalletAmount;
    }

     // The following functions are overrides required by Solidity.

    function _beforeTokenTransfer(address from, address to, uint tokenId, uint256 batchSize) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC721Enumerable, ERC721URIStorage) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

     function _burn(uint tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }


}