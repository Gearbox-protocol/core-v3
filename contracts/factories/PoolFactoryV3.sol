// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {RiskConfigurator} from "../core/RiskConfigurator.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

contract PoolFactoryV3 is IVersion {
    using EnumerableSet for EnumerableSet.AddressSet;
    /// @notice Contract version

    uint256 public constant override version = 3_10;

    // bytecode by version
    mapping(uint256 => bytes) public poolBytecode;

    // bytecode for fee tokens
    mapping(uint256 => mapping(address => bytes)) public poolBytecodeFeeTokens;

    modifier registeredCuratorsOnly() {
        _;
    }

    function deploy(
        uint256 _version,
        address underlying,
        address interestRateModel,
        uint256 totalDebtLimit,
        string calldata name,
        string calldata symbol,
        bytes32 salt
    ) external returns (address pool) {
        address acl = RiskConfigurator(msg.sender).acl();

        bytes memory constructorParams = abi.encode(acl, underlying, interestRateModel, totalDebtLimit, name, symbol);

        bytes memory bytescode = poolBytecodeFeeTokens[version][underlying];
        if (bytescode.length == 0) {
            bytescode = poolBytecode[_version];
        }

        return Create2.deploy(0, salt, bytescode);
    }

    function deployPoolQuotaKeeper(address pool) external returns (address pqk) {}

    function deployRateKeeper(address pool, uint8 rateKeeperType) external returns (address rateKeeper) {}
}
