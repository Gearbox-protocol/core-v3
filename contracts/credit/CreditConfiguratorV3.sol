// // SPDX-License-Identifier: BUSL-1.1
// // Gearbox Protocol. Generalized leverage for DeFi protocols
// // (c) Gearbox Foundation, 2024.
// pragma solidity ^0.8.17;

// // THIRD-PARTY
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
// import {Address} from "@openzeppelin/contracts/utils/Address.sol";

// // LIBRARIES & CONSTANTS
// import {BitMask} from "../libraries/BitMask.sol";
// import {OptionalCall} from "../libraries/OptionalCall.sol";
// import {PERCENTAGE_FACTOR, UNDERLYING_TOKEN_MASK, WAD} from "../libraries/Constants.sol";
// import {MarketHelper} from "../libraries/MarketHelper.sol";

// // CONTRACTS
// import {CreditFacadeV3} from "./CreditFacadeV3.sol";
// import {CreditManagerV3} from "./CreditManagerV3.sol";

// // INTERFACES
// import {ICreditConfiguratorV3, AllowanceAction} from "../interfaces/ICreditConfiguratorV3.sol";
// import {IPriceOracleV3} from "../interfaces/IPriceOracleV3.sol";
// import {IAdapter} from "../interfaces/base/IAdapter.sol";
// import {IPhantomToken} from "../interfaces/base/IPhantomToken.sol";

// // TRAITS
// import {ACLTrait} from "../traits/ACLTrait.sol";
// import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";

// // EXCEPTIONS
// import "../interfaces/IExceptions.sol";

// interface ICreditManagerLegacy {
//     function setQuotedMask(uint256 mask) external;
// }

// /// @title Credit configurator V3
// /// @notice Provides funcionality to configure various aspects of credit manager and facade's behavior
// /// @dev Most of the functions can only be accessed by configurator
// contract CreditConfiguratorV3 is ICreditConfiguratorV3, ACLTrait, SanityCheckTrait {
//     using EnumerableSet for EnumerableSet.AddressSet;
//     using Address for address;
//     using BitMask for uint256;
//     using MarketHelper for CreditManagerV3;

//     /// @notice Contract version
//     uint256 public constant override version = 3_10;

//     /// @notice Contract type
//     bytes32 public constant override contractType = "CREDIT_CONFIGURATOR";

//     /// @notice Credit manager address
//     address public immutable override creditManager;

//     /// @notice Underlying token address
//     address public immutable override underlying;

//     /// @dev Set of allowed contracts
//     EnumerableSet.AddressSet internal allowedAdaptersSet;

//     /// @dev Ensures that function is not called for underlying token
//     modifier nonUnderlyingTokenOnly(address token) {
//         _revertIfUnderlyingToken(token);
//         _;
//     }

//     /// @notice Constructor
//     /// @param _creditManager Credit manager to connect to
//     /// @dev Copies allowed adaprters from the currently connected configurator
//     constructor(address _creditManager) ACLTrait(CreditManagerV3(_creditManager).getACL()) {
//         creditManager = _creditManager; // I:[CC-1]
//         underlying = CreditManagerV3(_creditManager).underlying(); // I:[CC-1]

//         address currentConfigurator = CreditManagerV3(_creditManager).creditConfigurator();
//         if (!currentConfigurator.isContract()) return;
//         try CreditConfiguratorV3(currentConfigurator).allowedAdapters() returns (address[] memory adapters) {
//             uint256 len = adapters.length;
//             unchecked {
//                 for (uint256 i; i < len; ++i) {
//                     allowedAdaptersSet.add(adapters[i]); // I:[CC-29]
//                 }
//             }
//         } catch {}
//     }

//     /// @notice Returns the facade currently connected to the credit manager
//     function creditFacade() public view override returns (address) {
//         return CreditManagerV3(creditManager).creditFacade();
//     }

//     // ------ //
//     // TOKENS //
//     // ------ //

