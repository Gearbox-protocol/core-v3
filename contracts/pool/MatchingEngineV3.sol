// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {LibString} from "@solady/utils/LibString.sol";

// INTERFACES
import {ICreditManagerV3, CollateralTokenData} from "../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, AccountOpeningParams} from "../interfaces/ICreditFacadeV3.sol";
import {
    IMatchingEngineV3,
    LenderOrder,
    BorrowerOrder,
    GeneralOrderParams,
    MatchParams,
    CreditAccountData
} from "../interfaces/IMatchingEngineV3.sol";
import {IValidationStrategy} from "../interfaces/base/IValidationStrategy.sol";
import {IInterestRateModel} from "../interfaces/base/IInterestRateModel.sol";

// LIBS & TRAITS
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";
import {ReentrancyGuardTrait} from "../traits/ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";
import {Balance} from "../libraries/BalancesLogic.sol";

// CONSTANTS
import {RAY, MAX_WITHDRAW_FEE, PERCENTAGE_FACTOR} from "../libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @dev Struct that holds borrowed amount and debt limit
struct DebtParams {
    uint128 borrowed;
    uint128 limit;
}

contract MatchingEngineV3 is
    EIP712,
    Pausable,
    ReentrancyGuardTrait,
    SanityCheckTrait,
    ACLTrait,
    ContractsRegisterTrait,
    IMatchingEngineV3
{
    using Math for uint256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using CreditLogic for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using LibString for bytes32;
    using LibString for uint256;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    bytes32 public constant override contractType = "MATCHING_ENGINE";

    bytes32 private constant GENERAL_ORDER_TYPEHASH = keccak256(
        "GeneralOrderParams(address creditManager,address priceOracle,address interestRateModel,uint40 minDuration,uint40 maxDuration,uint256 nonce,uint40 expiry,address validationStrategy)"
    );

    bytes32 private constant BORROWER_ORDER_TYPEHASH = keccak256(
        "BorrowerOrder(GeneralOrderParams generalParams,address borrower,bytes32 rateParamsHash,uint256 principal,bytes32 collateralTokensHash,bytes32 collateralLTsHash,bytes32 initialCollateralsHash,bytes32 openingCallsHash)"
    );

    bytes32 private constant LENDER_ORDER_TYPEHASH = keccak256(
        "LenderOrder(GeneralOrderParams generalParams,address lender,bytes32 rateParamsHash,uint256 maxPrincipal,bytes32 collateralTokensHash,bytes32 collateralLTsHash,address fundingVault)"
    );

    /// @notice Protocol treasury address
    address public immutable override treasury;

    mapping(address => CreditAccountData) public caData;

    mapping(bytes32 => uint256) internal _alreadyFilled;

    mapping(bytes32 => bool) internal _cancelled;

    mapping(address => uint256) internal _minNonce;

    /// @dev List of all connected credit managers
    EnumerableSet.AddressSet internal _creditManagerSet;

    modifier matcherOnly() {
        if (!_hasRole("MATCHER", msg.sender)) revert IncorrectParameterException();
        _;
    }

    constructor(address acl_, address contractsRegister_, address treasury_, string memory name_)
        ACLTrait(acl_)
        ContractsRegisterTrait(contractsRegister_)
        EIP712(contractType.fromSmallString(), version.toString())
        nonZeroAddress(treasury_)
    {
        if (bytes(name_).length == 0) {
            revert IncorrectParameterException();
        }

        treasury = treasury_;
    }

    // ------- //
    // GETTERS //
    // ------- //

    function alreadyFilled(bytes32 orderHash) external view override returns (uint256) {
        return _alreadyFilled[orderHash];
    }

    function isCancelled(bytes32 orderHash) external view override returns (bool) {
        return _cancelled[orderHash];
    }

    function getGeneralOrderHash(GeneralOrderParams calldata order) public view override returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                GENERAL_ORDER_TYPEHASH,
                order.creditManager,
                order.priceOracle,
                order.interestRateModel,
                order.minDuration,
                order.maxDuration,
                order.nonce,
                order.expiry,
                order.validationStrategy
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getLenderOrderHash(LenderOrder calldata order) public view override returns (bytes32) {
        bytes32 generalOrderHash = getGeneralOrderHash(order.generalParams);
        bytes32 rateParamsHash = keccak256(order.minRateParams);
        bytes32 tokensHash = keccak256(abi.encode(order.permittedCollaterals));
        bytes32 ltsHash = keccak256(abi.encode(order.collateralLTs));

        bytes32 structHash = keccak256(
            abi.encode(
                LENDER_ORDER_TYPEHASH,
                generalOrderHash,
                order.lender,
                rateParamsHash,
                order.maxPrincipal,
                tokensHash,
                ltsHash,
                order.fundingVault
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getBorrowerOrderHash(BorrowerOrder calldata order) public view override returns (bytes32) {
        bytes32 rateParamsHash = keccak256(order.maxRateParams);
        bytes32 tokensHash = keccak256(abi.encode(order.requiredCollaterals));
        bytes32 ltsHash = keccak256(abi.encode(order.collateralLTs));
        bytes32 initialCollateralsHash = keccak256(abi.encode(order.initialCollaterals));
        bytes32 openingCallsHash = keccak256(abi.encode(order.openingCalls));

        bytes32 generalOrderHash = getGeneralOrderHash(order.generalParams);

        bytes32 structHash = keccak256(
            abi.encode(
                BORROWER_ORDER_TYPEHASH,
                generalOrderHash,
                order.borrower,
                rateParamsHash,
                order.principal,
                tokensHash,
                ltsHash,
                initialCollateralsHash,
                openingCallsHash
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /// @notice Addresses of all connected credit managers
    function creditManagers() external view override returns (address[] memory) {
        return _creditManagerSet.values();
    }

    // -------- //
    // MATCHING //
    // -------- //

    function matchOrders(
        LenderOrder calldata lender,
        BorrowerOrder calldata borrower,
        bytes calldata lenderSig,
        bytes calldata borrowerSig,
        MatchParams calldata params
    ) external override matcherOnly nonReentrant returns (address creditAccount) {
        bytes32 lenderHash = _validateOrderMatch(lender, borrower, lenderSig, borrowerSig, params);

        _alreadyFilled[lenderHash] += params.principal;
        _minNonce[lender.lender] = lender.generalParams.nonce + 1;
        _minNonce[borrower.borrower] = borrower.generalParams.nonce + 1;

        _drawInitialCollaterals(borrower.borrower, borrower.initialCollaterals);

        uint40 maturity = uint40(block.timestamp + params.duration);

        {

            CollateralTokenData[] memory collateralTokens =
                new CollateralTokenData[](borrower.requiredCollaterals.length);
            for (uint256 i; i < collateralTokens.length; ++i) {
                collateralTokens[i] =
                    CollateralTokenData({token: borrower.requiredCollaterals[i], lt: borrower.collateralLTs[i]});
            }

            AccountOpeningParams memory accountOpeningParams = AccountOpeningParams({
                onBehalfOf: borrower.borrower,
                interestRateModel: borrower.generalParams.interestRateModel,
                priceOracle: borrower.generalParams.priceOracle,
                debt: params.principal,
                maturityTimestamp: maturity,
                interestRateParams: borrower.maxRateParams,
                collateralTokens: collateralTokens,
                inititalCollaterals: borrower.initialCollaterals,
                calls: borrower.openingCalls
            });

            address creditFacade = ICreditManagerV3(borrower.generalParams.creditManager).creditFacade();
            creditAccount = ICreditFacadeV3(creditFacade).openCreditAccount(accountOpeningParams);
        }

        caData[creditAccount] = CreditAccountData({
            lender: lender.lender,
            borrower: borrower.borrower,
            creditManager: borrower.generalParams.creditManager,
            lenderFundingVault: lender.fundingVault
        });

        emit OrderMatched(
            creditAccount,
            lender.lender,
            borrower.borrower,
            params.principal,
            maturity,
            borrower.generalParams.interestRateModel,
            borrower.generalParams.priceOracle
        );
    }

    // TODO: implement cancels?

    // function cancelOrder(bytes32 orderHash) external override {
    //     _cancelled[orderHash] = true;
    //     emit OrderCancelled(orderHash, msg.sender);
    // }

    // --------------- //
    // ACCOUNT ACTIONS //
    // --------------- //

    function forceCloseCreditAccount(address creditAccount) external override {
        if (msg.sender != caData[creditAccount].lender) revert CallerNotLenderException();

        address creditFacade = ICreditManagerV3(caData[creditAccount].creditManager).creditFacade();

        ICreditFacadeV3(creditFacade).forceClosure(creditAccount);
    }

    function sellCreditAccount(address creditAccount) external override {}

    // ---------------- //
    // ORDER VALIDATION //
    // ---------------- //

    function _validateOrderMatch(
        LenderOrder calldata lender,
        BorrowerOrder calldata borrower,
        bytes calldata lenderSig,
        bytes calldata borrowerSig,
        MatchParams calldata params
    ) internal view returns (bytes32 lenderHash) {
        if (
            lender.lender == address(0) || lender.generalParams.creditManager == address(0)
                || lender.generalParams.interestRateModel == address(0)
        ) {
            revert ZeroAddressException();
        }

        if (
            borrower.borrower == address(0) || borrower.generalParams.creditManager == address(0)
                || borrower.generalParams.interestRateModel == address(0)
        ) {
            revert ZeroAddressException();
        }

        if (lender.generalParams.creditManager != borrower.generalParams.creditManager) {
            revert IncorrectParameterException();
        }

        if (lender.generalParams.interestRateModel != borrower.generalParams.interestRateModel) {
            revert IncorrectParameterException();
        }
        if (params.principal != borrower.principal) revert IncorrectParameterException();

        _validateNonce(lender.lender, lender.generalParams.nonce);
        _validateNonce(borrower.borrower, borrower.generalParams.nonce);

        _validateExpiry(lender.generalParams.expiry);
        _validateExpiry(borrower.generalParams.expiry);

        _validateDuration(
            lender.generalParams.minDuration,
            lender.generalParams.maxDuration,
            borrower.generalParams.minDuration,
            borrower.generalParams.maxDuration,
            params.duration
        );

        if (!IInterestRateModel(lender.generalParams.interestRateModel)
                .isGreaterRate(lender.minRateParams, borrower.maxRateParams)) {
            revert IncorrectParameterException();
        }

        _validateCollaterals(
            lender.generalParams.creditManager,
            lender.permittedCollaterals,
            lender.collateralLTs,
            borrower.requiredCollaterals,
            borrower.collateralLTs
        );

        lenderHash = getLenderOrderHash(lender);
        bytes32 borrowerHash = getBorrowerOrderHash(borrower);

        if (_cancelled[lenderHash] || _cancelled[borrowerHash]) revert IncorrectParameterException();
        _verifySignature(lender.lender, lenderHash, lenderSig);
        _verifySignature(borrower.borrower, borrowerHash, borrowerSig);

        uint256 filled = _alreadyFilled[lenderHash];
        if (filled + params.principal > lender.maxPrincipal) revert IncorrectParameterException();

        _validateEligibility(lender.generalParams.validationStrategy, lender, borrower);
        _validateEligibility(borrower.generalParams.validationStrategy, lender, borrower);
    }

    // TODO: maybe enforce collateral sorting to avoid mishaps

    function _validateCollaterals(
        address creditManager,
        address[] calldata lenderTokens,
        uint16[] calldata lenderLts,
        address[] calldata borrowerTokens,
        uint16[] calldata borrowerLts
    ) internal view {
        uint16 ltUnderlying = ICreditManagerV3(creditManager).ltUnderlying();
        uint256 len = lenderTokens.length;
        if (len != borrowerTokens.length || len != lenderLts.length || len != borrowerLts.length) {
            revert IncorrectParameterException();
        }
        for (uint256 i; i < len; ++i) {
            if (lenderTokens[i] != borrowerTokens[i] || lenderLts[i] < borrowerLts[i] || borrowerLts[i] > ltUnderlying)
            {
                revert IncorrectParameterException();
            }
        }
    }

    function _verifySignature(address signer, bytes32 digest, bytes calldata signature) internal pure {
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != signer) revert IncorrectParameterException();
    }

    function _validateNonce(address signer, uint256 nonce) internal view {
        if (nonce < _minNonce[signer]) revert IncorrectParameterException();
    }

    function _validateExpiry(uint40 expiry) internal view {
        if (expiry != 0 && block.timestamp > expiry) revert IncorrectParameterException();
    }

    function _validateDuration(uint40 minA, uint40 maxA, uint40 minB, uint40 maxB, uint40 duration) internal pure {
        if (duration <= minA || duration >= maxA || duration <= minB || duration >= maxB) {
            revert IncorrectParameterException();
        }
    }

    function _validateEligibility(address strategy, LenderOrder calldata lender, BorrowerOrder calldata borrower)
        internal
        view
    {
        if (strategy == address(0)) return;
        if (!IValidationStrategy(strategy).validate(lender, borrower)) {
            revert IncorrectParameterException();
        }
    }

    /// -------------- ///
    /// BORROW / REPAY ///
    /// -------------- ///

    /// @notice Lends funds to a credit account, can only be called by credit managers
    /// @param borrowedAmount Amount to borrow
    /// @param creditAccount Credit account to send the funds to
    function lendCreditAccount(uint256 borrowedAmount, address creditAccount) external override nonReentrant {
        if (!_creditManagerSet.contains(msg.sender)) {
            revert CallerNotCreditManagerException();
        }

        address creditManager = caData[creditAccount].creditManager;
        address underlying = ICreditManagerV3(creditManager).underlying();

        address fundingVault = caData[creditAccount].lenderFundingVault;
        address lender = caData[creditAccount].lender;

        if (fundingVault == address(0)) {
            IERC20(underlying).safeTransferFrom(lender, creditAccount, borrowedAmount);
        } else {
            IERC4626(fundingVault).withdraw(borrowedAmount, creditAccount, lender);
        }

        emit Borrow(creditManager, creditAccount, borrowedAmount);
    }

    function repayCreditAccount(address creditAccount, uint256 repaidAmount, uint256 profit, uint256 loss)
        external
        override
        nonReentrant
    {
        if (!_creditManagerSet.contains(msg.sender)) {
            revert CallerNotCreditManagerException();
        }

        address creditManager = msg.sender;
        address lender = caData[creditAccount].lender;
        address underlying = ICreditManagerV3(creditManager).underlying();

        if (profit > 0) {
            IERC20(underlying).safeTransfer(treasury, profit);
        } else if (loss > 0) {
            address treasury_ = treasury;
            /// TODO: maybe approval instead of balance?
            uint256 recoverableAssets = IERC20(underlying).balanceOf(treasury_);

            if (recoverableAssets < loss) {
                unchecked {
                    emit IncurUncoveredLoss({creditManager: msg.sender, loss: loss - recoverableAssets});
                }
                loss = recoverableAssets;
            }

            /// TODO: approval from treasury is probably not great, how to do better?
            IERC20(underlying).safeTransferFrom(treasury_, lender, loss);
        }

        address fundingVault = caData[creditAccount].lenderFundingVault;
        if (fundingVault == address(0)) {
            IERC20(underlying).safeTransfer(lender, repaidAmount);
        } else {
            IERC4626(fundingVault).deposit(repaidAmount, lender);
        }

        emit Repay(msg.sender, repaidAmount, profit, loss);
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setCreditManagerStatus(address creditManager, bool isAllowed)
        external
        override
        configuratorOnly
        nonZeroAddress(creditManager)
        registeredCreditManagerOnly(creditManager)
    {
        if (!_creditManagerSet.contains(creditManager) && isAllowed) {
            if (address(this) != ICreditManagerV3(creditManager).matchingEngine()) {
                revert IncompatibleCreditManagerException();
            }
            _creditManagerSet.add(creditManager);
            emit AddCreditManager(creditManager);
        } else if (_creditManagerSet.contains(creditManager) && !isAllowed) {
            _creditManagerSet.remove(creditManager);
            emit RemoveCreditManager(creditManager);
        }
    }

    /// @notice Pauses contract, can only be called by an account with pausable admin role
    /// @dev Pause only blocks deposits, withdrawals and transfers.
    ///      Borrowing and repayment can be paused on the credit side but are not blocked here
    ///      to allow emergency liquidations to proceed.
    /// @dev Reverts if contract is already paused
    function pause() external override pausableAdminsOnly {
        _pause();
    }

    /// @notice Unpauses contract, can only be called by an account with unpausable admin role
    /// @dev Reverts if contract is already unpaused
    function unpause() external override unpausableAdminsOnly {
        _unpause();
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _drawInitialCollaterals(address borrower, Balance[] calldata initialCollaterals) internal {
        for (uint256 i; i < initialCollaterals.length; ++i) {
            IERC20(initialCollaterals[i].token).safeTransferFrom(borrower, address(this), initialCollaterals[i].balance);
        }
    }

    /// @dev Returns amount of token that should be transferred to receive `amount`
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountWithFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Returns amount of token that will be received if `amount` is transferred
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountMinusFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Converts `uint128` to `uint256`, preserves maximum value
    function _convertToU256(uint128 limit) internal pure returns (uint256) {
        return (limit == type(uint128).max) ? type(uint256).max : limit;
    }

    /// @dev Converts `uint256` to `uint128`, preserves maximum value
    function _convertToU128(uint256 limit) internal pure returns (uint128) {
        return (limit == type(uint256).max) ? type(uint128).max : limit.toUint128();
    }
}
