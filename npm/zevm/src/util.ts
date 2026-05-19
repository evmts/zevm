import { secp256k1 } from "@noble/curves/secp256k1.js";
import { bytesToHex as nobleBytesToHex, hexToBytes as nobleHexToBytes, randomBytes as nobleRandomBytes } from "@noble/hashes/utils.js";
import { keccak_256 } from "@noble/hashes/sha3.js";
import { encode, decode } from "./rlp.js";

export type PrefixedHexString = `0x${string}`;
export type TransformableToBytes = { toBytes?(): Uint8Array };
export type BigIntLike = bigint | PrefixedHexString | number | Uint8Array;
export type BytesLike = Uint8Array | number[] | number | bigint | TransformableToBytes | PrefixedHexString;
export type AddressLike = Address | Uint8Array | PrefixedHexString;
export type ToBytesInputTypes = BytesLike | null | undefined;
export type NestedUint8Array = Array<Uint8Array | NestedUint8Array>;

export type DBObject = { [key: string]: string | string[] | number };

export const KeyEncoding = {
  String: "string",
  Bytes: "view",
  Number: "number",
} as const;
export type KeyEncoding = (typeof KeyEncoding)[keyof typeof KeyEncoding];

export const ValueEncoding = {
  String: "string",
  Bytes: "view",
  JSON: "json",
} as const;
export type ValueEncoding = (typeof ValueEncoding)[keyof typeof ValueEncoding];

export type EncodingOpts = {
  keyEncoding?: KeyEncoding;
  valueEncoding?: ValueEncoding;
};

export type PutBatch<
  TKey extends Uint8Array | string | number = Uint8Array,
  TValue extends Uint8Array | string | DBObject = Uint8Array,
> = {
  type: "put";
  key: TKey;
  value: TValue;
  opts?: EncodingOpts;
};

export type DelBatch<TKey extends Uint8Array | string | number = Uint8Array> = {
  type: "del";
  key: TKey;
  opts?: EncodingOpts;
};

export type BatchDBOp<
  TKey extends Uint8Array | string | number = Uint8Array,
  TValue extends Uint8Array | string | DBObject = Uint8Array,
> = PutBatch<TKey, TValue> | DelBatch<TKey>;

export interface DB<
  TKey extends Uint8Array | string | number = Uint8Array,
  TValue extends Uint8Array | string | DBObject = Uint8Array,
> {
  get(key: TKey, opts?: EncodingOpts): Promise<TValue | undefined>;
  put(key: TKey, val: TValue, opts?: EncodingOpts): Promise<void>;
  del(key: TKey, opts?: EncodingOpts): Promise<void>;
  batch(opStack: BatchDBOp<TKey, TValue>[]): Promise<void>;
  shallowCopy(): DB<TKey, TValue>;
  open(): Promise<void>;
}

export type TypeOutput = (typeof TypeOutput)[keyof typeof TypeOutput];
export const TypeOutput = {
  Number: 0,
  BigInt: 1,
  Uint8Array: 2,
  PrefixedHexString: 3,
} as const;

export type TypeOutputReturnType = {
  [TypeOutput.Number]: number;
  [TypeOutput.BigInt]: bigint;
  [TypeOutput.Uint8Array]: Uint8Array;
  [TypeOutput.PrefixedHexString]: PrefixedHexString;
};

export type EOACode7702AuthorizationListItemUnsigned = {
  chainId: PrefixedHexString;
  address: PrefixedHexString;
  nonce: PrefixedHexString;
};

export type EOACode7702AuthorizationListItem = {
  yParity: PrefixedHexString;
  r: PrefixedHexString;
  s: PrefixedHexString;
} & EOACode7702AuthorizationListItemUnsigned;

export type EOACode7702AuthorizationListBytesItem = [
  Uint8Array,
  Uint8Array,
  Uint8Array,
  Uint8Array,
  Uint8Array,
  Uint8Array,
];
export type EOACode7702AuthorizationListBytes = EOACode7702AuthorizationListBytesItem[];
export type EOACode7702AuthorizationList = EOACode7702AuthorizationListItem[];
export type EOACode7702AuthorizationListBytesItemUnsigned = [Uint8Array, Uint8Array, Uint8Array];

export type AccountData = {
  nonce?: BigIntLike;
  balance?: BigIntLike;
  storageRoot?: BytesLike;
  codeHash?: BytesLike;
};

