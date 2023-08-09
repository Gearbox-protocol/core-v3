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

export type PolicyStruct = {
  enabled: PromiseOrValue<boolean>;
  admin: PromiseOrValue<string>;
  flags: PromiseOrValue<BigNumberish>;
  exactValue: PromiseOrValue<BigNumberish>;
  minValue: PromiseOrValue<BigNumberish>;
  maxValue: PromiseOrValue<BigNumberish>;
  referencePoint: PromiseOrValue<BigNumberish>;
  referencePointUpdatePeriod: PromiseOrValue<BigNumberish>;
  referencePointTimestampLU: PromiseOrValue<BigNumberish>;
  minPctChange: PromiseOrValue<BigNumberish>;
  maxPctChange: PromiseOrValue<BigNumberish>;
  minChange: PromiseOrValue<BigNumberish>;
  maxChange: PromiseOrValue<BigNumberish>;
};

export type PolicyStructOutput = [
  boolean,
  string,
  number,
  BigNumber,
  BigNumber,
  BigNumber,
  BigNumber,
  number,
  number,
  number,
  number,
  BigNumber,
  BigNumber
] & {
  enabled: boolean;
  admin: string;
  flags: number;
  exactValue: BigNumber;
  minValue: BigNumber;
  maxValue: BigNumber;
  referencePoint: BigNumber;
  referencePointUpdatePeriod: number;
  referencePointTimestampLU: number;
  minPctChange: number;
  maxPctChange: number;
  minChange: BigNumber;
  maxChange: BigNumber;
};

export interface PolicyManagerInternalInterface extends utils.Interface {
  functions: {
    "CHECK_EXACT_VALUE_FLAG()": FunctionFragment;
    "CHECK_MAX_CHANGE_FLAG()": FunctionFragment;
    "CHECK_MAX_PCT_CHANGE_FLAG()": FunctionFragment;
    "CHECK_MAX_VALUE_FLAG()": FunctionFragment;
    "CHECK_MIN_CHANGE_FLAG()": FunctionFragment;
    "CHECK_MIN_PCT_CHANGE_FLAG()": FunctionFragment;
    "CHECK_MIN_VALUE_FLAG()": FunctionFragment;
    "acl()": FunctionFragment;
    "checkPolicy(address,string,uint256,uint256)": FunctionFragment;
    "checkPolicy(bytes32,uint256,uint256)": FunctionFragment;
    "controller()": FunctionFragment;
    "disablePolicy(bytes32)": FunctionFragment;
    "getGroup(address)": FunctionFragment;
    "getPolicy(bytes32)": FunctionFragment;
    "pause()": FunctionFragment;
    "paused()": FunctionFragment;
    "setController(address)": FunctionFragment;
    "setGroup(address,string)": FunctionFragment;
    "setPolicy(bytes32,(bool,address,uint8,uint256,uint256,uint256,uint256,uint40,uint40,uint16,uint16,uint256,uint256))": FunctionFragment;
    "unpause()": FunctionFragment;
  };

  getFunction(
    nameOrSignatureOrTopic:
      | "CHECK_EXACT_VALUE_FLAG"
      | "CHECK_MAX_CHANGE_FLAG"
      | "CHECK_MAX_PCT_CHANGE_FLAG"
      | "CHECK_MAX_VALUE_FLAG"
      | "CHECK_MIN_CHANGE_FLAG"
      | "CHECK_MIN_PCT_CHANGE_FLAG"
      | "CHECK_MIN_VALUE_FLAG"
      | "acl"
      | "checkPolicy(address,string,uint256,uint256)"
      | "checkPolicy(bytes32,uint256,uint256)"
      | "controller"
      | "disablePolicy"
      | "getGroup"
      | "getPolicy"
      | "pause"
      | "paused"
      | "setController"
      | "setGroup"
      | "setPolicy"
      | "unpause"
  ): FunctionFragment;

