/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import { Signer, utils, Contract, ContractFactory, Overrides } from "ethers";
import type { Provider, TransactionRequest } from "@ethersproject/providers";
import type { PromiseOrValue } from "../common";
import type { Claimable, ClaimableInterface } from "../Claimable";

const _abi = [
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "previousOwner",
        type: "address",
      },
      {
        indexed: true,
        internalType: "address",
        name: "newOwner",
        type: "address",
      },
    ],
    name: "OwnershipTransferred",
    type: "event",
  },
  {
    inputs: [],
    name: "claimOwnership",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "owner",
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
    name: "pendingOwner",
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
    name: "renounceOwnership",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "newOwner",
        type: "address",
      },
    ],
    name: "transferOwnership",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

const _bytecode =
  "0x608060405234801561001057600080fd5b5061001a3361001f565b61006f565b600080546001600160a01b038381166001600160a01b0319831681178455604051919092169283917f8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e09190a35050565b61045b8061007e6000396000f3fe608060405234801561001057600080fd5b50600436106100675760003560e01c80638da5cb5b116100505780638da5cb5b1461007e578063e30c3978146100c1578063f2fde38b146100e157600080fd5b80634e71e0c81461006c578063715018a614610076575b600080fd5b6100746100f4565b005b6100746101ec565b60005473ffffffffffffffffffffffffffffffffffffffff165b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200160405180910390f35b6001546100989073ffffffffffffffffffffffffffffffffffffffff1681565b6100746100ef3660046103e8565b610200565b60015473ffffffffffffffffffffffffffffffffffffffff1633146101a0576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152602660248201527f436c61696d61626c653a2053656e646572206973206e6f742070656e64696e6760448201527f206f776e6572000000000000000000000000000000000000000000000000000060648201526084015b60405180910390fd5b6001546101c29073ffffffffffffffffffffffffffffffffffffffff166102f2565b600180547fffffffffffffffffffffffff0000000000000000000000000000000000000000169055565b6101f4610367565b6101fe60006102f2565b565b610208610367565b73ffffffffffffffffffffffffffffffffffffffff81166102ab576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152602860248201527f436c61696d61626c653a206e6577206f776e657220697320746865207a65726f60448201527f20616464726573730000000000000000000000000000000000000000000000006064820152608401610197565b600180547fffffffffffffffffffffffff00000000000000000000000000000000000000001673ffffffffffffffffffffffffffffffffffffffff92909216919091179055565b6000805473ffffffffffffffffffffffffffffffffffffffff8381167fffffffffffffffffffffffff0000000000000000000000000000000000000000831681178455604051919092169283917f8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e09190a35050565b60005473ffffffffffffffffffffffffffffffffffffffff1633146101fe576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820181905260248201527f4f776e61626c653a2063616c6c6572206973206e6f7420746865206f776e65726044820152606401610197565b6000602082840312156103fa57600080fd5b813573ffffffffffffffffffffffffffffffffffffffff8116811461041e57600080fd5b939250505056fea2646970667358221220b91af5a4fddc08f73feed58e7a4fdf337de6112851f5255dee5141776e8ef25f64736f6c63430008110033";

type ClaimableConstructorParams =
  | [signer?: Signer]
  | ConstructorParameters<typeof ContractFactory>;

const isSuperArgs = (
  xs: ClaimableConstructorParams
): xs is ConstructorParameters<typeof ContractFactory> => xs.length > 1;

export class Claimable__factory extends ContractFactory {
  constructor(...args: ClaimableConstructorParams) {
    if (isSuperArgs(args)) {
      super(...args);
    } else {
      super(_abi, _bytecode, args[0]);
    }
    this.contractName = "Claimable";
  }

  override deploy(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<Claimable> {
    return super.deploy(overrides || {}) as Promise<Claimable>;
  }
  override getDeployTransaction(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): TransactionRequest {
    return super.getDeployTransaction(overrides || {});
  }
  override attach(address: string): Claimable {
    return super.attach(address) as Claimable;
  }
  override connect(signer: Signer): Claimable__factory {
    return super.connect(signer) as Claimable__factory;
  }
  static readonly contractName: "Claimable";

  public readonly contractName: "Claimable";

  static readonly bytecode = _bytecode;
  static readonly abi = _abi;
  static createInterface(): ClaimableInterface {
    return new utils.Interface(_abi) as ClaimableInterface;
  }
  static connect(
    address: string,
    signerOrProvider: Signer | Provider
  ): Claimable {
    return new Contract(address, _abi, signerOrProvider) as Claimable;
  }
}