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

export type ScheduledWithdrawalStruct = {
  tokenIndex: PromiseOrValue<BigNumberish>;
  maturity: PromiseOrValue<BigNumberish>;
  token: PromiseOrValue<string>;
  amount: PromiseOrValue<BigNumberish>;
};

export type ScheduledWithdrawalStructOutput = [
  number,
  number,
  string,
  BigNumber
] & { tokenIndex: number; maturity: number; token: string; amount: BigNumber };

export interface WithdrawalManagerV3Interface extends utils.Interface {
  functions: {
    "acl()": FunctionFragment;
    "addCreditManager(address)": FunctionFragment;
    "addImmediateWithdrawal(address,address,uint256)": FunctionFragment;
    "addScheduledWithdrawal(address,address,uint256,uint8)": FunctionFragment;
    "cancellableScheduledWithdrawals(address,bool)": FunctionFragment;
    "claimImmediateWithdrawal(address,address)": FunctionFragment;
    "claimScheduledWithdrawals(address,address,uint8)": FunctionFragment;
    "contractsRegister()": FunctionFragment;
    "creditManagers()": FunctionFragment;
    "delay()": FunctionFragment;
    "immediateWithdrawals(address,address)": FunctionFragment;
    "scheduledWithdrawals(address)": FunctionFragment;
    "setWithdrawalDelay(uint40)": FunctionFragment;
    "version()": FunctionFragment;
    "weth()": FunctionFragment;
  };

  getFunction(
    nameOrSignatureOrTopic:
      | "acl"
      | "addCreditManager"
      | "addImmediateWithdrawal"
      | "addScheduledWithdrawal"
      | "cancellableScheduledWithdrawals"
      | "claimImmediateWithdrawal"
      | "claimScheduledWithdrawals"
      | "contractsRegister"
      | "creditManagers"
      | "delay"
      | "immediateWithdrawals"
      | "scheduledWithdrawals"
      | "setWithdrawalDelay"
      | "version"
      | "weth"
  ): FunctionFragment;

