/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import { Signer, utils, Contract, ContractFactory, Overrides } from "ethers";
import type { Provider, TransactionRequest } from "@ethersproject/providers";
import type { PromiseOrValue } from "../common";
import type {
  PriceFeedOnDemandMock,
  PriceFeedOnDemandMockInterface,
} from "../PriceFeedOnDemandMock";

const _abi = [
  {
    inputs: [
      {
        internalType: "bytes",
        name: "data",
        type: "bytes",
      },
    ],
    name: "updatePrice",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

const _bytecode =
  "0x608060405234801561001057600080fd5b5060e18061001f6000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c80638736ec4714602d575b600080fd5b603c6038366004603e565b5050565b005b60008060208385031215605057600080fd5b823567ffffffffffffffff80821115606757600080fd5b818501915085601f830112607a57600080fd5b813581811115608857600080fd5b866020828501011115609957600080fd5b6020929092019691955090935050505056fea26469706673582212200e781b2f494ea33f1f2086ee631bf198b7e107337d7c79e301612a86a167831a64736f6c63430008110033";

type PriceFeedOnDemandMockConstructorParams =
  | [signer?: Signer]
  | ConstructorParameters<typeof ContractFactory>;

const isSuperArgs = (
  xs: PriceFeedOnDemandMockConstructorParams
): xs is ConstructorParameters<typeof ContractFactory> => xs.length > 1;

export class PriceFeedOnDemandMock__factory extends ContractFactory {
  constructor(...args: PriceFeedOnDemandMockConstructorParams) {
    if (isSuperArgs(args)) {
      super(...args);
    } else {
      super(_abi, _bytecode, args[0]);
    }
    this.contractName = "PriceFeedOnDemandMock";
  }

  override deploy(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<PriceFeedOnDemandMock> {
    return super.deploy(overrides || {}) as Promise<PriceFeedOnDemandMock>;
  }
  override getDeployTransaction(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): TransactionRequest {
    return super.getDeployTransaction(overrides || {});
  }
  override attach(address: string): PriceFeedOnDemandMock {
    return super.attach(address) as PriceFeedOnDemandMock;
  }
  override connect(signer: Signer): PriceFeedOnDemandMock__factory {
    return super.connect(signer) as PriceFeedOnDemandMock__factory;
  }
  static readonly contractName: "PriceFeedOnDemandMock";

  public readonly contractName: "PriceFeedOnDemandMock";

  static readonly bytecode = _bytecode;
  static readonly abi = _abi;
  static createInterface(): PriceFeedOnDemandMockInterface {
    return new utils.Interface(_abi) as PriceFeedOnDemandMockInterface;
  }
  static connect(
    address: string,
    signerOrProvider: Signer | Provider
  ): PriceFeedOnDemandMock {
    return new Contract(
      address,
      _abi,
      signerOrProvider
    ) as PriceFeedOnDemandMock;
  }
}