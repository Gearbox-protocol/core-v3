/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import { Signer, utils, Contract, ContractFactory, Overrides } from "ethers";
import type { Provider, TransactionRequest } from "@ethersproject/providers";
import type { PromiseOrValue } from "../common";
import type {
  GearStakingMock,
  GearStakingMockInterface,
} from "../GearStakingMock";

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
  {
    inputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    name: "allowedVotingContract",
    outputs: [
      {
        internalType: "enum VotingContractStatus",
        name: "",
        type: "uint8",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "user",
        type: "address",
      },
    ],
    name: "availableBalance",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "user",
        type: "address",
      },
    ],
    name: "balanceOf",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "to",
        type: "address",
      },
    ],
    name: "claimWithdrawals",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint96",
        name: "amount",
        type: "uint96",
      },
      {
        components: [
          {
            internalType: "address",
            name: "votingContract",
            type: "address",
          },
          {
            internalType: "uint96",
            name: "voteAmount",
            type: "uint96",
          },
          {
            internalType: "bool",
            name: "isIncrease",
            type: "bool",
          },
          {
            internalType: "bytes",
            name: "extraData",
            type: "bytes",
          },
        ],
        internalType: "struct MultiVote[]",
        name: "votes",
        type: "tuple[]",
      },
    ],
    name: "deposit",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint96",
        name: "amount",
        type: "uint96",
      },
      {
        internalType: "address",
        name: "to",
        type: "address",
      },
      {
        components: [
          {
            internalType: "address",
            name: "votingContract",
            type: "address",
          },
          {
            internalType: "uint96",
            name: "voteAmount",
            type: "uint96",
          },
          {
            internalType: "bool",
            name: "isIncrease",
            type: "bool",
          },
          {
            internalType: "bytes",
            name: "extraData",
            type: "bytes",
          },
        ],
        internalType: "struct MultiVote[]",
        name: "votes",
        type: "tuple[]",
      },
    ],
    name: "depositOnMigration",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "firstEpochTimestamp",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "gear",
    outputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "getCurrentEpoch",
    outputs: [
      {
        internalType: "uint16",
        name: "",
        type: "uint16",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "user",
        type: "address",
      },
    ],
    name: "getWithdrawableAmounts",
    outputs: [
      {
        internalType: "uint256",
        name: "withdrawableNow",
        type: "uint256",
      },
      {
        internalType: "uint256[4]",
        name: "withdrawableInEpochs",
        type: "uint256[4]",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint96",
        name: "amount",
        type: "uint96",
      },
      {
        components: [
          {
            internalType: "address",
            name: "votingContract",
            type: "address",
          },
          {
            internalType: "uint96",
            name: "voteAmount",
            type: "uint96",
          },
          {
            internalType: "bool",
            name: "isIncrease",
            type: "bool",
          },
          {
            internalType: "bytes",
            name: "extraData",
            type: "bytes",
          },
        ],
        internalType: "struct MultiVote[]",
        name: "votesBefore",
        type: "tuple[]",
      },
      {
        components: [
          {
            internalType: "address",
            name: "votingContract",
            type: "address",
          },
          {
            internalType: "uint96",
            name: "voteAmount",
            type: "uint96",
          },
          {
            internalType: "bool",
            name: "isIncrease",
            type: "bool",
          },
          {
            internalType: "bytes",
            name: "extraData",
            type: "bytes",
          },
        ],
        internalType: "struct MultiVote[]",
        name: "votesAfter",
        type: "tuple[]",
      },
    ],
    name: "migrate",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "migrator",
    outputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        components: [
          {
            internalType: "address",
            name: "votingContract",
            type: "address",
          },
          {
            internalType: "uint96",
            name: "voteAmount",
            type: "uint96",
          },
          {
            internalType: "bool",
            name: "isIncrease",
            type: "bool",
          },
          {
            internalType: "bytes",
            name: "extraData",
            type: "bytes",
          },
        ],
        internalType: "struct MultiVote[]",
        name: "votes",
        type: "tuple[]",
      },
    ],
    name: "multivote",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint16",
        name: "epoch",
        type: "uint16",
      },
    ],
    name: "setCurrentEpoch",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "newMigrator",
        type: "address",
      },
    ],
    name: "setMigrator",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "newSuccessor",
        type: "address",
      },
    ],
    name: "setSuccessor",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "votingContract",
        type: "address",
      },
      {
        internalType: "enum VotingContractStatus",
        name: "status",
        type: "uint8",
      },
    ],
    name: "setVotingContractStatus",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "successor",
    outputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "version",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint96",
        name: "amount",
        type: "uint96",
      },
      {
        internalType: "address",
        name: "to",
        type: "address",
      },
      {
        components: [
          {
            internalType: "address",
            name: "votingContract",
            type: "address",
          },
          {
            internalType: "uint96",
            name: "voteAmount",
            type: "uint96",
          },
          {
            internalType: "bool",
            name: "isIncrease",
            type: "bool",
          },
          {
            internalType: "bytes",
            name: "extraData",
            type: "bytes",
          },
        ],
        internalType: "struct MultiVote[]",
        name: "votes",
        type: "tuple[]",
      },
    ],
    name: "withdraw",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

