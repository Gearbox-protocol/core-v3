// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {PriceOracleFactoryV3} from "../factories/PriceOracleFactoryV3.sol";
import {InterestModelFactory} from "../factories/InterestModelFactory.sol";
import {PoolFactoryV3} from "../factories/PoolFactoryV3.sol";
import {CreditFactoryV3} from "../factories/CreditFactoryV3.sol";
import {AdapterFactoryV3} from "../factories/AdapterFactoryV3.sol";

import {IPriceOracleV3} from "../interfaces/IPriceOracleV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {ICreditConfiguratorV3} from "../interfaces/ICreditConfiguratorV3.sol";
import {IContractsRegister} from "@gearbox-protocol/core-v2/contracts/interfaces/IContractsRegister.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";

contract RiskConfigurator is Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;

    error InterestModelNotAllowedException(address);

    error PriceFeedIsNotAllowedException(address, address);

    event SetPriceFeedFromStore(address indexed token, address indexed priceFeed, bool trusted);

    event SetReservePriceFeedFromStore(address indexed token, address indexed priceFeedd);

    string public name;

    EnumerableSet.AddressSet internal _pools;
    EnumerableSet.AddressSet internal _creditManagers;
    EnumerableSet.AddressSet internal _adapters;

    // Mapping: market -> priceOracle
    mapping(address => address) public priceOracles;

    address acl;
    address interestModelFactory;
    address poolFactory;
    address creditFactory;
    address priceOracleFactory;
    address adapterFactory;
    address controller;

    function createMarket(address underlying, uint256 totalLimit, address interestModel, uint8 rateKeeperType)
        external
        onlyOwner
    {
        if (InterestModelFactory(interestModelFactory).isRegisteredInterestModel(interestModel)) {
            revert InterestModelNotAllowedException(interestModel);
        }
        address newPool = PoolFactoryV3(poolFactory).deploy(underlying, totalLimit, rateKeeperType);

        _pools.add(newPool);
        priceOracles[newPool] = PriceOracleFactoryV3(priceOracleFactory).deployPriceOracle();
    }

    function deployCreditManager(address pool) external onlyOwner {
        address newCreditManager = CreditFactoryV3(creditFactory).deploy(pool);
        _creditManagers.add(newCreditManager);
    }

    function setPriceFeedFromStore(address pool, address token, address priceFeed, bool trusted) external onlyOwner {
        // Check that pool exists
        if (!PriceOracleFactoryV3(priceOracleFactory).isRegisteredOracle(token, priceFeed)) {
            revert PriceFeedIsNotAllowedException(token, priceFeed);
        }

        IPriceOracleV3(priceOracles[pool]).setPriceFeed(
            token, priceFeed, PriceOracleFactoryV3(priceOracleFactory).stalenessPeriod(priceFeed), trusted
        );

        emit SetPriceFeedFromStore(token, priceFeed, trusted);
    }

    function setReservePriceFeedFromStore(address pool, address token, address priceFeed) external onlyOwner {
        // Check that pool exists
        if (!PriceOracleFactoryV3(priceOracleFactory).isRegisteredOracle(token, priceFeed)) {
            revert PriceFeedIsNotAllowedException(token, priceFeed);
        }

        IPriceOracleV3(priceOracles[pool]).setReservePriceFeed(
            token, priceFeed, PriceOracleFactoryV3(priceOracleFactory).stalenessPeriod(priceFeed)
        );

        emit SetReservePriceFeedFromStore(token, priceFeed);
    }

    function updateCreditFacade(uint256 version, address creditManager) external onlyOwner {
        // Check that credit manager is reristered
        ICreditConfiguratorV3 creditConfigurator = _creditConfigurator(creditManager);
        address newCreditFacade = CreditFactoryV3(creditFactory).deployCreditFacade(creditManager, version);
        creditConfigurator.setCreditFacade(newCreditFacade, true);
    }

    function updateCreditConfigurator(uint256 version, address creditManager) external onlyOwner {
        // Check that credit manager is reristered
        ICreditConfiguratorV3 creditConfigurator = _creditConfigurator(creditManager);
        address newCreditConfigurator = CreditFactoryV3(creditFactory).upgradeCreditConfigurator(creditManager, version);
        creditConfigurator.upgradeCreditConfigurator(newCreditConfigurator);
    }

    function changePriceOracle(
        address pool,
        uint256 version // , PriceUpdates[] calldata priceUpdates)
    ) external onlyOwner {
        // Check that prices for all tokens exists

        address oldOracle = priceOracles[pool];
        address newPriceOracle = PriceOracleFactoryV3(priceOracleFactory).deployPriceOracle(version);
        address[] memory collateralTokens = IPoolQuotaKeeperV3(IPoolV3(pool).poolQuotaKeeper()).quotedTokens();

        uint256 len = collateralTokens.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                address token = collateralTokens[i];
                try IPriceOracleV3(oldOracle).priceFeedsRaw(token, false) returns (address pf) {
                    IPriceOracleV3(newPriceOracle).setPriceFeed(token, pf, 0, false);
                } catch {}

                try IPriceOracleV3(oldOracle).priceFeedsRaw(token, true) returns (address pf) {
                    IPriceOracleV3(newPriceOracle).setReservePriceFeed(token, pf, 0);
                } catch {}
            }
        }

        address[] memory cms = IPoolV3(pool).creditManagers();
        len = cms.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                // _creditConfigurator(cms[i]).setPriceOracle(newPriceOracle);
            }
        }
    }

    /// @dev Adds new adapter from factory to credit manager
    function addAdapter(address creditManager, address target, uint256 _version, bytes calldata specificParams)
        external
        onlyOwner
    {
        address newAdapter =
            AdapterFactoryV3(adapterFactory).deployAdapter(creditManager, target, _version, specificParams);
        _adapters.add(newAdapter);
    }

    /// @dev Returns the array of registered pools
    function pools() external view returns (address[] memory) {
        return _pools.values();
    }

    /// @dev Returns true if the passed address is a pool
    function isPool(address pool) external view returns (bool) {
        return _pools.contains(pool);
    }

    //
    // CREDIT MANAGERS
    //

    /// @dev Returns the array of registered Credit Managers
    function creditManagers() external view returns (address[] memory) {
        return _creditManagers.values();
    }

    /// @dev Returns true if the passed address is a Credit Manager
    function isCreditManager(address creditManager) external view returns (bool) {
        return _creditManagers.contains(creditManager);
    }

    // Internal functions
    function _creditConfigurator(address creditManager) internal view returns (ICreditConfiguratorV3) {
        return ICreditConfiguratorV3(ICreditManagerV3(creditManager).creditConfigurator());
    }
}
