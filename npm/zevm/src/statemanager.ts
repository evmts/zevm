import { hexToBytes, bytesToUnprefixedHex } from "./util.js";

import type { Account, Address, PrefixedHexString } from "./util.js";

export type CacheType = (typeof CacheType)[keyof typeof CacheType];

export const CacheType = {
  LRU: "lru",
  ORDERED_MAP: "ordered_map",
} as const;

export interface CacheOpts {
  size: number;
  type: CacheType;
}

export interface CachesStateManagerOpts {
  account?: Partial<CacheOpts>;
  code?: Partial<CacheOpts>;
  storage?: Partial<CacheOpts>;
}

export type AccountCacheElement = {
  accountRLP: Uint8Array | undefined;
};

export type DiffStorageCacheMap = Map<string, Uint8Array | undefined>;
export type StorageCacheMap = Map<string, Uint8Array>;

export type StorageProof = {
  key: PrefixedHexString;
  proof: PrefixedHexString[];
  value: PrefixedHexString;
};

export type Proof = {
  address: PrefixedHexString;
  balance: PrefixedHexString;
  codeHash: PrefixedHexString;
  nonce: PrefixedHexString;
  storageHash: PrefixedHexString;
  accountProof: PrefixedHexString[];
  storageProof: StorageProof[];
};

type CacheStats = {
  size: number;
  reads: number;
  hits: number;
  writes: number;
  deletions: number;
};

class SimpleLRUCache<K, V> {
  readonly max: number;
  readonly #map = new Map<K, V>();

  constructor(opts: { max: number }) {
    this.max = opts.max;
  }

  get size(): number {
    return this.#map.size;
  }

  get(key: K): V | undefined {
    const value = this.#map.get(key);
    if (value !== undefined) {
      this.#map.delete(key);
      this.#map.set(key, value);
    }
    return value;
  }

  set(key: K, value: V): void {
    if (this.#map.has(key)) {
      this.#map.delete(key);
    }
    this.#map.set(key, value);
    if (this.#map.size > this.max) {
      const oldestKey = this.#map.keys().next().value as K | undefined;
      if (oldestKey !== undefined) {
        this.#map.delete(oldestKey);
      }
    }
  }

  has(key: K): boolean {
    return this.#map.has(key);
  }

  delete(key: K): boolean {
    return this.#map.delete(key);
  }

  clear(): void {
    this.#map.clear();
  }

  *rkeys(): IterableIterator<K> {
    for (const key of this.#map.keys()) {
      yield key;
    }
  }
}

class SimpleOrderedMap<K, V> {
  readonly #map = new Map<K, V>();

  getElementByKey(key: K): V | undefined {
    return this.#map.get(key);
  }

  setElement(key: K, value: V): void {
    this.#map.set(key, value);
  }

  eraseElementByKey(key: K): void {
    this.#map.delete(key);
  }

  clear(): void {
    this.#map.clear();
  }

  size(): number {
    return this.#map.size;
  }

  forEach(callback: (entry: [K, V], index: number, map: this) => void): void {
    let index = 0;
    for (const entry of this.#map.entries()) {
      callback(entry, index, this);
      index++;
    }
  }
}

class Cache {
  _checkpoints = 0;
  _stats: CacheStats = {
    size: 0,
    reads: 0,
    hits: 0,
    writes: 0,
    deletions: 0,
  };
  protected readonly DEBUG = false;
  _debug(_message: string): void {}
}

export class AccountCache extends Cache {
  _lruCache: SimpleLRUCache<string, AccountCacheElement> | undefined;
  _orderedMapCache: SimpleOrderedMap<string, AccountCacheElement> | undefined;
  _diffCache: Map<string, AccountCacheElement | undefined>[] = [];

  constructor(opts: CacheOpts) {
    super();
    if (opts.type === CacheType.LRU) {
      this._lruCache = new SimpleLRUCache({ max: opts.size });
    } else {
      this._orderedMapCache = new SimpleOrderedMap();
    }
    this._diffCache.push(new Map());
  }

  _saveCachePreState(cacheKeyHex: string): void {
    const diffMap = this._diffCache[this._checkpoints] ?? new Map<string, AccountCacheElement | undefined>();
    this._diffCache[this._checkpoints] = diffMap;
    if (!diffMap.has(cacheKeyHex)) {
      const oldElem = this._lruCache?.get(cacheKeyHex) ?? this._orderedMapCache?.getElementByKey(cacheKeyHex);
      diffMap.set(cacheKeyHex, oldElem);
    }
  }

  put(address: Address, account: Account | undefined, couldBePartialAccount = false): void {
    const addressHex = bytesToUnprefixedHex(address.bytes);
    this._saveCachePreState(addressHex);
    const elem = {
      accountRLP: account !== undefined ? (couldBePartialAccount ? account.serializeWithPartialInfo() : account.serialize()) : undefined,
    };

    if (this._lruCache) {
      this._lruCache.set(addressHex, elem);
    } else {
      this._orderedMapCache!.setElement(addressHex, elem);
    }
    this._stats.writes += 1;
  }