const _bytecode =
  "0x608060405234801561001057600080fd5b5061062b806100206000396000f3fe608060405234801561001057600080fd5b506004361061016c5760003560e01c80637cdef3ed116100cd578063a7dc1a3911610081578063b97dd9e211610066578063b97dd9e214610276578063ddca6ac114610297578063f71b7618146102a557600080fd5b8063a7dc1a3914610254578063b6f151641461025b57600080fd5b80639f2fd759116100b25780639f2fd7591461021f578063a0821be31461022e578063a63cdc10146101ef57600080fd5b80637cdef3ed14610242578063930d3f171461017157600080fd5b80632ac52d08116101245780636ff968c3116101095780636ff968c31461021f57806370a082311461022e5780637cd07e471461021f57600080fd5b80632ac52d08146101ef57806354fd4d501461020357600080fd5b806319e4fec01161015557806319e4fec0146101995780631d67782f146101ac57806323cf31181461017157600080fd5b806310e5bff81461017157806313a3ac1414610184575b600080fd5b61018261017f36600461031c565b50565b005b6101826101923660046103a6565b5050505050565b6101826101a7366004610427565b505050565b6101826101ba36600461047a565b600080547fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00001661ffff92909216919091179055565b6101826101fd36600461049e565b50505050565b61020c61012c81565b6040519081526020015b60405180910390f35b60405160008152602001610216565b61020c61023c36600461031c565b50600090565b6101826102503660046104ff565b5050565b600061020c565b61026961023c36600461031c565b6040516102169190610541565b6000546102849061ffff1681565b60405161ffff9091168152602001610216565b610182610250366004610582565b6102b86102b336600461031c565b6102c6565b6040516102169291906105bd565b60006102d06102d5565b915091565b60405180608001604052806004906020820280368337509192915050565b803573ffffffffffffffffffffffffffffffffffffffff8116811461031757600080fd5b919050565b60006020828403121561032e57600080fd5b610337826102f3565b9392505050565b80356bffffffffffffffffffffffff8116811461031757600080fd5b60008083601f84011261036c57600080fd5b50813567ffffffffffffffff81111561038457600080fd5b6020830191508360208260051b850101111561039f57600080fd5b9250929050565b6000806000806000606086880312156103be57600080fd5b6103c78661033e565b9450602086013567ffffffffffffffff808211156103e457600080fd5b6103f089838a0161035a565b9096509450604088013591508082111561040957600080fd5b506104168882890161035a565b969995985093965092949392505050565b60008060006040848603121561043c57600080fd5b6104458461033e565b9250602084013567ffffffffffffffff81111561046157600080fd5b61046d8682870161035a565b9497909650939450505050565b60006020828403121561048c57600080fd5b813561ffff8116811461033757600080fd5b600080600080606085870312156104b457600080fd5b6104bd8561033e565b93506104cb602086016102f3565b9250604085013567ffffffffffffffff8111156104e757600080fd5b6104f38782880161035a565b95989497509550505050565b6000806020838503121561051257600080fd5b823567ffffffffffffffff81111561052957600080fd5b6105358582860161035a565b90969095509350505050565b602081016003831061057c577f4e487b7100000000000000000000000000000000000000000000000000000000600052602160045260246000fd5b91905290565b6000806040838503121561059557600080fd5b61059e836102f3565b91506020830135600381106105b257600080fd5b809150509250929050565b82815260a0810160208083018460005b60048110156105ea578151835291830191908301906001016105cd565b50505050939250505056fea2646970667358221220980cad724af7400577bba6c590e7925d8c2dcde96aafdf69f1b4ebf73ad2337b64736f6c63430008110033";

type GearStakingMockConstructorParams =
  | [signer?: Signer]
  | ConstructorParameters<typeof ContractFactory>;

const isSuperArgs = (
  xs: GearStakingMockConstructorParams
): xs is ConstructorParameters<typeof ContractFactory> => xs.length > 1;

export class GearStakingMock__factory extends ContractFactory {
  constructor(...args: GearStakingMockConstructorParams) {
    if (isSuperArgs(args)) {
      super(...args);
    } else {
      super(_abi, _bytecode, args[0]);
    }
    this.contractName = "GearStakingMock";
  }

  override deploy(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<GearStakingMock> {
    return super.deploy(overrides || {}) as Promise<GearStakingMock>;
  }
  override getDeployTransaction(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): TransactionRequest {
    return super.getDeployTransaction(overrides || {});
  }
  override attach(address: string): GearStakingMock {
    return super.attach(address) as GearStakingMock;
  }
  override connect(signer: Signer): GearStakingMock__factory {
    return super.connect(signer) as GearStakingMock__factory;
  }
  static readonly contractName: "GearStakingMock";

  public readonly contractName: "GearStakingMock";

  static readonly bytecode = _bytecode;
  static readonly abi = _abi;
  static createInterface(): GearStakingMockInterface {
    return new utils.Interface(_abi) as GearStakingMockInterface;
  }
  static connect(
    address: string,
    signerOrProvider: Signer | Provider
  ): GearStakingMock {
    return new Contract(address, _abi, signerOrProvider) as GearStakingMock;
  }
}