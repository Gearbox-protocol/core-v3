/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import type {
  BaseContract,
  BigNumber,
  BigNumberish,
  BytesLike,
  CallOverrides,
  ContractTransaction,
  Overrides,
  PopulatedTransaction,
  Signer,
  utils,
} from "ethers";
import type {
  FunctionFragment,
  Result,
  EventFragment,
} from "@ethersproject/abi";
import type { Listener, Provider } from "@ethersproject/providers";
import type {
  TypedEventFilter,
  TypedEvent,
  TypedListener,
  OnEvent,
  PromiseOrValue,
} from "./common";

export type FactoryParamsStruct = {
  masterCreditAccount: PromiseOrValue<string>;
  head: PromiseOrValue<BigNumberish>;
  tail: PromiseOrValue<BigNumberish>;
};

export type FactoryParamsStructOutput = [string, number, number] & {
  masterCreditAccount: string;
  head: number;
  tail: number;
};

export type QueuedAccountStruct = {
  creditAccount: PromiseOrValue<string>;
  reusableAfter: PromiseOrValue<BigNumberish>;
};

export type QueuedAccountStructOutput = [string, number] & {
  creditAccount: string;
  reusableAfter: number;
};

export interface AccountFactoryV3HarnessInterface extends utils.Interface {
  functions: {
    "acl()": FunctionFragment;
    "addCreditManager(address)": FunctionFragment;
    "contractsRegister()": FunctionFragment;
    "delay()": FunctionFragment;
    "factoryParams(address)": FunctionFragment;
    "queuedAccounts(address,uint256)": FunctionFragment;
    "rescue(address,address,bytes)": FunctionFragment;
    "returnCreditAccount(address)": FunctionFragment;
    "setFactoryParams(address,address,uint40,uint40)": FunctionFragment;
    "setQueuedAccount(address,uint256,address,uint40)": FunctionFragment;
    "takeCreditAccount(uint256,uint256)": FunctionFragment;
    "version()": FunctionFragment;
  };

  getFunction(
    nameOrSignatureOrTopic:
      | "acl"
      | "addCreditManager"
      | "contractsRegister"
      | "delay"
      | "factoryParams"
      | "queuedAccounts"
      | "rescue"
      | "returnCreditAccount"
      | "setFactoryParams"
      | "setQueuedAccount"
      | "takeCreditAccount"
      | "version"
  ): FunctionFragment;

  encodeFunctionData(functionFragment: "acl", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "addCreditManager",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "contractsRegister",
    values?: undefined
  ): string;
  encodeFunctionData(functionFragment: "delay", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "factoryParams",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "queuedAccounts",
    values: [PromiseOrValue<string>, PromiseOrValue<BigNumberish>]
  ): string;
  encodeFunctionData(
    functionFragment: "rescue",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<string>,
      PromiseOrValue<BytesLike>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "returnCreditAccount",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "setFactoryParams",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<string>,
      PromiseOrValue<BigNumberish>,
      PromiseOrValue<BigNumberish>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "setQueuedAccount",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<BigNumberish>,
      PromiseOrValue<string>,
      PromiseOrValue<BigNumberish>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "takeCreditAccount",
    values: [PromiseOrValue<BigNumberish>, PromiseOrValue<BigNumberish>]
  ): string;
  encodeFunctionData(functionFragment: "version", values?: undefined): string;

  decodeFunctionResult(functionFragment: "acl", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "addCreditManager",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "contractsRegister",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "delay", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "factoryParams",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "queuedAccounts",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "rescue", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "returnCreditAccount",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "setFactoryParams",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "setQueuedAccount",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "takeCreditAccount",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "version", data: BytesLike): Result;

  events: {
    "AddCreditManager(address,address)": EventFragment;
    "DeployCreditAccount(address,address)": EventFragment;
    "ReturnCreditAccount(address,address)": EventFragment;
    "TakeCreditAccount(address,address)": EventFragment;
  };

  getEvent(nameOrSignatureOrTopic: "AddCreditManager"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "DeployCreditAccount"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "ReturnCreditAccount"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "TakeCreditAccount"): EventFragment;
}

export interface AddCreditManagerEventObject {
  creditManager: string;
  masterCreditAccount: string;
}
export type AddCreditManagerEvent = TypedEvent<
  [string, string],
  AddCreditManagerEventObject
>;

export type AddCreditManagerEventFilter =
  TypedEventFilter<AddCreditManagerEvent>;

export interface DeployCreditAccountEventObject {
  creditAccount: string;
  creditManager: string;
}
export type DeployCreditAccountEvent = TypedEvent<
  [string, string],
  DeployCreditAccountEventObject
>;

export type DeployCreditAccountEventFilter =
  TypedEventFilter<DeployCreditAccountEvent>;