  encodeFunctionData(
    functionFragment: "CHECK_EXACT_VALUE_FLAG",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "CHECK_MAX_CHANGE_FLAG",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "CHECK_MAX_PCT_CHANGE_FLAG",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "CHECK_MAX_VALUE_FLAG",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "CHECK_MIN_CHANGE_FLAG",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "CHECK_MIN_PCT_CHANGE_FLAG",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "CHECK_MIN_VALUE_FLAG",
    values?: undefined
  ): string;
  encodeFunctionData(functionFragment: "acl", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "checkPolicy(address,string,uint256,uint256)",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<string>,
      PromiseOrValue<BigNumberish>,
      PromiseOrValue<BigNumberish>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "checkPolicy(bytes32,uint256,uint256)",
    values: [
      PromiseOrValue<BytesLike>,
      PromiseOrValue<BigNumberish>,
      PromiseOrValue<BigNumberish>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "controller",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "disablePolicy",
    values: [PromiseOrValue<BytesLike>]
  ): string;
  encodeFunctionData(
    functionFragment: "getGroup",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "getPolicy",
    values: [PromiseOrValue<BytesLike>]
  ): string;
  encodeFunctionData(functionFragment: "pause", values?: undefined): string;
  encodeFunctionData(functionFragment: "paused", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "setController",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "setGroup",
    values: [PromiseOrValue<string>, PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "setPolicy",
    values: [PromiseOrValue<BytesLike>, PolicyStruct]
  ): string;
  encodeFunctionData(functionFragment: "unpause", values?: undefined): string;

  decodeFunctionResult(
    functionFragment: "CHECK_EXACT_VALUE_FLAG",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "CHECK_MAX_CHANGE_FLAG",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "CHECK_MAX_PCT_CHANGE_FLAG",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "CHECK_MAX_VALUE_FLAG",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "CHECK_MIN_CHANGE_FLAG",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "CHECK_MIN_PCT_CHANGE_FLAG",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "CHECK_MIN_VALUE_FLAG",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "acl", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "checkPolicy(address,string,uint256,uint256)",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "checkPolicy(bytes32,uint256,uint256)",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "controller", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "disablePolicy",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "getGroup", data: BytesLike): Result;
  decodeFunctionResult(functionFragment: "getPolicy", data: BytesLike): Result;
  decodeFunctionResult(functionFragment: "pause", data: BytesLike): Result;
  decodeFunctionResult(functionFragment: "paused", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "setController",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "setGroup", data: BytesLike): Result;
  decodeFunctionResult(functionFragment: "setPolicy", data: BytesLike): Result;
  decodeFunctionResult(functionFragment: "unpause", data: BytesLike): Result;

  events: {
    "NewController(address)": EventFragment;
    "Paused(address)": EventFragment;
    "SetGroup(address,string)": EventFragment;
    "SetPolicy(bytes32,bool)": EventFragment;
    "Unpaused(address)": EventFragment;
  };

  getEvent(nameOrSignatureOrTopic: "NewController"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "Paused"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "SetGroup"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "SetPolicy"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "Unpaused"): EventFragment;
}

export interface NewControllerEventObject {
  newController: string;
}
export type NewControllerEvent = TypedEvent<[string], NewControllerEventObject>;

export type NewControllerEventFilter = TypedEventFilter<NewControllerEvent>;

export interface PausedEventObject {
  account: string;
}
export type PausedEvent = TypedEvent<[string], PausedEventObject>;

export type PausedEventFilter = TypedEventFilter<PausedEvent>;

export interface SetGroupEventObject {
  contractAddress: string;
  group: string;
}
export type SetGroupEvent = TypedEvent<[string, string], SetGroupEventObject>;

export type SetGroupEventFilter = TypedEventFilter<SetGroupEvent>;

export interface SetPolicyEventObject {
  policyHash: string;
  enabled: boolean;
}
export type SetPolicyEvent = TypedEvent<
  [string, boolean],
  SetPolicyEventObject
>;

export type SetPolicyEventFilter = TypedEventFilter<SetPolicyEvent>;

export interface UnpausedEventObject {
  account: string;
}
export type UnpausedEvent = TypedEvent<[string], UnpausedEventObject>;

export type UnpausedEventFilter = TypedEventFilter<UnpausedEvent>;

export interface PolicyManagerInternal extends BaseContract {
  contractName: "PolicyManagerInternal";

  connect(signerOrProvider: Signer | Provider | string): this;
  attach(addressOrName: string): this;
  deployed(): Promise<this>;

  interface: PolicyManagerInternalInterface;

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
    CHECK_EXACT_VALUE_FLAG(overrides?: CallOverrides): Promise<[BigNumber]>;

    CHECK_MAX_CHANGE_FLAG(overrides?: CallOverrides): Promise<[BigNumber]>;

    CHECK_MAX_PCT_CHANGE_FLAG(overrides?: CallOverrides): Promise<[BigNumber]>;

    CHECK_MAX_VALUE_FLAG(overrides?: CallOverrides): Promise<[BigNumber]>;

    CHECK_MIN_CHANGE_FLAG(overrides?: CallOverrides): Promise<[BigNumber]>;

    CHECK_MIN_PCT_CHANGE_FLAG(overrides?: CallOverrides): Promise<[BigNumber]>;

    CHECK_MIN_VALUE_FLAG(overrides?: CallOverrides): Promise<[BigNumber]>;

    acl(overrides?: CallOverrides): Promise<[string]>;

    "checkPolicy(address,string,uint256,uint256)"(
      contractAddress: PromiseOrValue<string>,
      paramName: PromiseOrValue<string>,
      oldValue: PromiseOrValue<BigNumberish>,
      newValue: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    "checkPolicy(bytes32,uint256,uint256)"(
      policyHash: PromiseOrValue<BytesLike>,
      oldValue: PromiseOrValue<BigNumberish>,
      newValue: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    controller(overrides?: CallOverrides): Promise<[string]>;

    disablePolicy(
      policyHash: PromiseOrValue<BytesLike>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    getGroup(
      contractAddress: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<[string]>;

    getPolicy(
      policyHash: PromiseOrValue<BytesLike>,
      overrides?: CallOverrides
    ): Promise<[PolicyStructOutput]>;

    pause(
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    paused(overrides?: CallOverrides): Promise<[boolean]>;

    setController(
      newController: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    setGroup(
      contractAddress: PromiseOrValue<string>,
      group: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    setPolicy(
      policyHash: PromiseOrValue<BytesLike>,
      initialPolicy: PolicyStruct,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    unpause(
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;
  };

  CHECK_EXACT_VALUE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

  CHECK_MAX_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

  CHECK_MAX_PCT_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

  CHECK_MAX_VALUE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

  CHECK_MIN_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

  CHECK_MIN_PCT_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

  CHECK_MIN_VALUE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

  acl(overrides?: CallOverrides): Promise<string>;

  "checkPolicy(address,string,uint256,uint256)"(
    contractAddress: PromiseOrValue<string>,
    paramName: PromiseOrValue<string>,
    oldValue: PromiseOrValue<BigNumberish>,
    newValue: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  "checkPolicy(bytes32,uint256,uint256)"(
    policyHash: PromiseOrValue<BytesLike>,
    oldValue: PromiseOrValue<BigNumberish>,
    newValue: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  controller(overrides?: CallOverrides): Promise<string>;

  disablePolicy(
    policyHash: PromiseOrValue<BytesLike>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  getGroup(
    contractAddress: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<string>;

  getPolicy(
    policyHash: PromiseOrValue<BytesLike>,
    overrides?: CallOverrides
  ): Promise<PolicyStructOutput>;

  pause(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  paused(overrides?: CallOverrides): Promise<boolean>;

  setController(
    newController: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  setGroup(
    contractAddress: PromiseOrValue<string>,
    group: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  setPolicy(
    policyHash: PromiseOrValue<BytesLike>,
    initialPolicy: PolicyStruct,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  unpause(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  callStatic: {
    CHECK_EXACT_VALUE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MAX_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MAX_PCT_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MAX_VALUE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MIN_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MIN_PCT_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MIN_VALUE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    acl(overrides?: CallOverrides): Promise<string>;

    "checkPolicy(address,string,uint256,uint256)"(
      contractAddress: PromiseOrValue<string>,
      paramName: PromiseOrValue<string>,
      oldValue: PromiseOrValue<BigNumberish>,
      newValue: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<boolean>;

    "checkPolicy(bytes32,uint256,uint256)"(
      policyHash: PromiseOrValue<BytesLike>,
      oldValue: PromiseOrValue<BigNumberish>,
      newValue: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<boolean>;

    controller(overrides?: CallOverrides): Promise<string>;

    disablePolicy(
      policyHash: PromiseOrValue<BytesLike>,
      overrides?: CallOverrides
    ): Promise<void>;

    getGroup(
      contractAddress: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<string>;

    getPolicy(
      policyHash: PromiseOrValue<BytesLike>,
      overrides?: CallOverrides
    ): Promise<PolicyStructOutput>;

    pause(overrides?: CallOverrides): Promise<void>;

    paused(overrides?: CallOverrides): Promise<boolean>;

    setController(
      newController: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    setGroup(
      contractAddress: PromiseOrValue<string>,
      group: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    setPolicy(
      policyHash: PromiseOrValue<BytesLike>,
      initialPolicy: PolicyStruct,
      overrides?: CallOverrides
    ): Promise<void>;

    unpause(overrides?: CallOverrides): Promise<void>;
  };

  filters: {
    "NewController(address)"(
      newController?: PromiseOrValue<string> | null
    ): NewControllerEventFilter;
    NewController(
      newController?: PromiseOrValue<string> | null
    ): NewControllerEventFilter;

    "Paused(address)"(account?: null): PausedEventFilter;
    Paused(account?: null): PausedEventFilter;

    "SetGroup(address,string)"(
      contractAddress?: PromiseOrValue<string> | null,
      group?: PromiseOrValue<string> | null
    ): SetGroupEventFilter;
    SetGroup(
      contractAddress?: PromiseOrValue<string> | null,
      group?: PromiseOrValue<string> | null
    ): SetGroupEventFilter;

    "SetPolicy(bytes32,bool)"(
      policyHash?: PromiseOrValue<BytesLike> | null,
      enabled?: null
    ): SetPolicyEventFilter;
    SetPolicy(
      policyHash?: PromiseOrValue<BytesLike> | null,
      enabled?: null
    ): SetPolicyEventFilter;

    "Unpaused(address)"(account?: null): UnpausedEventFilter;
    Unpaused(account?: null): UnpausedEventFilter;
  };

  estimateGas: {
    CHECK_EXACT_VALUE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MAX_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MAX_PCT_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MAX_VALUE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MIN_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MIN_PCT_CHANGE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    CHECK_MIN_VALUE_FLAG(overrides?: CallOverrides): Promise<BigNumber>;

    acl(overrides?: CallOverrides): Promise<BigNumber>;

    "checkPolicy(address,string,uint256,uint256)"(
      contractAddress: PromiseOrValue<string>,
      paramName: PromiseOrValue<string>,
      oldValue: PromiseOrValue<BigNumberish>,
      newValue: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    "checkPolicy(bytes32,uint256,uint256)"(
      policyHash: PromiseOrValue<BytesLike>,
      oldValue: PromiseOrValue<BigNumberish>,
      newValue: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    controller(overrides?: CallOverrides): Promise<BigNumber>;

    disablePolicy(
      policyHash: PromiseOrValue<BytesLike>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    getGroup(
      contractAddress: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    getPolicy(
      policyHash: PromiseOrValue<BytesLike>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    pause(
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    paused(overrides?: CallOverrides): Promise<BigNumber>;

    setController(
      newController: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    setGroup(
      contractAddress: PromiseOrValue<string>,
      group: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    setPolicy(
      policyHash: PromiseOrValue<BytesLike>,
      initialPolicy: PolicyStruct,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    unpause(
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;
  };

  populateTransaction: {
    CHECK_EXACT_VALUE_FLAG(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    CHECK_MAX_CHANGE_FLAG(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    CHECK_MAX_PCT_CHANGE_FLAG(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    CHECK_MAX_VALUE_FLAG(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    CHECK_MIN_CHANGE_FLAG(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    CHECK_MIN_PCT_CHANGE_FLAG(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    CHECK_MIN_VALUE_FLAG(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    acl(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    "checkPolicy(address,string,uint256,uint256)"(
      contractAddress: PromiseOrValue<string>,
      paramName: PromiseOrValue<string>,
      oldValue: PromiseOrValue<BigNumberish>,
      newValue: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    "checkPolicy(bytes32,uint256,uint256)"(
      policyHash: PromiseOrValue<BytesLike>,
      oldValue: PromiseOrValue<BigNumberish>,
      newValue: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    controller(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    disablePolicy(
      policyHash: PromiseOrValue<BytesLike>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    getGroup(
      contractAddress: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    getPolicy(
      policyHash: PromiseOrValue<BytesLike>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    pause(
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    paused(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    setController(
      newController: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    setGroup(
      contractAddress: PromiseOrValue<string>,
      group: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    setPolicy(
      policyHash: PromiseOrValue<BytesLike>,
      initialPolicy: PolicyStruct,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    unpause(
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;
  };
}
