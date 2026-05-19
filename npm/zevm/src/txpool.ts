import {
	Blob4844Tx as BlobEIP4844Transaction,
	Capability,
	type FeeMarket1559Tx as FeeMarketEIP1559Transaction,
	type LegacyTx as LegacyTransaction,
	isAccessList2930Tx as isAccessListEIP2930Tx,
	isBlob4844Tx as isBlobEIP4844Tx,
	isFeeMarket1559Tx as isFeeMarketEIP1559Tx,
	isLegacyTx,
	type TypedTransaction,
} from "./tx.js";
import { Account, Address, bytesToHex, bytesToUnprefixedHex, equalsBytes, type PrefixedHexString } from "./util.js";

const MIN_GAS_PRICE_BUMP_PERCENT = 10;
const MIN_GAS_PRICE = BigInt(100000000);
const TX_MAX_DATA_SIZE = 128 * 1024;
const MAX_POOL_SIZE = 5000;
const MAX_TXS_PER_ACCOUNT = 100;

export interface ImpersonatedTx extends FeeMarketEIP1559Transaction {
	isImpersonated: true;
}

export type TxPoolTransaction = TypedTransaction | ImpersonatedTx;

export type TxPoolBlock = {
	transactions: TxPoolTransaction[];
	header: {
		baseFeePerGas?: bigint;
		gasLimit: bigint;
	};
};

export interface TxPoolVm {
	blockchain: {
		getCanonicalHeadBlock(): Promise<TxPoolBlock>;
	};
	stateManager: {
		getAccount(address: Address): Promise<Account | undefined>;
	};
	deepCopy(): Promise<TxPoolVm>;
}

export interface TxPoolOptions {
	vm: TxPoolVm;
	maxSize?: number;
	maxPerSender?: number;
}

export type TxPoolObject = {
	tx: TxPoolTransaction;
	hash: UnprefixedHash;
	added: number;
	error?: Error;
};

export type TxPoolAddResult =
	| {
			error: null;
			hash: PrefixedHexString;
	  }
	| {
			error: string;
			hash: PrefixedHexString;
	  };

type HandledObject = {
	address: UnprefixedAddress;
	added: number;
	error?: Error;
};

type UnprefixedAddress = string;
type UnprefixedHash = string;

type GasPrice = {
	tip: bigint;
	maxFee: bigint;
};

function isBlobPoolInstance(tx: TxPoolTransaction): tx is BlobEIP4844Transaction {
	return tx instanceof BlobEIP4844Transaction || tx.constructor.name === "MockBlobEIP4844Transaction";
}

class PriorityQueue<T> {
	private items: T[] = [];

	constructor(private readonly comesBefore: (a: T, b: T) => boolean) {}

	get length(): number {
		return this.items.length;
	}

	insert(item: T): void {
		this.items.push(item);
		this.bubbleUp(this.items.length - 1);
	}

	remove(): T | undefined {
		const first = this.items[0];
		const last = this.items.pop();
		if (first === undefined || last === undefined) {
			return first;
		}
		if (this.items.length > 0) {
			this.items[0] = last;
			this.bubbleDown(0);
		}
		return first;
	}

	private bubbleUp(index: number): void {
		let current = index;
		while (current > 0) {
			const parent = Math.floor((current - 1) / 2);
			const currentItem = this.items[current];
			const parentItem = this.items[parent];
			if (currentItem === undefined || parentItem === undefined || !this.comesBefore(currentItem, parentItem)) {
				break;
			}
			this.items[current] = parentItem;
			this.items[parent] = currentItem;
			current = parent;
		}
	}

	private bubbleDown(index: number): void {
		let current = index;
		while (true) {
			const left = current * 2 + 1;
			const right = left + 1;
			let best = current;

			const leftItem = this.items[left];
			const rightItem = this.items[right];
			const bestItem = this.items[best];
			if (leftItem !== undefined && bestItem !== undefined && this.comesBefore(leftItem, bestItem)) {
				best = left;
			}
			const newBestItem = this.items[best];
			if (rightItem !== undefined && newBestItem !== undefined && this.comesBefore(rightItem, newBestItem)) {
				best = right;
			}
			if (best === current) {
				break;
			}

			const currentItem = this.items[current];
			const swapItem = this.items[best];
			if (currentItem === undefined || swapItem === undefined) {
				break;
			}
			this.items[current] = swapItem;
			this.items[best] = currentItem;
			current = best;
		}
	}
}

