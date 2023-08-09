/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import { Signer, utils, Contract, ContractFactory, Overrides } from "ethers";
import type { Provider, TransactionRequest } from "@ethersproject/providers";
import type { PromiseOrValue } from "../common";
import type { WETHMock, WETHMockInterface } from "../WETHMock";

const _abi = [
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "owner",
        type: "address",
      },
      {
        indexed: true,
        internalType: "address",
        name: "spender",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "value",
        type: "uint256",
      },
    ],
    name: "Approval",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "dst",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "wad",
        type: "uint256",
      },
    ],
    name: "Deposit",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "from",
        type: "address",
      },
      {
        indexed: true,
        internalType: "address",
        name: "to",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "value",
        type: "uint256",
      },
    ],
    name: "Transfer",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "src",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "wad",
        type: "uint256",
      },
    ],
    name: "Withdrawal",
    type: "event",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    name: "allowance",
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
        name: "guy",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "wad",
        type: "uint256",
      },
    ],
    name: "approve",
    outputs: [
      {
        internalType: "bool",
        name: "",
        type: "bool",
      },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "",
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
    inputs: [],
    name: "decimals",
    outputs: [
      {
        internalType: "uint8",
        name: "",
        type: "uint8",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "deposit",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "to",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "amount",
        type: "uint256",
      },
    ],
    name: "mint",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "name",
    outputs: [
      {
        internalType: "string",
        name: "",
        type: "string",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "symbol",
    outputs: [
      {
        internalType: "string",
        name: "",
        type: "string",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "totalSupply",
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
        name: "dst",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "wad",
        type: "uint256",
      },
    ],
    name: "transfer",
    outputs: [
      {
        internalType: "bool",
        name: "",
        type: "bool",
      },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "src",
        type: "address",
      },
      {
        internalType: "address",
        name: "dst",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "wad",
        type: "uint256",
      },
    ],
    name: "transferFrom",
    outputs: [
      {
        internalType: "bool",
        name: "",
        type: "bool",
      },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint256",
        name: "wad",
        type: "uint256",
      },
    ],
    name: "withdraw",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    stateMutability: "payable",
    type: "receive",
  },
] as const;

