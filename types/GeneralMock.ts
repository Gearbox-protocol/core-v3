/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import type {
  BaseContract,
  BigNumber,
  BytesLike,
  CallOverrides,
  PopulatedTransaction,
  Signer,
  utils,
} from "ethers";
import type { FunctionFragment, Result } from "@ethersproject/abi";
import type { Listener, Provider } from "@ethersproject/providers";
import type {
  TypedEventFilter,
  TypedEvent,
  TypedListener,
  OnEvent,
} from "./common";

export interface GeneralMockInterface extends utils.Interface {
  functions: {
    "data()": FunctionFragment;
  };

  getFunction(nameOrSignatureOrTopic: "data"): FunctionFragment;

  encodeFunctionData(functionFragment: "data", values?: undefined): string;

  decodeFunctionResult(functionFragment: "data", data: BytesLike): Result;

  events: {};
}

export interface GeneralMock extends BaseContract {
  contractName: "GeneralMock";

  connect(signerOrProvider: Signer | Provider | string): this;
  attach(addressOrName: string): this;
  deployed(): Promise<this>;

  interface: GeneralMockInterface;

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
    data(overrides?: CallOverrides): Promise<[string]>;
  };

  data(overrides?: CallOverrides): Promise<string>;

  callStatic: {
    data(overrides?: CallOverrides): Promise<string>;
  };

  filters: {};

  estimateGas: {
    data(overrides?: CallOverrides): Promise<BigNumber>;
  };

  populateTransaction: {
    data(overrides?: CallOverrides): Promise<PopulatedTransaction>;
  };
}