export class TxPool {
	private vm: TxPoolVm;
	private maxSize: number;
	private maxPerSender: number;
	private opened: boolean;
	public running: boolean;

	private _cleanupInterval: ReturnType<typeof setInterval> | undefined;
	private _logInterval: ReturnType<typeof setInterval> | undefined;

	public pool: Map<UnprefixedAddress, TxPoolObject[]>;
	public txsInNonceOrder: Map<UnprefixedAddress, TxPoolTransaction[]> = new Map();
	public txsByHash: Map<UnprefixedHash, TxPoolTransaction> = new Map();
	public txsByNonce: Map<UnprefixedAddress, Map<bigint, TxPoolTransaction>> = new Map();
	public txsInPool: number;
	private handled: Map<UnprefixedHash, HandledObject>;

	public BLOCKS_BEFORE_TARGET_HEIGHT_ACTIVATION = 20;
	public POOLED_STORAGE_TIME_LIMIT = 20;
	public HANDLED_CLEANUP_TIME_LIMIT = 60;

	constructor({ vm, maxSize = MAX_POOL_SIZE, maxPerSender = MAX_TXS_PER_ACCOUNT }: TxPoolOptions) {
		this.vm = vm;
		this.maxSize = maxSize;
		this.maxPerSender = maxPerSender;
		this.pool = new Map<UnprefixedAddress, TxPoolObject[]>();
		this.txsInPool = 0;
		this.handled = new Map<UnprefixedHash, HandledObject>();
		this.txsByHash = new Map<UnprefixedHash, TxPoolTransaction>();
		this.txsByNonce = new Map<UnprefixedAddress, Map<bigint, TxPoolTransaction>>();
		this.txsInNonceOrder = new Map<UnprefixedAddress, TxPoolTransaction[]>();
		this.opened = false;
		this.running = true;
	}

	deepCopy(opt: TxPoolOptions): TxPool {
		const newTxPool = new TxPool(opt);
		newTxPool.pool = new Map(this.pool);
		newTxPool.txsInPool = this.txsInPool;
		newTxPool.handled = new Map(this.handled);
		newTxPool.txsByHash = new Map(this.txsByHash);
		newTxPool.txsByNonce = new Map(this.txsByNonce);
		newTxPool.txsInNonceOrder = new Map(this.txsInNonceOrder);
		newTxPool.opened = this.opened;
		newTxPool.running = this.running;
		return newTxPool;
	}

	open(): boolean {
		if (this.opened) {
			return false;
		}
		this.opened = true;
		return true;
	}

	start(): boolean {
		if (this.running) {
			return false;
		}
		this._cleanupInterval = setInterval(this.cleanup.bind(this), this.POOLED_STORAGE_TIME_LIMIT * 1000 * 60);
		this.running = true;
		return true;
	}

	private validateTxGasBump(existingTx: TxPoolTransaction, addedTx: TxPoolTransaction): void {
		const existingTxGasPrice = this.txGasPrice(existingTx);
		const newGasPrice = this.txGasPrice(addedTx);
		const minTipCap =
			existingTxGasPrice.tip + (existingTxGasPrice.tip * BigInt(MIN_GAS_PRICE_BUMP_PERCENT)) / BigInt(100);
		const minFeeCap =
			existingTxGasPrice.maxFee + (existingTxGasPrice.maxFee * BigInt(MIN_GAS_PRICE_BUMP_PERCENT)) / BigInt(100);
		if (newGasPrice.tip < minTipCap || newGasPrice.maxFee < minFeeCap) {
			throw new Error(
				`replacement gas too low, got tip ${newGasPrice.tip}, min: ${minTipCap}, got fee ${newGasPrice.maxFee}, min: ${minFeeCap}`,
			);
		}

		if (isBlobPoolInstance(addedTx) && isBlobPoolInstance(existingTx)) {
			const minblobGasFee =
				existingTx.maxFeePerBlobGas + (existingTx.maxFeePerBlobGas * BigInt(MIN_GAS_PRICE_BUMP_PERCENT)) / BigInt(100);
			if (addedTx.maxFeePerBlobGas < minblobGasFee) {
				throw new Error(`replacement blob gas too low, got: ${addedTx.maxFeePerBlobGas}, min: ${minblobGasFee}`);
			}
		}
	}

