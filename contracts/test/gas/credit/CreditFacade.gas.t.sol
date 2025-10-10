// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ICreditFacadeV3Multicall, MultiCall} from "../../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// TESTS
import "../../lib/constants.sol";
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// MOCKS
import {AdapterMock} from "../../mocks/core/AdapterMock.sol";

// SUITES
import "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

contract CreditFacadeGasTest is IntegrationTestHelper {
    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev G:[FA-2]: openCreditAccount with just adding collateral
    function test_G_FA_02_openCreditAccountMulticall_gas_estimate_1() public creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            })
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - opening an account with just adding collateral: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-3]: openCreditAccount with adding collateral and single swap
    function test_G_FA_03_openCreditAccountMulticall_gas_estimate_2() public withAdapterMock creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            }),
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())})
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(abi.encodePacked("Gas spent - opening an account with adding collateral and executing one swap: "))
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-4]: openCreditAccount with adding collateral and two swaps
    function test_G_FA_04_openCreditAccountMulticall_gas_estimate_3() public withAdapterMock creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            }),
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())}),
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())})
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(abi.encodePacked("Gas spent - opening an account with adding collateral and executing two swaps: "))
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-5]: openCreditAccount with adding quoted collateral and updating quota
    function test_G_FA_05_openCreditAccountMulticall_gas_estimate_4() public creditTest {
        vm.warp(block.timestamp + 7 days);
        vm.prank(CONFIGURATOR);
        gauge.updateEpoch();

        tokenTestSuite.mint(TOKEN_LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(TOKEN_LINK, USER, address(creditManager));

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_LINK), LINK_ACCOUNT_AMOUNT)
                )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(TOKEN_LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(TOKEN_WETH), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(TOKEN_LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
            })
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent array: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-6]: openCreditAccount with swapping and updating quota
    function test_G_FA_06_openCreditAccountMulticall_gas_estimate_5() public withAdapterMock creditTest {
        vm.warp(block.timestamp + 7 days);
        vm.prank(CONFIGURATOR);
        gauge.updateEpoch();

        tokenTestSuite.mint(TOKEN_LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(TOKEN_LINK, USER, address(creditManager));

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_LINK), LINK_ACCOUNT_AMOUNT)
                )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(TOKEN_LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
            }),
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())})
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(abi.encodePacked("Gas spent - opening an account with swapping into quoted collateral: "))
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-7]: multicall with increaseDebt
    function test_G_FA_07_increaseDebt_gas_estimate_1() public creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.number + 1);

        calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            })
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with increaseDebt: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-8]: multicall with decreaseDebt
    function test_G_FA_08_decreaseDebt_gas_estimate_1() public creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.timestamp + 1);

        calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (DAI_ACCOUNT_AMOUNT / 2))
            })
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with decreaseDebt: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-9]: multicall with decreaseDebt and active quota interest
    function test_G_FA_09_decreaseDebt_gas_estimate_2() public creditTest {
        vm.warp(block.timestamp + 7 days);
        vm.prank(CONFIGURATOR);
        gauge.updateEpoch();

        tokenTestSuite.mint(TOKEN_LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(TOKEN_LINK, USER, address(creditManager));

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_LINK), LINK_ACCOUNT_AMOUNT)
                )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(TOKEN_LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.timestamp + 1);
        vm.warp(block.timestamp + 30 days);

        calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(TOKEN_LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (DAI_ACCOUNT_AMOUNT / 2))
            })
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with decreaseDebt with quoted tokens: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-12]: multicall with a single swap
    function test_G_FA_12_multicall_gas_estimate_1() public withAdapterMock creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())})
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with a single swap: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-12A]: multicall with a single swap
    function test_G_FA_12A_multicall_gas_estimate_1A() public withAdapterMock creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())}),
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())})
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with two swaps: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-13]: multicall with a single swap into quoted token
    function test_G_FA_13_multicall_gas_estimate_2() public withAdapterMock creditTest {
        vm.warp(block.timestamp + 7 days);
        vm.prank(CONFIGURATOR);
        gauge.updateEpoch();

        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        tokenTestSuite.burn(TOKEN_DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);
        tokenTestSuite.mint(TOKEN_LINK, creditAccount, LINK_ACCOUNT_AMOUNT * 3);

        calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())}),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(TOKEN_LINK), int96(int256(LINK_ACCOUNT_AMOUNT * 3)), 0)
                )
            })
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(
                abi.encodePacked(
                    "Gas spent - multicall with a single swap into quoted collateral and updating quotas: "
                )
            )
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-14]: closeCreditAccount with no debt and underlying only
    function test_G_FA_14_closeCreditAccount_gas_estimate_1() public creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.number + 1);

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.closeCreditAccount(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.withdrawCollateral, (underlying, type(uint256).max, USER)
                    )
                })
            )
        );

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with no debt and underlying only: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-15]: closeCreditAccount with debt and underlying
    function test_G_FA_15_closeCreditAccount_gas_estimate_2() public creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.number + 1);

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.closeCreditAccount(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (type(uint256).max))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.withdrawCollateral, (underlying, type(uint256).max, USER)
                    )
                })
            )
        );

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with debt and underlying: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-16]: closeCreditAccount with debt and two tokens
    function test_G_FA_16_closeCreditAccount_gas_estimate_3() public creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);
        tokenTestSuite.mint(TOKEN_LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(TOKEN_LINK, USER, address(creditManager));

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_LINK), LINK_ACCOUNT_AMOUNT)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.number + 1);

        address linkToken = tokenTestSuite.addressOf(TOKEN_LINK);

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.closeCreditAccount(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (type(uint256).max))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.withdrawCollateral, (underlying, type(uint256).max, USER)
                    )
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.withdrawCollateral, (linkToken, type(uint256).max, USER)
                    )
                })
            )
        );

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with debt and 2 tokens: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-17]: closeCreditAccount with one swap
    function test_G_FA_17_closeCreditAccount_gas_estimate_4() public withAdapterMock creditTest {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(TOKEN_DAI), DAI_ACCOUNT_AMOUNT)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.number + 1);

        calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())}),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (type(uint256).max))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (underlying, type(uint256).max, USER))
            })
        );

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with one swap: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-18]: liquidateCreditAccount with underlying only
    function test_G_FA_18_liquidateCreditAccount_gas_esimate_1() public creditTest {
        uint256 debtAmount = DAI_ACCOUNT_AMOUNT;
        uint256 collateralAmount =
            debtAmount * PERCENTAGE_FACTOR / creditManager.liquidationThresholds(underlying) - debtAmount + 0.01e18;

        tokenTestSuite.mint(underlying, USER, collateralAmount);
        tokenTestSuite.approve(underlying, USER, address(creditManager), collateralAmount);

        MultiCall[] memory openCalls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debtAmount))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, collateralAmount))
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, openCalls, 0);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 30 days);

        uint256 gasBefore = gasleft();
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, new MultiCall[](0));
        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - liquidateCreditAccount with underlying only: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-19]: liquidateCreditAccount with one collateral token
    function test_G_FA_19_liquidateCreditAccount_gas_estimate_2() public creditTest {
        vm.warp(block.timestamp + 7 days);
        vm.prank(CONFIGURATOR);
        gauge.updateEpoch();

        uint256 debtAmount = DAI_ACCOUNT_AMOUNT;
        uint256 bufferedDebtAmount = 11 * debtAmount / 10;
        uint256 collateralAmount = priceOracle.convert(bufferedDebtAmount, weth, underlying) * PERCENTAGE_FACTOR
            / creditManager.liquidationThresholds(weth);

        tokenTestSuite.mint(weth, USER, collateralAmount);
        tokenTestSuite.approve(weth, USER, address(creditManager), collateralAmount);

        MultiCall[] memory openCalls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debtAmount))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (underlying, debtAmount, FRIEND))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (weth, collateralAmount))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (weth, int96(uint96(bufferedDebtAmount)), 0))
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, openCalls, 0);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 30 days);

        _makeAccountsLiquidatable();

        (,, uint16 discount,,) = creditManager.fees();
        uint256 repaidAmount = priceOracle.convert(collateralAmount, weth, underlying) * discount / PERCENTAGE_FACTOR;

        tokenTestSuite.mint(underlying, LIQUIDATOR, repaidAmount);
        tokenTestSuite.approve(underlying, LIQUIDATOR, address(creditManager), repaidAmount);

        MultiCall[] memory liquidateCalls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (weth, collateralAmount, FRIEND))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, repaidAmount))
            })
        );

        uint256 gasBefore = gasleft();
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, liquidateCalls);
        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - liquidateCreditAccount with one collateral token: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-20]: liquidateCreditAccount with two collateral tokens
    function test_G_FA_20_liquidateCreditAccount_gas_esimate_2() public creditTest {
        vm.warp(block.timestamp + 7 days);
        vm.prank(CONFIGURATOR);
        gauge.updateEpoch();

        address link = tokenTestSuite.addressOf(TOKEN_LINK);

        uint256 debtAmount = DAI_ACCOUNT_AMOUNT;
        uint256 bufferedDebtAmount = 11 * debtAmount / 10;
        uint256 wethCollateralAmount = priceOracle.convert(bufferedDebtAmount / 2, weth, underlying) * PERCENTAGE_FACTOR
            / creditManager.liquidationThresholds(weth);
        uint256 linkCollateralAmount = priceOracle.convert(bufferedDebtAmount / 2, link, underlying) * PERCENTAGE_FACTOR
            / creditManager.liquidationThresholds(link);

        tokenTestSuite.mint(weth, USER, wethCollateralAmount);
        tokenTestSuite.approve(weth, USER, address(creditManager), wethCollateralAmount);

        tokenTestSuite.mint(link, USER, linkCollateralAmount);
        tokenTestSuite.approve(link, USER, address(creditManager), linkCollateralAmount);

        MultiCall[] memory openCalls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debtAmount))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (underlying, debtAmount, FRIEND))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (weth, wethCollateralAmount))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (weth, int96(uint96(bufferedDebtAmount / 2)), 0)
                )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (link, linkCollateralAmount))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (link, int96(uint96(bufferedDebtAmount / 2)), 0)
                )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, openCalls, 0);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 30 days);

        _makeAccountsLiquidatable();

        (,, uint16 discount,,) = creditManager.fees();
        uint256 repaidAmount = (
            priceOracle.convert(wethCollateralAmount, weth, underlying)
                + priceOracle.convert(linkCollateralAmount, link, underlying)
        ) * discount / PERCENTAGE_FACTOR;

        tokenTestSuite.mint(underlying, LIQUIDATOR, repaidAmount);
        tokenTestSuite.approve(underlying, LIQUIDATOR, address(creditManager), repaidAmount);

        MultiCall[] memory liquidateCalls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (weth, wethCollateralAmount, FRIEND))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (link, linkCollateralAmount, FRIEND))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, repaidAmount))
            })
        );

        uint256 gasBefore = gasleft();
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, liquidateCalls);
        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - liquidateCreditAccount with two collateral tokens: ")));
        emit log_uint(gasSpent);
    }
}
