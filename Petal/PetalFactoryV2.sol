// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0 < 0.9.0;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PetalTokenV2} from "./PetalTokenV2.sol";
import {IPetalV2Factory} from "./interfaces/IPetalV2Factory.sol";
import {IPetalV2Router} from "./interfaces/IPetalV2Router.sol";

contract PetalFactoryV2 is Ownable2Step, ReentrancyGuard, ERC20 {
    using Clones for address;
    using Math for uint256;

    address public implementation;
    address public weth;
    IPetalV2Factory public petalV2Factory;
    IPetalV2Router public petalV2Router;

    uint256 private constant FEE_MAX       = 1 ether;
    uint256 private constant FEE_BPS_SCALE = 10_000;
    uint256 private constant FEE_BPS_MAX   = 1_000;  

    // Bonding-curve token reserves
    uint256 private constant RESERVE_REAL_TOKEN = 10_000_000 ether; 
    uint256 private constant RESERVE_VIRT_TOKEN = 20_000_000 ether; 

    // Economic knobs
    uint256 public tokenCreationFee = 0 ether;   
    uint256 public tradingFeeBPS = 300;  
    uint256 public tokenLaunchingFeeBPS = 1000;  

    uint256 public ethVirtualReserve = 40 ether;  
    uint256 public tokenTotalSupply = 80_000_000 ether;

    struct BondingCurve {
        uint256 tokenRealReserve;
        uint256 tokenVirtualReserve;
        uint256 ethRealReserve;
        uint256 ethRealReserveThreshold;
        uint256 ethVirtualReserve;
        uint256 k;
        uint256 spotPrice;
    }

    mapping(address account => uint8 count) public tokenCounts;
    mapping(PetalTokenV2 token => address creator) public tokenCreator;
    mapping(PetalTokenV2 token => BondingCurve curve) public bondingCurves;
    mapping(PetalTokenV2 token => bool isLaunched) public tokenLaunched;
    mapping(address => uint256) private amountBought;
    mapping(address => uint256) private amountSold;
    mapping(address => bool) public mintAddress;

    error CollectAdminFeesFailed();
    error InvalidEthAmountIn();
    error InvalidEthAmountOut();
    error InvalidEthVirtualReserve();
    error InvalidToken();
    error InvalidTokenAmountIn();
    error InvalidTokenAmountOut();
    error InvalidTokenCreationFee();
    error InvalidTokenLaunchingFeeBPS();
    error InvalidTradingFeeBPS();
    error SellFailed();
    error RefundFailed();

    event NewTokenCreationFee(uint256 fee);
    event NewTradingFeeBPS(uint256 bps);
    event NewGraduationFeeBPS(uint256 bps);
    event NewEthVirtualReserve(uint256 reserve);
    event NewToken(address indexed creator, PetalTokenV2 token);
    event NewTokenLaunch(PetalTokenV2 indexed token);
    event FeeCollected(uint256 amount);
    event FeeCreatorCollected(address indexed creator, address token, uint256 amount);
    event Buy(PetalTokenV2 indexed token, address from, address to, uint256 amountIn, uint256 amountOut);
    event Sell(PetalTokenV2 indexed token, address from, address to, uint256 amountIn, uint256 amountOut);

    constructor(
        address admin_,
        address implementation_,
        address petalV2Factory_,
        address petalV2Router_,
        address weth_
    ) Ownable(admin_) ERC20("WEED", "WEED") {
        implementation = implementation_;
        petalV2Router = IPetalV2Router(petalV2Router_);
        petalV2Factory = IPetalV2Factory(petalV2Factory_);
        weth = weth_;
    }

    ///////////////////////////////////////////////////////////////
    //                       Admin Actions                       //
    ///////////////////////////////////////////////////////////////
    
    function MintWeed(uint amount, address recipient) external{
        if(!mintAddress[msg.sender]) revert();
        _mint(recipient, amount);
    }

    function addMinter(address _address) external onlyOwner{
        mintAddress[_address] = true;
    }

    function removeMinter(address _address) external onlyOwner{
        mintAddress[_address] = false;
    }

    function setTokenCreationFee(uint256 fee_) external onlyOwner {
        if (fee_ > FEE_MAX) revert InvalidTokenCreationFee();
        if (fee_ == tokenCreationFee) revert InvalidTokenCreationFee();

        tokenCreationFee = fee_;
        emit NewTokenCreationFee(tokenCreationFee);
    }

    function setTradingFeeBPS(uint256 bps_) external onlyOwner {
        if (bps_ > FEE_BPS_MAX) revert InvalidTradingFeeBPS();
        if (bps_ == tradingFeeBPS) revert InvalidTradingFeeBPS();

        tradingFeeBPS = bps_;
        emit NewTradingFeeBPS(tradingFeeBPS);
    }

    function setTokenLaunchingFeeBPS(uint256 bps_) external onlyOwner {
        if (bps_ > FEE_BPS_MAX) revert InvalidTokenLaunchingFeeBPS();
        if (bps_ == tokenLaunchingFeeBPS) revert InvalidTokenLaunchingFeeBPS();

        tokenLaunchingFeeBPS = bps_;
        emit NewGraduationFeeBPS(tokenLaunchingFeeBPS);
    }

    function setEthVirtualReserve(uint256 amount_) external onlyOwner {
        if (amount_ == ethVirtualReserve) revert InvalidEthVirtualReserve();

        ethVirtualReserve = amount_;
        emit NewEthVirtualReserve(ethVirtualReserve);
    }

    ////////////////////////////////////////////////////////////////
    //                   Private Read Functions                   //
    ////////////////////////////////////////////////////////////////

    function getSalt(address account_) private view returns (bytes32 salt) {
        uint8 tokenIndex = tokenCounts[account_];
        salt = keccak256(abi.encodePacked(account_, tokenIndex));
    }

    function getTradingFeeAmount(uint256 amount_) private view returns (uint256 feeAmount) {
        feeAmount = amount_.mulDiv(tradingFeeBPS, FEE_BPS_SCALE, Math.Rounding.Ceil);
    }

    function getLaunchingFeeAmount(uint256 amount_) private view returns (uint256 feeAmount) {
        feeAmount = amount_.mulDiv(tokenLaunchingFeeBPS, FEE_BPS_SCALE, Math.Rounding.Ceil);
    }

    function getBondingCurveTokenAmountOut(PetalTokenV2 token_, uint256 ethAmountIn_)
        private
        view
        returns (uint256 tokenAmountOut)
    {
        BondingCurve memory curve = bondingCurves[token_];
        uint256 _maxEthAmountIn = getBondingCurveMaxCapacity(token_);
        if (ethAmountIn_ > _maxEthAmountIn) {
            ethAmountIn_ = _maxEthAmountIn;
        }
        uint256 _newEthVirtualReserve = curve.ethVirtualReserve + ethAmountIn_;
        uint256 _newTokenVirtualReserve = curve.k.mulDiv(1 ether, _newEthVirtualReserve, Math.Rounding.Floor);
        tokenAmountOut = curve.tokenVirtualReserve - _newTokenVirtualReserve;
    }

    function getBondingCurveEthAmountOut(PetalTokenV2 token_, uint256 tokenAmountIn_)
        private
        view
        returns (uint256 ethAmountOut)
    {
        BondingCurve memory curve = bondingCurves[token_];
        uint256 _newTokenVirtualReserve = curve.tokenVirtualReserve + tokenAmountIn_;
        uint256 _newEthVirtualReserve = curve.k.mulDiv(1 ether, _newTokenVirtualReserve);
        ethAmountOut = curve.ethVirtualReserve - _newEthVirtualReserve;
    }

    function getBondingCurveMaxCapacity(PetalTokenV2 token_) private view returns (uint256 maxCap) {
        BondingCurve memory curve = bondingCurves[token_];
        maxCap = curve.ethRealReserveThreshold - curve.ethRealReserve;
    }

    function getNewTokenAddress(address account_) external view returns (address token) {
        bytes32 salt = getSalt(account_);
        token = implementation.predictDeterministicAddress(salt);
    }

    function launchable(PetalTokenV2 token_) private view returns (bool isLaunchable) {
        BondingCurve memory curve = bondingCurves[token_];
        isLaunchable = curve.ethRealReserve >= curve.ethRealReserveThreshold;
    }

    
     function createToken(string memory name_, string memory symbol_)
        external
        payable
        nonReentrant
        onlyOwner
        returns (PetalTokenV2 token)
    {
        if (msg.value < tokenCreationFee) revert InvalidTokenCreationFee();

        uint256 _ethAmountIn = 0;
        if (msg.value > tokenCreationFee) {
            _ethAmountIn = msg.value - tokenCreationFee;
        }

        token = deployToken(msg.sender, name_, symbol_);
        createBondingCurve(token);
        createPetalV2Pair(token);

        if (_ethAmountIn > 0) {
            buy(msg.sender, msg.sender, token, _ethAmountIn, 0);
            collectAdminFees(tokenCreationFee);
        } else {
            collectAdminFees(tokenCreationFee);
        }

        emit NewToken(msg.sender, token);
    }

        function launchToken(PetalTokenV2 token_) private {
        if (tokenLaunched[token_]) revert InvalidToken();

        BondingCurve memory curve = bondingCurves[token_];

        uint256 _feeAmount = getLaunchingFeeAmount(curve.ethRealReserve);
        uint256 _ethAmount = curve.ethRealReserve - _feeAmount;
        uint256 _tokenAmount = tokenTotalSupply - RESERVE_REAL_TOKEN;
        tokenLaunched[token_] = true;

        if (_tokenAmount == 0) revert InvalidToken();

        addPetalV2Liquidity(token_, _ethAmount, _tokenAmount);
        resetBondingCurve(token_);
        collectAdminFees(_feeAmount);

        emit NewTokenLaunch(token_);
    }

    ////////////////////////////////////////////////////////////////
    //                  Private Write Functions                   //
    ////////////////////////////////////////////////////////////////


    function deployToken(address creator_, string memory name_, string memory symbol_)
        private
        returns (PetalTokenV2 token)
    {
        bytes32 salt = getSalt(creator_);
        address deployed = implementation.cloneDeterministic(salt);
        token = PetalTokenV2(deployed);

        tokenCounts[creator_] += 1;
        tokenCreator[token] = creator_;

        token.initialize(name_, symbol_, tokenTotalSupply, address(this));
    }

    function createBondingCurve(PetalTokenV2 token_) private {
        BondingCurve storage curve = bondingCurves[token_];
        curve.tokenRealReserve = RESERVE_REAL_TOKEN;
        curve.tokenVirtualReserve = RESERVE_VIRT_TOKEN;
        curve.ethRealReserve = 0 ether;
        curve.ethVirtualReserve = ethVirtualReserve;
        curve.k = RESERVE_VIRT_TOKEN.mulDiv(ethVirtualReserve, 1 ether);
        curve.spotPrice = ethVirtualReserve.mulDiv(1 ether, RESERVE_VIRT_TOKEN);
        curve.ethRealReserveThreshold =
            curve.k.mulDiv(1 ether, RESERVE_VIRT_TOKEN - RESERVE_REAL_TOKEN) - ethVirtualReserve;
    }

    function resetBondingCurve(PetalTokenV2 token_) private {
        BondingCurve storage curve = bondingCurves[token_];
        curve.tokenRealReserve = 0;
        curve.tokenVirtualReserve = 0;
        curve.ethRealReserve = 0 ether;
        curve.ethVirtualReserve = 0;
        curve.k = 0;
        curve.spotPrice = 0;
        curve.ethRealReserveThreshold = 0;
    }

    function updateBondingCurveOnBuy(PetalTokenV2 token_, uint256 ethAmountIn_, uint256 tokenAmountOut_) private {
        BondingCurve storage curve = bondingCurves[token_];
        curve.ethRealReserve += ethAmountIn_;
        curve.ethVirtualReserve += ethAmountIn_;
        curve.tokenVirtualReserve -= tokenAmountOut_;
        curve.spotPrice = curve.ethVirtualReserve.mulDiv(1 ether, curve.tokenVirtualReserve);
    }

    function updateBondingCurveOnSell(PetalTokenV2 token_, uint256 tokenAmountIn_, uint256 ethAmountOut_) private {
        BondingCurve storage curve = bondingCurves[token_];
        curve.tokenVirtualReserve += tokenAmountIn_;
        curve.ethRealReserve -= ethAmountOut_;
        curve.ethVirtualReserve -= ethAmountOut_;
        curve.spotPrice = curve.ethVirtualReserve.mulDiv(1 ether, curve.tokenVirtualReserve);
    }

    function collectAdminFees(uint256 amount_) private {
        if (amount_ == 0) return;
        (bool succeed,) = owner().call{value: amount_}("");
        if (!succeed) revert CollectAdminFeesFailed();
        emit FeeCollected(amount_);
    }

    function refundEth(address recipient_, uint256 amount_) private {
        if (amount_ == 0) return;
        (bool succeed,) = recipient_.call{value: amount_}("");
        if (!succeed) revert RefundFailed();
    }

    function collectCreatorFees(PetalTokenV2 token_, uint256 amount_) private {
        if (amount_ == 0) return;
        address creator = tokenCreator[token_];
        (bool succeed,) = creator.call{value: amount_}("");
        if (!succeed) revert CollectAdminFeesFailed();
        emit FeeCreatorCollected(creator, address(token_), amount_);
    }

    function collectTradingFees(PetalTokenV2 token_, uint256 amount_) private {
        uint256 protocolShare = amount_.mulDiv(5000, FEE_BPS_SCALE, Math.Rounding.Ceil);
        uint256 creatorShare = amount_ - protocolShare;
        collectAdminFees(protocolShare);
        collectCreatorFees(token_, creatorShare);
    }

    function createPetalV2Pair(PetalTokenV2 token_) private {
        address pair = petalV2Factory.createPair(weth, address(token_));
        token_.setPair(pair);
    }

    function addPetalV2Liquidity(PetalTokenV2 token_, uint256 ethAmount_, uint256 tokenAmount_) private {
        token_.unblockPair();
        token_.approve(address(petalV2Router), tokenAmount_);
        petalV2Router.addLiquidityETH{value: ethAmount_}(
            address(token_), tokenAmount_, tokenAmount_, ethAmount_, address(0), block.timestamp + 2 hours
        );
        token_.approve(address(petalV2Router), 0);
    }

    function buy(
        address sender_,
        address recipient_,
        PetalTokenV2 token_,
        uint256 ethAmountIn_,
        uint256 tokenAmountOutMin_
    ) private {
        uint256 _feeAmount = getTradingFeeAmount(ethAmountIn_);
        uint256 _ethAmount = ethAmountIn_ - _feeAmount;
        uint256 _maxEthAmountIn = getBondingCurveMaxCapacity(token_);
        uint256 refund = 0;
        if (_ethAmount > _maxEthAmountIn) {
            refund = _ethAmount - _maxEthAmountIn;
            _ethAmount = _maxEthAmountIn;
        }

        uint256 _tokenAmount = getBondingCurveTokenAmountOut(token_, _ethAmount);
        if (_tokenAmount < tokenAmountOutMin_) revert InvalidTokenAmountOut();

        updateBondingCurveOnBuy(token_, _ethAmount, _tokenAmount);
        collectTradingFees(token_, _feeAmount);

        token_.transfer(recipient_, _tokenAmount);
        refundEth(sender_, refund);

        uint256 previousNet = amountBought[sender_] > amountSold[sender_] 
        ? amountBought[sender_] - amountSold[sender_] 
        : 0;

        amountBought[sender_] += _tokenAmount;

        uint256 newNet = amountBought[sender_] > amountSold[sender_] 
        ? amountBought[sender_] - amountSold[sender_] 
        : 0;
        if (newNet > previousNet) {
        uint256 positiveChange = newNet - previousNet;
        _mint(sender_, positiveChange * 3);
        }
        emit Buy(token_, sender_, recipient_, ethAmountIn_, _tokenAmount);
    }

    ////////////////////////////////////////////////////////////////
    //                   Public Read Functions                    //
    ////////////////////////////////////////////////////////////////

    function getNewTokenAmount(uint256 ethAmountIn_) external view returns (uint256 tokenAmountOut) {
        uint256 _buyAmount = ethAmountIn_ - tokenCreationFee;
        uint256 _buyFeeAmount = getTradingFeeAmount(_buyAmount);
        uint256 _ethAmount = _buyAmount - _buyFeeAmount;
        uint256 _newEthVirtualReserve = ethVirtualReserve + _ethAmount;
        uint256 _k = RESERVE_VIRT_TOKEN.mulDiv(ethVirtualReserve, 1 ether);
        uint256 _newTokenVirtualReserve = _k.mulDiv(1 ether, _newEthVirtualReserve);
        tokenAmountOut = RESERVE_VIRT_TOKEN - _newTokenVirtualReserve;
    }

    function getTokenAmountOut(PetalTokenV2 token_, uint256 ethAmountIn_)
        external
        view
        returns (uint256 tokenAmountOut)
    {
        ethAmountIn_ -= getTradingFeeAmount(ethAmountIn_);
        return getBondingCurveTokenAmountOut(token_, ethAmountIn_);
    }

    function getEthAmountOut(PetalTokenV2 token_, uint256 tokenAmountIn_)
        external
        view
        returns (uint256 ethAmountOut)
    {
        ethAmountOut = getBondingCurveEthAmountOut(token_, tokenAmountIn_);
        uint256 _fee = getTradingFeeAmount(ethAmountOut);
        ethAmountOut -= _fee;
    }

    ////////////////////////////////////////////////////////////////
    //                   Public Write Functions                   //
    ////////////////////////////////////////////////////////////////

    function buy(PetalTokenV2 token_, uint256 tokenAmountOutMin_, address recipient_) external payable nonReentrant {
        if (msg.value == 0) revert InvalidEthAmountIn();
        if (tokenCreator[token_] == address(0)) revert InvalidToken();
        if (tokenLaunched[token_]) revert InvalidToken();

        buy(msg.sender, recipient_, token_, msg.value, tokenAmountOutMin_);

        if (launchable(token_)) {
            launchToken(token_);
        }
    }

    function sell(PetalTokenV2 token_, uint256 tokenAmountIn_, uint256 ethAmountOutMin_, address recipient_)
        external
        payable
        nonReentrant
    {
        if (tokenAmountIn_ == 0) revert InvalidTokenAmountIn();
        if (tokenCreator[token_] == address(0)) revert InvalidToken();
        if (tokenLaunched[token_]) revert InvalidToken();

        token_.transferFrom(msg.sender, address(this), tokenAmountIn_);

        uint256 _ethAmountOut = getBondingCurveEthAmountOut(token_, tokenAmountIn_);
        uint256 _feeAmount = getTradingFeeAmount(_ethAmountOut);
        uint256 _ethAmount = _ethAmountOut - _feeAmount;
        if (_ethAmount < ethAmountOutMin_) revert InvalidEthAmountOut();
        if (_ethAmount > bondingCurves[token_].ethRealReserve) revert InvalidEthAmountOut();

        updateBondingCurveOnSell(token_, tokenAmountIn_, _ethAmountOut);
        collectTradingFees(token_, _feeAmount);

        (bool succeed,) = recipient_.call{value: _ethAmount}("");
        if (!succeed) revert SellFailed();

        amountSold[msg.sender] += tokenAmountIn_;
        emit Sell(token_, msg.sender, recipient_, tokenAmountIn_, _ethAmount);
    }
}