export interface ReturnCreditAccountEventObject {
  creditAccount: string;
  creditManager: string;
}
export type ReturnCreditAccountEvent = TypedEvent<
  [string, string],
  ReturnCreditAccountEventObject
>;

export type ReturnCreditAccountEventFilter =
  TypedEventFilter<ReturnCreditAccountEvent>;

export interface TakeCreditAccountEventObject {
  creditAccount: string;
  creditManager: string;
}
export type TakeCreditAccountEvent = TypedEvent<
  [string, string],
  TakeCreditAccountEventObject
>;

export type TakeCreditAccountEventFilter =
  TypedEventFilter<TakeCreditAccountEvent>;

export interface AccountFactoryV3Harness extends BaseContract {
  contractName: "AccountFactoryV3Harness";

  connect(signerOrProvider: Signer | Provider | string): this;
  attach(addressOrName: string): this;
  deployed(): Promise<this>;

  interface: AccountFactoryV3HarnessInterface;

  queryFilter<TEvent extends TypedEvent>(
    event: TypedEventFilter<TEvent>,
    fromBlockOrBlockhash?: string | number | undefined,
    toBlock?: string | number | undefined
  ): Promise<Array<TEvent>>;

  listeners<TEvent extends TypedEvent>(
    eventFilter?: TypedEventFilter<TEvent>
  ): Array<TypedListener<TEvent>>;
  listeners(eventName?: string): Array<Listener>;
  removeAllListeners<TEvent extends TypedEvent>(
    eventFilter: TypedEventFilter<TEvent>
  ): this;
  removeAllListeners(eventName?: string): this;
  off: OnEvent<this>;
  on: OnEvent<this>;
  once: OnEvent<this>;
  removeListener: OnEvent<this>;

