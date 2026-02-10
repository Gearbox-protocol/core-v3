// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./base/IVersion.sol";
import {IACLTrait} from "./base/IACLTrait.sol";
import {IContractsRegisterTrait} from "./base/IContractsRegisterTrait.sol";
import {MultiCall} from "./ICreditFacadeV3.sol";
import {Balance} from "../libraries/BalancesLogic.sol";

struct GeneralOrderParams {
    address creditManager;
    address priceOracle;
    address interestRateModel;
    uint40 minDuration;
    uint40 maxDuration;
    uint256 nonce;
    uint40 expiry;
    address validationStrategy;
}

struct LenderOrder {
    GeneralOrderParams generalParams;
    address lender;
    uint256 maxPrincipal;
    address[] permittedCollaterals;
    uint16[] collateralLTs;
    address fundingVault;
}

struct BorrowerOrder {
    GeneralOrderParams generalParams;
    address borrower;
    uint256 principal;
    address[] requiredCollaterals;
    uint16[] collateralLTs;
    Balance[] initialCollaterals;
    MultiCall[] openingCalls;
}

struct MatchParams {
    uint256 principal;
    uint40 duration;
}

struct SellerOrder {
    address seller;
    address creditAccount;
    address receiveToken;
    uint256 receiveAmount;
    uint256 nonce;
    uint40 expiry;
}

struct BuyerOrder {
    address buyer;
    address creditAccount;
    uint256 nonce;
    uint40 expiry;
    address validationStrategy;
}

struct CreditAccountData {
    address lender;
    address borrower;
    address creditManager;
    address lenderFundingVault;
    address borrowerValidationStrategy;
}

interface IMatchingEngineV3Events {
    event OrderMatched(
        address indexed creditAccount,
        address indexed lender,
        address indexed borrower,
        uint256 principal,
        uint40 maturity,
        address interestRateModel,
        address priceOracle
    );

    event AddCreditManager(address indexed creditManager);
    event RemoveCreditManager(address indexed creditManager);

    event Borrow(address indexed creditManager, address indexed creditAccount, uint256 borrowedAmount);
    event Repay(address indexed creditManager, uint256 repaidAmount, uint256 profit, uint256 loss);

    event IncurUncoveredLoss(address indexed creditManager, uint256 loss);

    event CreditAccountSold(
        address indexed creditAccount,
        address indexed seller,
        address indexed buyer,
        address receiveToken,
        uint256 receiveAmount
    );
}

interface IMatchingEngineV3 is IVersion, IACLTrait, IContractsRegisterTrait, IMatchingEngineV3Events {
    function treasury() external view returns (address);

    function matchCreditOrders(
        LenderOrder calldata lender,
        BorrowerOrder calldata borrower,
        bytes calldata lenderSig,
        bytes calldata borrowerSig,
        MatchParams calldata params
    ) external returns (address creditAccount);

    function matchSellOrders(
        SellerOrder calldata sellerOrder,
        BuyerOrder calldata buyerOrder,
        bytes calldata sellerSig,
        bytes calldata buyerSig
    ) external;

    function sellCreditAccount(address creditAccount) external;

    function lendCreditAccount(uint256 borrowedAmount, address creditAccount) external;

    function repayCreditAccount(address creditAccount, uint256 repaidAmount, uint256 profit, uint256 loss) external;

    function forceCloseCreditAccount(address creditAccount) external;

    function creditManagers() external view returns (address[] memory);

    function getGeneralOrderHash(GeneralOrderParams calldata order) external view returns (bytes32);

    function getBorrowerOrderHash(BorrowerOrder calldata borrower) external view returns (bytes32);

    function getLenderOrderHash(LenderOrder calldata lender) external view returns (bytes32);

    function getSellerOrderHash(SellerOrder calldata sellerOrder) external view returns (bytes32);

    function getBuyerOrderHash(BuyerOrder calldata buyerOrder) external view returns (bytes32);

    function isCancelled(bytes32 orderHash) external view returns (bool);

    function alreadyFilled(bytes32 orderHash) external view returns (uint256);

    function pause() external;

    function unpause() external;

    function setCreditManagerStatus(address creditManager, bool isAllowed) external;
}