//     /// @notice Makes token recognizable as collateral in the credit manager and sets its liquidation threshold
//     /// @param token Token to add
//     /// @dev Reverts if `token` is not a valid ERC-20 token
//     /// @dev Reverts if `token` does not have a price feed in the price oracle
//     /// @dev Reverts if `token` is underlying
//     /// @dev Reverts if `token` is not quoted in the quota keeper
//     /// @dev Reverts if `liquidationThreshold` is greater than underlying's LT
//     /// @dev If `token` is a phantom token, reverts if its `depositedToken` is not added to the credit manager
//     /// @dev If `token` is a phantom token, an adapter for its `target` implementing `IPhantomTokenWithdrawer` interface
//     ///       must later be connected in order for withdrawals to work properly
//     /// @dev `liquidationThreshold` can be zero to allow users to deposit connector tokens to credit accounts and swap
//     ///      them into actual collateral and to withdraw reward tokens sent to credit accounts by integrated protocols
//     function addCollateralToken(address token)
//         external
//         override
//         nonZeroAddress(token)
//         nonUnderlyingTokenOnly(token)
//         configuratorOnly // I:[CC-2]

//     {
//         _addCollateralToken({token: token});
//     }

//     /// @dev `addCollateralToken` implementation
//     function _addCollateralToken(address token) internal {
//         if (!token.isContract()) revert AddressIsNotContractException(token);

//         try IERC20(token).balanceOf(address(this)) returns (uint256) {}
//         catch {
//             revert IncorrectTokenContractException();
//         }

//         // NOTE: Some external tokens without `getPhantomTokenInfo` may have a fallback function that changes state,
//         // which can cause a `THROW` that burns all gas, or does not change state and instead returns empty data.
//         // To handle these cases, we use a special call construction with a strict gas limit.
//         (bool success, bytes memory returnData) = OptionalCall.staticCallOptionalSafe({
//             target: token,
//             data: abi.encodeWithSelector(IPhantomToken.getPhantomTokenInfo.selector),
//             gasAllowance: 30_000
//         });
//         if (success) {
//             (, address depositedToken) = abi.decode(returnData, (address, address));
//             _revertIfNotAllowedCollateral(depositedToken);
//         }

//         CreditManagerV3(creditManager).addToken({token: token});
//         emit AddCollateralToken({token: token});
//     }

//     // -------- //
//     // ADAPTERS //
//     // -------- //

//     /// @notice Returns all allowed adapters
//     function allowedAdapters() external view override returns (address[] memory) {
//         return allowedAdaptersSet.values();
//     }

//     /// @notice Allows a new adapter in the credit manager
//     /// @notice If adapter's target contract already has an adapter in the credit manager, it is removed
//     /// @param adapter Adapter to allow
//     /// @dev Reverts if `adapter` is incompatible with the credit manager
//     /// @dev Reverts if `adapter`'s target contract is not a contract
//     /// @dev Reverts if `adapter` or its target contract is credit manager or credit facade
//     function allowAdapter(address adapter)
//         external
//         override
//         nonZeroAddress(adapter)
//         configuratorOnly // I:[CC-2]

//     {
//         address targetContract = _getTargetContractOrRevert({adapter: adapter});
//         if (!targetContract.isContract()) {
//             revert AddressIsNotContractException(targetContract); // I:[CC-10A]
//         }

//         address cf = creditFacade();
//         if (targetContract == cf || adapter == cf) {
//             revert TargetContractNotAllowedException(); // I:[CC-10C]
//         }

//         address currentAdapter = CreditManagerV3(creditManager).contractToAdapter(targetContract);
//         if (currentAdapter != address(0)) {
//             CreditManagerV3(creditManager).setContractAllowance({adapter: currentAdapter, targetContract: address(0)}); // I:[CC-12]
//             allowedAdaptersSet.remove(currentAdapter); // I:[CC-12]
//         }

//         CreditManagerV3(creditManager).setContractAllowance({adapter: adapter, targetContract: targetContract}); // I:[CC-11]

//         allowedAdaptersSet.add(adapter); // I:[CC-11]

//         emit AllowAdapter({targetContract: targetContract, adapter: adapter}); // I:[CC-11]
//     }

//     /// @notice Forbids both adapter and its target contract in the credit manager
//     /// @param adapter Adapter to forbid
//     /// @dev Reverts if `adapter` is incompatible with the credit manager
//     /// @dev Reverts if `adapter` is not registered in the credit manager
//     function forbidAdapter(address adapter)
//         external
//         override
//         nonZeroAddress(adapter)
//         configuratorOnly // I:[CC-2]

//     {
//         address targetContract = _getTargetContractOrRevert({adapter: adapter});
//         if (CreditManagerV3(creditManager).adapterToContract(adapter) == address(0)) {
//             revert AdapterIsNotRegisteredException(); // I:[CC-13]
//         }