  get(address: Address): AccountCacheElement | undefined {
    const addressHex = bytesToUnprefixedHex(address.bytes);
    const elem = this._lruCache?.get(addressHex) ?? this._orderedMapCache?.getElementByKey(addressHex);
    this._stats.reads += 1;
    if (elem) {
      this._stats.hits += 1;
    }
    return elem;
  }

  del(address: Address): void {
    const addressHex = bytesToUnprefixedHex(address.bytes);
    this._saveCachePreState(addressHex);
    const elem = { accountRLP: undefined };
    if (this._lruCache) {
      this._lruCache.set(addressHex, elem);
    } else {
      this._orderedMapCache!.setElement(addressHex, elem);
    }
    this._stats.deletions += 1;
  }

  flush(): [string, AccountCacheElement][] {
    const diffMap = this._diffCache[this._checkpoints]!;
    const items: [string, AccountCacheElement][] = [];
    for (const [cacheKeyHex] of diffMap.entries()) {
      const elem = this._lruCache?.get(cacheKeyHex) ?? this._orderedMapCache?.getElementByKey(cacheKeyHex);
      if (elem !== undefined) {
        items.push([cacheKeyHex, elem]);
      }
    }
    this._diffCache[this._checkpoints] = new Map();
    return items;
  }

  revert(): void {
    this._checkpoints -= 1;
    const diffMap = this._diffCache.pop()!;
    for (const [addressHex, elem] of diffMap.entries()) {
      if (elem === undefined) {
        if (this._lruCache) {
          this._lruCache.delete(addressHex);
        } else {
          this._orderedMapCache!.eraseElementByKey(addressHex);
        }
      } else if (this._lruCache) {
        this._lruCache.set(addressHex, elem);
      } else {
        this._orderedMapCache!.setElement(addressHex, elem);
      }
    }
  }

  commit(): void {
    this._checkpoints -= 1;
    const diffMap = this._diffCache.pop()!;
    const lowerDiffMap = this._diffCache[this._checkpoints] ?? new Map<string, AccountCacheElement | undefined>();
    this._diffCache[this._checkpoints] = lowerDiffMap;
    for (const [addressHex, elem] of diffMap.entries()) {
      if (!lowerDiffMap.has(addressHex)) {
        lowerDiffMap.set(addressHex, elem);
      }
    }
  }

  checkpoint(): void {
    this._checkpoints += 1;
    this._diffCache.push(new Map());
  }

  size(): number {
    return this._lruCache?.size ?? this._orderedMapCache!.size();
  }

  stats(reset = true): CacheStats {
    const stats = { ...this._stats, size: this.size() };
    if (reset) {
      this._stats = {
        size: 0,
        reads: 0,
        hits: 0,
        writes: 0,
        deletions: 0,
      };
    }
    return stats;
  }

  clear(): void {
    if (this._lruCache) {
      this._lruCache.clear();
    } else {
      this._orderedMapCache!.clear();
    }
  }
}

export class StorageCache extends Cache {
  _lruCache: SimpleLRUCache<string, StorageCacheMap> | undefined;
  _orderedMapCache: SimpleOrderedMap<string, StorageCacheMap> | undefined;
  _diffCache: Map<string, DiffStorageCacheMap>[] = [];

  constructor(opts: CacheOpts) {
    super();
    if (opts.type === CacheType.LRU) {
      this._lruCache = new SimpleLRUCache({ max: opts.size });
    } else {
      this._orderedMapCache = new SimpleOrderedMap();
    }
    this._diffCache.push(new Map());
  }

  _saveCachePreState(addressHex: string, keyHex: string): void {
    const diffMap = this._diffCache[this._checkpoints] ?? new Map<string, DiffStorageCacheMap>();
    this._diffCache[this._checkpoints] = diffMap;
    const diffStorageMap = diffMap.get(addressHex) ?? new Map<string, Uint8Array | undefined>();

    if (!diffStorageMap.has(keyHex)) {
      const oldStorageMap = this._lruCache?.get(addressHex) ?? this._orderedMapCache?.getElementByKey(addressHex);
      diffStorageMap.set(keyHex, oldStorageMap?.get(keyHex));
      diffMap.set(addressHex, diffStorageMap);
    }
  }

  put(address: Address, key: Uint8Array, value: Uint8Array): void {
    const addressHex = bytesToUnprefixedHex(address.bytes);
    const keyHex = bytesToUnprefixedHex(key);
    this._saveCachePreState(addressHex, keyHex);

    if (this._lruCache) {
      const storageMap = this._lruCache.get(addressHex) ?? new Map<string, Uint8Array>();
      storageMap.set(keyHex, value);
      this._lruCache.set(addressHex, storageMap);
    } else {
      const storageMap = this._orderedMapCache!.getElementByKey(addressHex) ?? new Map<string, Uint8Array>();
      storageMap.set(keyHex, value);
      this._orderedMapCache!.setElement(addressHex, storageMap);
    }
    this._stats.writes += 1;
  }

