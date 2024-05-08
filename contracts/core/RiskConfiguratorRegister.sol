// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ACLTrait} from "../traits/ACLTrait.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {RiskConfigurator} from "./RiskConfigurator.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";

import {IBotListV3} from "../interfaces/IBotListV3.sol";
import {IAccountFactoryV3} from "../interfaces/IAccountFactoryV3.sol";

contract RiskConfiguratorRegister is Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;

    error RiskConfiguratorsOnlyException();
    error CantRemoveRiskConfiguratorWithExistingPoolsException();

    event AddRiskCurator(address indexed newRiskConfigurator, string name, address _vetoAdmin);

    EnumerableSet.AddressSet internal _riskConfigurators;

    address public accountFactory;
    address public botList;

    address public interestModelFactory;
    address public poolFactory;
    address public creditFactory;
    address public priceOracleFactory;
    address public adapterFactory;

    modifier riskConfiguratorsOnly() {
        if (!_riskConfigurators.contains(msg.sender)) revert RiskConfiguratorsOnlyException();
        _;
    }

    function addRiskConfigurator(
        address newRiskConfigurator,
        address _treasury,
        string calldata name,
        address _vetoAdmin
    ) external onlyOwner {
        address rc = address(new RiskConfigurator(newRiskConfigurator, _treasury, name, _vetoAdmin));
        _riskConfigurators.add(rc);
        emit AddRiskCurator(newRiskConfigurator, name, _vetoAdmin);
    }

    function removeRiskConfigurator(address rc) external onlyOwner {
        if (RiskConfigurator(rc).pools().length != 0) revert CantRemoveRiskConfiguratorWithExistingPoolsException();
        _riskConfigurators.remove(rc);
        (rc);
    }

    function setAccountFactory(address newAccountFactory) external onlyOwner {
        if (Ownable2Step(newAccountFactory).owner() != address(this)) revert("address is not owned");
        accountFactory = newAccountFactory;
    }

    function setBotList(address newBotList) external onlyOwner {
        if (Ownable2Step(newBotList).owner() != address(this)) revert("address is not owned");
        botList = newBotList;
    }

    function riskConfigurators() external view returns (address[] memory) {
        return _riskConfigurators.values();
    }

    function isRiskConfigurator(address riskCurator) external view returns (bool) {
        return _riskConfigurators.contains(riskCurator);
    }

    function registerCreditManager(address creditManager) external riskConfiguratorsOnly {
        IBotListV3(botList).approvedCreditManager(creditManager);
        IAccountFactoryV3(accountFactory).addCreditManager(creditManager);
    }
}
