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
} from "../common";

export interface IAccountFactoryInterface extends utils.Interface {
  functions: {
    "countCreditAccounts()": FunctionFragment;
    "countCreditAccountsInStock()": FunctionFragment;
    "creditAccounts(uint256)": FunctionFragment;
    "getNext(address)": FunctionFragment;
    "head()": FunctionFragment;
    "returnCreditAccount(address)": FunctionFragment;
    "tail()": FunctionFragment;
    "takeCreditAccount(uint256,uint256)": FunctionFragment;
    "version()": FunctionFragment;
  };

  getFunction(
    nameOrSignatureOrTopic:
      | "countCreditAccounts"
      | "countCreditAccountsInStock"
      | "creditAccounts"
      | "getNext"
      | "head"
      | "returnCreditAccount"
      | "tail"
      | "takeCreditAccount"
      | "version"
  ): FunctionFragment;

  encodeFunctionData(
    functionFragment: "countCreditAccounts",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "countCreditAccountsInStock",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "creditAccounts",
    values: [PromiseOrValue<BigNumberish>]
  ): string;
  encodeFunctionData(
    functionFragment: "getNext",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(functionFragment: "head", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "returnCreditAccount",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(functionFragment: "tail", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "takeCreditAccount",
    values: [PromiseOrValue<BigNumberish>, PromiseOrValue<BigNumberish>]
  ): string;
  encodeFunctionData(functionFragment: "version", values?: undefined): string;

  decodeFunctionResult(
    functionFragment: "countCreditAccounts",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "countCreditAccountsInStock",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "creditAccounts",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "getNext", data: BytesLike): Result;
  decodeFunctionResult(functionFragment: "head", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "returnCreditAccount",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "tail", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "takeCreditAccount",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "version", data: BytesLike): Result;

  events: {
    "AccountMinerChanged(address)": EventFragment;
    "InitializeCreditAccount(address,address)": EventFragment;
    "NewCreditAccount(address)": EventFragment;
    "ReturnCreditAccount(address)": EventFragment;
    "TakeForever(address,address)": EventFragment;
  };

  getEvent(nameOrSignatureOrTopic: "AccountMinerChanged"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "InitializeCreditAccount"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "NewCreditAccount"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "ReturnCreditAccount"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "TakeForever"): EventFragment;
}

export interface AccountMinerChangedEventObject {
  miner: string;
}
export type AccountMinerChangedEvent = TypedEvent<
  [string],
  AccountMinerChangedEventObject
>;

export type AccountMinerChangedEventFilter =
  TypedEventFilter<AccountMinerChangedEvent>;

export interface InitializeCreditAccountEventObject {
  account: string;
  creditManager: string;
}
export type InitializeCreditAccountEvent = TypedEvent<
  [string, string],
  InitializeCreditAccountEventObject
>;

export type InitializeCreditAccountEventFilter =
  TypedEventFilter<InitializeCreditAccountEvent>;

export interface NewCreditAccountEventObject {
  account: string;
}
export type NewCreditAccountEvent = TypedEvent<
  [string],
  NewCreditAccountEventObject
>;

export type NewCreditAccountEventFilter =
  TypedEventFilter<NewCreditAccountEvent>;

export interface ReturnCreditAccountEventObject {
  account: string;
}
export type ReturnCreditAccountEvent = TypedEvent<
  [string],
  ReturnCreditAccountEventObject
>;

export type ReturnCreditAccountEventFilter =
  TypedEventFilter<ReturnCreditAccountEvent>;

export interface TakeForeverEventObject {
  creditAccount: string;
  to: string;
}
export type TakeForeverEvent = TypedEvent<
  [string, string],
  TakeForeverEventObject
>;

export type TakeForeverEventFilter = TypedEventFilter<TakeForeverEvent>;

export interface IAccountFactory extends BaseContract {
  contractName: "IAccountFactory";

  connect(signerOrProvider: Signer | Provider | string): this;
  attach(addressOrName: string): this;
  deployed(): Promise<this>;

  interface: IAccountFactoryInterface;

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
    countCreditAccounts(overrides?: CallOverrides): Promise<[BigNumber]>;

    countCreditAccountsInStock(overrides?: CallOverrides): Promise<[BigNumber]>;

    creditAccounts(
      id: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<[string]>;

    getNext(
      creditAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<[string]>;

    head(overrides?: CallOverrides): Promise<[string]>;

    returnCreditAccount(
      usedAccount: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    tail(overrides?: CallOverrides): Promise<[string]>;

    takeCreditAccount(
      _borrowedAmount: PromiseOrValue<BigNumberish>,
      _cumulativeIndexAtOpen: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    version(overrides?: CallOverrides): Promise<[BigNumber]>;
  };

  countCreditAccounts(overrides?: CallOverrides): Promise<BigNumber>;

  countCreditAccountsInStock(overrides?: CallOverrides): Promise<BigNumber>;

  creditAccounts(
    id: PromiseOrValue<BigNumberish>,
    overrides?: CallOverrides
  ): Promise<string>;

  getNext(
    creditAccount: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<string>;

  head(overrides?: CallOverrides): Promise<string>;

  returnCreditAccount(
    usedAccount: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  tail(overrides?: CallOverrides): Promise<string>;

  takeCreditAccount(
    _borrowedAmount: PromiseOrValue<BigNumberish>,
    _cumulativeIndexAtOpen: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  version(overrides?: CallOverrides): Promise<BigNumber>;

  callStatic: {
    countCreditAccounts(overrides?: CallOverrides): Promise<BigNumber>;

    countCreditAccountsInStock(overrides?: CallOverrides): Promise<BigNumber>;

    creditAccounts(
      id: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<string>;

    getNext(
      creditAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<string>;

    head(overrides?: CallOverrides): Promise<string>;

    returnCreditAccount(
      usedAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    tail(overrides?: CallOverrides): Promise<string>;

    takeCreditAccount(
      _borrowedAmount: PromiseOrValue<BigNumberish>,
      _cumulativeIndexAtOpen: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<string>;

    version(overrides?: CallOverrides): Promise<BigNumber>;
  };

  filters: {
    "AccountMinerChanged(address)"(
      miner?: PromiseOrValue<string> | null
    ): AccountMinerChangedEventFilter;
    AccountMinerChanged(
      miner?: PromiseOrValue<string> | null
    ): AccountMinerChangedEventFilter;

    "InitializeCreditAccount(address,address)"(
      account?: PromiseOrValue<string> | null,
      creditManager?: PromiseOrValue<string> | null
    ): InitializeCreditAccountEventFilter;
    InitializeCreditAccount(
      account?: PromiseOrValue<string> | null,
      creditManager?: PromiseOrValue<string> | null
    ): InitializeCreditAccountEventFilter;

    "NewCreditAccount(address)"(
      account?: PromiseOrValue<string> | null
    ): NewCreditAccountEventFilter;
    NewCreditAccount(
      account?: PromiseOrValue<string> | null
    ): NewCreditAccountEventFilter;

    "ReturnCreditAccount(address)"(
      account?: PromiseOrValue<string> | null
    ): ReturnCreditAccountEventFilter;
    ReturnCreditAccount(
      account?: PromiseOrValue<string> | null
    ): ReturnCreditAccountEventFilter;

    "TakeForever(address,address)"(
      creditAccount?: PromiseOrValue<string> | null,
      to?: PromiseOrValue<string> | null
    ): TakeForeverEventFilter;
    TakeForever(
      creditAccount?: PromiseOrValue<string> | null,
      to?: PromiseOrValue<string> | null
    ): TakeForeverEventFilter;
  };

  estimateGas: {
    countCreditAccounts(overrides?: CallOverrides): Promise<BigNumber>;

    countCreditAccountsInStock(overrides?: CallOverrides): Promise<BigNumber>;

    creditAccounts(
      id: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    getNext(
      creditAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    head(overrides?: CallOverrides): Promise<BigNumber>;

    returnCreditAccount(
      usedAccount: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    tail(overrides?: CallOverrides): Promise<BigNumber>;

    takeCreditAccount(
      _borrowedAmount: PromiseOrValue<BigNumberish>,
      _cumulativeIndexAtOpen: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    version(overrides?: CallOverrides): Promise<BigNumber>;
  };

  populateTransaction: {
    countCreditAccounts(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    countCreditAccountsInStock(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    creditAccounts(
      id: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    getNext(
      creditAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    head(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    returnCreditAccount(
      usedAccount: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    tail(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    takeCreditAccount(
      _borrowedAmount: PromiseOrValue<BigNumberish>,
      _cumulativeIndexAtOpen: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    version(overrides?: CallOverrides): Promise<PopulatedTransaction>;
  };
}