  functions: {
    acl(overrides?: CallOverrides): Promise<[string]>;

    addCreditManager(
      creditManager: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    contractsRegister(overrides?: CallOverrides): Promise<[string]>;

    delay(overrides?: CallOverrides): Promise<[number]>;

    factoryParams(
      creditManager: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<[FactoryParamsStructOutput]>;

    queuedAccounts(
      creditManager: PromiseOrValue<string>,
      index: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<[QueuedAccountStructOutput]>;

    rescue(
      creditAccount: PromiseOrValue<string>,
      target: PromiseOrValue<string>,
      data: PromiseOrValue<BytesLike>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    returnCreditAccount(
      creditAccount: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    setFactoryParams(
      creditManager: PromiseOrValue<string>,
      masterCreditAccount: PromiseOrValue<string>,
      head: PromiseOrValue<BigNumberish>,
      tail: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    setQueuedAccount(
      creditManager: PromiseOrValue<string>,
      index: PromiseOrValue<BigNumberish>,
      creditAccount: PromiseOrValue<string>,
      reusableAfter: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    takeCreditAccount(
      arg0: PromiseOrValue<BigNumberish>,
      arg1: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    version(overrides?: CallOverrides): Promise<[BigNumber]>;
  };

  acl(overrides?: CallOverrides): Promise<string>;

  addCreditManager(
    creditManager: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  contractsRegister(overrides?: CallOverrides): Promise<string>;

  delay(overrides?: CallOverrides): Promise<number>;

  factoryParams(
    creditManager: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<FactoryParamsStructOutput>;

  queuedAccounts(
    creditManager: PromiseOrValue<string>,
    index: PromiseOrValue<BigNumberish>,
    overrides?: CallOverrides
  ): Promise<QueuedAccountStructOutput>;

  rescue(
    creditAccount: PromiseOrValue<string>,
    target: PromiseOrValue<string>,
    data: PromiseOrValue<BytesLike>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  returnCreditAccount(
    creditAccount: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  setFactoryParams(
    creditManager: PromiseOrValue<string>,
    masterCreditAccount: PromiseOrValue<string>,
    head: PromiseOrValue<BigNumberish>,
    tail: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  setQueuedAccount(
    creditManager: PromiseOrValue<string>,
    index: PromiseOrValue<BigNumberish>,
    creditAccount: PromiseOrValue<string>,
    reusableAfter: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  takeCreditAccount(
    arg0: PromiseOrValue<BigNumberish>,
    arg1: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  version(overrides?: CallOverrides): Promise<BigNumber>;

  callStatic: {
    acl(overrides?: CallOverrides): Promise<string>;

    addCreditManager(
      creditManager: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    contractsRegister(overrides?: CallOverrides): Promise<string>;

    delay(overrides?: CallOverrides): Promise<number>;

    factoryParams(
      creditManager: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<FactoryParamsStructOutput>;

    queuedAccounts(
      creditManager: PromiseOrValue<string>,
      index: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<QueuedAccountStructOutput>;

    rescue(
      creditAccount: PromiseOrValue<string>,
      target: PromiseOrValue<string>,
      data: PromiseOrValue<BytesLike>,
      overrides?: CallOverrides
    ): Promise<void>;

    returnCreditAccount(
      creditAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    setFactoryParams(
      creditManager: PromiseOrValue<string>,
      masterCreditAccount: PromiseOrValue<string>,
      head: PromiseOrValue<BigNumberish>,
      tail: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<void>;

    setQueuedAccount(
      creditManager: PromiseOrValue<string>,
      index: PromiseOrValue<BigNumberish>,
      creditAccount: PromiseOrValue<string>,
      reusableAfter: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<void>;

    takeCreditAccount(
      arg0: PromiseOrValue<BigNumberish>,
      arg1: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<string>;

    version(overrides?: CallOverrides): Promise<BigNumber>;
  };

  filters: {
    "AddCreditManager(address,address)"(
      creditManager?: PromiseOrValue<string> | null,
      masterCreditAccount?: null
    ): AddCreditManagerEventFilter;
    AddCreditManager(
      creditManager?: PromiseOrValue<string> | null,
      masterCreditAccount?: null
    ): AddCreditManagerEventFilter;

    "DeployCreditAccount(address,address)"(
      creditAccount?: PromiseOrValue<string> | null,
      creditManager?: PromiseOrValue<string> | null
    ): DeployCreditAccountEventFilter;
    DeployCreditAccount(
      creditAccount?: PromiseOrValue<string> | null,
      creditManager?: PromiseOrValue<string> | null
    ): DeployCreditAccountEventFilter;

    "ReturnCreditAccount(address,address)"(
      creditAccount?: PromiseOrValue<string> | null,
      creditManager?: PromiseOrValue<string> | null
    ): ReturnCreditAccountEventFilter;
    ReturnCreditAccount(
      creditAccount?: PromiseOrValue<string> | null,
      creditManager?: PromiseOrValue<string> | null
    ): ReturnCreditAccountEventFilter;

    "TakeCreditAccount(address,address)"(
      creditAccount?: PromiseOrValue<string> | null,
      creditManager?: PromiseOrValue<string> | null
    ): TakeCreditAccountEventFilter;
    TakeCreditAccount(
      creditAccount?: PromiseOrValue<string> | null,
      creditManager?: PromiseOrValue<string> | null
    ): TakeCreditAccountEventFilter;
  };

  estimateGas: {
    acl(overrides?: CallOverrides): Promise<BigNumber>;

    addCreditManager(
      creditManager: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    contractsRegister(overrides?: CallOverrides): Promise<BigNumber>;

    delay(overrides?: CallOverrides): Promise<BigNumber>;

    factoryParams(
      creditManager: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    queuedAccounts(
      creditManager: PromiseOrValue<string>,
      index: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    rescue(
      creditAccount: PromiseOrValue<string>,
      target: PromiseOrValue<string>,
      data: PromiseOrValue<BytesLike>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    returnCreditAccount(
      creditAccount: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    setFactoryParams(
      creditManager: PromiseOrValue<string>,
      masterCreditAccount: PromiseOrValue<string>,
      head: PromiseOrValue<BigNumberish>,
      tail: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    setQueuedAccount(
      creditManager: PromiseOrValue<string>,
      index: PromiseOrValue<BigNumberish>,
      creditAccount: PromiseOrValue<string>,
      reusableAfter: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    takeCreditAccount(
      arg0: PromiseOrValue<BigNumberish>,
      arg1: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    version(overrides?: CallOverrides): Promise<BigNumber>;
  };

  populateTransaction: {
    acl(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    addCreditManager(
      creditManager: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    contractsRegister(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    delay(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    factoryParams(
      creditManager: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    queuedAccounts(
      creditManager: PromiseOrValue<string>,
      index: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    rescue(
      creditAccount: PromiseOrValue<string>,
      target: PromiseOrValue<string>,
      data: PromiseOrValue<BytesLike>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    returnCreditAccount(
      creditAccount: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    setFactoryParams(
      creditManager: PromiseOrValue<string>,
      masterCreditAccount: PromiseOrValue<string>,
      head: PromiseOrValue<BigNumberish>,
      tail: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    setQueuedAccount(
      creditManager: PromiseOrValue<string>,
      index: PromiseOrValue<BigNumberish>,
      creditAccount: PromiseOrValue<string>,
      reusableAfter: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    takeCreditAccount(
      arg0: PromiseOrValue<BigNumberish>,
      arg1: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    version(overrides?: CallOverrides): Promise<PopulatedTransaction>;
  };
}