export type PartialAccountData = {
  nonce?: BigIntLike | null;
  balance?: BigIntLike | null;
  storageRoot?: BytesLike | null;
  codeHash?: BytesLike | null;
  codeSize?: BigIntLike | null;
  version?: BigIntLike | null;
};

export type AccountBodyBytes = [Uint8Array, Uint8Array, Uint8Array, Uint8Array];

export type WithdrawalData = {
  index: BigIntLike;
  validatorIndex: BigIntLike;
  address: AddressLike;
  amount: BigIntLike;
};

export interface JSONRPCWithdrawal {
  index: PrefixedHexString;
  validatorIndex: PrefixedHexString;
  address: PrefixedHexString;
  amount: PrefixedHexString;
}

export type WithdrawalBytes = [Uint8Array, Uint8Array, Uint8Array, Uint8Array];

type ProviderLike = string | { _getConnection?: () => { url: string } };
type RpcParams = { method: string; params?: unknown[] };
type RecoveredSignature = { recovery: number; r: bigint; s: bigint };

export const BIGINT_0 = 0n;
export const BIGINT_1 = 1n;
const BIGINT_2 = 2n;
const BIGINT_27 = 27n;

export const MAX_UINT64 = BigInt("0xffffffffffffffff");
const SECP256K1_ORDER = secp256k1.Point.CURVE().n;
export const SECP256K1_ORDER_DIV_2 = SECP256K1_ORDER / 2n;
export const GWEI_TO_WEI = BigInt(10 ** 9);

export const bytesToUnprefixedHex = nobleBytesToHex;
export const randomBytes = nobleRandomBytes;

function fail(message: string): Error {
  return new Error(message);
}

function stripHexPrefix(hex: string): string {
  return hex.startsWith("0x") ? hex.slice(2) : hex;
}

function padToEven(hex: string): string {
  return hex.length % 2 === 0 ? hex : `0${hex}`;
}

function isHexString(value: string): value is PrefixedHexString {
  return /^0x[0-9a-fA-F]*$/.test(value);
}

function assertBytes(value: unknown): asserts value is Uint8Array {
  if (!(value instanceof Uint8Array)) {
    throw fail(`This method only supports Uint8Array but input was: ${value}`);
  }
}

function assertString(value: unknown): asserts value is string {
  if (typeof value !== "string") {
    throw fail(`This method only supports strings but input was: ${value}`);
  }
}

export function hexToBytes(hex: PrefixedHexString): Uint8Array {
  if (!hex.startsWith("0x")) {
    throw fail("input string must be 0x prefixed");
  }
  return nobleHexToBytes(padToEven(stripHexPrefix(hex)));
}

export function unprefixedHexToBytes(hex: string): Uint8Array {
  if (hex.startsWith("0x")) {
    throw fail("input string cannot be 0x prefixed");
  }
  return nobleHexToBytes(padToEven(hex));
}

export function bytesToHex(bytes: Uint8Array): PrefixedHexString {
  return `0x${bytesToUnprefixedHex(bytes)}`;
}

export function bytesToBigInt(bytes: Uint8Array, littleEndian = false): bigint {
  assertBytes(bytes);
  const input = littleEndian ? bytes.slice().reverse() : bytes;
  const hex = bytesToHex(input);
  return hex === "0x" ? BIGINT_0 : BigInt(hex);
}

export function bytesToInt(bytes: Uint8Array): number {
  const value = Number(bytesToBigInt(bytes));
  if (!Number.isSafeInteger(value)) {
    throw fail("Number exceeds 53 bits");
  }
  return value;
}

export function intToHex(value: number): PrefixedHexString {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw fail(`Received an invalid integer type: ${value}`);
  }
  return `0x${value.toString(16)}`;
}

export function intToBytes(value: number): Uint8Array {
  return hexToBytes(intToHex(value));
}

export function bigIntToBytes(value: bigint, littleEndian = false): Uint8Array {
  if (value < BIGINT_0) {
    throw fail(`Cannot convert negative bigint to Uint8Array. Given: ${value}`);
  }
  const bytes = hexToBytes(`0x${padToEven(value.toString(16))}`);
  return littleEndian ? bytes.reverse() : bytes;
}

