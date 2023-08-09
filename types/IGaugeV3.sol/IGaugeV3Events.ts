/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import type { BaseContract, BigNumber, Signer, utils } from "ethers";
import type { EventFragment } from "@ethersproject/abi";
import type { Listener, Provider } from "@ethersproject/providers";
import type {
  TypedEventFilter,
  TypedEvent,
  TypedListener,
  OnEvent,
  PromiseOrValue,
} from "../common";

export interface IGaugeV3EventsInterface extends utils.Interface {
  functions: {};

  events: {
    "AddQuotaToken(address,uint16,uint16)": EventFragment;
    "SetFrozenEpoch(bool)": EventFragment;
    "SetQuotaTokenParams(address,uint16,uint16)": EventFragment;
    "Unvote(address,address,uint96,bool)": EventFragment;
    "UpdateEpoch(uint16)": EventFragment;
    "Vote(address,address,uint96,bool)": EventFragment;
  };

  getEvent(nameOrSignatureOrTopic: "AddQuotaToken"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "SetFrozenEpoch"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "SetQuotaTokenParams"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "Unvote"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "UpdateEpoch"): EventFragment;
  getEvent(nameOrSignatureOrTopic: "Vote"): EventFragment;
}

export interface AddQuotaTokenEventObject {
  token: string;
  minRate: number;
  maxRate: number;
}
export type AddQuotaTokenEvent = TypedEvent<
  [string, number, number],
  AddQuotaTokenEventObject
>;

export type AddQuotaTokenEventFilter = TypedEventFilter<AddQuotaTokenEvent>;

export interface SetFrozenEpochEventObject {
  status: boolean;
}
export type SetFrozenEpochEvent = TypedEvent<
  [boolean],
  SetFrozenEpochEventObject
>;

export type SetFrozenEpochEventFilter = TypedEventFilter<SetFrozenEpochEvent>;

export interface SetQuotaTokenParamsEventObject {
  token: string;
  minRate: number;
  maxRate: number;
}
export type SetQuotaTokenParamsEvent = TypedEvent<
  [string, number, number],
  SetQuotaTokenParamsEventObject
>;

export type SetQuotaTokenParamsEventFilter =
  TypedEventFilter<SetQuotaTokenParamsEvent>;

export interface UnvoteEventObject {
  user: string;
  token: string;
  votes: BigNumber;
  lpSide: boolean;
}
export type UnvoteEvent = TypedEvent<
  [string, string, BigNumber, boolean],
  UnvoteEventObject
>;

export type UnvoteEventFilter = TypedEventFilter<UnvoteEvent>;

export interface UpdateEpochEventObject {
  epochNow: number;
}
export type UpdateEpochEvent = TypedEvent<[number], UpdateEpochEventObject>;

export type UpdateEpochEventFilter = TypedEventFilter<UpdateEpochEvent>;

export interface VoteEventObject {
  user: string;
  token: string;
  votes: BigNumber;
  lpSide: boolean;
}
export type VoteEvent = TypedEvent<
  [string, string, BigNumber, boolean],
  VoteEventObject
>;

export type VoteEventFilter = TypedEventFilter<VoteEvent>;

export interface IGaugeV3Events extends BaseContract {
  contractName: "IGaugeV3Events";

  connect(signerOrProvider: Signer | Provider | string): this;
  attach(addressOrName: string): this;
  deployed(): Promise<this>;

  interface: IGaugeV3EventsInterface;

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

  functions: {};

  callStatic: {};

  filters: {
    "AddQuotaToken(address,uint16,uint16)"(
      token?: PromiseOrValue<string> | null,
      minRate?: null,
      maxRate?: null
    ): AddQuotaTokenEventFilter;
    AddQuotaToken(
      token?: PromiseOrValue<string> | null,
      minRate?: null,
      maxRate?: null
    ): AddQuotaTokenEventFilter;

    "SetFrozenEpoch(bool)"(status?: null): SetFrozenEpochEventFilter;
    SetFrozenEpoch(status?: null): SetFrozenEpochEventFilter;

    "SetQuotaTokenParams(address,uint16,uint16)"(
      token?: PromiseOrValue<string> | null,
      minRate?: null,
      maxRate?: null
    ): SetQuotaTokenParamsEventFilter;
    SetQuotaTokenParams(
      token?: PromiseOrValue<string> | null,
      minRate?: null,
      maxRate?: null
    ): SetQuotaTokenParamsEventFilter;

    "Unvote(address,address,uint96,bool)"(
      user?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      votes?: null,
      lpSide?: null
    ): UnvoteEventFilter;
    Unvote(
      user?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      votes?: null,
      lpSide?: null
    ): UnvoteEventFilter;

    "UpdateEpoch(uint16)"(epochNow?: null): UpdateEpochEventFilter;
    UpdateEpoch(epochNow?: null): UpdateEpochEventFilter;

    "Vote(address,address,uint96,bool)"(
      user?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      votes?: null,
      lpSide?: null
    ): VoteEventFilter;
    Vote(
      user?: PromiseOrValue<string> | null,
      token?: PromiseOrValue<string> | null,
      votes?: null,
      lpSide?: null
    ): VoteEventFilter;
  };

  estimateGas: {};

  populateTransaction: {};
}