  get(address: Address, key: Uint8Array): Uint8Array | undefined {
    const addressHex = bytesToUnprefixedHex(address.bytes);
    const keyHex = bytesToUnprefixedHex(key);
    const storageMap = this._lruCache?.get(addressHex) ?? this._orderedMapCache?.getElementByKey(addressHex);
    this._stats.reads += 1;
    if (storageMap) {
      this._stats.hits += 1;
      return storageMap.get(keyHex);
    }
    return undefined;
  }

  del(address: Address, key: Uint8Array): void {
    const addressHex = bytesToUnprefixedHex(address.bytes);
    const keyHex = bytesToUnprefixedHex(key);
    this._saveCachePreState(addressHex, keyHex);

    if (this._lruCache) {
      const storageMap = this._lruCache.get(addressHex) ?? new Map<string, Uint8Array>();
      storageMap.set(keyHex, hexToBytes("0x80"));
      this._lruCache.set(addressHex, storageMap);
    } else {
      const storageMap = this._orderedMapCache!.getElementByKey(addressHex) ?? new Map<string, Uint8Array>();
      storageMap.set(keyHex, hexToBytes("0x80"));
      this._orderedMapCache!.setElement(addressHex, storageMap);
    }
    this._stats.deletions += 1;
  }

  clearStorage(address: Address): void {
    const addressHex = bytesToUnprefixedHex(address.bytes);
    if (this._lruCache) {
      this._lruCache.set(addressHex, new Map());
    } else {
      this._orderedMapCache!.setElement(addressHex, new Map());
    }
  }

  flush(): [string, string, Uint8Array | undefined][] {
    const diffMap = this._diffCache[this._checkpoints]!;
    const items: [string, string, Uint8Array | undefined][] = [];

    for (const [addressHex, diffStorageMap] of diffMap.entries()) {
      const storageMap = this._lruCache?.get(addressHex) ?? this._orderedMapCache?.getElementByKey(addressHex);
      if (storageMap === undefined) {
        throw new Error("internal error: storage cache map for account should be defined");
      }
      for (const [keyHex] of diffStorageMap.entries()) {
        items.push([addressHex, keyHex, storageMap.get(keyHex)]);
      }
    }
    this._diffCache[this._checkpoints] = new Map();
    return items;
  }

  revert(): void {
    this._checkpoints -= 1;
    const diffMap = this._diffCache.pop()!;

    for (const [addressHex, diffStorageMap] of diffMap.entries()) {
      for (const [keyHex, value] of diffStorageMap.entries()) {
        if (this._lruCache) {
          const storageMap = this._lruCache.get(addressHex) ?? new Map<string, Uint8Array>();
          if (value === undefined) {
            storageMap.delete(keyHex);
          } else {
            storageMap.set(keyHex, value);
          }
          this._lruCache.set(addressHex, storageMap);
        } else {
          const storageMap = this._orderedMapCache!.getElementByKey(addressHex) ?? new Map<string, Uint8Array>();
          if (value === undefined) {
            storageMap.delete(keyHex);
          } else {
            storageMap.set(keyHex, value);
          }
          this._orderedMapCache!.setElement(addressHex, storageMap);
        }
      }
    }
  }

  commit(): void {
    this._checkpoints -= 1;
    const higherHeightDiffMap = this._diffCache.pop()!;
    const lowerHeightDiffMap = this._diffCache[this._checkpoints] ?? new Map<string, DiffStorageCacheMap>();
    this._diffCache[this._checkpoints] = lowerHeightDiffMap;

    for (const [addressHex, higherHeightStorageDiff] of higherHeightDiffMap.entries()) {
      const lowerHeightStorageDiff = lowerHeightDiffMap.get(addressHex) ?? new Map<string, Uint8Array | undefined>();
      for (const [keyHex, elem] of higherHeightStorageDiff.entries()) {
        if (!lowerHeightStorageDiff.has(keyHex)) {
          lowerHeightStorageDiff.set(keyHex, elem);
        }
      }
      lowerHeightDiffMap.set(addressHex, lowerHeightStorageDiff);
    }
  }

  checkpoint(): void {
    this._checkpoints += 1;
    this._diffCache.push(new Map());
  }

  size(): number {
    return this._lruCache?.size ?? this._orderedMapCache!.size();
  }

  stats(reset = true): CacheStats {
    const stats = { ...this._stats, size: this.size() };
    if (reset) {
      this._stats = {
        size: 0,
        reads: 0,
        hits: 0,
        writes: 0,
        deletions: 0,
      };
    }
    return stats;
  }

  clear(): void {
    if (this._lruCache) {
      this._lruCache.clear();
    } else {
      this._orderedMapCache!.clear();
    }
  }

  dump(address: Address): StorageCacheMap | undefined {
    const addressHex = bytesToUnprefixedHex(address.bytes);
    return this._lruCache?.get(addressHex) ?? this._orderedMapCache?.getElementByKey(addressHex);
  }
}