	private async validate(
		tx: TxPoolTransaction,
		isLocalTransaction = false,
		requireSignature = true,
		skipBalance = false,
	): Promise<void> {
		if (requireSignature && !tx.isSigned()) {
			throw new Error("Attempting to add tx to txpool which is not signed");
		}
		if (tx.data.length > TX_MAX_DATA_SIZE) {
			throw new Error(`Tx is too large (${tx.data.length} bytes) and exceeds the max data size of ${TX_MAX_DATA_SIZE} bytes`);
		}
		const currentGasPrice = this.txGasPrice(tx);
		const currentTip = currentGasPrice.tip;
		if (!isLocalTransaction) {
			if (this.txsInPool >= this.maxSize) {
				throw new Error("Transaction pool is full");
			}
			if (currentTip < MIN_GAS_PRICE) {
				throw new Error(`Tx does not pay the minimum gas price of ${MIN_GAS_PRICE}`);
			}
		}

		const senderAddress = tx.getSenderAddress();
		const sender: UnprefixedAddress = senderAddress.toString().slice(2).toLowerCase();
		const inPool = this.pool.get(sender);
		if (inPool) {
			if (!isLocalTransaction && inPool.length >= this.maxPerSender) {
				throw new Error(`Sender has too many transactions: already have ${inPool.length} txs for this account`);
			}
			const existingTxn = inPool.find((poolObj) => poolObj.tx.nonce === tx.nonce);
			if (existingTxn) {
				if (equalsBytes(existingTxn.tx.hash(), tx.hash())) {
					throw new Error(`${bytesToHex(tx.hash())}: this transaction is already in the TxPool`);
				}
				this.validateTxGasBump(existingTxn.tx, tx);
			}
		}

		const block = await this.vm.blockchain.getCanonicalHeadBlock();
		if (typeof block.header.baseFeePerGas === "bigint" && block.header.baseFeePerGas !== 0n) {
			if (currentGasPrice.maxFee < block.header.baseFeePerGas / 2n && !isLocalTransaction) {
				throw new Error(
					`Tx cannot pay basefee of ${block.header.baseFeePerGas}, have ${currentGasPrice.maxFee} (not within 50% range of current basefee)`,
				);
			}
		}
		if (tx.gasLimit > block.header.gasLimit) {
			throw new Error(
				`Tx gaslimit of ${tx.gasLimit} exceeds block gas limit of ${block.header.gasLimit} (exceeds last block gas limit)`,
			);
		}

		const vmCopy = await this.vm.deepCopy();
		let account = await vmCopy.stateManager.getAccount(senderAddress);
		if (account === undefined) {
			account = new Account();
		}
		if (account.nonce > tx.nonce) {
			throw new Error(
				`0x${sender} tries to send a tx with nonce ${tx.nonce}, but account has nonce ${account.nonce} (tx nonce too low)`,
			);
		}
		const minimumBalance = tx.value + currentGasPrice.maxFee * tx.gasLimit;
		if (!skipBalance && account.balance < minimumBalance) {
			throw new Error(
				`0x${sender} does not have enough balance to cover transaction costs, need ${minimumBalance}, but have ${account.balance} (insufficient balance)`,
			);
		}
	}

	async addUnverified(tx: TxPoolTransaction): Promise<TxPoolAddResult> {
		const hash: UnprefixedHash = bytesToUnprefixedHex(tx.hash());
		const added = Date.now();
		const address: UnprefixedAddress = tx.getSenderAddress().toString().slice(2).toLowerCase();
		try {
			let add: TxPoolObject[] = this.pool.get(address) ?? [];
			const inPool = this.pool.get(address);

			this.txsByHash.set(hash, tx);

			let nonceMap = this.txsByNonce.get(address);
			if (!nonceMap) {
				nonceMap = new Map();
				this.txsByNonce.set(address, nonceMap);
			}
			nonceMap.set(tx.nonce, tx);

			let txList = this.txsInNonceOrder.get(address) ?? [];
			txList = txList.filter((existingTx) => existingTx.nonce !== tx.nonce);
			txList.push(tx);
			txList.sort((a, b) => Number(a.nonce - b.nonce));
			this.txsInNonceOrder.set(address, txList);

			if (inPool) {
				add = inPool.filter((poolObj) => poolObj.tx.nonce !== tx.nonce);
			}
			add.push({ tx, added, hash });
			this.pool.set(address, add);
			this.handled.set(hash, { address, added });
			this.txsInPool++;

			this.fireEvent("txadded", bytesToHex(tx.hash()));

			return { error: null, hash: bytesToHex(tx.hash()) };
		} catch (e) {
			this.handled.set(hash, { address, added, error: e as Error });
			return { error: (e as Error).message, hash: bytesToHex(tx.hash()) };
		}
	}