function setLength(msg: Uint8Array, length: number, right: boolean, allowTruncate: boolean): Uint8Array {
  if (msg.length > length) {
    if (!allowTruncate) {
      throw fail(`Input length ${msg.length} exceeds target length ${length}. Use allowTruncate option to truncate.`);
    }
    return right ? msg.subarray(0, length) : msg.subarray(-length);
  }
  if (msg.length === length) {
    return msg;
  }

  const out = new Uint8Array(length);
  if (right) {
    out.set(msg);
  } else {
    out.set(msg, length - msg.length);
  }
  return out;
}

export function setLengthLeft(msg: Uint8Array, length: number, opts: { allowTruncate?: boolean } = {}): Uint8Array {
  assertBytes(msg);
  return setLength(msg, length, false, opts.allowTruncate ?? false);
}

export function setLengthRight(msg: Uint8Array, length: number, opts: { allowTruncate?: boolean } = {}): Uint8Array {
  assertBytes(msg);
  return setLength(msg, length, true, opts.allowTruncate ?? false);
}

export function unpadBytes(value: Uint8Array): Uint8Array {
  assertBytes(value);
  let firstNonZero = 0;
  while (firstNonZero < value.length && value[firstNonZero] === 0) {
    firstNonZero++;
  }
  return value.slice(firstNonZero);
}

export function bigIntToUnpaddedBytes(value: bigint): Uint8Array {
  return unpadBytes(bigIntToBytes(value));
}

export function intToUnpaddedBytes(value: number): Uint8Array {
  return unpadBytes(intToBytes(value));
}

export function toBytes(value: ToBytesInputTypes): Uint8Array {
  if (value === null || value === undefined) {
    return new Uint8Array();
  }
  if (Array.isArray(value) || value instanceof Uint8Array) {
    return Uint8Array.from(value);
  }
  if (typeof value === "string") {
    if (!isHexString(value)) {
      throw fail(`Cannot convert string to Uint8Array. toBytes only supports 0x-prefixed hex strings and this string was given: ${value}`);
    }
    return hexToBytes(value);
  }
  if (typeof value === "number") {
    return intToBytes(value);
  }
  if (typeof value === "bigint") {
    return bigIntToBytes(value);
  }
  if (value.toBytes !== undefined) {
    return value.toBytes();
  }
  throw fail("invalid type");
}

export function bytesToUtf8(bytes: Uint8Array): string {
  if (!(bytes instanceof Uint8Array)) {
    throw new TypeError(`bytesToUtf8 expected Uint8Array, got ${typeof bytes}`);
  }
  return new TextDecoder().decode(bytes);
}

export function concatBytes(...arrays: Uint8Array[]): Uint8Array {
  if (arrays.length === 0) {
    return new Uint8Array();
  }
  if (arrays.length === 1) {
    return arrays[0]!;
  }

  const length = arrays.reduce((sum, arr) => sum + arr.length, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const arr of arrays) {
    out.set(arr, offset);
    offset += arr.length;
  }
  return out;
}

export function equalsBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

export function bigIntToHex(value: bigint): PrefixedHexString {
  return `0x${value.toString(16)}`;
}

export function toType<T extends TypeOutput>(input: null, outputType: T): null;
export function toType<T extends TypeOutput>(input: undefined, outputType: T): undefined;
export function toType<T extends TypeOutput>(input: ToBytesInputTypes, outputType: T): TypeOutputReturnType[T];
export function toType<T extends TypeOutput>(input: ToBytesInputTypes, outputType: T): TypeOutputReturnType[T] | null | undefined {
  if (input === null || input === undefined) {
    return input;
  }
  if (typeof input === "string" && !isHexString(input)) {
    throw fail(`A string must be provided with a 0x-prefix, given: ${input}`);
  }
  if (typeof input === "number" && !Number.isSafeInteger(input)) {
    throw fail("The provided number is greater than MAX_SAFE_INTEGER (please use an alternative input type)");
  }

  const output = toBytes(input);
  switch (outputType) {
    case TypeOutput.Uint8Array:
      return output as TypeOutputReturnType[T];
    case TypeOutput.BigInt:
      return bytesToBigInt(output) as TypeOutputReturnType[T];
    case TypeOutput.Number: {
      const bigint = bytesToBigInt(output);
      if (bigint > BigInt(Number.MAX_SAFE_INTEGER)) {
        throw fail("The provided number is greater than MAX_SAFE_INTEGER (please use an alternative output type)");
      }
      return Number(bigint) as TypeOutputReturnType[T];
    }
    case TypeOutput.PrefixedHexString:
      return bytesToHex(output) as TypeOutputReturnType[T];
    default:
      throw fail("unknown outputType");
  }
}

