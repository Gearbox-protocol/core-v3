// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MAX_WITHDRAW_FEE, RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import "../../../interfaces/IExceptions.sol";
import {ILinearInterestRateModelV3} from "../../../interfaces/ILinearInterestRateModelV3.sol";
import {IPoolQuotaKeeperV3} from "../../../interfaces/IPoolQuotaKeeperV3.sol";
import {IPoolV3Events} from "../../../interfaces/IPoolV3.sol";

import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {TestHelper} from "../../lib/helper.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {ERC20FeeMock} from "../../mocks/token/ERC20FeeMock.sol";

import {PoolV3Harness} from "./PoolV3Harness.sol";

interface IERC4626Events {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
}

/// @title Pool V3 unit test
/// @notice U:[LP]: Unit tests for lending pool
contract PoolV3UnitTest is TestHelper, IPoolV3Events, IERC4626Events {
    PoolV3Harness pool;

    // accounts
    address lp;
    address user;
    address configurator;
    address creditAccount;
    address treasury;

    // contracts
    address interestRateModel;
    address creditManager;
    address quotaKeeper;

    // mocks
    ERC20FeeMock underlying;
    AddressProviderV3ACLMock addressProvider;

    bytes4 constant calcBorrowRateSelector = bytes4(keccak256("calcBorrowRate(uint256,uint256,bool)"));

    // ----- //
    // SETUP //
    // ----- //

    function setUp() public {
        // note that the test contract becomes the recipient of transfer fees
        underlying = new ERC20FeeMock("Test Token", "TEST", 18);

        user = makeAddr("USER");
        lp = makeAddr("LIQUIDITY_PROVIDER");
        configurator = makeAddr("CONFIGURATOR");
        creditManager = makeAddr("CREDIT_MANAGER");
        creditAccount = makeAddr("CREDIT_ACCOUNT");
        interestRateModel = makeAddr("INTEREST_RATE_MODEL");
        quotaKeeper = makeAddr("QUOTA_KEEPER");

        vm.startPrank(configurator);
        addressProvider = new AddressProviderV3ACLMock();
        addressProvider.addPausableAdmin(configurator);
        addressProvider.addCreditManager(creditManager);
        treasury = addressProvider.getTreasuryContract();
        vm.stopPrank();

        _setupPool();
    }

    function _setupPool() internal {
        pool = new PoolV3Harness({
            underlyingToken_: address(underlying),
            addressProvider_: address(addressProvider),
            interestRateModel_: interestRateModel,
            totalDebtLimit_: 2000,
            name_: string(abi.encodePacked("diesel ", IERC20Metadata(underlying).name())),
            symbol_: string(abi.encodePacked("d", IERC20Metadata(underlying).symbol()))
        });

        // setup mocks
        vm.mockCall(interestRateModel, abi.encode(calcBorrowRateSelector), abi.encode(RAY / 20)); // 5%
        vm.mockCall(creditManager, abi.encodeCall(ICreditManagerV3.pool, ()), abi.encode(pool));
        vm.mockCall(quotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.pool, ()), abi.encode(pool));
        vm.mockCall(quotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.poolQuotaRevenue, ()), abi.encode(0));

        // connect contracts
        vm.startPrank(configurator);
        pool.setCreditManagerDebtLimit(creditManager, 1000);
        pool.setPoolQuotaKeeper(quotaKeeper);
        vm.stopPrank();

        // setup liquidity and borrowing
        pool.hackExpectedLiquidityLU(2000);
        deal({token: address(underlying), to: address(pool), give: 1000});

        pool.hackTotalBorrowed(1000);
        pool.hackCreditManagerBorrowed(creditManager, 500);

        deal({token: address(pool), to: lp, give: 1500, adjust: true});
        deal({token: address(pool), to: treasury, give: 100, adjust: true});
    }

    // ------- //
    // GENERAL //
    // ------- //

    /// @notice U:[LP-1A]: Constructor reverts on zero addresses
    function test_U_LP_01A_constructor_reverts_on_zero_addresses() public {
        vm.expectRevert(ZeroAddressException.selector);
        new PoolV3Harness({
            underlyingToken_: address(0),
            addressProvider_: address(addressProvider),
            interestRateModel_: interestRateModel,
            totalDebtLimit_: type(uint256).max,
            name_: "",
            symbol_: ""
        });

        vm.expectRevert(ZeroAddressException.selector);
        new PoolV3Harness({
            underlyingToken_: address(underlying),
            addressProvider_: address(0),
            interestRateModel_: interestRateModel,
            totalDebtLimit_: type(uint256).max,
            name_: "",
            symbol_: ""
        });

        vm.expectRevert(ZeroAddressException.selector);
        new PoolV3Harness({
            underlyingToken_: address(underlying),
            addressProvider_: address(addressProvider),
            interestRateModel_: address(0),
            totalDebtLimit_: type(uint256).max,
            name_: "",
            symbol_: ""
        });
    }

    /// @notice U:[LP-1B]: Constructor sets correct values and emits events
    function test_U_LP_01B_constructor_sets_correct_values_and_emits_events() public {
        vm.expectEmit(true, false, false, false);
        emit SetInterestRateModel({newInterestRateModel: interestRateModel});

        vm.expectEmit(false, false, false, true);
        emit SetTotalDebtLimit({limit: 2000});

        pool = new PoolV3Harness({
            underlyingToken_: address(underlying),
            addressProvider_: address(addressProvider),
            interestRateModel_: interestRateModel,
            totalDebtLimit_: 2000,
            name_: string(abi.encodePacked("diesel ", IERC20Metadata(underlying).name())),
            symbol_: string(abi.encodePacked("d", IERC20Metadata(underlying).symbol()))
        });

        assertEq(pool.asset(), address(underlying), "Incorrect asset");
        assertEq(pool.symbol(), "dTEST", "Incorrect symbol");
        assertEq(pool.name(), "diesel Test Token", "Incorrect name");
        assertEq(pool.addressProvider(), address(addressProvider), "Incorrect addressProvider");
        assertEq(pool.underlyingToken(), address(underlying), "Incorrect underlyingToken");
        assertEq(pool.treasury(), treasury, "Incorrect treasury");
        assertEq(pool.lastBaseInterestUpdate(), block.timestamp, "Incorrect lastBaseInterestUpdate");
        assertEq(pool.baseInterestIndex(), RAY, "Incorrect baseInterestIndex");
        assertEq(pool.interestRateModel(), address(interestRateModel), "Incorrect interestRateModel");
        assertEq(pool.totalDebtLimit(), 2000, "Incorrect totalDebtLimit");

        (, string memory eip712Name,,,,,) = pool.eip712Domain();
        assertEq(eip712Name, "diesel Test Token", "Incorrect EIP-712 name");
    }

    /// @notice U:[LP-2A]: External functions revert when contract is on pause
    function test_U_LP_02A_external_functions_revert_on_pause() public {
        vm.prank(configurator);
        pool.pause();

        vm.expectRevert("Pausable: paused");
        pool.deposit({assets: 1, receiver: user});

        vm.expectRevert("Pausable: paused");
        pool.depositWithReferral({assets: 1, receiver: user, referralCode: 0});

        vm.expectRevert("Pausable: paused");
        pool.mint({shares: 1, receiver: user});

        vm.expectRevert("Pausable: paused");
        pool.mintWithReferral({shares: 1, receiver: user, referralCode: 0});

        vm.expectRevert("Pausable: paused");
        pool.redeem({shares: 1, owner: user, receiver: user});

        vm.expectRevert("Pausable: paused");
        pool.withdraw({assets: 1, owner: user, receiver: user});

        vm.expectRevert("Pausable: paused");
        pool.lendCreditAccount({borrowedAmount: 0, creditAccount: address(0)});

        vm.expectRevert("Pausable: paused");
        pool.repayCreditAccount({repaidAmount: 0, profit: 0, loss: 0});
    }

    /// @notice U:[LP-2B]: External functions revert on re-entrancy
    function test_U_LP_02B_external_functions_revert_on_reentrancy() public {
        pool.hackReentrancyStatus(true);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        pool.deposit({assets: 1, receiver: user});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        pool.depositWithReferral({assets: 1, receiver: user, referralCode: 0});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        pool.mint({shares: 1, receiver: user});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        pool.mintWithReferral({shares: 1, receiver: user, referralCode: 0});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        pool.redeem({shares: 1, owner: user, receiver: user});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        pool.withdraw({assets: 1, owner: user, receiver: user});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        pool.lendCreditAccount({borrowedAmount: 0, creditAccount: address(0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        pool.repayCreditAccount({repaidAmount: 0, profit: 0, loss: 0});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        vm.prank(quotaKeeper);
        pool.updateQuotaRevenue({quotaRevenueDelta: 0});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        vm.prank(quotaKeeper);
        pool.setQuotaRevenue({newQuotaRevenue: 0});
    }

    /// @notice U:[LP-2C]: External function have correct access rights
    function test_U_LP_02C_external_functions_have_correct_access() public {
        vm.expectRevert(CreditManagerCantBorrowException.selector);
        pool.lendCreditAccount({borrowedAmount: 1, creditAccount: address(0)});

        vm.expectRevert(CallerNotCreditManagerException.selector);
        pool.repayCreditAccount({repaidAmount: 1, profit: 0, loss: 0});

        vm.expectRevert(CallerNotPoolQuotaKeeperException.selector);
        pool.updateQuotaRevenue({quotaRevenueDelta: 0});

        vm.expectRevert(CallerNotPoolQuotaKeeperException.selector);
        pool.setQuotaRevenue({newQuotaRevenue: 0});

        vm.expectRevert(CallerNotConfiguratorException.selector);
        pool.setInterestRateModel({newInterestRateModel: address(0)});

        vm.expectRevert(CallerNotConfiguratorException.selector);
        pool.setPoolQuotaKeeper({newPoolQuotaKeeper: address(0)});

        vm.expectRevert(CallerNotControllerException.selector);
        pool.setTotalDebtLimit({newLimit: 0});

        vm.expectRevert(CallerNotControllerException.selector);
        pool.setCreditManagerDebtLimit({creditManager: address(0), newLimit: 0});

        vm.expectRevert(CallerNotControllerException.selector);
        pool.setWithdrawFee({newWithdrawFee: 0});
    }

    /// @notice U:[LP-3]: `availableLiquidity` works as expected
    function test_U_LP_03_availableLiquidity_works_as_expected() public {
        vm.expectCall(address(underlying), abi.encodeCall(IERC20.balanceOf, (address(pool))));
        assertEq(pool.availableLiquidity(), 1000, "Incorrect availableLiquidity");
    }

    /// @notice U:[LP-4]: `expectedLiquidity` works as expected
    function test_U_LP_04_expectedLiquidity_works_as_expected() public {
        pool.hackBaseInterestRate(RAY / 10); // 10% yearly

        assertEq(pool.expectedLiquidity(), 2000, "Incorrect expectedLiquidity right after base interest update");

        vm.warp(block.timestamp + 365 days);
        // 2000 + 1000 * 10%
        assertEq(pool.expectedLiquidity(), 2100, "Incorrect expectedLiquidity 1 year after base interest update");

        pool.hackQuotaRevenue(100); // 100 units yearly

        assertEq(pool.expectedLiquidity(), 2100, "Incorrect expectedLiquidity right after quota revenue update");

        vm.warp(block.timestamp + 365 days);
        // 2000 + 1000 * 10% * 2 + 100
        assertEq(pool.expectedLiquidity(), 2300, "Incorrect expectedLiquidity 1 year after quota revenue update");
    }

    // ---------------- //
    // ERC-4626 LENDING //
    // ---------------- //

    /// @notice U:[LP-5]: `{deposit|mint|withdraw|redeem}` functions revert on zero address receiver
    function test_U_LP_05_lending_functions_revert_on_zero_address_receiver() public {
        vm.startPrank(user);

        vm.expectRevert(ZeroAddressException.selector);
        pool.deposit({assets: 1, receiver: address(0)});

        vm.expectRevert(ZeroAddressException.selector);
        pool.depositWithReferral({assets: 1, receiver: address(0), referralCode: 0});

        vm.expectRevert(ZeroAddressException.selector);
        pool.mint({shares: 1, receiver: address(0)});

        vm.expectRevert(ZeroAddressException.selector);
        pool.mintWithReferral({shares: 1, receiver: address(0), referralCode: 0});

        vm.expectRevert(ZeroAddressException.selector);
        pool.withdraw({assets: 1, receiver: address(0), owner: user});

        vm.expectRevert(ZeroAddressException.selector);
        pool.redeem({shares: 1, receiver: address(0), owner: user});
        vm.stopPrank();
    }

    struct DepositTestCase {
        string name;
        // scenario
        uint256 assets;
        uint256 transferFee;
        // outcome
        uint256 expectedShares;
        uint256 expectedAssetsReceived;
    }

    /// @notice U:[LP-6]: `deposit[WithReferral]` works as expected
    function test_U_LP_06_deposit_works_as_expected(address caller) public {
        vm.assume(caller != address(0) && caller != address(pool) && caller != address(this));

        DepositTestCase[2] memory cases = [
            DepositTestCase({
                name: "deposit with 0% transfer fee",
                assets: 100,
                transferFee: 0,
                expectedShares: 80,
                expectedAssetsReceived: 100
            }),
            DepositTestCase({
                name: "deposit with 5% transfer fee",
                assets: 100,
                transferFee: 500,
                expectedShares: 76,
                expectedAssetsReceived: 95
            })
        ];

        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < cases.length; ++i) {
            if (cases[i].transferFee != 0) _activateTransferFee(cases[i].transferFee);

            _prepareAssets(caller, cases[i].assets);

            // receives udnerlying
            vm.expectCall(
                address(underlying), abi.encodeCall(IERC20.transferFrom, (caller, address(pool), cases[i].assets))
            );

            // implicitly test that `_updateBaseInterest` is called with correct parameters
            vm.expectCall(
                interestRateModel,
                abi.encodeWithSelector(
                    calcBorrowRateSelector,
                    2000 + cases[i].expectedAssetsReceived,
                    1000 + cases[i].expectedAssetsReceived,
                    false
                )
            );

            // emits events
            vm.expectEmit(true, true, false, true);
            emit Deposit(caller, user, cases[i].assets, cases[i].expectedShares);

            vm.expectEmit(true, true, false, true);
            emit Refer(user, 123, cases[i].assets);

            vm.prank(caller);
            uint256 shares = pool.depositWithReferral({assets: cases[i].assets, receiver: user, referralCode: 123});

            // updates balance
            assertEq(
                pool.balanceOf(user),
                cases[i].expectedShares,
                _testCaseErr(cases[i].name, "Incorrect shares minted to user")
            );
            assertEq(underlying.balanceOf(caller), 0, _testCaseErr(cases[i].name, "Incorrect assets taken from caller"));

            // returns correct value
            assertEq(shares, cases[i].expectedShares, "Incorrect shares returned");

            vm.revertTo(snapshot);
        }
    }

    struct MintTestCase {
        string name;
        // scenario
        uint256 shares;
        uint256 transferFee;
        // outcome
        uint256 expectedAssets;
        uint256 expectedAssetsReceived;
    }

    /// @notice U:[LP-7]: `mint[WithReferral]` works as expected
    function test_U_LP_07_mint_works_as_expected(address caller) public {
        vm.assume(caller != address(0) && caller != address(pool) && caller != address(this));

        MintTestCase[2] memory cases = [
            MintTestCase({
                name: "mint with 0% transfer fee",
                shares: 80,
                transferFee: 0,
                expectedAssets: 100,
                expectedAssetsReceived: 100
            }),
            MintTestCase({
                name: "mint with 5% transfer fee",
                shares: 80,
                transferFee: 500,
                expectedAssets: 105,
                expectedAssetsReceived: 100
            })
        ];

        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < cases.length; ++i) {
            if (cases[i].transferFee != 0) _activateTransferFee(cases[i].transferFee);

            _prepareAssets(caller, cases[i].expectedAssets);

            // receives underlying
            vm.expectCall(
                address(underlying),
                abi.encodeCall(IERC20.transferFrom, (caller, address(pool), cases[i].expectedAssets))
            );

            // implicitly test that `_updateBaseInterest` is called with correct parameters
            vm.expectCall(
                interestRateModel,
                abi.encodeWithSelector(
                    calcBorrowRateSelector,
                    2000 + cases[i].expectedAssetsReceived,
                    1000 + cases[i].expectedAssetsReceived,
                    false
                )
            );

            // emits events
            vm.expectEmit(true, true, false, true);
            emit Deposit(caller, user, cases[i].expectedAssets, cases[i].shares);

            vm.expectEmit(true, true, false, true);
            emit Refer(user, 123, cases[i].expectedAssets);

            vm.prank(caller);
            uint256 assets = pool.mintWithReferral({shares: cases[i].shares, receiver: user, referralCode: 123});

            // updates balance
            assertEq(
                pool.balanceOf(user), cases[i].shares, _testCaseErr(cases[i].name, "Incorrect shares minted to user")
            );
            assertEq(underlying.balanceOf(caller), 0, _testCaseErr(cases[i].name, "Incorrect assets taken from caller"));

            // returns correct value
            assertEq(assets, cases[i].expectedAssets, "Incorrect assets returned");

            vm.revertTo(snapshot);
        }
    }

    struct WithdrawTestCase {
        string name;
        // scenario
        uint256 assets;
        uint256 transferFee;
        uint256 withdrawFee;
        // outcome
        uint256 expectedShares;
        uint256 expectedAssetsToReceiver;
        uint256 expectedAssetsToTreasury;
    }

    /// @notice U:[LP-8]: `withdraw` works as expected
    function test_U_LP_08_withdraw_works_as_expected(address owner) public {
        vm.assume(owner != address(0) && owner != address(pool) && owner != address(this));

        WithdrawTestCase[3] memory cases = [
            WithdrawTestCase({
                name: "withdraw with 0% transfer and 0% withdraw fee",
                assets: 100,
                transferFee: 0,
                withdrawFee: 0,
                expectedShares: 80,
                expectedAssetsToReceiver: 100,
                expectedAssetsToTreasury: 0
            }),
            WithdrawTestCase({
                name: "withdraw with 5% transfer and 0% withdraw fee",
                assets: 100,
                transferFee: 500,
                withdrawFee: 0,
                expectedShares: 84,
                expectedAssetsToReceiver: 105,
                expectedAssetsToTreasury: 0
            }),
            WithdrawTestCase({
                name: "withdraw with 5% transfer and 1% withdraw fee",
                assets: 100,
                transferFee: 500,
                withdrawFee: 100,
                expectedShares: 85,
                expectedAssetsToReceiver: 105,
                expectedAssetsToTreasury: 1
            })
        ];

        uint256 snapshot = vm.snapshot();
        for (uint256 i = 2; i < cases.length; ++i) {
            if (cases[i].transferFee != 0) _activateTransferFee(cases[i].transferFee);
            if (cases[i].withdrawFee != 0) _activateWithdrawFee(cases[i].withdrawFee);

            uint256 sharesBefore = pool.balanceOf(owner);
            _prepareShares(owner, user, cases[i].expectedShares);

            // implicitly test that `_updateBaseInterest` is called with correct parameters
            vm.expectCall(
                interestRateModel,
                abi.encodeWithSelector(
                    calcBorrowRateSelector,
                    pool.expectedLiquidity() - cases[i].expectedAssetsToReceiver - cases[i].expectedAssetsToTreasury,
                    pool.availableLiquidity() - cases[i].expectedAssetsToReceiver - cases[i].expectedAssetsToTreasury,
                    false
                )
            );

            // sends underlying
            vm.expectCall(
                address(underlying), abi.encodeCall(IERC20.transfer, (owner, cases[i].expectedAssetsToReceiver))
            );
            if (cases[i].expectedAssetsToTreasury != 0) {
                vm.expectCall(
                    address(underlying), abi.encodeCall(IERC20.transfer, (treasury, cases[i].expectedAssetsToTreasury))
                );
            }

            // emits event
            vm.expectEmit(true, true, true, true);
            emit Withdraw(user, owner, owner, cases[i].assets, cases[i].expectedShares);

            vm.prank(user);
            uint256 shares = pool.withdraw({assets: cases[i].assets, receiver: owner, owner: owner});

            // updates balance and allowance
            assertEq(pool.allowance(user, owner), 0, _testCaseErr(cases[i].name, "Incorrect shares allowance"));
            assertEq(
                pool.balanceOf(owner), sharesBefore, _testCaseErr(cases[i].name, "Incorrect shares burned from owner")
            );

            // returns correct value
            assertEq(shares, cases[i].expectedShares, _testCaseErr(cases[i].name, "Incorrect shares returned"));

            vm.revertTo(snapshot);
        }
    }

    struct RedeemTestCase {
        string name;
        // scenario
        uint256 shares;
        uint256 transferFee;
        uint256 withdrawFee;
        // outcome
        uint256 expectedAssets;
        uint256 expectedAssetsToReceiver;
        uint256 expectedAssetsToTreasury;
    }

    /// @notice U:[LP-9]: `redeem` works as expected
    function test_U_LP_09_redeem_works_as_expected(address owner) public {
        vm.assume(owner != address(0) && owner != address(pool) && owner != address(this));

        RedeemTestCase[3] memory cases = [
            RedeemTestCase({
                name: "redeem with 0% transfer and 0% withdraw fee",
                shares: 80,
                transferFee: 0,
                withdrawFee: 0,
                expectedAssets: 100,
                expectedAssetsToReceiver: 100,
                expectedAssetsToTreasury: 0
            }),
            RedeemTestCase({
                name: "redeem with 5% transfer and 0% withdraw fee",
                shares: 80,
                transferFee: 500,
                withdrawFee: 0,
                expectedAssets: 95,
                expectedAssetsToReceiver: 100,
                expectedAssetsToTreasury: 0
            }),
            RedeemTestCase({
                name: "redeem with 5% transfer and 1% withdraw fee",
                shares: 80,
                transferFee: 500,
                withdrawFee: 100,
                expectedAssets: 94,
                expectedAssetsToReceiver: 99,
                expectedAssetsToTreasury: 1
            })
        ];

        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < cases.length; ++i) {
            if (cases[i].transferFee != 0) _activateTransferFee(cases[i].transferFee);
            if (cases[i].withdrawFee != 0) _activateWithdrawFee(cases[i].withdrawFee);

            uint256 sharesBefore = pool.balanceOf(owner);
            _prepareShares(owner, user, cases[i].shares);

            // implicitly test that `_updateBaseInterest` is called with correct parameters
            vm.expectCall(
                interestRateModel,
                abi.encodeWithSelector(
                    calcBorrowRateSelector,
                    pool.expectedLiquidity() - cases[i].expectedAssetsToReceiver - cases[i].expectedAssetsToTreasury,
                    pool.availableLiquidity() - cases[i].expectedAssetsToReceiver - cases[i].expectedAssetsToTreasury,
                    false
                )
            );

            // sends underlying
            vm.expectCall(
                address(underlying), abi.encodeCall(IERC20.transfer, (owner, cases[i].expectedAssetsToReceiver))
            );
            if (cases[i].expectedAssetsToTreasury != 0) {
                vm.expectCall(
                    address(underlying), abi.encodeCall(IERC20.transfer, (treasury, cases[i].expectedAssetsToTreasury))
                );
            }

            // emits event
            vm.expectEmit(true, true, true, true);
            emit Withdraw(user, owner, owner, cases[i].expectedAssets, cases[i].shares);

            vm.prank(user);
            uint256 assets = pool.redeem({shares: cases[i].shares, receiver: owner, owner: owner});

            // updates balance and allowance
            assertEq(pool.allowance(user, owner), 0, _testCaseErr(cases[i].name, "Incorrect shares allowance"));
            assertLe(
                pool.balanceOf(owner), sharesBefore, _testCaseErr(cases[i].name, "Incorrect shares burned from owner")
            );

            // returns correct value
            assertEq(assets, cases[i].expectedAssets, _testCaseErr(cases[i].name, "Incorrect assets returned"));

            vm.revertTo(snapshot);
        }
    }

    struct PreviewTestCase {
        string name;
        // scenario
        uint256 transferFee;
        uint256 withdrawFee;
        // outcome
        uint256 expectedSharesOut;
        uint256 expectedAssetsIn;
        uint256 expectedAssetsOut;
        uint256 expectedSharesIn;
    }

    /// @notice U:[LP-10]: `preview{Deposit|Mint|Withdraw|Redeem}` functions work as exptected
    function test_U_LP_10_preview_functions_work_as_expected() public {
        PreviewTestCase[3] memory cases = [
            PreviewTestCase({
                name: "preview with 0% transfer and 0% withdraw fee",
                transferFee: 0,
                withdrawFee: 0,
                expectedSharesOut: 80,
                expectedAssetsIn: 100,
                expectedSharesIn: 80,
                expectedAssetsOut: 100
            }),
            PreviewTestCase({
                name: "preview with 5% transfer and 0% withdraw fee",
                transferFee: 500,
                withdrawFee: 0,
                expectedSharesOut: 76,
                expectedAssetsIn: 105,
                expectedSharesIn: 84,
                expectedAssetsOut: 95
            }),
            PreviewTestCase({
                name: "preview with 5% transfer and 1% withdraw fee",
                transferFee: 500,
                withdrawFee: 100,
                expectedSharesOut: 76,
                expectedAssetsIn: 105,
                expectedSharesIn: 85,
                expectedAssetsOut: 94
            })
        ];

        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < cases.length; ++i) {
            if (cases[i].transferFee != 0) _activateTransferFee(cases[i].transferFee);
            if (cases[i].withdrawFee != 0) _activateWithdrawFee(cases[i].withdrawFee);

            assertEq(
                pool.previewDeposit(100),
                cases[i].expectedSharesOut,
                _testCaseErr(cases[i].name, "Incorrect previewDeposit")
            );
            assertEq(
                pool.previewMint(80), cases[i].expectedAssetsIn, _testCaseErr(cases[i].name, "Incorrect previewMint")
            );
            assertEq(
                pool.previewWithdraw(100),
                cases[i].expectedSharesIn,
                _testCaseErr(cases[i].name, "Incorrect previewWithdraw")
            );
            assertEq(
                pool.previewRedeem(80),
                cases[i].expectedAssetsOut,
                _testCaseErr(cases[i].name, "Incorrect previewRedeem")
            );
            vm.revertTo(snapshot);
        }
    }

    /// @notice U:[LP-11]: `max{Deposit|Mint|Withdraw|Redeem}` functions work as expected
    function test_U_LP_11_max_functions_work_as_expected() public {
        // no-fee case is rather trivial, so let's test with both fee types activated
        _activateTransferFee(500);
        _activateWithdrawFee(100);

        assertEq(pool.maxDeposit(lp), type(uint256).max, "Incorrect maxDeposit");
        assertEq(pool.maxMint(lp), type(uint256).max, "Incorrect maxMint");
        assertEq(
            pool.maxWithdraw(lp),
            940, // = (1000 * 95%) * 99%
            "Incorrect maxWithdraw (insufficient available liquidity)"
        );
        assertEq(
            pool.maxWithdraw(treasury),
            116, // = (125 * 95%) * 99%
            "Incorrect maxWithdraw (sufficient available liquidity)"
        );
        assertEq(pool.maxRedeem(lp), 800, "Incorrect maxRedeem (insufficient available liquidity)");
        assertEq(pool.maxRedeem(treasury), 100, "Incorrect maxRedeem (sufficient available liquidity)");

        vm.prank(configurator);
        pool.pause();
        assertEq(pool.maxDeposit(lp), 0, "Incorrect maxDeposit on pause");
        assertEq(pool.maxMint(lp), 0, "Incorrect maxMint on pause");
        assertEq(pool.maxWithdraw(lp), 0, "Incorrect maxWithdraw on pause");
        assertEq(pool.maxRedeem(lp), 0, "Incorrect maxRedeem on pause");
    }

    // --------- //
    // BORROWING //
    // --------- //

    /// @notice U:[LP-12]: `creditManagerBorrowable` works as expected
    function test_U_LP_12_creditManagerBorrowable_works_as_expected() public {
        // for the next two cases, `irm.availableToBorrow` should not be called
        vm.mockCallRevert(
            interestRateModel, abi.encode(ILinearInterestRateModelV3.availableToBorrow.selector), "should not be called"
        );

        // case: total debt limit is fully used
        pool.hackTotalBorrowed(2000);
        assertEq(pool.creditManagerBorrowable(creditManager), 0, "Incorrect borrowable (total debt limit fully used)");

        // case: CM debt limit is fully used (total limit is not)
        pool.hackTotalBorrowed(0);
        pool.hackCreditManagerBorrowed(creditManager, 1000);
        assertEq(pool.creditManagerBorrowable(creditManager), 0, "Incorrect borrowable (CM debt limit fully used)");

        // for the next three cases, let `irm.availableToBorrow` always return 500
        vm.mockCall(
            interestRateModel, abi.encode(ILinearInterestRateModelV3.availableToBorrow.selector), abi.encode(500)
        );

        // case: `irm.availableToBorrow` is the smallest
        pool.hackCreditManagerBorrowed(creditManager, 0);
        assertEq(
            pool.creditManagerBorrowable(creditManager),
            500,
            "Incorrect borrowable (irm.availableToBorrow is the smallest)"
        );

        // case: unused total debt is the smallest
        pool.hackTotalBorrowed(1600);
        assertEq(
            pool.creditManagerBorrowable(creditManager),
            400,
            "Incorrect borrowable (unused total debt limit is the smallest)"
        );

        // case: unused CM debt limit is the smallest
        pool.hackCreditManagerBorrowed(creditManager, 700);
        assertEq(
            pool.creditManagerBorrowable(creditManager),
            300,
            "Incorrect borrowable (unused CM debt limit is the smallest)"
        );
    }

    /// @notice U:[LP-13A]: `lendCreditAccount` reverts on out of debt limits
    function test_U_LP_13A_lendCreditAccount_reverts_on_out_of_debt_limits() public {
        // case: zero amount
        vm.expectRevert(CreditManagerCantBorrowException.selector);
        pool.lendCreditAccount({borrowedAmount: 0, creditAccount: address(0)});

        // case: CM debt limit violated
        pool.hackCreditManagerBorrowed(creditManager, 500);
        vm.expectRevert(CreditManagerCantBorrowException.selector);
        vm.prank(creditManager);
        pool.lendCreditAccount({borrowedAmount: 501, creditAccount: address(0)});

        // case: total debt limit violated
        pool.hackTotalBorrowed(1600);
        vm.expectRevert(CreditManagerCantBorrowException.selector);
        vm.prank(creditManager);
        pool.lendCreditAccount({borrowedAmount: 401, creditAccount: address(0)});
    }

    /// @notice U:[LP-13B]: `lendCreditAccount` works as expected
    function test_U_LP_13B_lendCreditAccount_works_as_expected() public {
        // implicitly test that `_updateBaseInterest` is called with correct parameters
        vm.expectCall(interestRateModel, abi.encodeWithSelector(calcBorrowRateSelector, 2000, 700, true));

        vm.expectCall(address(underlying), abi.encodeCall(IERC20.transfer, (creditAccount, 300)));

        vm.expectEmit(true, true, false, true);
        emit Borrow(creditManager, creditAccount, 300);

        vm.prank(creditManager);
        pool.lendCreditAccount({borrowedAmount: 300, creditAccount: creditAccount});

        assertEq(pool.totalBorrowed(), 1300, "Incorrect totalBorrowed");
        assertEq(pool.creditManagerBorrowed(creditManager), 800, "Incorrect creditManagerBorrowed");
    }

    /// @notice U:[LP-14A]: `repayCreditAccount` reverts on no debt
    function test_U_LP_14A_repayCreditAccount_reverts_on_no_debt() public {
        pool.hackCreditManagerBorrowed(creditManager, 0);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        vm.prank(creditManager);
        pool.repayCreditAccount({repaidAmount: 0, profit: 0, loss: 0});
    }

    /// @notice U:[LP-14B]: `repayCreditAccount` with profit works as expected
    function test_U_LP_14B_repayCreditAccount_with_profit_works_as_expected() public {
        // implicitly test that `_updateBaseInterest` is called with correct parameters
        vm.expectCall(interestRateModel, abi.encodeWithSelector(calcBorrowRateSelector, 2100, 1000, false));

        vm.expectEmit(true, true, false, true);
        emit Repay(creditManager, 300, 100, 0);

        vm.prank(creditManager);
        pool.repayCreditAccount({repaidAmount: 300, profit: 100, loss: 0});

        assertEq(pool.totalBorrowed(), 700, "Incorrect totalBorrowed");
        assertEq(pool.creditManagerBorrowed(creditManager), 200, "Incorrect creditManagerBorrowed");
        assertEq(pool.balanceOf(treasury), 180, "Incorrect treasury balance of diesel token");
    }

    /// @notice U:[LP-14C]: `repayCreditAccount` with covered loss works as expected
    function test_U_LP_14C_repayCreditAccount_with_covered_loss_works_as_expected() public {
        // implicitly test that `_updateBaseInterest` is called with correct parameters
        vm.expectCall(interestRateModel, abi.encodeWithSelector(calcBorrowRateSelector, 1900, 1000, false));

        vm.expectEmit(true, true, false, true);
        emit Repay(creditManager, 300, 0, 100);

        vm.prank(creditManager);
        pool.repayCreditAccount({repaidAmount: 300, profit: 0, loss: 100});

        assertEq(pool.totalBorrowed(), 700, "Incorrect totalBorrowed");
        assertEq(pool.creditManagerBorrowed(creditManager), 200, "Incorrect creditManagerBorrowed");
        assertEq(pool.balanceOf(treasury), 20, "Incorrect treasury balance of diesel token");
    }

    /// @notice U:[LP-14D]: `repayCreditAccount` with uncovered loss works as expected
    function test_U_LP_14D_repayCreditAccount_with_uncovered_loss_works_as_expected() public {
        // implicitly test that `_updateBaseInterest` is called with correct parameters
        vm.expectCall(interestRateModel, abi.encodeWithSelector(calcBorrowRateSelector, 1800, 1000, false));

        vm.expectEmit(true, false, false, true);
        // loss is 200 / 1.25 = 160 shares, but treasury only has 100
        // so, uncovered loss is 75 = (160 - 100) * 1.25
        emit IncurUncoveredLoss(creditManager, 75);

        vm.expectEmit(true, true, false, true);
        emit Repay(creditManager, 300, 0, 200);

        vm.prank(creditManager);
        pool.repayCreditAccount({repaidAmount: 300, profit: 0, loss: 200});

        assertEq(pool.totalBorrowed(), 700, "Incorrect totalBorrowed");
        assertEq(pool.creditManagerBorrowed(creditManager), 200, "Incorrect creditManagerBorrowed");
        assertEq(pool.balanceOf(treasury), 0, "Incorrect treasury balance of diesel token");
    }

    // ------------- //
    // INTEREST RATE //
    // ------------- //

    /// @notice U:[LP-15]: `supplyRate` works as expected
    function test_U_LP_15_supplyRate_works_as_expected() public {
        _activateWithdrawFee(100);

        // supply rate now:
        // 9.9% = (100% - 1%) * (1000 * 10% + 100) / 2000
        // supply rate in a year:
        // 9% =  (100% - 1%) * (1000 * 10% + 100) / (2000 + 1000 * 10% + 100)
        pool.hackBaseInterestRate(RAY / 10);
        pool.hackQuotaRevenue(100);

        assertEq(pool.supplyRate(), 99 * RAY / 1000, "Incorrect supplyRate right after update");

        vm.warp(block.timestamp + 365 days);
        assertEq(pool.supplyRate(), 9 * RAY / 100, "Incorrect supplyRate 1 year after update");
    }

    /// @notice U:[LP-16]: `baseInterestIndex` works as expected
    function test_U_LP_16_baseInterestIndex_works_as_expected() public {
        pool.hackBaseInterestRate(RAY / 10);
        pool.hackBaseInterestIndexLU(11 * RAY / 10);

        assertEq(pool.baseInterestIndex(), 11 * RAY / 10, "Incorrect baseInterestIndex right after update");

        vm.warp(block.timestamp + 365 days);
        assertEq(pool.baseInterestIndex(), 121 * RAY / 100, "Incorrect baseInterestIndex 1 year after update");
    }

    /// @notice U:[LP-17]: `_calcBaseInterestAccrued` works as expected
    function test_U_LP_17_calcBaseInterestAccrued_works_as_expected() public {
        pool.hackBaseInterestRate(RAY / 10);

        assertEq(pool.calcBaseInterestAccrued(), 0, "Incorrect baseInterest accrued right after update");

        vm.warp(block.timestamp + 365 days);
        assertEq(pool.calcBaseInterestAccrued(), 100, "Incorrect baseInterest accrued 1 year after update");
    }

    /// @notice U:[LP-18]: `_updateBaseInterest` works as expected
    function test_U_LP_18_updateBaseInterest_works_as_expected() public {
        // expected liquidity in a year: 2200 = 2000 + 1000 * 10% + 100
        // expected base interest index in a year: 1.32 = 1.2 * 1.1
        pool.hackBaseInterestRate(RAY / 10);
        pool.hackBaseInterestIndexLU(6 * RAY / 5);
        pool.hackQuotaRevenue(100);

        vm.warp(block.timestamp + 365 days);

        // let's update base interest with expected liquidity delta of -300 and available liquidity delta of 300
        vm.expectCall(interestRateModel, abi.encodeWithSelector(calcBorrowRateSelector, 1900, 1300, true));

        pool.updateBaseInterest({
            expectedLiquidityDelta: -300,
            availableLiquidityDelta: 300,
            checkOptimalBorrowing: true
        });

        assertEq(pool.expectedLiquidity(), 1900, "Incorrect expectedLiquidity");
        assertEq(pool.expectedLiquidityLU(), 1900, "Incorrect expectedLiquidityLU");
        assertEq(pool.baseInterestRate(), RAY / 20, "Incorrect baseInterestRate");
        assertEq(pool.baseInterestIndex(), 132 * RAY / 100, "Incorrect baseInterestIndex");
        assertEq(pool.lastBaseInterestUpdate(), block.timestamp, "Incorrect lastBaseInterestUpdate");
        assertEq(pool.lastQuotaRevenueUpdate(), block.timestamp, "Incorrect lastQuotaRevenueUpdate");
    }

    // ------ //
    // QUOTAS //
    // ------ //

    /// @notice U:[LP-19]: `updateQuotaRevenue` works as expected
    function test_U_LP_19_updateQuotaRevenue_works_as_expected() public {
        pool.hackQuotaRevenue(100);

        vm.prank(quotaKeeper);
        pool.updateQuotaRevenue(10);

        // implicitly test that `_setQuotaRevenue` is called with correct parameters
        assertEq(pool.quotaRevenue(), 110, "Incorrect quotaRevenue");
    }

    /// @notice U:[LP-20]: `setQuotaRevenue` works as expected
    function test_U_LP_20_setQuotaRevenue_works_as_expected() public {
        pool.hackQuotaRevenue(100);
        vm.warp(block.timestamp + 365 days);

        vm.prank(quotaKeeper);
        pool.setQuotaRevenue(200);
        assertEq(pool.expectedLiquidityLU(), 2100, "Incorrect expectedLiquidityLU");
        assertEq(pool.lastQuotaRevenueUpdate(), block.timestamp, "Incorrect lastQuotaRevenueUpdate");
        assertEq(pool.quotaRevenue(), 200, "Incorrect quotaRevenue");
    }

    /// @notice U:[LP-21]: `_calcQuotaRevenueAccrued` works as expected
    function test_U_LP_21_calcQuotaRevenueAccrued_works_as_expected() public {
        pool.hackQuotaRevenue(100);

        assertEq(pool.calcQuotaRevenueAccrued(), 0, "Incorrect quotaRevenue accrued right after update");

        vm.warp(block.timestamp + 365 days);
        assertEq(pool.calcQuotaRevenueAccrued(), 100, "Incorrect quotaRevenue accrued 1 year after update");
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice U:[LP-22A]: `setInterestRateModel` reverts on zero address
    function test_U_LP_22A_setInterestRateModel_reverts_on_zero_address() public {
        vm.expectRevert(ZeroAddressException.selector);
        vm.prank(configurator);
        pool.setInterestRateModel(address(0));
    }

    /// @notice U:[LP-22B]: `setInterestRateModel` works as expected
    function test_U_LP_22B_setInterestRateModel_works_as_expected() public {
        address newInterestRateModel = makeAddr("NEW_INTEREST_RATE_MODEL");
        bytes memory irmCallData = abi.encodeWithSelector(calcBorrowRateSelector, 2000, 1000, false);
        vm.mockCall(newInterestRateModel, irmCallData, abi.encode(0));

        vm.expectEmit(true, false, false, false);
        emit SetInterestRateModel(newInterestRateModel);

        // implicitly test that `_updateBaseInterest` is called with correct parameters
        vm.expectCall(newInterestRateModel, irmCallData);

        vm.prank(configurator);
        pool.setInterestRateModel(newInterestRateModel);

        assertEq(pool.interestRateModel(), newInterestRateModel, "Incorrect interestRateModel");
    }

    /// @notice U:[LP-23A]: `setPoolQuotaKeeper` reverts on zero address
    function test_U_LP_23A_setPoolQuotaKeeper_reverts_on_zero_address() public {
        vm.expectRevert(ZeroAddressException.selector);
        vm.prank(configurator);
        pool.setPoolQuotaKeeper(address(0));
    }

    /// @notice U:[LP-23C]: `setPoolQuotaKeeper` reverts on incompatible quota keeper
    function test_U_LP_23C_setPoolQuotaKeeper_reverts_on_incompatible_quota_keeper() public {
        address newQuotaKeeper = makeAddr("NEW_QUOTA_KEEPER");
        vm.mockCall(newQuotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.pool, ()), abi.encode(makeAddr("WRONG_POOL")));

        vm.expectRevert(IncompatiblePoolQuotaKeeperException.selector);
        vm.prank(configurator);
        pool.setPoolQuotaKeeper(newQuotaKeeper);
    }

    /// @notice U:[LP-23D]: `setPoolQuotaKeeper` works as expected
    function test_U_LP_23D_setPoolQuotaKeeper_works_as_expected() public {
        address newQuotaKeeper = makeAddr("NEW_QUOTA_KEEPER");
        vm.mockCall(newQuotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.pool, ()), abi.encode(address(pool)));
        vm.mockCall(newQuotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.poolQuotaRevenue, ()), abi.encode(100));

        vm.expectEmit(true, false, false, false);
        emit SetPoolQuotaKeeper(newQuotaKeeper);

        vm.expectCall(newQuotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.poolQuotaRevenue, ()));

        vm.prank(configurator);
        pool.setPoolQuotaKeeper(newQuotaKeeper);

        assertEq(pool.poolQuotaKeeper(), newQuotaKeeper, "Incorrect poolQuotaKeeper");
        // implicitly test that `_setQuotaRevenue` is called with correct parameters
        assertEq(pool.quotaRevenue(), 100, "Incorrect quotaRevenue");
    }

    /// @notice U:[LP-24]: `setTotalDebtLimit` works as expected
    function test_U_LP_24_setTotalDebtLimit_works_as_expected() public {
        // case: finite limit
        vm.expectEmit(false, false, false, false);
        emit SetTotalDebtLimit(123);

        vm.prank(configurator);
        pool.setTotalDebtLimit(123);

        assertEq(pool.totalDebtLimit(), 123, "Incorrect totalDebtLimit (case: finite limit)");

        // case: no limit
        vm.expectEmit(false, false, false, false);
        emit SetTotalDebtLimit(type(uint256).max);

        vm.prank(configurator);
        pool.setTotalDebtLimit(type(uint256).max);

        assertEq(pool.totalDebtLimit(), type(uint256).max, "Incorrect totalDebtLimit (case: no limit)");
    }

    /// @notice U:[LP-25A]: `setCreditManagerDebtLimit` reverts on zero address
    function test_U_LP_25A_setCreditManagerDebtLimit_reverts_on_zero_address() public {
        vm.expectRevert(ZeroAddressException.selector);
        vm.prank(configurator);
        pool.setCreditManagerDebtLimit(address(0), 0);
    }

    /// @notice U:[LP-25B]: `setCreditManagerDebtLimit` reverts on non-registered credit manager
    function test_U_LP_25B_setCreditManagerDebtLimit_reverts_on_non_registered_credit_manager() public {
        vm.expectRevert(RegisteredCreditManagerOnlyException.selector);
        vm.prank(configurator);
        pool.setCreditManagerDebtLimit(makeAddr("NEW_CREDIT_MANAGER"), 0);
    }

    /// @notice U:[LP-25C]: `setCreditManagerDebtLimit` reverts on incompatible credit manager
    function test_U_LP_25C_setCreditManagerDebtLimit_reverts_on_incompatible_credit_manager() public {
        address newCreditManager = makeAddr("NEW_CREDIT_MANAGER");

        vm.prank(configurator);
        addressProvider.addCreditManager(newCreditManager);

        vm.mockCall(newCreditManager, abi.encodeCall(ICreditManagerV3.pool, ()), abi.encode(makeAddr("WRONG_POOL")));

        vm.expectRevert(IncompatibleCreditManagerException.selector);
        vm.prank(configurator);
        pool.setCreditManagerDebtLimit(newCreditManager, 0);
    }

    /// @notice U:[LP-25D]: `setCreditManagerDebtLimit` works as expected
    function test_U_LP_25D_setCreditManagerDebtLimit_works_as_expected() public {
        address newCreditManager = makeAddr("NEW_CREDIT_MANAGER");

        vm.prank(configurator);
        addressProvider.addCreditManager(newCreditManager);

        // when credit manager is not in the credit managers list, it should add it there
        vm.mockCall(newCreditManager, abi.encodeCall(ICreditManagerV3.pool, ()), abi.encode(address(pool)));

        vm.expectEmit(true, false, false, false);
        emit AddCreditManager(newCreditManager);

        vm.expectEmit(true, false, false, true);
        emit SetCreditManagerDebtLimit(newCreditManager, 123);

        vm.prank(configurator);
        pool.setCreditManagerDebtLimit(newCreditManager, 123);

        assertEq(pool.creditManagers()[0], creditManager, "Incorrect creditManagers[0]");
        assertEq(pool.creditManagers()[1], newCreditManager, "Incorrect creditManagers[1]");
        assertEq(
            pool.creditManagerDebtLimit(newCreditManager), 123, "Incorrect credit manager debt limit after first call"
        );

        // when credit manager is already added to the list, it should not check compatibility
        vm.mockCallRevert(newCreditManager, abi.encodeCall(ICreditManagerV3.pool, ()), "already added");

        vm.expectEmit(true, false, false, true);
        emit SetCreditManagerDebtLimit(newCreditManager, 456);

        vm.prank(configurator);
        pool.setCreditManagerDebtLimit(newCreditManager, 456);

        assertEq(
            pool.creditManagerDebtLimit(newCreditManager), 456, "Incorrect credit manager debt limit after second call"
        );
    }

    /// @notice U:[LP-26A]: `setWithdrawFee` reverts on incorrect value
    function test_U_LP_26A_setWithdrawFee_reverts_on_incorrect_value() public {
        vm.expectRevert(IncorrectParameterException.selector);
        vm.prank(configurator);
        pool.setWithdrawFee(MAX_WITHDRAW_FEE + 1);
    }

    /// @notice U:[LP-26B]: `setWithdrawFee` works as expected
    function test_U_LP_26B_setWithdrawFee_works_as_expected() public {
        uint256 newWithdrawFee = MAX_WITHDRAW_FEE / 2;

        vm.expectEmit(false, false, false, true);
        emit SetWithdrawFee(newWithdrawFee);

        vm.prank(configurator);
        pool.setWithdrawFee(newWithdrawFee);

        assertEq(pool.withdrawFee(), newWithdrawFee, "Incorrect withdrawFee");
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _prepareAssets(address owner, uint256 assets) internal {
        deal({token: address(underlying), to: owner, give: assets, adjust: true});
        vm.prank(owner);
        underlying.approve(address(pool), assets);
    }

    function _prepareShares(address owner, address spender, uint256 shares) internal {
        _prepareAssets(owner, pool.previewMint(shares));
        vm.startPrank(owner);
        pool.mint(shares, owner);
        if (spender != owner) pool.approve(spender, shares);
        vm.stopPrank();
    }

    function _activateTransferFee(uint256 fee) internal {
        pool.hackTransferFee(fee);
        underlying.setBasisPointsRate(fee);
        underlying.setMaximumFee(type(uint256).max);
    }

    function _activateWithdrawFee(uint256 fee) internal {
        vm.prank(configurator);
        pool.setWithdrawFee(fee);
    }
}