	async add(tx: TxPoolTransaction, requireSignature = true, skipBalance = false): Promise<TxPoolAddResult> {
		try {
			await this.validate(tx, true, requireSignature, skipBalance);
			return this.addUnverified(tx);
		} catch (error) {
			return {
				error: (error as Error).message,
				hash: bytesToHex(tx.hash()),
			};
		}
	}

	getByHash(txHashes: string): TxPoolTransaction | null;
	getByHash(txHashes: ReadonlyArray<Uint8Array>): TxPoolTransaction[];
	getByHash(txHashes: ReadonlyArray<Uint8Array> | string): TxPoolTransaction[] | TxPoolTransaction | null {
		if (typeof txHashes === "string") {
			const txHashStr = txHashes.startsWith("0x") ? txHashes.slice(2).toLowerCase() : txHashes.toLowerCase();
			const handled = this.handled.get(txHashStr);
			if (!handled) return null;
			const inPool = this.pool.get(handled.address)?.filter((poolObj) => poolObj.hash === txHashStr);
			if (inPool && inPool.length === 1) {
				if (!inPool[0]) {
					throw new Error("Expected element to exist in pool");
				}
				return inPool[0].tx;
			}
			return null;
		}

		const found: TxPoolTransaction[] = [];
		for (const txHash of txHashes) {
			const txHashStr = bytesToUnprefixedHex(txHash);
			const handled = this.handled.get(txHashStr);
			if (!handled) continue;
			const inPool = this.pool.get(handled.address)?.filter((poolObj) => poolObj.hash === txHashStr);
			if (inPool && inPool.length === 1) {
				if (!inPool[0]) {
					throw new Error("Expected element to exist in pool");
				}
				found.push(inPool[0].tx);
			}
		}
		return found;
	}

	removeByHash(txHash: string): void {
		const unprefixedTxHash = txHash.startsWith("0x") ? txHash.slice(2).toLowerCase() : txHash.toLowerCase();
		const handled = this.handled.get(unprefixedTxHash);
		if (!handled) return;
		const { address } = handled;

		this.txsByHash.delete(unprefixedTxHash);

		const poolObjects = this.pool.get(address);
		if (!poolObjects) return;

		const txToRemove = poolObjects.find((poolObj) => poolObj.hash === unprefixedTxHash);
		if (txToRemove) {
			const nonceMap = this.txsByNonce.get(address);
			if (nonceMap) {
				nonceMap.delete(txToRemove.tx.nonce);
				if (nonceMap.size === 0) {
					this.txsByNonce.delete(address);
				}
			}

			const txList = this.txsInNonceOrder.get(address);
			if (txList) {
				const newTxList = txList.filter((tx) => tx.nonce !== txToRemove.tx.nonce);
				if (newTxList.length === 0) {
					this.txsInNonceOrder.delete(address);
				} else {
					this.txsInNonceOrder.set(address, newTxList);
				}
			}
		}

		const newPoolObjects = poolObjects.filter((poolObj) => poolObj.hash !== unprefixedTxHash);
		this.txsInPool--;
		if (newPoolObjects.length === 0) {
			this.pool.delete(address);
		} else {
			this.pool.set(address, newPoolObjects);
		}

		this.fireEvent("txremoved", `0x${unprefixedTxHash}`);
	}

	removeNewBlockTxs(newBlocks: TxPoolBlock[]): void {
		if (!this.running) return;
		for (const block of newBlocks) {
			for (const tx of block.transactions) {
				const txHash: UnprefixedHash = bytesToUnprefixedHex(tx.hash());
				this.removeByHash(txHash);
			}
		}
	}