  encodeFunctionData(functionFragment: "acl", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "addCreditManager",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "addImmediateWithdrawal",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<string>,
      PromiseOrValue<BigNumberish>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "addScheduledWithdrawal",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<string>,
      PromiseOrValue<BigNumberish>,
      PromiseOrValue<BigNumberish>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "cancellableScheduledWithdrawals",
    values: [PromiseOrValue<string>, PromiseOrValue<boolean>]
  ): string;
  encodeFunctionData(
    functionFragment: "claimImmediateWithdrawal",
    values: [PromiseOrValue<string>, PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "claimScheduledWithdrawals",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<string>,
      PromiseOrValue<BigNumberish>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "contractsRegister",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "creditManagers",
    values?: undefined
  ): string;
  encodeFunctionData(functionFragment: "delay", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "immediateWithdrawals",
    values: [PromiseOrValue<string>, PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "scheduledWithdrawals",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "setWithdrawalDelay",
    values: [PromiseOrValue<BigNumberish>]
  ): string;
  encodeFunctionData(functionFragment: "version", values?: undefined): string;
  encodeFunctionData(functionFragment: "weth", values?: undefined): string;

  decodeFunctionResult(functionFragment: "acl", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "addCreditManager",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "addImmediateWithdrawal",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "addScheduledWithdrawal",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "cancellableScheduledWithdrawals",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "claimImmediateWithdrawal",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "claimScheduledWithdrawals",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "contractsRegister",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "creditManagers",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "delay", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "immediateWithdrawals",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "scheduledWithdrawals",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "setWithdrawalDelay",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "version", data: BytesLike): Result;
  decodeFunctionResult(functionFragment: "weth", data: BytesLike): Result;

  events: {
    "AddCreditManager(address)": EventFragment;
    "AddImmediateWithdrawal(address,address,uint256)": EventFragment;
    "AddScheduledWithdrawal(address,address,uint256,uint40)": EventFragment;
    "CancelScheduledWithdrawal(address,address,uint256)": EventFragment;
    "ClaimImmediateWithdrawal(address,address,address,uint256)": EventFragment;
    "ClaimScheduledWithdrawal(address,address,address,uint256)": EventFragment;
    "SetWithdrawalDelay(uint40)": EventFragment;
  };

  getEvent(nameOrSignatureOrTopic: "AddCreditManager"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "AddImmediateWithdrawal"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "AddScheduledWithdrawal"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "CancelScheduledWithdrawal"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "ClaimImmediateWithdrawal"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "ClaimScheduledWithdrawal"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "SetWithdrawalDelay"): EventFragment;
}

export interface AddCreditManagerEventObject {
  creditManager: string;
}
export type AddCreditManagerEvent = TypedEvent<
  [string],
  AddCreditManagerEventObject
>;

export type AddCreditManagerEventFilter =
  TypedEventFilter<AddCreditManagerEvent>;

export interface AddImmediateWithdrawalEventObject {
  account: string;
  token: string;
  amount: BigNumber;
}
export type AddImmediateWithdrawalEvent = TypedEvent<
  [string, string, BigNumber],
  AddImmediateWithdrawalEventObject
>;

export type AddImmediateWithdrawalEventFilter =
  TypedEventFilter<AddImmediateWithdrawalEvent>;

export interface AddScheduledWithdrawalEventObject {
  creditAccount: string;
  token: string;
  amount: BigNumber;
  maturity: number;
}
export type AddScheduledWithdrawalEvent = TypedEvent<
  [string, string, BigNumber, number],
  AddScheduledWithdrawalEventObject
>;

export type AddScheduledWithdrawalEventFilter =
  TypedEventFilter<AddScheduledWithdrawalEvent>;

export interface CancelScheduledWithdrawalEventObject {
  creditAccount: string;
  token: string;
  amount: BigNumber;
}
export type CancelScheduledWithdrawalEvent = TypedEvent<
  [string, string, BigNumber],
  CancelScheduledWithdrawalEventObject
>;

export type CancelScheduledWithdrawalEventFilter =
  TypedEventFilter<CancelScheduledWithdrawalEvent>;

export interface ClaimImmediateWithdrawalEventObject {
  account: string;
  token: string;
  to: string;
  amount: BigNumber;
}
export type ClaimImmediateWithdrawalEvent = TypedEvent<
  [string, string, string, BigNumber],
  ClaimImmediateWithdrawalEventObject
>;

export type ClaimImmediateWithdrawalEventFilter =
  TypedEventFilter<ClaimImmediateWithdrawalEvent>;

export interface ClaimScheduledWithdrawalEventObject {
  creditAccount: string;
  token: string;
  to: string;
  amount: BigNumber;
}
export type ClaimScheduledWithdrawalEvent = TypedEvent<
  [string, string, string, BigNumber],
  ClaimScheduledWithdrawalEventObject
>;

export type ClaimScheduledWithdrawalEventFilter =
  TypedEventFilter<ClaimScheduledWithdrawalEvent>;

export interface SetWithdrawalDelayEventObject {
  newDelay: number;
}
export type SetWithdrawalDelayEvent = TypedEvent<
  [number],
  SetWithdrawalDelayEventObject
>;

export type SetWithdrawalDelayEventFilter =
  TypedEventFilter<SetWithdrawalDelayEvent>;

export interface WithdrawalManagerV3 extends BaseContract {
  contractName: "WithdrawalManagerV3";

  connect(signerOrProvider: Signer | Provider | string): this;
  attach(addressOrName: string): this;
  deployed(): Promise<this>;

  interface: WithdrawalManagerV3Interface;

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
      newCreditManager: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    addImmediateWithdrawal(
      token: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      amount: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    addScheduledWithdrawal(
      creditAccount: PromiseOrValue<string>,
      token: PromiseOrValue<string>,
      amount: PromiseOrValue<BigNumberish>,
      tokenIndex: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    cancellableScheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      isForceCancel: PromiseOrValue<boolean>,
      overrides?: CallOverrides
    ): Promise<
      [string, BigNumber, string, BigNumber] & {
        token1: string;
        amount1: BigNumber;
        token2: string;
        amount2: BigNumber;
      }
    >;

    claimImmediateWithdrawal(
      token: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    claimScheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      action: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    contractsRegister(overrides?: CallOverrides): Promise<[string]>;

    creditManagers(overrides?: CallOverrides): Promise<[string[]]>;

    delay(overrides?: CallOverrides): Promise<[number]>;

    immediateWithdrawals(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<[BigNumber]>;

    scheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<
      [[ScheduledWithdrawalStructOutput, ScheduledWithdrawalStructOutput]]
    >;

    setWithdrawalDelay(
      newDelay: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    version(overrides?: CallOverrides): Promise<[BigNumber]>;

    weth(overrides?: CallOverrides): Promise<[string]>;
  };

  acl(overrides?: CallOverrides): Promise<string>;

  addCreditManager(
    newCreditManager: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  addImmediateWithdrawal(
    token: PromiseOrValue<string>,
    to: PromiseOrValue<string>,
    amount: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  addScheduledWithdrawal(
    creditAccount: PromiseOrValue<string>,
    token: PromiseOrValue<string>,
    amount: PromiseOrValue<BigNumberish>,
    tokenIndex: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  cancellableScheduledWithdrawals(
    creditAccount: PromiseOrValue<string>,
    isForceCancel: PromiseOrValue<boolean>,
    overrides?: CallOverrides
  ): Promise<
    [string, BigNumber, string, BigNumber] & {
      token1: string;
      amount1: BigNumber;
      token2: string;
      amount2: BigNumber;
    }
  >;

  claimImmediateWithdrawal(
    token: PromiseOrValue<string>,
    to: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  claimScheduledWithdrawals(
    creditAccount: PromiseOrValue<string>,
    to: PromiseOrValue<string>,
    action: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  contractsRegister(overrides?: CallOverrides): Promise<string>;

  creditManagers(overrides?: CallOverrides): Promise<string[]>;

  delay(overrides?: CallOverrides): Promise<number>;

  immediateWithdrawals(
    arg0: PromiseOrValue<string>,
    arg1: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<BigNumber>;

  scheduledWithdrawals(
    creditAccount: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<
    [ScheduledWithdrawalStructOutput, ScheduledWithdrawalStructOutput]
  >;

  setWithdrawalDelay(
    newDelay: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  version(overrides?: CallOverrides): Promise<BigNumber>;

  weth(overrides?: CallOverrides): Promise<string>;

  callStatic: {
    acl(overrides?: CallOverrides): Promise<string>;

    addCreditManager(
      newCreditManager: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    addImmediateWithdrawal(
      token: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      amount: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<void>;

    addScheduledWithdrawal(
      creditAccount: PromiseOrValue<string>,
      token: PromiseOrValue<string>,
      amount: PromiseOrValue<BigNumberish>,
      tokenIndex: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<void>;

    cancellableScheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      isForceCancel: PromiseOrValue<boolean>,
      overrides?: CallOverrides
    ): Promise<
      [string, BigNumber, string, BigNumber] & {
        token1: string;
        amount1: BigNumber;
        token2: string;
        amount2: BigNumber;
      }
    >;

    claimImmediateWithdrawal(
      token: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    claimScheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      action: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<
      [boolean, BigNumber] & {
        hasScheduled: boolean;
        tokensToEnable: BigNumber;
      }
    >;

    contractsRegister(overrides?: CallOverrides): Promise<string>;

    creditManagers(overrides?: CallOverrides): Promise<string[]>;

    delay(overrides?: CallOverrides): Promise<number>;

    immediateWithdrawals(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    scheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<
      [ScheduledWithdrawalStructOutput, ScheduledWithdrawalStructOutput]
    >;

    setWithdrawalDelay(
      newDelay: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<void>;

    version(overrides?: CallOverrides): Promise<BigNumber>;

    weth(overrides?: CallOverrides): Promise<string>;
  };

  filters: {
    "AddCreditManager(address)"(
      creditManager?: PromiseOrValue<string> | null
    ): AddCreditManagerEventFilter;
    AddCreditManager(
      creditManager?: PromiseOrValue<string> | null
    ): AddCreditManagerEventFilter;

    "AddImmediateWithdrawal(address,address,uint256)"(
      account?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      amount?: null
    ): AddImmediateWithdrawalEventFilter;
    AddImmediateWithdrawal(
      account?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      amount?: null
    ): AddImmediateWithdrawalEventFilter;

    "AddScheduledWithdrawal(address,address,uint256,uint40)"(
      creditAccount?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      amount?: null,
      maturity?: null
    ): AddScheduledWithdrawalEventFilter;
    AddScheduledWithdrawal(
      creditAccount?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      amount?: null,
      maturity?: null
    ): AddScheduledWithdrawalEventFilter;

    "CancelScheduledWithdrawal(address,address,uint256)"(
      creditAccount?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      amount?: null
    ): CancelScheduledWithdrawalEventFilter;
    CancelScheduledWithdrawal(
      creditAccount?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      amount?: null
    ): CancelScheduledWithdrawalEventFilter;

    "ClaimImmediateWithdrawal(address,address,address,uint256)"(
      account?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      to?: null,
      amount?: null
    ): ClaimImmediateWithdrawalEventFilter;
    ClaimImmediateWithdrawal(
      account?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      to?: null,
      amount?: null
    ): ClaimImmediateWithdrawalEventFilter;

    "ClaimScheduledWithdrawal(address,address,address,uint256)"(
      creditAccount?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      to?: null,
      amount?: null
    ): ClaimScheduledWithdrawalEventFilter;
    ClaimScheduledWithdrawal(
      creditAccount?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      to?: null,
      amount?: null
    ): ClaimScheduledWithdrawalEventFilter;

    "SetWithdrawalDelay(uint40)"(
      newDelay?: null
    ): SetWithdrawalDelayEventFilter;
    SetWithdrawalDelay(newDelay?: null): SetWithdrawalDelayEventFilter;
  };

  estimateGas: {
    acl(overrides?: CallOverrides): Promise<BigNumber>;

    addCreditManager(
      newCreditManager: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    addImmediateWithdrawal(
      token: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      amount: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    addScheduledWithdrawal(
      creditAccount: PromiseOrValue<string>,
      token: PromiseOrValue<string>,
      amount: PromiseOrValue<BigNumberish>,
      tokenIndex: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    cancellableScheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      isForceCancel: PromiseOrValue<boolean>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    claimImmediateWithdrawal(
      token: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    claimScheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      action: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    contractsRegister(overrides?: CallOverrides): Promise<BigNumber>;

    creditManagers(overrides?: CallOverrides): Promise<BigNumber>;

    delay(overrides?: CallOverrides): Promise<BigNumber>;

    immediateWithdrawals(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    scheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    setWithdrawalDelay(
      newDelay: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    version(overrides?: CallOverrides): Promise<BigNumber>;

    weth(overrides?: CallOverrides): Promise<BigNumber>;
  };

  populateTransaction: {
    acl(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    addCreditManager(
      newCreditManager: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    addImmediateWithdrawal(
      token: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      amount: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    addScheduledWithdrawal(
      creditAccount: PromiseOrValue<string>,
      token: PromiseOrValue<string>,
      amount: PromiseOrValue<BigNumberish>,
      tokenIndex: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    cancellableScheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      isForceCancel: PromiseOrValue<boolean>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    claimImmediateWithdrawal(
      token: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    claimScheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      to: PromiseOrValue<string>,
      action: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    contractsRegister(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    creditManagers(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    delay(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    immediateWithdrawals(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    scheduledWithdrawals(
      creditAccount: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    setWithdrawalDelay(
      newDelay: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    version(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    weth(overrides?: CallOverrides): Promise<PopulatedTransaction>;
  };
}