export const KECCAK256_NULL = hexToBytes("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
export const KECCAK256_RLP_ARRAY = hexToBytes("0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347");
export const KECCAK256_RLP = hexToBytes("0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");

export class Address {
  bytes: Uint8Array;

  constructor(bytes: Uint8Array) {
    if (bytes.length !== 20) {
      throw fail("Invalid address length");
    }
    this.bytes = bytes;
  }

  static fromString(str: string): Address {
    return createAddressFromString(str);
  }

  static zero(): Address {
    return new Address(new Uint8Array(20));
  }

  equals(address: Address): boolean {
    return equalsBytes(this.bytes, address.bytes);
  }

  isZero(): boolean {
    return this.equals(new Address(new Uint8Array(20)));
  }

  isPrecompileOrSystemAddress(): boolean {
    const address = bytesToBigInt(this.bytes);
    return address >= BIGINT_0 && address <= BigInt("0xffff");
  }

  toString(): PrefixedHexString {
    return bytesToHex(this.bytes);
  }

  toBytes(): Uint8Array {
    return new Uint8Array(this.bytes);
  }
}

export function isValidAddress(hexAddress: string): hexAddress is PrefixedHexString {
  try {
    assertString(hexAddress);
  } catch {
    return false;
  }
  return /^0x[0-9a-fA-F]{40}$/.test(hexAddress);
}

export function createZeroAddress(): Address {
  return new Address(new Uint8Array(20));
}

export function createAddressFromString(str: string): Address {
  if (!isValidAddress(str)) {
    throw fail(`Invalid address input=${str}`);
  }
  return new Address(hexToBytes(str));
}

export class Account {
  _nonce: bigint | null;
  _balance: bigint | null;
  _storageRoot: Uint8Array | null;
  _codeHash: Uint8Array | null;
  _codeSize: number | null;
  _version: number | null;

  constructor(
    nonce: bigint | null = BIGINT_0,
    balance: bigint | null = BIGINT_0,
    storageRoot: Uint8Array | null = KECCAK256_RLP,
    codeHash: Uint8Array | null = KECCAK256_NULL,
    codeSize: number | null = 0,
    version: number | null = 0,
  ) {
    this._nonce = nonce;
    this._balance = balance;
    this._storageRoot = storageRoot;
    this._codeHash = codeHash;
    this._codeSize = codeSize === null && codeHash !== null && !this.isContract() ? 0 : codeSize;
    this._version = version;
    this._validate();
  }

  get version(): number {
    if (this._version === null) {
      throw fail("version=null not loaded");
    }
    return this._version;
  }

  set version(version: number) {
    this._version = version;
  }

  get nonce(): bigint {
    if (this._nonce === null) {
      throw fail("nonce=null not loaded");
    }
    return this._nonce;
  }

  set nonce(nonce: bigint) {
    this._nonce = nonce;
  }

  get balance(): bigint {
    if (this._balance === null) {
      throw fail("balance=null not loaded");
    }
    return this._balance;
  }

  set balance(balance: bigint) {
    this._balance = balance;
  }

  get storageRoot(): Uint8Array {
    if (this._storageRoot === null) {
      throw fail("storageRoot=null not loaded");
    }
    return this._storageRoot;
  }

  set storageRoot(storageRoot: Uint8Array) {
    this._storageRoot = storageRoot;
  }

  get codeHash(): Uint8Array {
    if (this._codeHash === null) {
      throw fail("codeHash=null not loaded");
    }
    return this._codeHash;
  }

  set codeHash(codeHash: Uint8Array) {
    this._codeHash = codeHash;
  }

  get codeSize(): number {
    if (this._codeSize === null) {
      throw fail("codeSize=null not loaded");
    }
    return this._codeSize;
  }

  set codeSize(codeSize: number) {
    this._codeSize = codeSize;
  }

  _validate(): void {
    if (this._nonce !== null && this._nonce < BIGINT_0) {
      throw fail("nonce must be greater than zero");
    }
    if (this._balance !== null && this._balance < BIGINT_0) {
      throw fail("balance must be greater than zero");
    }
    if (this._storageRoot !== null && this._storageRoot.length !== 32) {
      throw fail("storageRoot must have a length of 32");
    }
    if (this._codeHash !== null && this._codeHash.length !== 32) {
      throw fail("codeHash must have a length of 32");
    }
    if (this._codeSize !== null && this._codeSize < 0) {
      throw fail("codeSize must be greater than zero");
    }
  }

  raw(): Uint8Array[] {
    return [bigIntToUnpaddedBytes(this.nonce), bigIntToUnpaddedBytes(this.balance), this.storageRoot, this.codeHash];
  }

  serialize(): Uint8Array {
    return encode(this.raw());
  }

  serializeWithPartialInfo(): Uint8Array {
    const zeroEncoded = intToUnpaddedBytes(0);
    const oneEncoded = intToUnpaddedBytes(1);
    const partialData = [
      this._nonce !== null ? [oneEncoded, bigIntToUnpaddedBytes(this._nonce)] : [zeroEncoded],
      this._balance !== null ? [oneEncoded, bigIntToUnpaddedBytes(this._balance)] : [zeroEncoded],
      this._storageRoot !== null ? [oneEncoded, this._storageRoot] : [zeroEncoded],
      this._codeHash !== null ? [oneEncoded, this._codeHash] : [zeroEncoded],
      this._codeSize !== null ? [oneEncoded, intToUnpaddedBytes(this._codeSize)] : [zeroEncoded],
      this._version !== null ? [oneEncoded, intToUnpaddedBytes(this._version)] : [zeroEncoded],
    ];
    return encode(partialData);
  }

  isContract(): boolean {
    if (this._codeHash === null && this._codeSize === null) {
      throw fail("Insufficient data as codeHash=null and codeSize=null");
    }
    return (this._codeHash !== null && !equalsBytes(this._codeHash, KECCAK256_NULL)) || (this._codeSize !== null && this._codeSize !== 0);
  }

  isEmpty(): boolean {
    if (
      (this._balance !== null && this._balance !== BIGINT_0) ||
      (this._nonce !== null && this._nonce !== BIGINT_0) ||
      (this._codeHash !== null && !equalsBytes(this._codeHash, KECCAK256_NULL))
    ) {
      return false;
    }
    return this.balance === BIGINT_0 && this.nonce === BIGINT_0 && equalsBytes(this.codeHash, KECCAK256_NULL);
  }
}

export function createAccount(accountData: AccountData): Account {
  const { nonce, balance, storageRoot, codeHash } = accountData;
  if (nonce === null || balance === null || storageRoot === null || codeHash === null) {
    throw fail("Partial fields not supported in fromAccountData");
  }
  return new Account(
    nonce !== undefined ? bytesToBigInt(toBytes(nonce)) : undefined,
    balance !== undefined ? bytesToBigInt(toBytes(balance)) : undefined,
    storageRoot !== undefined ? toBytes(storageRoot) : undefined,
    codeHash !== undefined ? toBytes(codeHash) : undefined,
  );
}

export function createAccountFromBytesArray(values: Uint8Array[]): Account {
  const [nonce, balance, storageRoot, codeHash] = values;
  if (nonce === undefined || balance === undefined || storageRoot === undefined || codeHash === undefined) {
    throw fail("Invalid account bytes array");
  }
  return new Account(bytesToBigInt(nonce), bytesToBigInt(balance), storageRoot, codeHash);
}

export function createPartialAccount(partialAccountData: PartialAccountData): Account {
  const { nonce, balance, storageRoot, codeHash, codeSize, version } = partialAccountData;
  if (nonce === null && balance === null && storageRoot === null && codeHash === null && codeSize === null && version === null) {
    throw fail("All partial fields null");
  }
  return new Account(
    nonce !== undefined && nonce !== null ? bytesToBigInt(toBytes(nonce)) : nonce,
    balance !== undefined && balance !== null ? bytesToBigInt(toBytes(balance)) : balance,
    storageRoot !== undefined && storageRoot !== null ? toBytes(storageRoot) : storageRoot,
    codeHash !== undefined && codeHash !== null ? toBytes(codeHash) : codeHash,
    codeSize !== undefined && codeSize !== null ? bytesToInt(toBytes(codeSize)) : codeSize,
    version !== undefined && version !== null ? bytesToInt(toBytes(version)) : version,
  );
}

export function createAccountFromRLP(serialized: Uint8Array): Account {
  const values = decode(serialized);
  if (!Array.isArray(values) || values.some((value) => !(value instanceof Uint8Array))) {
    throw fail("Invalid serialized account input. Must be array");
  }
  return createAccountFromBytesArray(values as Uint8Array[]);
}

function nullIndicator(values: Uint8Array | NestedUint8Array): Uint8Array | null {
  if (!Array.isArray(values)) {
    throw fail("Invalid partial encoding. Each item must be an array");
  }
  const [indicator, value] = values;
  if (!(indicator instanceof Uint8Array)) {
    throw fail("Invalid partial encoding. Indicator must be bytes");
  }
  const decodedIndicator = bytesToInt(indicator);
  if (decodedIndicator === 0) {
    return null;
  }
  if (decodedIndicator !== 1) {
    throw fail(`Invalid isNullIndicator=${decodedIndicator}`);
  }
  if (!(value instanceof Uint8Array)) {
    throw fail(`Invalid values length=${values.length}`);
  }
  return value;
}

export function createPartialAccountFromRLP(serialized: Uint8Array): Account {
  const values = decode(serialized);
  if (!Array.isArray(values)) {
    throw fail("Invalid serialized account input. Must be array");
  }
  const [nonceRaw, balanceRaw, storageRoot, codeHash, codeSizeRaw, versionRaw] = values.map(nullIndicator);
  return createPartialAccount({
    nonce: nonceRaw === null ? null : bytesToBigInt(nonceRaw),
    balance: balanceRaw === null ? null : bytesToBigInt(balanceRaw),
    storageRoot,
    codeHash,
    codeSize: codeSizeRaw === null ? null : bytesToInt(codeSizeRaw),
    version: versionRaw === null ? null : bytesToInt(versionRaw),
  });
}

export function publicToAddress(pubKey: Uint8Array, sanitize = false): Uint8Array {
  assertBytes(pubKey);
  let publicKey = pubKey;
  if (sanitize && publicKey.length !== 64) {
    publicKey = secp256k1.Point.fromBytes(publicKey).toBytes(false).slice(1);
  }
  if (publicKey.length !== 64) {
    throw fail("Expected pubKey to be of length 64");
  }
  return keccak_256(publicKey).subarray(-20);
}

export const pubToAddress = publicToAddress;

export function calculateSigRecovery(v: bigint, chainId?: bigint): bigint {
  if (v === BIGINT_0 || v === BIGINT_1) {
    return v;
  }
  if (chainId === undefined) {
    return v - BIGINT_27;
  }
  return v - (chainId * BIGINT_2 + 35n);
}

function isValidSigRecovery(recovery: bigint): boolean {
  return recovery === BIGINT_0 || recovery === BIGINT_1;
}

export function ecrecover(msgHash: Uint8Array, v: bigint, r: Uint8Array, s: Uint8Array, chainId?: bigint): Uint8Array {
  const signature = concatBytes(setLengthLeft(r, 32), setLengthLeft(s, 32));
  const recovery = calculateSigRecovery(v, chainId);
  if (!isValidSigRecovery(recovery)) {
    throw fail("Invalid signature v value");
  }
  const sig = secp256k1.Signature.fromBytes(signature).addRecoveryBit(Number(recovery));
  return sig.recoverPublicKey(msgHash).toBytes(false).slice(1);
}

export const EOA_CODE_7702_AUTHORITY_SIGNING_MAGIC = hexToBytes("0x05");

export function eoaCode7702AuthorizationListBytesItemToJSON(
  authorizationList: EOACode7702AuthorizationListBytesItem,
): EOACode7702AuthorizationListItem {
  const [chainId, address, nonce, yParity, r, s] = authorizationList;
  return {
    chainId: bytesToHex(chainId),
    address: bytesToHex(address),
    nonce: bytesToHex(nonce),
    yParity: bytesToHex(yParity),
    r: bytesToHex(r),
    s: bytesToHex(s),
  };
}

export function eoaCode7702AuthorizationListJSONItemToBytes(
  authorizationList: EOACode7702AuthorizationListItem,
): EOACode7702AuthorizationListBytesItem {
  const requiredFields = ["chainId", "address", "nonce", "yParity", "r", "s"] as const;
  for (const field of requiredFields) {
    if (authorizationList[field] === undefined) {
      throw fail(`EIP-7702 authorization list invalid: ${field} is not defined`);
    }
  }
  return [
    unpadBytes(hexToBytes(authorizationList.chainId)),
    hexToBytes(authorizationList.address),
    unpadBytes(hexToBytes(authorizationList.nonce)),
    unpadBytes(hexToBytes(authorizationList.yParity)),
    unpadBytes(hexToBytes(authorizationList.r)),
    unpadBytes(hexToBytes(authorizationList.s)),
  ];
}

function unsignedAuthorizationListToBytes(
  input: EOACode7702AuthorizationListItemUnsigned,
): EOACode7702AuthorizationListBytesItemUnsigned {
  const { chainId: chainIdHex, address: addressHex, nonce: nonceHex } = input;
  return [unpadBytes(hexToBytes(chainIdHex)), setLengthLeft(hexToBytes(addressHex), 20), unpadBytes(hexToBytes(nonceHex))];
}

export function eoaCode7702AuthorizationMessageToSign(
  input: EOACode7702AuthorizationListItemUnsigned | EOACode7702AuthorizationListBytesItemUnsigned,
): Uint8Array {
  if (Array.isArray(input)) {
    const [chainId, address, nonce] = input;
    if (address.length !== 20) {
      throw fail("Cannot sign authority: address length should be 20 bytes");
    }
    return concatBytes(EOA_CODE_7702_AUTHORITY_SIGNING_MAGIC, encode([unpadBytes(chainId), address, unpadBytes(nonce)]));
  }
  const [chainId, address, nonce] = unsignedAuthorizationListToBytes(input);
  return concatBytes(EOA_CODE_7702_AUTHORITY_SIGNING_MAGIC, encode([chainId, address, nonce]));
}

export function eoaCode7702AuthorizationHashedMessageToSign(
  input: EOACode7702AuthorizationListItemUnsigned | EOACode7702AuthorizationListBytesItemUnsigned,
): Uint8Array {
  return keccak_256(eoaCode7702AuthorizationMessageToSign(input));
}

export function eoaCode7702SignAuthorization(
  input: EOACode7702AuthorizationListItemUnsigned | EOACode7702AuthorizationListBytesItemUnsigned,
  privateKey: Uint8Array,
  ecSign?: (msg: Uint8Array, pk: Uint8Array, ecSignOpts?: { extraEntropy?: Uint8Array | boolean }) => RecoveredSignature,
): EOACode7702AuthorizationListBytesItem {
  const msgHash = eoaCode7702AuthorizationHashedMessageToSign(input);
  const signed =
    ecSign?.(msgHash, privateKey) ??
    secp256k1.Signature.fromBytes(secp256k1.sign(msgHash, privateKey, { prehash: false, format: "recovered" }), "recovered");
  if (signed.recovery === undefined) {
    throw fail("Missing signature recovery");
  }
  const [chainId, address, nonce] = Array.isArray(input) ? input : unsignedAuthorizationListToBytes(input);
  return [
    unpadBytes(chainId),
    address,
    unpadBytes(nonce),
    bigIntToUnpaddedBytes(BigInt(signed.recovery)),
    bigIntToUnpaddedBytes(signed.r),
    bigIntToUnpaddedBytes(signed.s),
  ];
}

export function eoaCode7702RecoverAuthority(input: EOACode7702AuthorizationListItem | EOACode7702AuthorizationListBytesItem): Address {
  const inputBytes = Array.isArray(input) ? input : eoaCode7702AuthorizationListJSONItemToBytes(input);
  const [chainId, address, nonce, yParity, r, s] = [
    unpadBytes(inputBytes[0]),
    inputBytes[1],
    unpadBytes(inputBytes[2]),
    unpadBytes(inputBytes[3]),
    unpadBytes(inputBytes[4]),
    unpadBytes(inputBytes[5]),
  ];
  const msgHash = eoaCode7702AuthorizationHashedMessageToSign([chainId, address, nonce]);
  return new Address(publicToAddress(ecrecover(msgHash, bytesToBigInt(yParity), r, s)));
}

export function isEOACode7702AuthorizationListBytes(
  input: EOACode7702AuthorizationListBytes | EOACode7702AuthorizationList,
): input is EOACode7702AuthorizationListBytes {
  if (input.length === 0) {
    return true;
  }
  return Array.isArray(input[0]);
}

export function isEOACode7702AuthorizationList(
  input: EOACode7702AuthorizationListBytes | EOACode7702AuthorizationList,
): input is EOACode7702AuthorizationList {
  return !isEOACode7702AuthorizationListBytes(input);
}

export function withdrawalToBytesArray(withdrawal: Withdrawal | WithdrawalData): WithdrawalBytes {
  const { index, validatorIndex, address, amount } = withdrawal;
  const indexBytes = toType(index, TypeOutput.BigInt) === BIGINT_0 ? new Uint8Array() : toType(index, TypeOutput.Uint8Array);
  const validatorIndexBytes =
    toType(validatorIndex, TypeOutput.BigInt) === BIGINT_0 ? new Uint8Array() : toType(validatorIndex, TypeOutput.Uint8Array);
  const addressBytes = address instanceof Address ? address.bytes : toType(address, TypeOutput.Uint8Array);
  const amountBytes = toType(amount, TypeOutput.BigInt) === BIGINT_0 ? new Uint8Array() : toType(amount, TypeOutput.Uint8Array);
  return [indexBytes, validatorIndexBytes, addressBytes, amountBytes];
}

export class Withdrawal {
  readonly index: bigint;
  readonly validatorIndex: bigint;
  readonly address: Address;
  readonly amount: bigint;

  constructor(index: bigint, validatorIndex: bigint, address: Address, amount: bigint) {
    this.index = index;
    this.validatorIndex = validatorIndex;
    this.address = address;
    this.amount = amount;
  }

  static fromWithdrawalData(withdrawalData: WithdrawalData): Withdrawal {
    return createWithdrawal(withdrawalData);
  }

  raw(): WithdrawalBytes {
    return withdrawalToBytesArray(this);
  }

  toValue(): { index: bigint; validatorIndex: bigint; address: Uint8Array; amount: bigint } {
    return {
      index: this.index,
      validatorIndex: this.validatorIndex,
      address: this.address.bytes,
      amount: this.amount,
    };
  }

  toJSON(): JSONRPCWithdrawal {
    return {
      index: bigIntToHex(this.index),
      validatorIndex: bigIntToHex(this.validatorIndex),
      address: bytesToHex(this.address.bytes),
      amount: bigIntToHex(this.amount),
    };
  }
}

export function createWithdrawal(withdrawalData: WithdrawalData): Withdrawal {
  const { index: indexData, validatorIndex: validatorIndexData, address: addressData, amount: amountData } = withdrawalData;
  const index = toType(indexData, TypeOutput.BigInt);
  const validatorIndex = toType(validatorIndexData, TypeOutput.BigInt);
  const address = addressData instanceof Address ? addressData : new Address(toBytes(addressData));
  const amount = toType(amountData, TypeOutput.BigInt);
  return new Withdrawal(index, validatorIndex, address, amount);
}

export function createWithdrawalFromBytesArray(withdrawalArray: WithdrawalBytes): Withdrawal {
  if (withdrawalArray.length !== 4) {
    throw fail(`Invalid withdrawalArray length expected=4 actual=${withdrawalArray.length}`);
  }
  const [index, validatorIndex, address, amount] = withdrawalArray;
  return createWithdrawal({ index, validatorIndex, address, amount });
}

export async function fetchFromProvider(url: string, params: RpcParams): Promise<unknown> {
  const res = await fetch(url, {
    headers: { "content-type": "application/json" },
    method: "POST",
    body: JSON.stringify({ method: params.method, params: params.params, jsonrpc: "2.0", id: 1 }),
  });
  if (!res.ok) {
    throw fail(
      `JSONRPCError: ${JSON.stringify(
        {
          method: params.method,
          status: res.status,
          message: await res.text().catch(() => "Could not parse error message likely because of a network error"),
        },
        null,
        2,
      )}`,
    );
  }
  const json = (await res.json()) as { result: unknown };
  return json.result;
}

export function getProvider(provider: ProviderLike): string {
  if (typeof provider === "string") {
    return provider;
  }
  if (typeof provider === "object" && provider._getConnection !== undefined) {
    return provider._getConnection().url;
  }
  throw fail("Must provide valid provider URL or Web3Provider");
}