	cleanup(): void {
		let compDate = Date.now() - this.POOLED_STORAGE_TIME_LIMIT * 1000 * 60;
		for (const [i, mapToClean] of [this.pool].entries()) {
			for (const [key, objects] of mapToClean) {
				const updatedObjects = objects.filter((obj) => obj.added >= compDate);
				if (updatedObjects.length < objects.length) {
					if (i === 0) this.txsInPool -= objects.length - updatedObjects.length;
					if (updatedObjects.length === 0) {
						mapToClean.delete(key);
					} else {
						mapToClean.set(key, updatedObjects);
					}
				}
			}
		}

		compDate = Date.now() - this.HANDLED_CLEANUP_TIME_LIMIT * 1000 * 60;
		for (const [address, handleObj] of this.handled) {
			if (handleObj.added < compDate) {
				this.handled.delete(address);
			}
		}
	}

	private normalizedGasPrice(tx: TxPoolTransaction, baseFee?: bigint): bigint {
		const supports1559 = tx.supports(Capability.EIP1559FeeMarket);
		if (typeof baseFee === "bigint" && baseFee !== 0n) {
			if (supports1559) {
				return (tx as FeeMarketEIP1559Transaction).maxPriorityFeePerGas;
			}
			return (tx as LegacyTransaction).gasPrice - baseFee;
		}
		if (supports1559) {
			return (tx as FeeMarketEIP1559Transaction).maxFeePerGas;
		}
		return (tx as LegacyTransaction).gasPrice;
	}

	private txGasPrice(tx: TxPoolTransaction): GasPrice {
		if ("isImpersonated" in tx && tx.isImpersonated) {
			return {
				maxFee: tx.maxFeePerGas,
				tip: tx.maxPriorityFeePerGas,
			};
		}
		if (isLegacyTx(tx)) {
			return {
				maxFee: tx.gasPrice,
				tip: tx.gasPrice,
			};
		}

		if (isAccessListEIP2930Tx(tx)) {
			return {
				maxFee: tx.gasPrice,
				tip: tx.gasPrice,
			};
		}

		if (isFeeMarketEIP1559Tx(tx) || isBlobEIP4844Tx(tx)) {
			return {
				maxFee: tx.maxFeePerGas,
				tip: tx.maxPriorityFeePerGas,
			};
		}
		throw new Error(`tx of type ${(tx as TypedTransaction).type} unknown`);
	}

	async getBySenderAddress(address: Address): Promise<TxPoolObject[]> {
		const unprefixedAddress = address.toString().slice(2).toLowerCase();
		return this.pool.get(unprefixedAddress) ?? [];
	}

	async getPendingTransactions(): Promise<TxPoolTransaction[]> {
		const allTxs: TxPoolTransaction[] = [];
		for (const txs of this.pool.values()) {
			allTxs.push(...txs.map((obj) => obj.tx));
		}
		return allTxs;
	}

	async getTransactionStatus(txHash: string): Promise<"pending" | "mined" | "unknown"> {
		const hash = txHash.startsWith("0x") ? txHash.slice(2).toLowerCase() : txHash.toLowerCase();

		if (this.txsByHash.has(hash)) {
			return "pending";
		}

		const handled = this.handled.get(hash);
		if (handled) {
			return "mined";
		}

		return "unknown";
	}

	private events: { [key: string]: Array<(hash: string) => void> } = {
		txadded: [],
		txremoved: [],
	};

	on(event: "txadded" | "txremoved", callback: (hash: string) => void): () => void {
		if (!this.events[event]) {
			this.events[event] = [];
		}
		this.events[event].push(callback);

		return () => {
			this.events[event] = this.events[event]?.filter((cb) => cb !== callback) ?? [];
		};
	}

	private fireEvent(event: "txadded" | "txremoved", hash: string): void {
		if (this.events[event]) {
			for (const callback of this.events[event]) {
				callback(hash);
			}
		}
	}

	async onBlockAdded(block: TxPoolBlock): Promise<void> {
		this.removeNewBlockTxs([block]);
	}

