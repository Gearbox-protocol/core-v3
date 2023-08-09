/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import { Signer, utils, Contract, ContractFactory, Overrides } from "ethers";
import type { Provider, TransactionRequest } from "@ethersproject/providers";
import type { PromiseOrValue } from "../../common";
import type {
  ERC20ApproveRestrictedFalse,
  ERC20ApproveRestrictedFalseInterface,
} from "../../ERC20ApproveRestricted.sol/ERC20ApproveRestrictedFalse";

const _abi = [
  {
    inputs: [],
    stateMutability: "nonpayable",
    type: "constructor",
  },
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
    inputs: [
      {
        internalType: "address",
        name: "owner",
        type: "address",
      },
      {
        internalType: "address",
        name: "spender",
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
        name: "user",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "amount",
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
        name: "account",
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
    inputs: [
      {
        internalType: "address",
        name: "spender",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "subtractedValue",
        type: "uint256",
      },
    ],
    name: "decreaseAllowance",
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
        name: "spender",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "addedValue",
        type: "uint256",
      },
    ],
    name: "increaseAllowance",
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
    name: "renounceOwnership",
    outputs: [],
    stateMutability: "nonpayable",
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
        name: "to",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "amount",
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
        name: "from",
        type: "address",
      },
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
  "0x60806040523480156200001157600080fd5b506040805160208082018352600080835283519182019093529182529060036200003c838262000169565b5060046200004b828262000169565b50505062000068620000626200006e60201b60201c565b62000072565b62000235565b3390565b600580546001600160a01b038381166001600160a01b0319831681179093556040519116919082907f8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e090600090a35050565b634e487b7160e01b600052604160045260246000fd5b600181811c90821680620000ef57607f821691505b6020821081036200011057634e487b7160e01b600052602260045260246000fd5b50919050565b601f8211156200016457600081815260208120601f850160051c810160208610156200013f5750805b601f850160051c820191505b8181101562000160578281556001016200014b565b5050505b505050565b81516001600160401b03811115620001855762000185620000c4565b6200019d81620001968454620000da565b8462000116565b602080601f831160018114620001d55760008415620001bc5750858301515b600019600386901b1c1916600185901b17855562000160565b600085815260208120601f198616915b828110156200020657888601518255948401946001909101908401620001e5565b5085821015620002255787850151600019600388901b60f8161c191681555b5050505050600190811b01905550565b610d9480620002456000396000f3fe608060405234801561001057600080fd5b50600436106100ea5760003560e01c8063715018a61161008c578063a457c2d711610066578063a457c2d7146101e7578063a9059cbb146101fa578063dd62ed3e1461020d578063f2fde38b1461025357600080fd5b8063715018a6146101ad5780638da5cb5b146101b757806395d89b41146101df57600080fd5b806323b872dd116100c857806323b872dd14610142578063313ce56714610155578063395093511461016457806370a082311461017757600080fd5b806306fdde03146100ef578063095ea7b31461010d57806318160ddd14610130575b600080fd5b6100f7610266565b6040516101049190610b81565b60405180910390f35b61012061011b366004610c16565b6102f8565b6040519015158152602001610104565b6002545b604051908152602001610104565b610120610150366004610c40565b610358565b60405160128152602001610104565b610120610172366004610c16565b61037c565b610134610185366004610c7c565b73ffffffffffffffffffffffffffffffffffffffff1660009081526020819052604090205490565b6101b56103d2565b005b60055460405173ffffffffffffffffffffffffffffffffffffffff9091168152602001610104565b6100f76103e6565b6101206101f5366004610c16565b6103f5565b610120610208366004610c16565b6104cb565b61013461021b366004610c9e565b73ffffffffffffffffffffffffffffffffffffffff918216600090815260016020908152604080832093909416825291909152205490565b6101b5610261366004610c7c565b6104d9565b60606003805461027590610cd1565b80601f01602080910402602001604051908101604052809291908181526020018280546102a190610cd1565b80156102ee5780601f106102c3576101008083540402835291602001916102ee565b820191906000526020600020905b8154815290600101906020018083116102d157829003601f168201915b5050505050905090565b33600090815260016020908152604080832073ffffffffffffffffffffffffffffffffffffffff861684529091528120548110801561033657508115155b1561034357506000610352565b61034e338484610590565b5060015b92915050565b600033610366858285610743565b61037185858561081a565b506001949350505050565b33600081815260016020908152604080832073ffffffffffffffffffffffffffffffffffffffff871684529091528120549091906103c890829086906103c3908790610d24565b610590565b5060019392505050565b6103da610a89565b6103e46000610b0a565b565b60606004805461027590610cd1565b33600081815260016020908152604080832073ffffffffffffffffffffffffffffffffffffffff87168452909152812054909190838110156104be576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152602560248201527f45524332303a2064656372656173656420616c6c6f77616e63652062656c6f7760448201527f207a65726f00000000000000000000000000000000000000000000000000000060648201526084015b60405180910390fd5b6103718286868403610590565b6000336103c881858561081a565b6104e1610a89565b73ffffffffffffffffffffffffffffffffffffffff8116610584576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152602660248201527f4f776e61626c653a206e6577206f776e657220697320746865207a65726f206160448201527f646472657373000000000000000000000000000000000000000000000000000060648201526084016104b5565b61058d81610b0a565b50565b73ffffffffffffffffffffffffffffffffffffffff8316610632576040517f08c379a0000000000000000000000000000000000000000000000000000000008152602060048201526024808201527f45524332303a20617070726f76652066726f6d20746865207a65726f2061646460448201527f726573730000000000000000000000000000000000000000000000000000000060648201526084016104b5565b73ffffffffffffffffffffffffffffffffffffffff82166106d5576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152602260248201527f45524332303a20617070726f766520746f20746865207a65726f20616464726560448201527f737300000000000000000000000000000000000000000000000000000000000060648201526084016104b5565b73ffffffffffffffffffffffffffffffffffffffff83811660008181526001602090815260408083209487168084529482529182902085905590518481527f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925910160405180910390a3505050565b73ffffffffffffffffffffffffffffffffffffffff8381166000908152600160209081526040808320938616835292905220547fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff81146108145781811015610807576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601d60248201527f45524332303a20696e73756666696369656e7420616c6c6f77616e636500000060448201526064016104b5565b6108148484848403610590565b50505050565b73ffffffffffffffffffffffffffffffffffffffff83166108bd576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152602560248201527f45524332303a207472616e736665722066726f6d20746865207a65726f20616460448201527f647265737300000000000000000000000000000000000000000000000000000060648201526084016104b5565b73ffffffffffffffffffffffffffffffffffffffff8216610960576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152602360248201527f45524332303a207472616e7366657220746f20746865207a65726f206164647260448201527f657373000000000000000000000000000000000000000000000000000000000060648201526084016104b5565b73ffffffffffffffffffffffffffffffffffffffff831660009081526020819052604090205481811015610a16576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152602660248201527f45524332303a207472616e7366657220616d6f756e742065786365656473206260448201527f616c616e6365000000000000000000000000000000000000000000000000000060648201526084016104b5565b73ffffffffffffffffffffffffffffffffffffffff848116600081815260208181526040808320878703905593871680835291849020805487019055925185815290927fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef910160405180910390a3610814565b60055473ffffffffffffffffffffffffffffffffffffffff1633146103e4576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820181905260248201527f4f776e61626c653a2063616c6c6572206973206e6f7420746865206f776e657260448201526064016104b5565b6005805473ffffffffffffffffffffffffffffffffffffffff8381167fffffffffffffffffffffffff0000000000000000000000000000000000000000831681179093556040519116919082907f8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e090600090a35050565b600060208083528351808285015260005b81811015610bae57858101830151858201604001528201610b92565b5060006040828601015260407fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f8301168501019250505092915050565b803573ffffffffffffffffffffffffffffffffffffffff81168114610c1157600080fd5b919050565b60008060408385031215610c2957600080fd5b610c3283610bed565b946020939093013593505050565b600080600060608486031215610c5557600080fd5b610c5e84610bed565b9250610c6c60208501610bed565b9150604084013590509250925092565b600060208284031215610c8e57600080fd5b610c9782610bed565b9392505050565b60008060408385031215610cb157600080fd5b610cba83610bed565b9150610cc860208401610bed565b90509250929050565b600181811c90821680610ce557607f821691505b602082108103610d1e577f4e487b7100000000000000000000000000000000000000000000000000000000600052602260045260246000fd5b50919050565b80820180821115610352577f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fdfea2646970667358221220e9b7cf9533329459004ed45edd7231093f94903ea4671f744e53ac75d80eeb7b64736f6c63430008110033";

