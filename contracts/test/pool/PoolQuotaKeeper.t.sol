// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IPoolQuotaKeeper,
    QuotaUpdate,
    IPoolQuotaKeeperEvents,
    IPoolQuotaKeeperExceptions,
    TokenLT,
    TokenQuotaParams
} from "../../interfaces/IPoolQuotaKeeper.sol";
import {IGauge} from "../../interfaces/IGauge.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolServiceMock} from "../mocks/pool/PoolServiceMock.sol";

import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {CreditManagerMockForPoolTest} from "../mocks/pool/CreditManagerMockForPoolTest.sol";
import {addLiquidity, referral, PoolQuotaKeeperTestSuite} from "../suites/PoolQuotaKeeperTestSuite.sol";

import "@gearbox-protocol/core-v2/contracts/libraries/Errors.sol";

import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {Tokens} from "../config/Tokens.sol";
import {BalanceHelper} from "../helpers/BalanceHelper.sol";

import {PoolQuotaKeeper} from "../../pool/PoolQuotaKeeper.sol";
import {GaugeMock} from "../mocks/pool/GaugeMock.sol";

// TEST
import "../lib/constants.sol";
import "../lib/StringUtils.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// EXCEPTIONS
import {
    CallerNotConfiguratorException,
    CallerNotControllerException,
    ZeroAddressException,
    CreditManagerNotRegsiterException,
    CallerNotCreditManagerException,
    TokenAlreadyAddedException
} from "../../interfaces/IErrors.sol";

import "forge-std/console.sol";