const _bytecode =
  "0x60c0604052600d60809081526c2bb930b83832b21022ba3432b960991b60a05260009061002c9082610114565b506040805180820190915260048152630ae8aa8960e31b60208201526001906100559082610114565b506002805460ff1916601217905534801561006f57600080fd5b506101d3565b634e487b7160e01b600052604160045260246000fd5b600181811c9082168061009f57607f821691505b6020821081036100bf57634e487b7160e01b600052602260045260246000fd5b50919050565b601f82111561010f57600081815260208120601f850160051c810160208610156100ec5750805b601f850160051c820191505b8181101561010b578281556001016100f8565b5050505b505050565b81516001600160401b0381111561012d5761012d610075565b6101418161013b845461008b565b846100c5565b602080601f831160018114610176576000841561015e5750858301515b600019600386901b1c1916600185901b17855561010b565b600085815260208120601f198616915b828110156101a557888601518255948401946001909101908401610186565b50858210156101c35787850151600019600388901b60f8161c191681555b5050505050600190811b01905550565b610944806101e26000396000f3fe6080604052600436106100cb5760003560e01c806340c10f1911610074578063a9059cbb1161004e578063a9059cbb14610225578063d0e30db014610245578063dd62ed3e1461024d57600080fd5b806340c10f19146101c357806370a08231146101e357806395d89b411461021057600080fd5b806323b872dd116100a557806323b872dd146101575780632e1a7d4d14610177578063313ce5671461019757600080fd5b806306fdde03146100df578063095ea7b31461010a57806318160ddd1461013a57600080fd5b366100da576100d8610285565b005b600080fd5b3480156100eb57600080fd5b506100f46102e0565b6040516101019190610704565b60405180910390f35b34801561011657600080fd5b5061012a610125366004610799565b61036e565b6040519015158152602001610101565b34801561014657600080fd5b50475b604051908152602001610101565b34801561016357600080fd5b5061012a6101723660046107c3565b6103e8565b34801561018357600080fd5b506100d86101923660046107ff565b6105ff565b3480156101a357600080fd5b506002546101b19060ff1681565b60405160ff9091168152602001610101565b3480156101cf57600080fd5b506100d86101de366004610799565b6106a5565b3480156101ef57600080fd5b506101496101fe366004610818565b60036020526000908152604090205481565b34801561021c57600080fd5b506100f46106e3565b34801561023157600080fd5b5061012a610240366004610799565b6106f0565b6100d8610285565b34801561025957600080fd5b50610149610268366004610833565b600460209081526000928352604080842090915290825290205481565b33600090815260036020526040812080543492906102a4908490610895565b909155505060405134815233907fe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c9060200160405180910390a2565b600080546102ed906108a8565b80601f0160208091040260200160405190810160405280929190818152602001828054610319906108a8565b80156103665780601f1061033b57610100808354040283529160200191610366565b820191906000526020600020905b81548152906001019060200180831161034957829003601f168201915b505050505081565b33600081815260046020908152604080832073ffffffffffffffffffffffffffffffffffffffff8716808552925280832085905551919290917f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925906103d69086815260200190565b60405180910390a35060015b92915050565b73ffffffffffffffffffffffffffffffffffffffff831660009081526003602052604081205482111561041a57600080fd5b73ffffffffffffffffffffffffffffffffffffffff84163314801590610490575073ffffffffffffffffffffffffffffffffffffffff841660009081526004602090815260408083203384529091529020547fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff14155b156105185773ffffffffffffffffffffffffffffffffffffffff841660009081526004602090815260408083203384529091529020548211156104d257600080fd5b73ffffffffffffffffffffffffffffffffffffffff84166000908152600460209081526040808320338452909152812080548492906105129084906108fb565b90915550505b73ffffffffffffffffffffffffffffffffffffffff84166000908152600360205260408120805484929061054d9084906108fb565b909155505073ffffffffffffffffffffffffffffffffffffffff831660009081526003602052604081208054849290610587908490610895565b925050819055508273ffffffffffffffffffffffffffffffffffffffff168473ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef846040516105ed91815260200190565b60405180910390a35060019392505050565b3360009081526003602052604090205481111561061b57600080fd5b336000908152600360205260408120805483929061063a9084906108fb565b9091555050604051339082156108fc029083906000818181858888f1935050505015801561066c573d6000803e3d6000fd5b5060405181815233907f7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b659060200160405180910390a250565b73ffffffffffffffffffffffffffffffffffffffff8216600090815260036020526040812080548392906106da908490610895565b90915550505050565b600180546102ed906108a8565b60006106fd3384846103e8565b9392505050565b600060208083528351808285015260005b8181101561073157858101830151858201604001528201610715565b5060006040828601015260407fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f8301168501019250505092915050565b803573ffffffffffffffffffffffffffffffffffffffff8116811461079457600080fd5b919050565b600080604083850312156107ac57600080fd5b6107b583610770565b946020939093013593505050565b6000806000606084860312156107d857600080fd5b6107e184610770565b92506107ef60208501610770565b9150604084013590509250925092565b60006020828403121561081157600080fd5b5035919050565b60006020828403121561082a57600080fd5b6106fd82610770565b6000806040838503121561084657600080fd5b61084f83610770565b915061085d60208401610770565b90509250929050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b808201808211156103e2576103e2610866565b600181811c908216806108bc57607f821691505b6020821081036108f5577f4e487b7100000000000000000000000000000000000000000000000000000000600052602260045260246000fd5b50919050565b818103818111156103e2576103e261086656fea2646970667358221220cab6cf0ddac733ed89831720200e950b9e38f8275f54ec916be85d593ddfc71c64736f6c63430008110033";

type WETHMockConstructorParams =
  | [signer?: Signer]
  | ConstructorParameters<typeof ContractFactory>;

const isSuperArgs = (
  xs: WETHMockConstructorParams
): xs is ConstructorParameters<typeof ContractFactory> => xs.length > 1;

export class WETHMock__factory extends ContractFactory {
  constructor(...args: WETHMockConstructorParams) {
    if (isSuperArgs(args)) {
      super(...args);
    } else {
      super(_abi, _bytecode, args[0]);
    }
    this.contractName = "WETHMock";
  }

  override deploy(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<WETHMock> {
    return super.deploy(overrides || {}) as Promise<WETHMock>;
  }
  override getDeployTransaction(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): TransactionRequest {
    return super.getDeployTransaction(overrides || {});
  }
  override attach(address: string): WETHMock {
    return super.attach(address) as WETHMock;
  }
  override connect(signer: Signer): WETHMock__factory {
    return super.connect(signer) as WETHMock__factory;
  }
  static readonly contractName: "WETHMock";

  public readonly contractName: "WETHMock";

  static readonly bytecode = _bytecode;
  static readonly abi = _abi;
  static createInterface(): WETHMockInterface {
    return new utils.Interface(_abi) as WETHMockInterface;
  }
  static connect(
    address: string,
    signerOrProvider: Signer | Provider
  ): WETHMock {
    return new Contract(address, _abi, signerOrProvider) as WETHMock;
  }
}