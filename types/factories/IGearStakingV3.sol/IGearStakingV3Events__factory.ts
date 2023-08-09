/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */

import { Contract, Signer, utils } from "ethers";
import type { Provider } from "@ethersproject/providers";
import type {
  IGearStakingV3Events,
  IGearStakingV3EventsInterface,
} from "../../IGearStakingV3.sol/IGearStakingV3Events";

const _abi = [
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "user",
        type: "address",
      },
      {
        indexed: false,
        internalType: "address",
        name: "to",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "amount",
        type: "uint256",
      },
    ],
    name: "ClaimGearWithdrawal",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "user",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "amount",
        type: "uint256",
      },
    ],
    name: "DepositGear",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "user",
        type: "address",
      },
      {
        indexed: true,
        internalType: "address",
        name: "successor",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "amount",
        type: "uint256",
      },
    ],
    name: "MigrateGear",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "user",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "amount",
        type: "uint256",
      },
    ],
    name: "ScheduleGearWithdrawal",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "migrator",
        type: "address",
      },
    ],
    name: "SetMigrator",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "successor",
        type: "address",
      },
    ],
    name: "SetSuccessor",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "votingContract",
        type: "address",
      },
      {
        indexed: false,
        internalType: "enum VotingContractStatus",
        name: "status",
        type: "uint8",
      },
    ],
    name: "SetVotingContractStatus",
    type: "event",
  },
] as const;

export class IGearStakingV3Events__factory {
  static readonly abi = _abi;
  static createInterface(): IGearStakingV3EventsInterface {
    return new utils.Interface(_abi) as IGearStakingV3EventsInterface;
  }
  static connect(
    address: string,
    signerOrProvider: Signer | Provider
  ): IGearStakingV3Events {
    return new Contract(
      address,
      _abi,
      signerOrProvider
    ) as IGearStakingV3Events;
  }
}