/// @title pool
/// @notice Business logic for borrowing liquidity pools
contract PoolQuotaKeeperTest is DSTest, BalanceHelper, IPoolQuotaKeeperEvents {
    using Math for uint256;
    using StringUtils for string;

    CheatCodes evm = CheatCodes(HEVM_ADDRESS);

    PoolQuotaKeeperTestSuite psts;
    PoolQuotaKeeper pqk;
    GaugeMock gaugeMock;

    ACL acl;
    PoolServiceMock pool;
    address underlying;
    CreditManagerMockForPoolTest cmMock;

    function setUp() public {
        _setUp(Tokens.DAI);
    }

    function _setUp(Tokens t) public {
        tokenTestSuite = new TokensTestSuite();
        psts = new PoolQuotaKeeperTestSuite(
            tokenTestSuite,
            tokenTestSuite.addressOf(t)
        );

        pool = psts.pool4626();

        underlying = address(psts.underlying());
        cmMock = psts.cmMock();
        acl = psts.acl();
        pqk = psts.poolQuotaKeeper();
        gaugeMock = psts.gaugeMock();
    }

    function _testCaseErr(string memory caseName, string memory err) internal pure returns (string memory) {
        return string("\nCase: ").concat(caseName).concat("\n").concat("Error: ").concat(err);
    }

    //
    // TESTS
    //

    // [PQK-1]: constructor sets parameters correctly
    function test_PQK_01_constructor_sets_parameters_correctly() public {
        assertEq(address(pool), address(pqk.pool()), "Incorrect pool address");
        assertEq(underlying, pqk.underlying(), "Incorrect pool address");
    }

    // [PQK-2]: configuration functions revert if called nonConfigurator(nonController)
    function test_PQK_02_configuration_functions_reverts_if_call_nonConfigurator() public {
        evm.startPrank(USER);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        pqk.setGauge(DUMB_ADDRESS);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        pqk.addCreditManager(DUMB_ADDRESS);

        evm.expectRevert(CallerNotControllerException.selector);
        pqk.setTokenLimit(DUMB_ADDRESS, 1);

        evm.stopPrank();
    }

    // [PQK-3]: gaugeOnly funcitons revert if called by non-gauge contract
    function test_PQK_03_gaugeOnly_funcitons_reverts_if_called_by_non_gauge() public {
        evm.startPrank(USER);

        evm.expectRevert(IPoolQuotaKeeperExceptions.GaugeOnlyException.selector);
        pqk.addQuotaToken(DUMB_ADDRESS);

        evm.expectRevert(IPoolQuotaKeeperExceptions.GaugeOnlyException.selector);
        pqk.updateRates();

        evm.stopPrank();
    }

    // [PQK-4]: creditManagerOnly funcitons revert if called by non registered creditManager
    function test_PQK_04_gaugeOnly_funcitons_reverts_if_called_by_non_gauge() public {
        evm.startPrank(USER);

        QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](1);
        evm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.updateQuotas(DUMB_ADDRESS, quotaUpdates, 0);

        TokenLT[] memory tokensLT = new TokenLT[](1);
        evm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.closeCreditAccount(DUMB_ADDRESS, tokensLT);

        evm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.accrueQuotaInterest(DUMB_ADDRESS, tokensLT);
        evm.stopPrank();
    }

    // [PQK-5]: addQuotaToken adds token and set parameters correctly
    function test_PQK_05_addQuotaToken_adds_token_and_set_parameters_correctly() public {
        address[] memory tokens = pqk.quotedTokens();

        assertEq(tokens.length, 0, "SETUP: tokens set unexpectedly has tokens");

        evm.expectEmit(true, true, false, false);
        emit NewQuotaTokenAdded(DUMB_ADDRESS);

        evm.prank(pqk.gauge());
        pqk.addQuotaToken(DUMB_ADDRESS);

        tokens = pqk.quotedTokens();

        assertEq(tokens.length, 1, "token wasn't added to quotaTokenSet");
        assertEq(tokens[0], DUMB_ADDRESS, "Incorrect address was added to quotaTokenSet");
        assertEq(tokens.length, 1, "token wasn't added to quotaTokenSet");

        (uint96 totalQuoted, uint96 limit, uint16 rate, uint192 cumulativeIndexLU_RAY) =
            pqk.totalQuotaParams(DUMB_ADDRESS);

        assertEq(totalQuoted, 0, "totalQuoted !=0");
        assertEq(limit, 0, "limit !=0");
        assertEq(rate, 0, "rate !=0");
        assertEq(cumulativeIndexLU_RAY, RAY, "Cumulative index !=RAY");
    }

    // [PQK-6]: addQuotaToken reverts on adding the same token twice
    function test_PQK_06_addQuotaToken_reverts_on_adding_the_same_token_twice() public {
        address gauge = pqk.gauge();
        evm.prank(gauge);
        pqk.addQuotaToken(DUMB_ADDRESS);

        evm.prank(gauge);
        evm.expectRevert(TokenAlreadyAddedException.selector);
        pqk.addQuotaToken(DUMB_ADDRESS);
    }

    // [PQK-7]: updateRates works as expected
    function test_PQK_07_updateRates_works_as_expected() public {
        address DAI = tokenTestSuite.addressOf(Tokens.DAI);
        address USDC = tokenTestSuite.addressOf(Tokens.USDC);

        console.log(pqk.lastQuotaRateUpdate());
        console.log(block.timestamp);

        evm.prank(CONFIGURATOR);
        gaugeMock.addQuotaToken(DAI, 20_00);

        evm.prank(CONFIGURATOR);
        gaugeMock.addQuotaToken(USDC, 40_00);

        evm.warp(block.timestamp + 365 days);

        address[] memory tokens = new address[](2);
        tokens[0] = DAI;
        tokens[1] = USDC;
        evm.expectCall(address(gaugeMock), abi.encodeCall(IGauge.getRates, tokens));

        evm.expectEmit(true, true, false, true);
        emit QuotaRateUpdated(DAI, 20_00);

        evm.expectEmit(true, true, false, true);
        emit QuotaRateUpdated(USDC, 40_00);

        gaugeMock.updateEpoch();

        (uint96 totalQuoted, uint96 limit, uint16 rate, uint192 cumulativeIndexLU_RAY) = pqk.totalQuotaParams(DAI);

        assertEq(rate, 20_00, "Incorrect DAI rate");
        assertEq(cumulativeIndexLU_RAY, RAY * 12 / 10, "Incorrect DAI cumulativeIndexLU");

        (totalQuoted, limit, rate, cumulativeIndexLU_RAY) = pqk.totalQuotaParams(USDC);

        assertEq(rate, 40_00, "Incorrect USDC rate");
        assertEq(cumulativeIndexLU_RAY, RAY * 14 / 10, "Incorrect USDC cumulativeIndexLU");

        // address gauge = pqk.gauge();
        // evm.prank(gauge);
        // pqk.addQuotaToken(DUMB_ADDRESS);

        // evm.prank(gauge);
        // pqk.addQuotaToken(DUMB_ADDRESS2);

        // evm.prank(gauge);
        // evm.expectRevert(IPoolQuotaKeeperExceptions.IncorrectQuotaRateUpdateLengthException.selector);
        // pqk.updateRates();
    }
}