//         CreditManagerV3(creditManager).setContractAllowance({adapter: adapter, targetContract: address(0)}); // I:[CC-14]
//         CreditManagerV3(creditManager).setContractAllowance({adapter: address(0), targetContract: targetContract}); // I:[CC-14]

//         allowedAdaptersSet.remove(adapter); // I:[CC-14]

//         emit ForbidAdapter({targetContract: targetContract, adapter: adapter}); // I:[CC-14]
//     }

//     /// @dev Checks that adapter is compatible with credit manager and returns its target contract
//     function _getTargetContractOrRevert(address adapter) internal view returns (address targetContract) {
//         _revertIfContractIncompatible(adapter); // I:[CC-10,10B]

//         try IAdapter(adapter).targetContract() returns (address tc) {
//             targetContract = tc;
//         } catch {
//             revert IncompatibleContractException();
//         }

//         if (targetContract == address(0)) revert TargetContractNotAllowedException();
//     }

//     // -------------- //
//     // CREDIT MANAGER //
//     // -------------- //

//     function setFees(uint16 feeLiquidation, uint16 liquidationPremium, uint16 maxEarlyClosurePenalty)
//         external
//         override
//         configuratorOnly // I:[CC-2]

//     {
//         if (
//             feeLiquidation > liquidationPremium
//                 || liquidationPremium + feeLiquidation + maxEarlyClosurePenalty >= PERCENTAGE_FACTOR
//         ) revert IncorrectParameterException(); // I:[CC-17]

//         (
//             uint16 _feeInterestCurrent,
//             uint16 _feeLiquidationCurrent,
//             uint16 _liquidationDiscountCurrent,
//             uint16 _maxEarlyClosurePenaltyCurrent
//         ) = CreditManagerV3(creditManager).fees();

//         uint16 liquidationDiscount = PERCENTAGE_FACTOR - liquidationPremium;

//         if (
//             (feeLiquidation == _feeLiquidationCurrent) && (liquidationDiscount == _liquidationDiscountCurrent)
//                 && (maxEarlyClosurePenalty == _maxEarlyClosurePenaltyCurrent)
//         ) return;

//         if (liquidationDiscount - feeLiquidation != _liquidationDiscountCurrent - _feeLiquidationCurrent) {
//             revert InconsistentLiquidationFeesException();
//         }

//         CreditManagerV3(creditManager)
//             .setFees(_feeInterestCurrent, feeLiquidation, liquidationDiscount, maxEarlyClosurePenalty);

//         emit UpdateFees({
//             feeLiquidation: feeLiquidation,
//             liquidationPremium: liquidationPremium,
//             maxEarlyClosurePenalty: maxEarlyClosurePenalty
//         });
//     }

//     // -------- //
//     // UPGRADES //
//     // -------- //

//     /// @notice Upgrades a facade connected to the credit manager
//     /// @param newCreditFacade New credit facade
//     /// @param migrateParams Whether to migrate old credit facade params
//     /// @dev Reverts if `newCreditFacade` is incompatible with credit manager
//     /// @dev Reverts if `newCreditFacade` is one of allowed adapters or their target contracts
//     /// @dev Special care must be taken in case `newCreditFacade`'s bot list differs from the old one
//     function setCreditFacade(address newCreditFacade, bool migrateParams) external override configuratorOnly {
//         CreditFacadeV3 prevCreditFacade = CreditFacadeV3(creditFacade());
//         if (newCreditFacade == address(prevCreditFacade)) return;

//         _revertIfContractIncompatible(newCreditFacade);
//         if (
//             CreditManagerV3(creditManager).adapterToContract(newCreditFacade) != address(0)
//                 || CreditManagerV3(creditManager).contractToAdapter(newCreditFacade) != address(0)
//         ) revert TargetContractNotAllowedException();

//         CreditManagerV3(creditManager).setCreditFacade(newCreditFacade);

//         if (migrateParams) {
//             (uint128 minDebt, uint128 maxDebt) = prevCreditFacade.debtLimits();
//             _setLimits({minDebt: minDebt, maxDebt: maxDebt});
//         }

//         emit SetCreditFacade(newCreditFacade);
//     }

//     /// @notice Upgrades credit manager's configurator contract
//     /// @param newCreditConfigurator New credit configurator
//     /// @dev Reverts if `newCreditConfigurator` is incompatible with credit manager
//     function upgradeCreditConfigurator(address newCreditConfigurator) external override configuratorOnly {
//         if (newCreditConfigurator == address(this)) return;

