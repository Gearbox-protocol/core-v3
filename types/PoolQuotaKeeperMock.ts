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

export interface PoolQuotaKeeperMockInterface extends utils.Interface {
  functions: {
    "accountQuota()": FunctionFragment;
    "accrueQuotaInterest(address,address[])": FunctionFragment;
    "addCreditManager(address)": FunctionFragment;
    "addQuotaToken(address)": FunctionFragment;
    "call_creditAccount()": FunctionFragment;
    "call_quotaChange()": FunctionFragment;
    "call_setLimitsToZero()": FunctionFragment;
    "call_token()": FunctionFragment;
    "call_tokens(uint256)": FunctionFragment;
    "creditManagers()": FunctionFragment;
    "cumulativeIndex(address)": FunctionFragment;
    "gauge()": FunctionFragment;
    "getQuota(address,address)": FunctionFragment;
    "getQuotaAndOutstandingInterest(address,address)": FunctionFragment;
    "getQuotaRate(address)": FunctionFragment;
    "getTokenQuotaParams(address)": FunctionFragment;
    "isQuotedToken(address)": FunctionFragment;
    "lastQuotaRateUpdate()": FunctionFragment;
    "pool()": FunctionFragment;
    "poolQuotaRevenue()": FunctionFragment;
    "quotedTokens()": FunctionFragment;
    "removeQuotas(address,address[],bool)": FunctionFragment;
    "setGauge(address)": FunctionFragment;
    "setQuotaAndOutstandingInterest(address,uint96,uint128)": FunctionFragment;
    "setTokenLimit(address,uint96)": FunctionFragment;
    "setTokenQuotaIncreaseFee(address,uint16)": FunctionFragment;
    "setUpdateQuotaReturns(uint128,bool,bool)": FunctionFragment;
    "totalQuotaParam()": FunctionFragment;
    "underlying()": FunctionFragment;
    "updateQuota(address,address,int96,uint96,uint96)": FunctionFragment;
    "updateRates()": FunctionFragment;
    "version()": FunctionFragment;
  };

  getFunction(
    nameOrSignatureOrTopic:
      | "accountQuota"
      | "accrueQuotaInterest"
      | "addCreditManager"
      | "addQuotaToken"
      | "call_creditAccount"
      | "call_quotaChange"
      | "call_setLimitsToZero"
      | "call_token"
      | "call_tokens"
      | "creditManagers"
      | "cumulativeIndex"
      | "gauge"
      | "getQuota"
      | "getQuotaAndOutstandingInterest"
      | "getQuotaRate"
      | "getTokenQuotaParams"
      | "isQuotedToken"
      | "lastQuotaRateUpdate"
      | "pool"
      | "poolQuotaRevenue"
      | "quotedTokens"
      | "removeQuotas"
      | "setGauge"
      | "setQuotaAndOutstandingInterest"
      | "setTokenLimit"
      | "setTokenQuotaIncreaseFee"
      | "setUpdateQuotaReturns"
      | "totalQuotaParam"
      | "underlying"
      | "updateQuota"
      | "updateRates"
      | "version"
  ): FunctionFragment;

