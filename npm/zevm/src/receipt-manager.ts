import { bytesToHex, concatBytes, type PrefixedHexString } from "./util.js";

export type DbType =
  | "Receipts"
  | "TxHash"
  | "SkeletonBlock"
  | "SkeletonBlockHashToNumber"
  | "SkeletonStatus"
  | "SkeletonUnfinalizedBlockByHash"
  | "Preimage";

export interface MetaDBManagerOptions {
  cache: Map<PrefixedHexString, Uint8Array>;
}

export type MapDb = {
  _cache: Map<PrefixedHexString, Uint8Array>;
  put(type: DbType, hash: Uint8Array, value: Uint8Array): Promise<void>;
  get(type: DbType, hash: Uint8Array): Promise<Uint8Array | null>;
  delete(type: DbType, hash: Uint8Array): Promise<void>;
  deepCopy(): MapDb;
};

export const typeToId: Record<DbType, number> = {
  Receipts: 0,
  TxHash: 1,
  SkeletonBlock: 2,
  SkeletonBlockHashToNumber: 3,
  SkeletonStatus: 4,
  SkeletonUnfinalizedBlockByHash: 5,
  Preimage: 6,
};

function dbKey(type: DbType, key: Uint8Array): PrefixedHexString {
  return bytesToHex(concatBytes(Uint8Array.of(typeToId[type]), key));
}

export function createMapDb({ cache }: MetaDBManagerOptions): MapDb {
  return {
    _cache: cache,
    put(type, hash, value) {
      cache.set(dbKey(type, hash), value);
      return Promise.resolve();
    },
    get(type, hash) {
      return Promise.resolve(cache.get(dbKey(type, hash)) ?? null);
    },
    delete(type, hash) {
      cache.delete(dbKey(type, hash));
      return Promise.resolve();
    },
    deepCopy() {
      return createMapDb({ cache: new Map(cache) });
    },
  };
}
