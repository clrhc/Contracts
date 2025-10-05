// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IEACAggregatorProxy {
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);
}

interface IPetalFactoryV2 {
    function MintWeed(uint256 amount, address recipient) external;
}

interface IPetalTokenV2 {
    function MintToken(uint256 amount, address recipient) external;
}

contract PetalPrediction is Ownable, ReentrancyGuard {

    struct currentBid {
        uint256 roundId;
        uint256 priceBid;
        uint256 priceBidTime;
        bool    higher;
        uint256 amountBid;
    }

    struct bidHistory {
        uint256 roundId;
        uint256 priceBid;
        uint256 priceBidTime;
        bool    higher;
        uint256 amountBid;
        uint256 ethWinnings;
        uint256 weedWinnings;
        uint256 petalWinnings;
    }

    mapping(address => currentBid)  public userBid;
    mapping(address => uint256[])   public userBidIDs;
    mapping(uint256  => bidHistory) public userHistory;

    uint256 public index;
    uint256 public epochCheck;
    uint256 public price;
    address public immutable dataFeed;
    address public immutable treasury;
    address public immutable factory;
    address public immutable petal;

    event BidPlaced(address indexed user, uint256 roundId, uint256 priceBid, bool higher, uint256 netAmount);
    event BidResolved(address indexed user, uint256 historyId, uint256 result, uint256 ethWinnings, uint256 weedWinnings, uint256 petalWinnings);

    constructor(address _dataFeed, address _factory, address _petal)
        Ownable(msg.sender)
    {
        dataFeed = _dataFeed;
        index = 1;
        epochCheck = 1;
        treasury = 0xB1fadDeca6cBCCD536355a4eFe0E2d5517a1F04F;
        factory = _factory;
        petal = _petal;
        price = 2_000_000_000_000;
    }

    function _latest()
        internal
        view
        returns (uint80 rid, int256 ans, uint256 updatedAt, uint80 answeredInRound)
    {
        (rid, ans, , updatedAt, answeredInRound) = IEACAggregatorProxy(dataFeed).latestRoundData();
    }

    function _get(uint80 rid)
        internal
        view
        returns (int256 ans, uint256 updatedAt, uint80 answeredInRound)
    {
        ( , ans, , updatedAt, answeredInRound) = IEACAggregatorProxy(dataFeed).getRoundData(rid);
    }

    function _ready(address u) internal view returns (bool) {
        (uint80 latestId, , , ) = _latest();
        uint256 diff = uint256(latestId) - userBid[u].roundId;
        return diff >= epochCheck;
    }

    function bid(uint256 _amountBid, bool _higher) public payable {
        require(msg.value == _amountBid, "amount mismatch");
        require(userBid[msg.sender].roundId == 0, "open bid exists");

        (uint80 rid, int256 ans, , ) = _latest();
        require(ans > 0, "oracle answer");

        // 3% tax to treasury
        uint256 tax = (msg.value * 3) / 100;
        (bool ok, ) = payable(treasury).call{value: tax}("");
        require(ok, "tax xfer failed");

        userBid[msg.sender] = currentBid({
            roundId: uint256(rid),
            priceBid: uint256(ans),
            priceBidTime: block.timestamp,
            higher: _higher,
            amountBid: msg.value - tax
        });

        emit BidPlaced(msg.sender, uint256(rid), uint256(ans), _higher, msg.value - tax);
    }

    function checkBid(address u) public view returns (uint256) {
    if (userBid[u].roundId == 0) return 0;
    if (!_ready(u)) return 0;

    uint80 targetId = uint80(userBid[u].roundId + epochCheck);
    (int256 a, uint256 updatedAt, uint80 answeredInRound) = _get(targetId);
    if (updatedAt == 0 || answeredInRound < targetId) return 0;

    require(a > 0, "invalid oracle answer");
    uint256 finalPrice = uint256(a);
    uint256 bidPrice   = userBid[u].priceBid;
    bool higher        = userBid[u].higher;

    if (higher)  return finalPrice >= bidPrice ? 1 : 2;
    else         return finalPrice <  bidPrice ? 1 : 2;
    }

    function resolveBid() public nonReentrant {
        currentBid memory b = userBid[msg.sender];
        require(b.roundId != 0, "no bid");

        uint256 result = checkBid(msg.sender);
        require(result != 0, "not ready / tie");

        delete userBid[msg.sender];

        uint256 petalAmount = Math.mulDiv(b.amountBid, 1 * 1e18, price);
        uint256 weed = Math.mulDiv(b.amountBid, 3 * 1e18, price);

        if (result == 1) {
            (bool ok, ) = payable(msg.sender).call{value: b.amountBid}("");
            require(ok, "eth payout failed");

            IPetalTokenV2(petal).MintToken(petalAmount, msg.sender);
            IPetalFactoryV2(factory).MintWeed(weed, msg.sender);

            userBidIDs[msg.sender].push(index);
            userHistory[index] = bidHistory({
                roundId: b.roundId,
                priceBid: b.priceBid,
                priceBidTime: b.priceBidTime,
                higher: b.higher,
                amountBid: b.amountBid,
                ethWinnings: b.amountBid,
                weedWinnings: weed,
                petalWinnings: petalAmount
            });

            emit BidResolved(msg.sender, index, result, b.amountBid, weed, petalAmount);
            index += 1;
        } else {
            (bool ok, ) = payable(treasury).call{value: b.amountBid}("");
            require(ok, "eth payout failed");

            IPetalFactoryV2(factory).MintWeed(weed, msg.sender);

            userBidIDs[msg.sender].push(index);
            userHistory[index] = bidHistory({
                roundId: b.roundId,
                priceBid: b.priceBid,
                priceBidTime: b.priceBidTime,
                higher: b.higher,
                amountBid: b.amountBid,
                ethWinnings: 0,
                weedWinnings: weed,
                petalWinnings: 0
            });

            emit BidResolved(msg.sender, index, result, 0, weed, 0);
            index += 1;
        }
    }

    function getBid(address _user) external view returns (currentBid memory) {
        return userBid[_user];
    }

    function getBidHistory(uint256 _index) external view returns (bidHistory memory) {
        return userHistory[_index];
    }

    function getBidIDs(address _user) external view returns (uint256[] memory) {
        return userBidIDs[_user];
    }

    function changeEpoch(uint256 _epoch) external onlyOwner {
        epochCheck = _epoch;
    }
}