//         _revertIfContractIncompatible(newCreditConfigurator); // I:[CC-20]

//         address[] memory newAllowedAdapters = CreditConfiguratorV3(newCreditConfigurator).allowedAdapters();
//         uint256 num = newAllowedAdapters.length;
//         if (num != allowedAdaptersSet.length()) revert IncorrectAdaptersSetException();
//         unchecked {
//             for (uint256 i; i < num; ++i) {
//                 if (!allowedAdaptersSet.contains(newAllowedAdapters[i])) revert IncorrectAdaptersSetException();
//             }
//         }

//         CreditManagerV3(creditManager).setCreditConfigurator(newCreditConfigurator);
//         emit CreditConfiguratorUpgraded(newCreditConfigurator);
//     }

//     // ------------- //
//     // CREDIT FACADE //
//     // ------------- //

//     /// @notice Sets the new min and max debt limits in the credit facade
//     /// @param newMinDebt New minimum debt per credit account
//     /// @param newMaxDebt New maximum debt per credit account
//     /// @dev Reverts if `newMinDebt` is greater than `newMaxDebt`
//     /// @dev Reverts if `newMaxDebt / newMinDebt` is above the safety threhsold of `100 / maxEnabledTokens`
//     /// @dev Reverts if USD value of `minDebt` is zero according to the current price oracle
//     function setDebtLimits(uint128 newMinDebt, uint128 newMaxDebt)
//         external
//         override
//         configuratorOnly // I:[CC-2]

//     {
//         _setLimits(newMinDebt, newMaxDebt);
//     }

//     /// @dev `set{Min|Max}DebtLimit` implementation
//     function _setLimits(uint128 minDebt, uint128 maxDebt) internal {
//         if (minDebt > maxDebt) {
//             revert IncorrectLimitsException();
//         }
//         if (maxDebt * CreditManagerV3(creditManager).maxEnabledTokens() > minDebt * 100) {
//             revert IncorrectLimitsException();
//         }

//         CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

//         (uint128 currentMinDebt, uint128 currentMaxDebt) = cf.debtLimits();
//         if (currentMinDebt == minDebt && currentMaxDebt == maxDebt) return;

//         cf.setDebtLimits(minDebt, maxDebt);
//         emit SetBorrowingLimits(minDebt, maxDebt);
//     }

//     /// @notice Sets the new loss policy which control which lossy liquidations should be allowed
//     /// @param newLossPolicy New loss policy, must be a contract
//     function setLossPolicy(address newLossPolicy)
//         external
//         override
//         configuratorOnly // I:[CC-2]
//         nonZeroAddress(newLossPolicy) // I:[CC-26]

//     {
//         if (!newLossPolicy.isContract()) revert AddressIsNotContractException(newLossPolicy); // I:[CC-26]

//         CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

//         if (cf.lossPolicy() == newLossPolicy) return;

//         cf.setLossPolicy(newLossPolicy); // I:[CC-26]
//         emit SetLossPolicy(newLossPolicy); // I:[CC-26]
//     }

//     // --------- //
//     // INTERNALS //
//     // --------- //

//     /// @dev Internal wrapper for `creditManager.revertIfNotAllowedCollateral` call to reduce contract size
//     function _revertIfNotAllowedCollateral(address token) internal view {
//         CreditManagerV3(creditManager).revertIfNotAllowedCollateral(token);
//     }

//     /// @dev Ensures that contract is compatible with credit manager by checking that it implements
//     ///      the `creditManager()` function that returns the correct address
//     function _revertIfContractIncompatible(address _contract)
//         internal
//         view
//         nonZeroAddress(_contract) // I:[CC-12,29]

//     {
//         if (!_contract.isContract()) {
//             revert AddressIsNotContractException(_contract); // I:[CC-12A,29]
//         }

//         // any interface with `creditManager()` would work instead of `CreditFacadeV3` here
//         try CreditFacadeV3(_contract).creditManager() returns (address cm) {
//             if (cm != creditManager) revert IncompatibleContractException(); // I:[CC-12B,29]
//         } catch {
//             revert IncompatibleContractException(); // I:[CC-12B,29]
//         }
//     }

//     /// @dev Reverts if `token` is underlying
//     function _revertIfUnderlyingToken(address token) internal view {
//         if (token == underlying) revert TokenNotAllowedException();
//     }
// }
