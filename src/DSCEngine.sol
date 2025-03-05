// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volatility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Ilhan Salih Ilmansyah
 *
 * The system is design to be as minimal as possible,
 * and have the tokens maintain a 1 token == $1 peg.
 *
 * This stablecoin has the properties
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees,
 * and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized".
 * At no point, should the value of all collateral <= the $ backed value of all the DSC
 *
 *
 * @notice This contract is the core of the DSC System. It handles all the logic
 * for minting and redeeming DSC, as well as depositing & withdrawing collateral
 * @notice This contract is VERY loosely base on MakerDao DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////////
    /// Errors       ///
    ////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();

    ///////////////////////////
    /// State variables     ///
    ///////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeed; // token to pricefeed
    mapping(address use => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /////////////
    /// Events //
    /////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    ////////////////////
    /// Modifier     ///
    ////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////
    /// Functions    ///
    ////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////
    /// External Functions  ///
    ///////////////////////////

    function depositCollateralAndMintDsc() external {}

    /**
     * @notice follow CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}
 
    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of dsc to mint
     * @notice they must have more collateral value than minimum threshold 
     */
    function mintDsc(uint256 amountDscToMint) external 
    moreThanZero(amountDscToMint)
    nonReentrant
    {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If they minted too much 
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    //////////////////////////////////////////
    /// Private & Internal view Functions  ///
    //////////////////////////////////////////

    function _getAccountInformation(address user)
        private 
        view 
        returns(uint256 totalDscMinted, uint256 totalCollateralValueInUsd) 
    {
        totalDscMinted = s_DSCMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user); 
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated  
     */
    function _healthFactor(address user) private view returns(uint256) {
        // Total dsc minted 
        // Total collateral value
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = 
        (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health factor (Do they have enough collateral?)
        // 2. Revert if they don't
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }
    }
   
    /////////////////////////////////////////
    /// Public & External view Functions  ///
    /////////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        // loop trough collateral token, get the amount they have deposited,
        // and map it to the price, to get the USD value 

        for(uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd +=  getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price, , ,) = priceFeed.latestRoundData();
        return (uint256(price) * ADDITIONAL_FEED_PRECISION) * amount / PRECISION;
    }
}