type ERC20ApproveRestrictedFalseConstructorParams =
  | [signer?: Signer]
  | ConstructorParameters<typeof ContractFactory>;

const isSuperArgs = (
  xs: ERC20ApproveRestrictedFalseConstructorParams
): xs is ConstructorParameters<typeof ContractFactory> => xs.length > 1;

export class ERC20ApproveRestrictedFalse__factory extends ContractFactory {
  constructor(...args: ERC20ApproveRestrictedFalseConstructorParams) {
    if (isSuperArgs(args)) {
      super(...args);
    } else {
      super(_abi, _bytecode, args[0]);
    }
    this.contractName = "ERC20ApproveRestrictedFalse";
  }

  override deploy(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<ERC20ApproveRestrictedFalse> {
    return super.deploy(
      overrides || {}
    ) as Promise<ERC20ApproveRestrictedFalse>;
  }
  override getDeployTransaction(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): TransactionRequest {
    return super.getDeployTransaction(overrides || {});
  }
  override attach(address: string): ERC20ApproveRestrictedFalse {
    return super.attach(address) as ERC20ApproveRestrictedFalse;
  }
  override connect(signer: Signer): ERC20ApproveRestrictedFalse__factory {
    return super.connect(signer) as ERC20ApproveRestrictedFalse__factory;
  }
  static readonly contractName: "ERC20ApproveRestrictedFalse";

  public readonly contractName: "ERC20ApproveRestrictedFalse";

  static readonly bytecode = _bytecode;
  static readonly abi = _abi;
  static createInterface(): ERC20ApproveRestrictedFalseInterface {
    return new utils.Interface(_abi) as ERC20ApproveRestrictedFalseInterface;
  }
  static connect(
    address: string,
    signerOrProvider: Signer | Provider
  ): ERC20ApproveRestrictedFalse {
    return new Contract(
      address,
      _abi,
      signerOrProvider
    ) as ERC20ApproveRestrictedFalse;
  }
}