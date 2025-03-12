/*确保DSC的稳定性，保持1DSC=$1
* 通过ETH和BTC作为抵押品
* 类似MakerDAO的DAI
* 稳定性保证包括超额抵押、实时喂价、健康因子、清算机制、交互限制
*/

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    // Errors
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImporved();
    error DSCEngine__NotEnoughCollateral();
    error DSCEngine__NotEnoughDSC();

    // Type
    using OracleLib for AggregatorV3Interface;

    // State Variables
    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => uint256 amount) private s_DSCMinted;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    address[] private s_collateralTokens;

    // Events
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    // 因为可能会被清算，赎回的目标地址可能不是质押的源地址
    event CollateralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address token,
        uint256 amount
    );

    // Modifiers
    modifier moreThanZero(uint256 _amount) {
        if(_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if(s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    // Functions

    constructor(
        address[] memory pricefeeds,
        address[] memory collateralTokens,
        address dscAddress
    ) {
        if(pricefeeds.length != collateralTokens.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
        }
        for(uint256 i = 0; i < pricefeeds.length; ++i) {
            s_priceFeeds[collateralTokens[i]] = pricefeeds[i];
            s_collateralTokens.push(collateralTokens[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // private
    function _burnDSC(
        address user,
        uint256 amount
    ) 
        private
        moreThanZero(amount)
    {
        s_DSCMinted[user] -= amount;

        bool success = i_dsc.transferFrom(
            user,
            address(this),
            amount
        );
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }
    

    function _redeemCollateral(
        address fromAddress,
        address toAddress,
        uint256 amount,
        address collateralAddress
    ) 
        private
        moreThanZero(amount)
        isAllowedToken(collateralAddress)
        nonReentrant
    {
        s_collateralDeposited[fromAddress][collateralAddress] -= amount;
        emit CollateralRedeemed(
            fromAddress,
            toAddress,
            collateralAddress,
            amount
        );

        bool success = IERC20(collateralAddress).transferFrom(fromAddress, toAddress, amount);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user) private view returns (uint256, uint256) {
        uint256 DSCHolded = s_DSCMinted[user];
        uint256 totalCollateralInUSD = getAccountCollateralValue(user);
        
        return (DSCHolded, totalCollateralInUSD);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDSCMinted,
            uint256 collateralValueInUSD
        ) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
    }

    function _calculateHealthFactor(
        uint256 totalDSCMinted,
        uint256 collateralValueInUSD
    ) internal pure returns (uint256) {
        if(totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * 
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _revertIfHealthFactorIsBroken(
        address user
    ) internal view {
        uint256 healthFactor = _healthFactor(user);
        if(healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(healthFactor);
        }
    }
    // external

    function depositCollateralAndMintDSC(
        address collateralAddress,
        uint256 collateralAmount,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(collateralAddress, collateralAmount);
        mintDSC(amountDSCToMint);
    }

    // public

    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool success = i_dsc.mint(msg.sender, amountDSCToMint);
        if(!success) {
            revert DSCEngine__MintFailed();
        }
    }


    function depositCollateral(
        address collateralAddress,
        uint256 amount
    )
        public
        moreThanZero(amount)
        isAllowedToken(collateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][collateralAddress] += amount;
        emit CollateralDeposited(
            msg.sender,
            collateralAddress,
            amount
        );

        bool success = IERC20(collateralAddress).transferFrom(
            msg.sender, 
            address(this), 
            amount
        );

        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralFromDSC(
        address tokenAddress,
        uint256 amountDSCToBurn,
        uint256 amountCollateral
    ) external {
        _burnDSC(msg.sender, amountDSCToBurn);
        redeemCollateral(tokenAddress, amountCollateral);
    }

    function redeemCollateral(
        address collateralAddress,
        uint256 amount
    ) 
        public
        moreThanZero(amount)
        nonReentrant
    {
        if(amount > s_collateralDeposited[msg.sender][collateralAddress]) {
            revert DSCEngine__NotEnoughCollateral();
        }
        _redeemCollateral(
            msg.sender,
            msg.sender,
            amount,
            collateralAddress
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startUserHealthFactor = _healthFactor(user);
        if(startUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(collateral, debtToCover);

        uint256 bonus = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        _redeemCollateral(
            user, 
            msg.sender, 
            tokenAmountFromDebtCovered + bonus,
            collateral
        );

        if(s_DSCMinted[msg.sender] < debtToCover) {
            revert DSCEngine__NotEnoughDSC();
        }

        _burnDSC(msg.sender, debtToCover);

        uint256 endUserHealthFactor = _healthFactor(user);
        if(endUserHealthFactor <= startUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImporved();
        }

    }

    // get函数

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralInUSD;
        for(uint256 i = 0; i < s_collateralTokens.length; ++i) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralInUSD += getUSDValue(token, amount);
        }

        return totalCollateralInUSD;
    }

    function getUSDValue(
        address tokenaddress,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[tokenaddress]
        );
        (, int price, , , ) = priceFeed.staleCheckLatestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUSD(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getCollateralBalanceOfUser(
        address user,
        address tokenAddress
    ) external view returns (uint256) {
        return s_collateralDeposited[user][tokenAddress];
    }

    function getPrecison() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDSC() external view returns (address) {
        return address(this);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

}