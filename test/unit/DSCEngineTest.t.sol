// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDsc} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";

contract DSCEngineTest is Test {
    DeployDsc deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDsc();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    /////////////////////////
    /// Constructor tests ///
    /////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////
    /// Price tests ///
    ///////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e8 * 2000 = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////
    /// Deposit collateral test ///
    ///////////////////////////////

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock newToken = new ERC20Mock("NEW", "NEW", USER, STARTING_ERC20_BALANCE);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(newToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDsceMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDsceMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testCannotLiquidateHealthyUser() public depositedCollateral {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 amountToMint = dsce.getTokenAmountFromUsd(weth, AMOUNT_COLLATERAL) / 2;
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        uint256 healthFactor = dsce.getHealthFactor(USER);
        assert(healthFactor >= 1e18);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, amountToMint);

        vm.stopPrank();
    }

    function testRevertIfMintingDscWithoutCollateral() public {
        // Step 1: set USER did not have collateral deposited
        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(collateralValueInUsd, 0); // 0 collateral deposited

        // Step 2: USER minting dsc without collateral deposited
        vm.startPrank(USER);
        uint256 amountToMint = 10 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreakHealthFactor.selector,
                0 // No collateral deposited
            )
        ); // expect revert DSCE__BreakHealthFactor(0)
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testMintingDscRespectsCollateralRatio() public {
        // Step 1: USER deposits collateral
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Step 2: Calculate maximum mintable DSC based on collateral ratio
        uint256 maxMintableDsc = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) / 2; // Adjusted for 200% collateralization
        uint256 userCollateral = dsce.getAccountCollateralValue(USER);

        console.log("User Collateral (USD):", userCollateral);
        console.log("Max Mintable DSC (Adjusted):", maxMintableDsc);
        console.log("User Collateral (USD):", dsce.getAccountCollateralValue(USER));
        console.log("Health factor before minting attempt:", dsce.getHealthFactor(USER));

        // Step 3: Ensure minting beyond allowed value is reverted
        uint256 excessiveMint = maxMintableDsc + 1 ether;
        console.log("Max mintable dsc:", excessiveMint);
        vm.expectRevert();
        dsce.mintDsc(excessiveMint);

        // Step 4: Mint within the allowed limit
        dsce.mintDsc(maxMintableDsc);

        console.log("Health factor after minting:", dsce.getHealthFactor(USER));

        // Step 5: Verify DSC balance
        uint256 dscBalance = dsc.balanceOf(USER);
        console.log("Final DSC Balance:", dscBalance);
        assertEq(dscBalance, maxMintableDsc);

        vm.stopPrank();
    }

    function testLiquidateUser() public depositedCollateral {
        // 1. USER deposit dan mint DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 userMintable = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) * 3 / 10;
        dsce.mintDsc(userMintable);
        vm.stopPrank();

        // 2. Turunkan harga ETH → harga turun 50%
        // check user collateral value before price updated
        console.log("User collateral before price updated:", dsce.getAccountCollateralValue(USER));
        address priceFeed = dsce.getPriceFeed(weth);
        // user health factor before price updated
        uint256 hfBeforePriceUpdated = dsce.getHealthFactor(USER);
        console.log("user Health Factor BEFORE price updated:", hfBeforePriceUpdated);
        MockV3Aggregator mockFeed = MockV3Aggregator(priceFeed);
        mockFeed.updateAnswer(1000e8); // ETH turun dari $2000 ke $1000
        // check user collateral value after price updated
        console.log("User collateral after price updated:", dsce.getAccountCollateralValue(USER));
        // health factor after price updated
        uint256 hfAfterPriceUpdated = dsce.getHealthFactor(USER);
        console.log("user Health Factor AFTER price updated:", hfAfterPriceUpdated);

        // 3. Pastikan health factor < 1
        uint256 hfBefore = dsce.getHealthFactor(USER);
        console.log("user Health Factor BEFORE liquidation:", hfBefore);
        assertLt(hfBefore, 1e18);

        // 4. LIQUIDATOR mint DSC agar bisa melakukan likuidasi
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        uint256 liquidatorMaxMintable = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) / 2;
        // dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, liquidatorMaxMintable);
        uint256 liquidatorCollateralValue = dsce.getAccountCollateralValue(LIQUIDATOR);
        console.log("liquidator collateral price:", liquidatorCollateralValue);
        vm.stopPrank();

        // 5. Approve & lakukan likuidasi sebagian besar DSC milik USER
        vm.startPrank(LIQUIDATOR);
        // (uint256 liquidatorMintedDsce, ) = dsce.getAccountInformation(LIQUIDATOR);
        uint256 amountToLiquidate = liquidatorMaxMintable;
        dsc.approve(address(dsce), amountToLiquidate);

        dsce.liquidate(weth, USER, amountToLiquidate);
        vm.stopPrank();

        // 6. Pastikan health factor meningkat
        uint256 hfAfter = dsce.getHealthFactor(USER);
        console.log("Health Factor AFTER liquidation:", hfAfter);
        assertGt(hfAfter, hfBefore);
    }
}