  encodeFunctionData(
    functionFragment: "accountQuota",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "accrueQuotaInterest",
    values: [PromiseOrValue<string>, PromiseOrValue<string>[]]
  ): string;
  encodeFunctionData(
    functionFragment: "addCreditManager",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "addQuotaToken",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "call_creditAccount",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "call_quotaChange",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "call_setLimitsToZero",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "call_token",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "call_tokens",
    values: [PromiseOrValue<BigNumberish>]
  ): string;
  encodeFunctionData(
    functionFragment: "creditManagers",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "cumulativeIndex",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(functionFragment: "gauge", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "getQuota",
    values: [PromiseOrValue<string>, PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "getQuotaAndOutstandingInterest",
    values: [PromiseOrValue<string>, PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "getQuotaRate",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "getTokenQuotaParams",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "isQuotedToken",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "lastQuotaRateUpdate",
    values?: undefined
  ): string;
  encodeFunctionData(functionFragment: "pool", values?: undefined): string;
  encodeFunctionData(
    functionFragment: "poolQuotaRevenue",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "quotedTokens",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "removeQuotas",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<string>[],
      PromiseOrValue<boolean>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "setGauge",
    values: [PromiseOrValue<string>]
  ): string;
  encodeFunctionData(
    functionFragment: "setQuotaAndOutstandingInterest",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<BigNumberish>,
      PromiseOrValue<BigNumberish>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "setTokenLimit",
    values: [PromiseOrValue<string>, PromiseOrValue<BigNumberish>]
  ): string;
  encodeFunctionData(
    functionFragment: "setTokenQuotaIncreaseFee",
    values: [PromiseOrValue<string>, PromiseOrValue<BigNumberish>]
  ): string;
  encodeFunctionData(
    functionFragment: "setUpdateQuotaReturns",
    values: [
      PromiseOrValue<BigNumberish>,
      PromiseOrValue<boolean>,
      PromiseOrValue<boolean>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "totalQuotaParam",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "underlying",
    values?: undefined
  ): string;
  encodeFunctionData(
    functionFragment: "updateQuota",
    values: [
      PromiseOrValue<string>,
      PromiseOrValue<string>,
      PromiseOrValue<BigNumberish>,
      PromiseOrValue<BigNumberish>,
      PromiseOrValue<BigNumberish>
    ]
  ): string;
  encodeFunctionData(
    functionFragment: "updateRates",
    values?: undefined
  ): string;
  encodeFunctionData(functionFragment: "version", values?: undefined): string;

  decodeFunctionResult(
    functionFragment: "accountQuota",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "accrueQuotaInterest",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "addCreditManager",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "addQuotaToken",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "call_creditAccount",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "call_quotaChange",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "call_setLimitsToZero",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "call_token", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "call_tokens",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "creditManagers",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "cumulativeIndex",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "gauge", data: BytesLike): Result;
  decodeFunctionResult(functionFragment: "getQuota", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "getQuotaAndOutstandingInterest",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "getQuotaRate",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "getTokenQuotaParams",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "isQuotedToken",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "lastQuotaRateUpdate",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "pool", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "poolQuotaRevenue",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "quotedTokens",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "removeQuotas",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "setGauge", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "setQuotaAndOutstandingInterest",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "setTokenLimit",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "setTokenQuotaIncreaseFee",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "setUpdateQuotaReturns",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "totalQuotaParam",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "underlying", data: BytesLike): Result;
  decodeFunctionResult(
    functionFragment: "updateQuota",
    data: BytesLike
  ): Result;
  decodeFunctionResult(
    functionFragment: "updateRates",
    data: BytesLike
  ): Result;
  decodeFunctionResult(functionFragment: "version", data: BytesLike): Result;

  events: {
    "AddCreditManager(address)": EventFragment;
    "AddQuotaToken(address)": EventFragment;
    "SetGauge(address)": EventFragment;
    "SetQuotaIncreaseFee(address,uint16)": EventFragment;
    "SetTokenLimit(address,uint96)": EventFragment;
    "UpdateQuota(address,address,int96)": EventFragment;
    "UpdateTokenQuotaRate(address,uint16)": EventFragment;
  };

  getEvent(nameOrSignatureOrTopic: "AddCreditManager"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "AddQuotaToken"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "SetGauge"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "SetQuotaIncreaseFee"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "SetTokenLimit"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "UpdateQuota"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "UpdateTokenQuotaRate"): EventFragment;
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

export interface AddQuotaTokenEventObject {
  token: string;
}
export type AddQuotaTokenEvent = TypedEvent<[string], AddQuotaTokenEventObject>;

export type AddQuotaTokenEventFilter = TypedEventFilter<AddQuotaTokenEvent>;

export interface SetGaugeEventObject {
  newGauge: string;
}
export type SetGaugeEvent = TypedEvent<[string], SetGaugeEventObject>;

export type SetGaugeEventFilter = TypedEventFilter<SetGaugeEvent>;

export interface SetQuotaIncreaseFeeEventObject {
  token: string;
  fee: number;
}
export type SetQuotaIncreaseFeeEvent = TypedEvent<
  [string, number],
  SetQuotaIncreaseFeeEventObject
>;

export type SetQuotaIncreaseFeeEventFilter =
  TypedEventFilter<SetQuotaIncreaseFeeEvent>;

export interface SetTokenLimitEventObject {
  token: string;
  limit: BigNumber;
}
export type SetTokenLimitEvent = TypedEvent<
  [string, BigNumber],
  SetTokenLimitEventObject
>;

export type SetTokenLimitEventFilter = TypedEventFilter<SetTokenLimitEvent>;

export interface UpdateQuotaEventObject {
  creditAccount: string;
  token: string;
  quotaChange: BigNumber;
}
export type UpdateQuotaEvent = TypedEvent<
  [string, string, BigNumber],
  UpdateQuotaEventObject
>;

export type UpdateQuotaEventFilter = TypedEventFilter<UpdateQuotaEvent>;

export interface UpdateTokenQuotaRateEventObject {
  token: string;
  rate: number;
}
export type UpdateTokenQuotaRateEvent = TypedEvent<
  [string, number],
  UpdateTokenQuotaRateEventObject
>;

export type UpdateTokenQuotaRateEventFilter =
  TypedEventFilter<UpdateTokenQuotaRateEvent>;

export interface PoolQuotaKeeperMock extends BaseContract {
  contractName: "PoolQuotaKeeperMock";

  connect(signerOrProvider: Signer | Provider | string): this;
  attach(addressOrName: string): this;
  deployed(): Promise<this>;

  interface: PoolQuotaKeeperMockInterface;

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
    accountQuota(
      overrides?: CallOverrides
    ): Promise<
      [BigNumber, BigNumber] & {
        quota: BigNumber;
        cumulativeIndexLU: BigNumber;
      }
    >;

    accrueQuotaInterest(
      creditAccount: PromiseOrValue<string>,
      tokens: PromiseOrValue<string>[],
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    addCreditManager(
      _creditManager: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    addQuotaToken(
      token: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    call_creditAccount(overrides?: CallOverrides): Promise<[string]>;

    call_quotaChange(overrides?: CallOverrides): Promise<[BigNumber]>;

    call_setLimitsToZero(overrides?: CallOverrides): Promise<[boolean]>;

    call_token(overrides?: CallOverrides): Promise<[string]>;

    call_tokens(
      arg0: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<[string]>;

    creditManagers(overrides?: CallOverrides): Promise<[string[]]>;

    cumulativeIndex(
      token: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<[BigNumber]>;

    gauge(overrides?: CallOverrides): Promise<[string]>;

    getQuota(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<
      [BigNumber, BigNumber] & {
        quota: BigNumber;
        cumulativeIndexLU: BigNumber;
      }
    >;

    getQuotaAndOutstandingInterest(
      arg0: PromiseOrValue<string>,
      token: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<
      [BigNumber, BigNumber] & { quoted: BigNumber; interest: BigNumber }
    >;

    getQuotaRate(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<[number]>;

    getTokenQuotaParams(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<
      [number, BigNumber, number, BigNumber, BigNumber] & {
        rate: number;
        cumulativeIndexLU: BigNumber;
        quotaIncreaseFee: number;
        totalQuoted: BigNumber;
        limit: BigNumber;
      }
    >;

    isQuotedToken(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<[boolean]>;

    lastQuotaRateUpdate(overrides?: CallOverrides): Promise<[number]>;

    pool(overrides?: CallOverrides): Promise<[string]>;

    poolQuotaRevenue(
      overrides?: CallOverrides
    ): Promise<[BigNumber] & { quotaRevenue: BigNumber }>;

    quotedTokens(overrides?: CallOverrides): Promise<[string[]]>;

    removeQuotas(
      creditAccount: PromiseOrValue<string>,
      tokens: PromiseOrValue<string>[],
      setLimitsToZero: PromiseOrValue<boolean>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    setGauge(
      _gauge: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    setQuotaAndOutstandingInterest(
      token: PromiseOrValue<string>,
      quoted: PromiseOrValue<BigNumberish>,
      outstandingInterest: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    setTokenLimit(
      token: PromiseOrValue<string>,
      limit: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    setTokenQuotaIncreaseFee(
      token: PromiseOrValue<string>,
      fee: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    setUpdateQuotaReturns(
      caQuotaInterestChange: PromiseOrValue<BigNumberish>,
      enableToken: PromiseOrValue<boolean>,
      disableToken: PromiseOrValue<boolean>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    totalQuotaParam(
      overrides?: CallOverrides
    ): Promise<
      [number, BigNumber, number, BigNumber, BigNumber] & {
        rate: number;
        cumulativeIndexLU: BigNumber;
        quotaIncreaseFee: number;
        totalQuoted: BigNumber;
        limit: BigNumber;
      }
    >;

    underlying(overrides?: CallOverrides): Promise<[string]>;

    updateQuota(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      arg2: PromiseOrValue<BigNumberish>,
      arg3: PromiseOrValue<BigNumberish>,
      arg4: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<
      [BigNumber, BigNumber, boolean, boolean] & {
        caQuotaInterestChange: BigNumber;
        fees: BigNumber;
        enableToken: boolean;
        disableToken: boolean;
      }
    >;

    updateRates(
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<ContractTransaction>;

    version(overrides?: CallOverrides): Promise<[BigNumber]>;
  };

  accountQuota(
    overrides?: CallOverrides
  ): Promise<
    [BigNumber, BigNumber] & { quota: BigNumber; cumulativeIndexLU: BigNumber }
  >;

  accrueQuotaInterest(
    creditAccount: PromiseOrValue<string>,
    tokens: PromiseOrValue<string>[],
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  addCreditManager(
    _creditManager: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  addQuotaToken(
    token: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  call_creditAccount(overrides?: CallOverrides): Promise<string>;

  call_quotaChange(overrides?: CallOverrides): Promise<BigNumber>;

  call_setLimitsToZero(overrides?: CallOverrides): Promise<boolean>;

  call_token(overrides?: CallOverrides): Promise<string>;

  call_tokens(
    arg0: PromiseOrValue<BigNumberish>,
    overrides?: CallOverrides
  ): Promise<string>;

  creditManagers(overrides?: CallOverrides): Promise<string[]>;

  cumulativeIndex(
    token: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<BigNumber>;

  gauge(overrides?: CallOverrides): Promise<string>;

  getQuota(
    arg0: PromiseOrValue<string>,
    arg1: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<
    [BigNumber, BigNumber] & { quota: BigNumber; cumulativeIndexLU: BigNumber }
  >;

  getQuotaAndOutstandingInterest(
    arg0: PromiseOrValue<string>,
    token: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<
    [BigNumber, BigNumber] & { quoted: BigNumber; interest: BigNumber }
  >;

  getQuotaRate(
    arg0: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<number>;

  getTokenQuotaParams(
    arg0: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<
    [number, BigNumber, number, BigNumber, BigNumber] & {
      rate: number;
      cumulativeIndexLU: BigNumber;
      quotaIncreaseFee: number;
      totalQuoted: BigNumber;
      limit: BigNumber;
    }
  >;

  isQuotedToken(
    arg0: PromiseOrValue<string>,
    overrides?: CallOverrides
  ): Promise<boolean>;

  lastQuotaRateUpdate(overrides?: CallOverrides): Promise<number>;

  pool(overrides?: CallOverrides): Promise<string>;

  poolQuotaRevenue(overrides?: CallOverrides): Promise<BigNumber>;

  quotedTokens(overrides?: CallOverrides): Promise<string[]>;

  removeQuotas(
    creditAccount: PromiseOrValue<string>,
    tokens: PromiseOrValue<string>[],
    setLimitsToZero: PromiseOrValue<boolean>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  setGauge(
    _gauge: PromiseOrValue<string>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  setQuotaAndOutstandingInterest(
    token: PromiseOrValue<string>,
    quoted: PromiseOrValue<BigNumberish>,
    outstandingInterest: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  setTokenLimit(
    token: PromiseOrValue<string>,
    limit: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  setTokenQuotaIncreaseFee(
    token: PromiseOrValue<string>,
    fee: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  setUpdateQuotaReturns(
    caQuotaInterestChange: PromiseOrValue<BigNumberish>,
    enableToken: PromiseOrValue<boolean>,
    disableToken: PromiseOrValue<boolean>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  totalQuotaParam(
    overrides?: CallOverrides
  ): Promise<
    [number, BigNumber, number, BigNumber, BigNumber] & {
      rate: number;
      cumulativeIndexLU: BigNumber;
      quotaIncreaseFee: number;
      totalQuoted: BigNumber;
      limit: BigNumber;
    }
  >;

  underlying(overrides?: CallOverrides): Promise<string>;

  updateQuota(
    arg0: PromiseOrValue<string>,
    arg1: PromiseOrValue<string>,
    arg2: PromiseOrValue<BigNumberish>,
    arg3: PromiseOrValue<BigNumberish>,
    arg4: PromiseOrValue<BigNumberish>,
    overrides?: CallOverrides
  ): Promise<
    [BigNumber, BigNumber, boolean, boolean] & {
      caQuotaInterestChange: BigNumber;
      fees: BigNumber;
      enableToken: boolean;
      disableToken: boolean;
    }
  >;

  updateRates(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ContractTransaction>;

  version(overrides?: CallOverrides): Promise<BigNumber>;

  callStatic: {
    accountQuota(
      overrides?: CallOverrides
    ): Promise<
      [BigNumber, BigNumber] & {
        quota: BigNumber;
        cumulativeIndexLU: BigNumber;
      }
    >;

    accrueQuotaInterest(
      creditAccount: PromiseOrValue<string>,
      tokens: PromiseOrValue<string>[],
      overrides?: CallOverrides
    ): Promise<void>;

    addCreditManager(
      _creditManager: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    addQuotaToken(
      token: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    call_creditAccount(overrides?: CallOverrides): Promise<string>;

    call_quotaChange(overrides?: CallOverrides): Promise<BigNumber>;

    call_setLimitsToZero(overrides?: CallOverrides): Promise<boolean>;

    call_token(overrides?: CallOverrides): Promise<string>;

    call_tokens(
      arg0: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<string>;

    creditManagers(overrides?: CallOverrides): Promise<string[]>;

    cumulativeIndex(
      token: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    gauge(overrides?: CallOverrides): Promise<string>;

    getQuota(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<
      [BigNumber, BigNumber] & {
        quota: BigNumber;
        cumulativeIndexLU: BigNumber;
      }
    >;

    getQuotaAndOutstandingInterest(
      arg0: PromiseOrValue<string>,
      token: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<
      [BigNumber, BigNumber] & { quoted: BigNumber; interest: BigNumber }
    >;

    getQuotaRate(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<number>;

    getTokenQuotaParams(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<
      [number, BigNumber, number, BigNumber, BigNumber] & {
        rate: number;
        cumulativeIndexLU: BigNumber;
        quotaIncreaseFee: number;
        totalQuoted: BigNumber;
        limit: BigNumber;
      }
    >;

    isQuotedToken(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<boolean>;

    lastQuotaRateUpdate(overrides?: CallOverrides): Promise<number>;

    pool(overrides?: CallOverrides): Promise<string>;

    poolQuotaRevenue(overrides?: CallOverrides): Promise<BigNumber>;

    quotedTokens(overrides?: CallOverrides): Promise<string[]>;

    removeQuotas(
      creditAccount: PromiseOrValue<string>,
      tokens: PromiseOrValue<string>[],
      setLimitsToZero: PromiseOrValue<boolean>,
      overrides?: CallOverrides
    ): Promise<void>;

    setGauge(
      _gauge: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<void>;

    setQuotaAndOutstandingInterest(
      token: PromiseOrValue<string>,
      quoted: PromiseOrValue<BigNumberish>,
      outstandingInterest: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<void>;

    setTokenLimit(
      token: PromiseOrValue<string>,
      limit: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<void>;

    setTokenQuotaIncreaseFee(
      token: PromiseOrValue<string>,
      fee: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<void>;

    setUpdateQuotaReturns(
      caQuotaInterestChange: PromiseOrValue<BigNumberish>,
      enableToken: PromiseOrValue<boolean>,
      disableToken: PromiseOrValue<boolean>,
      overrides?: CallOverrides
    ): Promise<void>;

    totalQuotaParam(
      overrides?: CallOverrides
    ): Promise<
      [number, BigNumber, number, BigNumber, BigNumber] & {
        rate: number;
        cumulativeIndexLU: BigNumber;
        quotaIncreaseFee: number;
        totalQuoted: BigNumber;
        limit: BigNumber;
      }
    >;

    underlying(overrides?: CallOverrides): Promise<string>;

    updateQuota(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      arg2: PromiseOrValue<BigNumberish>,
      arg3: PromiseOrValue<BigNumberish>,
      arg4: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<
      [BigNumber, BigNumber, boolean, boolean] & {
        caQuotaInterestChange: BigNumber;
        fees: BigNumber;
        enableToken: boolean;
        disableToken: boolean;
      }
    >;

    updateRates(overrides?: CallOverrides): Promise<void>;

    version(overrides?: CallOverrides): Promise<BigNumber>;
  };

  filters: {
    "AddCreditManager(address)"(
      creditManager?: PromiseOrValue<string> | null
    ): AddCreditManagerEventFilter;
    AddCreditManager(
      creditManager?: PromiseOrValue<string> | null
    ): AddCreditManagerEventFilter;

    "AddQuotaToken(address)"(
      token?: PromiseOrValue<string> | null
    ): AddQuotaTokenEventFilter;
    AddQuotaToken(
      token?: PromiseOrValue<string> | null
    ): AddQuotaTokenEventFilter;

    "SetGauge(address)"(
      newGauge?: PromiseOrValue<string> | null
    ): SetGaugeEventFilter;
    SetGauge(newGauge?: PromiseOrValue<string> | null): SetGaugeEventFilter;

    "SetQuotaIncreaseFee(address,uint16)"(
      token?: PromiseOrValue<string> | null,
      fee?: null
    ): SetQuotaIncreaseFeeEventFilter;
    SetQuotaIncreaseFee(
      token?: PromiseOrValue<string> | null,
      fee?: null
    ): SetQuotaIncreaseFeeEventFilter;

    "SetTokenLimit(address,uint96)"(
      token?: PromiseOrValue<string> | null,
      limit?: null
    ): SetTokenLimitEventFilter;
    SetTokenLimit(
      token?: PromiseOrValue<string> | null,
      limit?: null
    ): SetTokenLimitEventFilter;

    "UpdateQuota(address,address,int96)"(
      creditAccount?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      quotaChange?: null
    ): UpdateQuotaEventFilter;
    UpdateQuota(
      creditAccount?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      quotaChange?: null
    ): UpdateQuotaEventFilter;

    "UpdateTokenQuotaRate(address,uint16)"(
      token?: PromiseOrValue<string> | null,
      rate?: null
    ): UpdateTokenQuotaRateEventFilter;
    UpdateTokenQuotaRate(
      token?: PromiseOrValue<string> | null,
      rate?: null
    ): UpdateTokenQuotaRateEventFilter;
  };

  estimateGas: {
    accountQuota(overrides?: CallOverrides): Promise<BigNumber>;

    accrueQuotaInterest(
      creditAccount: PromiseOrValue<string>,
      tokens: PromiseOrValue<string>[],
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    addCreditManager(
      _creditManager: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    addQuotaToken(
      token: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    call_creditAccount(overrides?: CallOverrides): Promise<BigNumber>;

    call_quotaChange(overrides?: CallOverrides): Promise<BigNumber>;

    call_setLimitsToZero(overrides?: CallOverrides): Promise<BigNumber>;

    call_token(overrides?: CallOverrides): Promise<BigNumber>;

    call_tokens(
      arg0: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    creditManagers(overrides?: CallOverrides): Promise<BigNumber>;

    cumulativeIndex(
      token: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    gauge(overrides?: CallOverrides): Promise<BigNumber>;

    getQuota(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    getQuotaAndOutstandingInterest(
      arg0: PromiseOrValue<string>,
      token: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    getQuotaRate(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    getTokenQuotaParams(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    isQuotedToken(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    lastQuotaRateUpdate(overrides?: CallOverrides): Promise<BigNumber>;

    pool(overrides?: CallOverrides): Promise<BigNumber>;

    poolQuotaRevenue(overrides?: CallOverrides): Promise<BigNumber>;

    quotedTokens(overrides?: CallOverrides): Promise<BigNumber>;

    removeQuotas(
      creditAccount: PromiseOrValue<string>,
      tokens: PromiseOrValue<string>[],
      setLimitsToZero: PromiseOrValue<boolean>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    setGauge(
      _gauge: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    setQuotaAndOutstandingInterest(
      token: PromiseOrValue<string>,
      quoted: PromiseOrValue<BigNumberish>,
      outstandingInterest: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    setTokenLimit(
      token: PromiseOrValue<string>,
      limit: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    setTokenQuotaIncreaseFee(
      token: PromiseOrValue<string>,
      fee: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    setUpdateQuotaReturns(
      caQuotaInterestChange: PromiseOrValue<BigNumberish>,
      enableToken: PromiseOrValue<boolean>,
      disableToken: PromiseOrValue<boolean>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    totalQuotaParam(overrides?: CallOverrides): Promise<BigNumber>;

    underlying(overrides?: CallOverrides): Promise<BigNumber>;

    updateQuota(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      arg2: PromiseOrValue<BigNumberish>,
      arg3: PromiseOrValue<BigNumberish>,
      arg4: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<BigNumber>;

    updateRates(
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<BigNumber>;

    version(overrides?: CallOverrides): Promise<BigNumber>;
  };

  populateTransaction: {
    accountQuota(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    accrueQuotaInterest(
      creditAccount: PromiseOrValue<string>,
      tokens: PromiseOrValue<string>[],
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    addCreditManager(
      _creditManager: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    addQuotaToken(
      token: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    call_creditAccount(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    call_quotaChange(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    call_setLimitsToZero(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    call_token(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    call_tokens(
      arg0: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    creditManagers(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    cumulativeIndex(
      token: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    gauge(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    getQuota(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    getQuotaAndOutstandingInterest(
      arg0: PromiseOrValue<string>,
      token: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    getQuotaRate(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    getTokenQuotaParams(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    isQuotedToken(
      arg0: PromiseOrValue<string>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    lastQuotaRateUpdate(
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    pool(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    poolQuotaRevenue(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    quotedTokens(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    removeQuotas(
      creditAccount: PromiseOrValue<string>,
      tokens: PromiseOrValue<string>[],
      setLimitsToZero: PromiseOrValue<boolean>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    setGauge(
      _gauge: PromiseOrValue<string>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    setQuotaAndOutstandingInterest(
      token: PromiseOrValue<string>,
      quoted: PromiseOrValue<BigNumberish>,
      outstandingInterest: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    setTokenLimit(
      token: PromiseOrValue<string>,
      limit: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    setTokenQuotaIncreaseFee(
      token: PromiseOrValue<string>,
      fee: PromiseOrValue<BigNumberish>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    setUpdateQuotaReturns(
      caQuotaInterestChange: PromiseOrValue<BigNumberish>,
      enableToken: PromiseOrValue<boolean>,
      disableToken: PromiseOrValue<boolean>,
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    totalQuotaParam(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    underlying(overrides?: CallOverrides): Promise<PopulatedTransaction>;

    updateQuota(
      arg0: PromiseOrValue<string>,
      arg1: PromiseOrValue<string>,
      arg2: PromiseOrValue<BigNumberish>,
      arg3: PromiseOrValue<BigNumberish>,
      arg4: PromiseOrValue<BigNumberish>,
      overrides?: CallOverrides
    ): Promise<PopulatedTransaction>;

    updateRates(
      overrides?: Overrides & { from?: PromiseOrValue<string> }
    ): Promise<PopulatedTransaction>;

    version(overrides?: CallOverrides): Promise<PopulatedTransaction>;
  };
}