	async onChainReorganization(removedBlocks: TxPoolBlock[], addedBlocks: TxPoolBlock[]): Promise<void> {
		for (const block of removedBlocks) {
			for (const tx of block.transactions) {
				const txHash = bytesToHex(tx.hash());
				const txHashUnprefixed = txHash.slice(2).toLowerCase();
				if (this.txsByHash.has(txHashUnprefixed)) continue;

				await this.addUnverified(tx);
			}
		}

		this.removeNewBlockTxs(addedBlocks);
	}

	async txsByPriceAndNonce({ baseFee, allowedBlobs }: { baseFee?: bigint; allowedBlobs?: number } = {}): Promise<
		TxPoolTransaction[]
	> {
		const txs: TxPoolTransaction[] = [];
		const byNonce = new Map<string, TxPoolTransaction[]>();
		const skippedStats = { byNonce: 0, byPrice: 0, byBlobsLimit: 0 };
		for (const [address, poolObjects] of this.pool) {
			let txsSortedByNonce = poolObjects.map((obj) => obj.tx).sort((a, b) => Number(a.nonce - b.nonce));
			if (typeof baseFee === "bigint" && baseFee !== 0n) {
				const found = txsSortedByNonce.findIndex((tx) => this.normalizedGasPrice(tx) < baseFee);
				if (found > -1) {
					skippedStats.byPrice += found + 1;
					txsSortedByNonce = txsSortedByNonce.slice(0, found);
				}
			}
			byNonce.set(address, txsSortedByNonce);
		}

		const byPrice = new PriorityQueue<TxPoolTransaction>(
			(a, b) => this.normalizedGasPrice(b, baseFee) - this.normalizedGasPrice(a, baseFee) < 0n,
		);
		for (const [address, accountTxs] of byNonce) {
			if (!accountTxs[0]) {
				continue;
			}
			byPrice.insert(accountTxs[0]);
			byNonce.set(address, accountTxs.slice(1));
		}

		let blobsCount = 0;
		while (byPrice.length > 0) {
			const best = byPrice.remove();
			if (best === undefined) break;

			const address = best.getSenderAddress().toString().slice(2).toLowerCase();
			const accTxs = byNonce.get(address);

			if (!accTxs) {
				throw new Error("Expected accTxs to be defined");
			}

			if (
				!isBlobPoolInstance(best) ||
				allowedBlobs === undefined ||
				((best as BlobEIP4844Transaction).blobs ?? []).length + blobsCount <= allowedBlobs
			) {
				if (accTxs.length > 0) {
					if (!accTxs[0]) {
						throw new Error("Expected accTxs to be defined");
					}
					byPrice.insert(accTxs[0]);
					byNonce.set(address, accTxs.slice(1));
				}
				txs.push(best);
				if (isBlobPoolInstance(best)) {
					blobsCount += ((best as BlobEIP4844Transaction).blobs ?? []).length;
				}
			} else {
				skippedStats.byBlobsLimit += 1 + accTxs.length;
				byNonce.set(address, []);
			}
		}
		return txs;
	}

	stop(): boolean {
		if (!this.running) return false;
		clearInterval(this._cleanupInterval);
		clearInterval(this._logInterval);
		this.running = false;
		return true;
	}

	close(): void {
		this.pool.clear();
		this.handled.clear();
		this.txsByHash.clear();
		this.txsByNonce.clear();
		this.txsInNonceOrder.clear();
		this.txsInPool = 0;
		this.opened = false;
	}

	async clear(): Promise<void> {
		this.pool.clear();
		this.txsByHash.clear();
		this.txsByNonce.clear();
		this.txsInNonceOrder.clear();
		this.txsInPool = 0;
	}

	logStats(): void {
		console.log("TxPool Stats:");
		console.log(`  Pending: ${this.txsInPool}`);
		console.log(`  Handled: ${this.handled.size}`);

		let handledadds = 0;
		let handlederrors = 0;
		for (const handledobject of this.handled.values()) {
			if (handledobject.error === undefined) {
				handledadds++;
			} else {
				handlederrors++;
			}
		}

		console.log(`  Successful: ${handledadds}`);
		console.log(`  Errors: ${handlederrors}`);

		const addresses = Array.from(this.pool.keys());
		console.log(`  Unique accounts: ${addresses.length}`);
	}

	_logPoolStats(): void {
		this.logStats();
	}
}
