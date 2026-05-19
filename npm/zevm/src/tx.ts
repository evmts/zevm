import { keccak_256 } from "@noble/hashes/sha3.js";
import { createFeeMarket1559Tx, type FeeMarket1559Tx, type FeeMarketEIP1559TxData, type TxOptions } from "@ethereumjs/tx";
import type { Address } from "./util.js";

export {
  type AccessList,
  AccessList2930Tx as AccessListEIP2930Transaction,
  type AccessListItem,
  Blob4844Tx as BlobEIP4844Transaction,
  Capability,
  createEOACode7702Tx as createEOACodeEIP7702Tx,
  createEOACode7702TxFromBytesArray as createEOACodeEIP7702TxFromBytesArray,
  createEOACode7702TxFromRLP as createEOACodeEIP7702TxFromRLP,
  createTx as TransactionFactory,
  createTxFromBlockBodyData,
  createTxFromRLP,
  type EIP1559CompatibleTx,
  type EIP4844CompatibleTx,
  EOACode7702Tx as EOACodeEIP7702Transaction,
  type EOACode7702TxData as EOACodeEIP7702TxData,
  FeeMarket1559Tx as FeeMarketEIP1559Transaction,
  isAccessList2930Tx as isAccessListEIP2930Tx,
  isBlob4844Tx as isBlobEIP4844Tx,
  isEOACode7702Tx as isEOACodeEIP7702Tx,
  isFeeMarket1559Tx as isFeeMarketEIP1559Tx,
  isLegacyTx,
  type JSONRPCTx as JsonRpcTx,
  type JSONTx as JsonTx,
  LegacyTx as LegacyTransaction,
  TransactionType,
  type TxData,
  type TxOptions,
  type TypedTransaction,
} from "@ethereumjs/tx";
export * from "@ethereumjs/tx";

export interface ImpersonatedTx extends FeeMarket1559Tx {
  isImpersonated: true;
}

export type ImpersonatedTxData = FeeMarketEIP1559TxData & {
  impersonatedAddress: Address;
};

type ErrorOptionsWithCause = {
  cause?: unknown;
};

export class InternalError extends Error {
  readonly _tag = "InternalError";

  constructor(message = "Internal error occurred.", options: ErrorOptionsWithCause = {}) {
    super(message, options);
    this.name = "InternalError";
  }
}

export class InvalidGasLimitError extends Error {
  readonly _tag = "InvalidGasLimitError";

  constructor(message = "Invalid gas limit.", options: ErrorOptionsWithCause = {}) {
    super(message, options);
    this.name = "InvalidGasLimitError";
  }
}

/**
 * Creates an unsigned EIP-1559 transaction that behaves as if it were signed by
 * `impersonatedAddress`.
 */
export function createImpersonatedTx(txData: ImpersonatedTxData, opts?: TxOptions): ImpersonatedTx {
  let tx: FeeMarket1559Tx;
  try {
    tx = createFeeMarket1559Tx(txData, opts);
  } catch (e) {
    if (!(e instanceof Error)) {
      throw new InternalError("Unknown Error", { cause: e });
    }
    if (e.message.includes("EIP-1559 not enabled on Common")) {
      throw new InternalError(
        "EIP-1559 is not enabled on Common. Tevm currently only supports 1559 and it should be enabled by default",
        { cause: e },
      );
    }
    if (
      e.message.includes("gasLimit cannot exceed MAX_UINT64 (2^64-1)") ||
      e.message.includes("gasLimit * maxFeePerGas cannot exceed MAX_INTEGER (2^256-1)") ||
      e.message.includes("maxFeePerGas cannot be less than maxPriorityFeePerGas (The total must be the larger of the two)")
    ) {
      throw new InvalidGasLimitError(e.message, { cause: e });
    }
    throw new InternalError(e.message, { cause: e });
  }

  return new Proxy(tx, {
    get(target, prop, receiver) {
      if (prop === "isImpersonated") {
        return true;
      }
      if (prop === "hash") {
        return () => {
          try {
            return target.hash();
          } catch {
            return keccak_256(target.getHashedMessageToSign());
          }
        };
      }
      if (prop === "isSigned") {
        return () => true;
      }
      if (prop === "getSenderAddress") {
        return () => txData.impersonatedAddress;
      }
      return Reflect.get(target, prop, receiver);
    },
  }) as ImpersonatedTx;
}
