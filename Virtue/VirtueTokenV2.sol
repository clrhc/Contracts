// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0 < 0.9.0;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVirtueV2Factory} from "./interfaces/IVirtueV2Factory.sol";

interface IUniswapV2Router02{
        function factory() external pure returns (address);
        function WETH() external pure returns (address);
        function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}


contract VirtueTokenV2 is Initializable, ERC20Burnable, Ownable, ReentrancyGuard {
    string private _name;
    string private _symbol;
    bool private inSwap;
    IUniswapV2Router02 private immutable uniswapV2router;
    address private immutable router;
    address private immutable factory;
    address private immutable weth;
    address private virtueFactory;
    address public immutable treasury;
    address public pair;
    bool public pairBlocked;
    uint256 public immutable swapThreshold = 80_000 * 10**decimals();
    mapping(address => bool) public mintAddress;

    error InvalidTransfer();

     modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(address _router) Ownable(msg.sender) ERC20("VIRTUE", "VIRTUE") {
        treasury = 0xB1fadDeca6cBCCD536355a4eFe0E2d5517a1F04F;
        uniswapV2router = IUniswapV2Router02(_router);
        router = address(uniswapV2router);
        factory = uniswapV2router.factory();
        weth = uniswapV2router.WETH();
    }

   function initialize(string memory name_, string memory symbol_, uint256 totalSupply_, address factory_) external initializer {
    _name = name_;
    _symbol = symbol_;
    virtueFactory = factory_;
    _mint(msg.sender, totalSupply_);
    _transferOwnership(msg.sender);
    pairBlocked = true;
}

    ///////////////////////////////////////////////////////////////
    //                       Admin Actions                       //
    ///////////////////////////////////////////////////////////////

     function MintToken(uint amount, address recipient) external{
        if(!mintAddress[msg.sender]) revert();
        _mint(recipient, amount);
    }

    function addMinter(address _address) external{
        require(msg.sender == treasury, "Only Treasury can add minters");
        mintAddress[_address] = true;
    }

    function removeMinter(address _address) external{
        require(msg.sender == treasury, "Only Treasury can remove minters");
        mintAddress[_address] = false;
    }

    function setPair(address pair_) external onlyOwner {
        pair = pair_;
    }

    function unblockPair() external onlyOwner {
        pairBlocked = false;
    }

    ////////////////////////////////////////////////////////////////
    //                  Private Write Functions                   //
    ////////////////////////////////////////////////////////////////

function _update(address from, address to, uint256 value) internal virtual override {
    if (to == pair && pairBlocked) revert InvalidTransfer();


    if (from == address(0) || to == address(0)) {
        super._update(from, to, value);
        return;
    }


    bool launched = IVirtueV2Factory(virtueFactory).tokenLaunched(address(this));
    if (!launched || inSwap) {
        super._update(from, to, value);
        return;
    }

    if (!inSwap && to == pair) {
        uint256 contractBalance = balanceOf(address(this));
        if (contractBalance >= swapThreshold && swapThreshold > 0) {
            collectFee(contractBalance);
        }
    }


    uint256 fees = 0;
    if (from == pair) {
        fees = (value * 3) / 100;
    } else if (to == pair) {
        fees = (value * 3) / 100;
    }

    if (fees > 0) {
        super._update(from, address(this), fees); 
        value -= fees;
    }

    super._update(from, to, value);
}

function collectFee(uint256 amount) private lockTheSwap {
    if (amount == 0) return;

    address[] memory path = new address[](2);
    path[0] = address(this);
    path[1] = weth;

    _approve(address(this), address(uniswapV2router), 0);
    _approve(address(this), address(uniswapV2router), amount);

    uniswapV2router.swapExactTokensForETHSupportingFeeOnTransferTokens(
        amount,
        0,
        path,
        treasury,                      
        block.timestamp + 1000
    );

    _approve(address(this), address(uniswapV2router), 0);
}

    ////////////////////////////////////////////////////////////////
    //                   Public Read Functions                    //
    ////////////////////////////////////////////////////////////////

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }
}
