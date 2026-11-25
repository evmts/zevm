//! Execution extensions (ExEx): node lifecycle events delivered to
//! in-process extensions running on their own threads.
//!
//! The module has three parts:
//!
//! - `Event`: a tagged union of every lifecycle event the node can emit.
//! - `EventIterator` and `EventHub`: a bounded, drop-oldest ring buffer per
//!   subscriber and a fan-out hub that clones each emitted event into every
//!   open subscriber. A slow extension never blocks the node; it loses its
//!   oldest events and can read the loss from `missedCount()`.
//! - `NodeWith(RuntimeType, Extensions)`: a comptime wrapper that owns the
//!   runtime, the hub, and one thread per extension. `NodeWith(R, .{})`
//!   stores no hub and no threads, and `emit` compiles to nothing.
//!
//! Ownership rules:
//!
//! - An `Event` passed to `EventHub.emit` or `NodeWith.emit` is borrowed. The
//!   hub clones it once per subscriber, so the caller keeps ownership.
//! - An `Event` returned by `EventIterator.next` or `tryNext` is owned by the
//!   caller. Free it with `event.deinit(iterator.allocator)`.
//! - `EventIterator.push` takes ownership of its argument, including on
//!   failure.
//!
//! This file imports only `std` so the event contract does not depend on the
//! runtime. The `*Tag` enums mirror runtime enums by tag name; `Tag.from`
//! fails to compile if the runtime enum gains a tag this module lacks.

const std = @import("std");

/// Default per-subscriber ring buffer capacity.
pub const DEFAULT_EVENT_CAPACITY: usize = 256;

// ---------------------------------------------------------------------------
// Mirror tags
// ---------------------------------------------------------------------------

/// Mirrors `node/runtime.zig` `Mode`.
pub const ModeTag = enum {
    trusted,
    light,

    pub fn from(value: anytype) ModeTag {
        return mirrorTag(ModeTag, value);
    }
};

/// Mirrors `mining.zig` `MiningConfigType` (accepts the enum or the
/// `MiningConfig` union).
pub const MiningModeTag = enum {
    auto,
    manual,
    interval,

    pub fn from(value: anytype) MiningModeTag {
        return mirrorTag(MiningModeTag, value);
    }
};

/// Mirrors `consensus_sync.zig` `SyncStatus`.
pub const SyncStatusTag = enum {
    syncing,
    synced,
    err,

    pub fn from(value: anytype) SyncStatusTag {
        return mirrorTag(SyncStatusTag, value);
    }
};

/// Converts an enum or tagged-union value to the enum `Tag` with the same tag
/// name. A tag missing from `Tag` is a compile error.
fn mirrorTag(comptime Tag: type, value: anytype) Tag {
    const tag = switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => value,
        .@"union" => std.meta.activeTag(value),
        else => @compileError("mirrorTag expects an enum or tagged union, found " ++ @typeName(@TypeOf(value))),
    };
    switch (tag) {
        inline else => |known| return @field(Tag, @tagName(known)),
    }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

pub const NodeStartedEvent = struct {
    mode: ModeTag,
    chain_id: u64,
    host: []const u8,
    port: u16,
};

pub const NodeStoppingEvent = struct {
    mode: ModeTag,
};

pub const BlockCommittedEvent = struct {
    block_number: u64,
    block_hash: [32]u8,
    parent_hash: [32]u8,
    timestamp: u64,
    gas_used: u64,
    tx_count: usize,
    tx_hashes: [][32]u8,
    receipt_count: usize,
    state_diff_count: usize,
};

pub const BlockRevertedEvent = struct {
    reverted_block_number: u64,
    new_head_number: u64,
    new_head_hash: [32]u8,
};

pub const TxPoolAddEvent = struct {
    tx_hash: [32]u8,
    sender: [20]u8,
    nonce: u64,
};

pub const TxDropReason = enum { mined, dropped, replaced };

pub const TxPoolDropEvent = struct {
    tx_hash: [32]u8,
    reason: TxDropReason,
};

pub const StateField = enum { balance, nonce, code, storage };

/// One account field change. `balance`, `nonce`, and `storage` use the
/// `*_u256` values; `code` uses the `*_bytes` values; `storage` also sets
/// `storage_slot`.
pub const StateChangeEvent = struct {
    address: [20]u8,
    field: StateField,
    storage_slot: ?u256 = null,
    old_u256: ?u256 = null,
    new_u256: ?u256 = null,
    old_bytes: ?[]u8 = null,
    new_bytes: ?[]u8 = null,
};

pub const SnapshotCreatedEvent = struct {
    snapshot_id: u64,
    block_number: u64,
};

pub const SnapshotRevertedEvent = struct {
    snapshot_id: u64,
    success: bool,
    new_head_number: u64,
};

pub const ForkChangedEvent = struct {
    enabled: bool,
    url: ?[]u8,
    block_number: ?u64,
    follow: bool,
};

pub const MiningModeChangedEvent = struct {
    mode: MiningModeTag,
    interval_seconds: u64,
};

pub const ChainIdChangedEvent = struct {
    old_chain_id: u64,
    new_chain_id: u64,
};

pub const ImpersonationChangedEvent = struct {
    address: ?[20]u8,
    impersonating: bool,
    auto_impersonate: bool,
};

pub const TimeAdjustedEvent = struct {
    next_timestamp: ?u64,
    interval_seconds: ?u64,
    delta_seconds: ?i64,
};

pub const CoinbaseChangedEvent = struct {
    old_coinbase: [20]u8,
    new_coinbase: [20]u8,
};

pub const BlockGasLimitChangedEvent = struct {
    old_gas_limit: u64,
    new_gas_limit: u64,
};

pub const SyncStatusChangedEvent = struct {
    old_status: SyncStatusTag,
    new_status: SyncStatusTag,
    ready: bool,
};

pub const ReadinessChangedEvent = struct {
    ready: bool,
};

pub const CheckpointAcceptedEvent = struct {
    checkpoint: [32]u8,
};

pub const HeadUpdatedEvent = struct {
    optimistic_slot: u64,
    safe_slot: u64,
    finalized_slot: u64,
};

pub const RebaseStartedEvent = struct {
    old_fork_block: u64,
    new_upstream_head: u64,
};

pub const RebaseTxReplayedEvent = struct {
    tx_hash: [32]u8,
    new_block_number: u64,
    skipped_execution: bool,
};

pub const RebaseTxDroppedEvent = struct {
    tx_hash: [32]u8,
    reason: []u8,
};

pub const RebaseCompletedEvent = struct {
    new_fork_block: u64,
    replayed_count: usize,
    dropped_count: usize,
};

/// Every node lifecycle event. Slice fields (`[]T` and `?[]T`) are owned by
/// the event after `clone` and released by `deinit`; all other fields are
/// plain values.
pub const Event = union(enum) {
    // Shared.
    node_started: NodeStartedEvent,
    node_stopping: NodeStoppingEvent,
    // Trusted block lifecycle (#15).
    block_committed: BlockCommittedEvent,
    block_reverted: BlockRevertedEvent,
    // Trusted tx pool (#16).
    tx_pool_add: TxPoolAddEvent,
    tx_pool_drop: TxPoolDropEvent,
    // Trusted state change (#16).
    state_change: StateChangeEvent,
    // Trusted control surface (#16).
    snapshot_created: SnapshotCreatedEvent,
    snapshot_reverted: SnapshotRevertedEvent,
    fork_changed: ForkChangedEvent,
    mining_mode_changed: MiningModeChangedEvent,
    chain_id_changed: ChainIdChangedEvent,
    impersonation_changed: ImpersonationChangedEvent,
    time_adjusted: TimeAdjustedEvent,
    coinbase_changed: CoinbaseChangedEvent,
    block_gas_limit_changed: BlockGasLimitChangedEvent,
    // Light mode (#17).
    sync_status_changed: SyncStatusChangedEvent,
    readiness_changed: ReadinessChangedEvent,
    checkpoint_accepted: CheckpointAcceptedEvent,
    head_updated: HeadUpdatedEvent,
    // Rebase fork (#21).
    rebase_started: RebaseStartedEvent,
    rebase_tx_replayed: RebaseTxReplayedEvent,
    rebase_tx_dropped: RebaseTxDroppedEvent,
    rebase_completed: RebaseCompletedEvent,

    /// Returns a deep copy whose slices are allocated with `allocator`. On
    /// error, nothing is leaked.
    pub fn clone(self: Event, allocator: std.mem.Allocator) std.mem.Allocator.Error!Event {
        switch (self) {
            inline else => |payload, tag| {
                const copy = try clonePayload(@TypeOf(payload), allocator, payload);
                return @unionInit(Event, @tagName(tag), copy);
            },
        }
    }

    /// Frees every slice the event owns. Call only on events produced by
    /// `clone` (or returned by an `EventIterator`).
    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*payload| deinitPayload(@TypeOf(payload.*), allocator, payload),
        }
        self.* = undefined;
    }
};

const FieldKind = enum { plain, slice, optional_slice };

fn fieldKind(comptime T: type) FieldKind {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .slice) @compileError("Event payloads may only hold slice pointers, found " ++ @typeName(T));
            return .slice;
        },
        .optional => |optional| switch (@typeInfo(optional.child)) {
            .pointer => |pointer| {
                if (pointer.size != .slice) @compileError("Event payloads may only hold slice pointers, found " ++ @typeName(T));
                return .optional_slice;
            },
            else => return .plain,
        },
        else => return .plain,
    }
}

fn SliceElement(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        .optional => |optional| @typeInfo(optional.child).pointer.child,
        else => @compileError("not a slice: " ++ @typeName(T)),
    };
}

fn clonePayload(comptime T: type, allocator: std.mem.Allocator, source: T) std.mem.Allocator.Error!T {
    const fields = @typeInfo(T).@"struct".fields;
    var copy = source;
    // Clear every owned slice first so the errdefer only frees what this
    // function allocated. A zero-length slice is a no-op for
    // `Allocator.free`.
    inline for (fields) |field| {
        switch (comptime fieldKind(field.type)) {
            .plain => {},
            .slice => @field(copy, field.name).len = 0,
            .optional_slice => @field(copy, field.name) = null,
        }
    }
    errdefer deinitPayload(T, allocator, &copy);
    inline for (fields) |field| {
        switch (comptime fieldKind(field.type)) {
            .plain => {},
            .slice => @field(copy, field.name) = try allocator.dupe(SliceElement(field.type), @field(source, field.name)),
            .optional_slice => if (@field(source, field.name)) |slice| {
                @field(copy, field.name) = try allocator.dupe(SliceElement(field.type), slice);
            },
        }
    }
    return copy;
}

fn deinitPayload(comptime T: type, allocator: std.mem.Allocator, payload: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        switch (comptime fieldKind(field.type)) {
            .plain => {},
            .slice => allocator.free(@field(payload.*, field.name)),
            .optional_slice => if (@field(payload.*, field.name)) |slice| allocator.free(slice),
        }
    }
}

// ---------------------------------------------------------------------------
// EventIterator
// ---------------------------------------------------------------------------

/// A single consumer's bounded event queue. When full, `push` frees the
/// oldest event, increments `missedCount()`, and stores the new event, so the
/// producer never blocks.
pub const EventIterator = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    buffer: []Event,
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,
    detached: bool = false,
    missed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !EventIterator {
        if (capacity == 0) return error.InvalidCapacity;
        return .{
            .allocator = allocator,
            .buffer = try allocator.alloc(Event, capacity),
        };
    }

    /// Frees buffered events and the buffer. No thread may be using the
    /// iterator.
    pub fn deinit(self: *EventIterator) void {
        self.discardBufferedLocked();
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    /// Takes ownership of `event`. Returns false (and frees `event`) if the
    /// iterator is closed.
    pub fn push(self: *EventIterator, event: Event) bool {
        var owned = event;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) {
            owned.deinit(self.allocator);
            return false;
        }
        if (self.len == self.buffer.len) {
            self.buffer[self.head].deinit(self.allocator);
            self.head = (self.head + 1) % self.buffer.len;
            self.len -= 1;
            self.missed += 1;
        }
        self.buffer[(self.head + self.len) % self.buffer.len] = owned;
        self.len += 1;
        self.condition.signal();
        return true;
    }

    /// Blocks until an event is available. Returns null once the iterator is
    /// closed and drained. The caller owns the returned event.
    pub fn next(self: *EventIterator) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.len == 0 and !self.closed) self.condition.wait(&self.mutex);
        return self.popLocked();
    }

    /// Returns the oldest buffered event without blocking, or null. The
    /// caller owns the returned event.
    pub fn tryNext(self: *EventIterator) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.popLocked();
    }

    /// Stops accepting events and wakes waiters. Buffered events stay
    /// readable, so a consumer drains them before `next` returns null.
    pub fn close(self: *EventIterator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.condition.broadcast();
    }

    /// Closes the iterator and frees buffered events. Used when the consumer
    /// has exited and will never read again.
    pub fn detach(self: *EventIterator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.detached = true;
        self.discardBufferedLocked();
        self.condition.broadcast();
    }

    fn detachIfNotClosed(self: *EventIterator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closed) {
            self.closed = true;
            self.detached = true;
        }
        self.discardBufferedLocked();
        self.condition.broadcast();
    }

    /// Number of events lost because the buffer was full or a clone failed.
    pub fn missedCount(self: *EventIterator) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.missed;
    }

    pub fn isClosed(self: *EventIterator) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed;
    }

    pub fn isDetached(self: *EventIterator) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.detached;
    }

    fn recordMissed(self: *EventIterator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.missed += 1;
    }

    fn popLocked(self: *EventIterator) ?Event {
        if (self.len == 0) return null;
        const event = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.len -= 1;
        return event;
    }

    fn discardBufferedLocked(self: *EventIterator) void {
        while (self.popLocked()) |buffered| {
            var event = buffered;
            event.deinit(self.allocator);
        }
        self.head = 0;
    }
};

// ---------------------------------------------------------------------------
// EventHub
// ---------------------------------------------------------------------------

/// Fans each emitted event out to every open subscriber. The hub owns its
/// subscribers and frees them in `deinit`.
pub const EventHub = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    subscribers: std.ArrayList(*EventIterator) = .empty,

    pub fn init(allocator: std.mem.Allocator) EventHub {
        return .{ .allocator = allocator };
    }

    /// Frees every subscriber. No thread may still use a subscriber.
    pub fn deinit(self: *EventHub) void {
        for (self.subscribers.items) |iterator| {
            iterator.deinit();
            self.allocator.destroy(iterator);
        }
        self.subscribers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Adds a subscriber with a ring buffer of `capacity` events. The pointer
    /// stays valid until `deinit`.
    pub fn subscribe(self: *EventHub, capacity: usize) !*EventIterator {
        const iterator = try self.allocator.create(EventIterator);
        errdefer self.allocator.destroy(iterator);
        iterator.* = try EventIterator.init(self.allocator, capacity);
        errdefer iterator.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.subscribers.append(self.allocator, iterator);
        return iterator;
    }

    /// Clones `event` into every open subscriber. Never fails: a clone
    /// failure counts as a missed event for that subscriber.
    pub fn emit(self: *EventHub, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscribers.items) |iterator| {
            if (iterator.isClosed()) continue;
            const copy = event.clone(self.allocator) catch {
                iterator.recordMissed();
                continue;
            };
            _ = iterator.push(copy);
        }
    }

    /// Closes every subscriber so blocked consumers drain and exit.
    pub fn closeAll(self: *EventHub) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscribers.items) |iterator| iterator.close();
    }

    /// True if any subscriber is still open. Producers can skip building
    /// expensive events when this is false.
    pub fn hasSubscribers(self: *EventHub) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscribers.items) |iterator| {
            if (!iterator.isClosed()) return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// NodeWith
// ---------------------------------------------------------------------------

/// Wraps `RuntimeType` with a tuple of extension types.
///
/// `RuntimeType` must provide `init(allocator, config) !RuntimeType` and
/// `deinit(*RuntimeType) void`. If it has an `event_hub: ?*EventHub` field,
/// the node points it at its hub while extensions are installed.
///
/// Each extension type must provide
/// `pub fn run(node: *RuntimeType, events: *EventIterator) !void` (or
/// `void`). `run` executes on its own thread and shares the runtime with the
/// node, so it must synchronize any runtime access itself.
///
/// The node must not move after `init`: the hub and runtime are referenced by
/// address.
pub fn NodeWith(comptime RuntimeType: type, comptime Extensions: anytype) type {
    comptime validateRuntime(RuntimeType);
    comptime validateExtensions(RuntimeType, Extensions);
    const extension_fields = @typeInfo(@TypeOf(Extensions)).@"struct".fields;

    return struct {
        const Self = @This();

        pub const Runtime = RuntimeType;
        pub const Config = @typeInfo(@TypeOf(RuntimeType.init)).@"fn".params[1].type.?;
        pub const extension_count: usize = extension_fields.len;
        pub const has_extensions: bool = extension_count > 0;

        runtime: RuntimeType,
        hub: if (has_extensions) EventHub else void = if (has_extensions) undefined else {},
        iterators: if (has_extensions) [extension_count]*EventIterator else void = if (has_extensions) undefined else {},
        threads: if (has_extensions) [extension_count]?std.Thread else void = if (has_extensions) [_]?std.Thread{null} ** extension_count else {},
        started: if (has_extensions) bool else void = if (has_extensions) false else {},

        /// Initializes the runtime in place and, with extensions, subscribes
        /// one iterator per extension. Events emitted before
        /// `startExtensions` are buffered.
        pub fn init(self: *Self, allocator: std.mem.Allocator, config: Config) !void {
            self.* = .{ .runtime = try RuntimeType.init(allocator, config) };
            errdefer self.runtime.deinit();
            if (comptime has_extensions) {
                self.hub = EventHub.init(allocator);
                errdefer self.hub.deinit();
                for (&self.iterators) |*slot| {
                    slot.* = try self.hub.subscribe(DEFAULT_EVENT_CAPACITY);
                }
                if (comptime @hasField(RuntimeType, "event_hub")) self.runtime.event_hub = &self.hub;
            }
        }

        /// Spawns one thread per extension. An extension that returns, or
        /// returns an error, detaches its iterator; the node and the other
        /// extensions keep running.
        pub fn startExtensions(self: *Self) !void {
            if (comptime has_extensions) {
                if (self.started) return error.ExtensionsAlreadyStarted;
                self.started = true;
                inline for (extension_fields, 0..) |field, index| {
                    const Ext = @field(Extensions, field.name);
                    const iterator = self.iterators[index];
                    self.threads[index] = std.Thread.spawn(.{}, ExtensionThread(Ext).main, .{ &self.runtime, iterator }) catch |err| {
                        for (self.iterators[index..]) |unstarted| unstarted.detach();
                        return err;
                    };
                }
            }
        }

        /// Delivers a borrowed event to every extension. Compiles to nothing
        /// without extensions.
        pub fn emit(self: *Self, event: Event) void {
            if (comptime has_extensions) self.hub.emit(event);
        }

        /// Closes every iterator and joins every extension thread. Buffered
        /// events are drained by extensions still running.
        pub fn stopExtensions(self: *Self) void {
            if (comptime has_extensions) {
                self.hub.closeAll();
                for (&self.threads) |*slot| {
                    if (slot.*) |thread| {
                        thread.join();
                        slot.* = null;
                    }
                }
            }
        }

        pub fn deinit(self: *Self) void {
            if (comptime has_extensions) {
                self.stopExtensions();
                if (comptime @hasField(RuntimeType, "event_hub")) self.runtime.event_hub = null;
                self.hub.deinit();
            }
            self.runtime.deinit();
            self.* = undefined;
        }

        fn ExtensionThread(comptime Ext: type) type {
            return struct {
                fn main(runtime: *RuntimeType, events: *EventIterator) void {
                    defer events.detachIfNotClosed();
                    const result: anyerror!void = Ext.run(runtime, events);
                    result catch |err| {
                        std.log.scoped(.exex).warn("extension {s} exited with error: {s}", .{ @typeName(Ext), @errorName(err) });
                    };
                }
            };
        }
    };
}

fn validateRuntime(comptime RuntimeType: type) void {
    if (!@hasDecl(RuntimeType, "init")) @compileError(@typeName(RuntimeType) ++ " must declare init(allocator, config) !Self");
    if (!@hasDecl(RuntimeType, "deinit")) @compileError(@typeName(RuntimeType) ++ " must declare deinit(*Self) void");
    const init_info = @typeInfo(@TypeOf(RuntimeType.init));
    if (init_info != .@"fn" or init_info.@"fn".params.len != 2) {
        @compileError(@typeName(RuntimeType) ++ ".init must take (allocator, config)");
    }
    if (@hasField(RuntimeType, "event_hub")) {
        if (@FieldType(RuntimeType, "event_hub") != ?*EventHub) {
            @compileError(@typeName(RuntimeType) ++ ".event_hub must have type ?*exex.EventHub");
        }
    }
}

fn validateExtensions(comptime RuntimeType: type, comptime Extensions: anytype) void {
    const info = @typeInfo(@TypeOf(Extensions));
    if (info != .@"struct") @compileError("NodeWith extensions must be a tuple of types, e.g. .{ MyExtension }");
    inline for (info.@"struct".fields) |field| {
        const Ext = @field(Extensions, field.name);
        if (@TypeOf(Ext) != type) @compileError("NodeWith extension '" ++ field.name ++ "' is not a type");
        const name = @typeName(Ext);
        if (!@hasDecl(Ext, "run")) @compileError(name ++ " must declare pub fn run(*" ++ @typeName(RuntimeType) ++ ", *EventIterator) !void");
        const run_info = @typeInfo(@TypeOf(Ext.run));
        if (run_info != .@"fn") @compileError(name ++ ".run must be a function");
        const run_fn = run_info.@"fn";
        if (run_fn.params.len != 2 or
            (run_fn.params[0].type orelse void) != *RuntimeType or
            (run_fn.params[1].type orelse void) != *EventIterator)
        {
            @compileError(name ++ ".run must take (*" ++ @typeName(RuntimeType) ++ ", *EventIterator)");
        }
        const Return = run_fn.return_type orelse @compileError(name ++ ".run must not be generic");
        const returns_void = Return == void or
            (@typeInfo(Return) == .error_union and @typeInfo(Return).error_union.payload == void);
        if (!returns_void) @compileError(name ++ ".run must return void or !void");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const MockConfig = struct {
    chain_id: u64 = 1,
};

const MockRecord = struct {
    block_numbers: [8]u64 = undefined,
    block_count: usize = 0,
    host_ok: bool = false,
    host_ptr: usize = 0,
    tx_hashes_ok: bool = true,
    tx_hashes_ptr: usize = 0,
    ran: bool = false,
};

const MockRuntime = struct {
    chain_id: u64,
    event_hub: ?*EventHub = null,
    mutex: std.Thread.Mutex = .{},
    records: [3]MockRecord = [_]MockRecord{.{}} ** 3,

    pub fn init(allocator: std.mem.Allocator, config: MockConfig) !MockRuntime {
        _ = allocator;
        return .{ .chain_id = config.chain_id };
    }

    pub fn deinit(self: *MockRuntime) void {
        self.* = undefined;
    }

    fn record(self: *MockRuntime, slot: usize, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = &self.records[slot];
        entry.ran = true;
        switch (event) {
            .node_started => |started| {
                entry.host_ok = std.mem.eql(u8, started.host, "127.0.0.1");
                entry.host_ptr = @intFromPtr(started.host.ptr);
            },
            .block_committed => |block| {
                entry.block_numbers[entry.block_count] = block.block_number;
                entry.block_count += 1;
                entry.tx_hashes_ptr = @intFromPtr(block.tx_hashes.ptr);
                entry.tx_hashes_ok = entry.tx_hashes_ok and block.tx_hashes.len == 2 and
                    block.tx_hashes[0][0] == 0xaa and block.tx_hashes[1][0] == 0xbb;
            },
            else => {},
        }
    }
};

fn RecordingExtension(comptime slot: usize) type {
    return struct {
        pub fn run(node: *MockRuntime, events: *EventIterator) !void {
            while (events.next()) |received| {
                var event = received;
                defer event.deinit(events.allocator);
                node.record(slot, event);
            }
        }
    };
}

const FailingExtension = struct {
    pub fn run(node: *MockRuntime, events: *EventIterator) !void {
        _ = node;
        _ = events;
        return error.ExtensionFailed;
    }
};

const ReturningExtension = struct {
    pub fn run(node: *MockRuntime, events: *EventIterator) void {
        _ = node;
        _ = events;
    }
};

fn testBlock(block_number: u64, tx_hashes: [][32]u8) Event {
    return .{ .block_committed = .{
        .block_number = block_number,
        .block_hash = [_]u8{@intCast(block_number)} ** 32,
        .parent_hash = [_]u8{0} ** 32,
        .timestamp = 1_700_000_000 + block_number,
        .gas_used = 21_000,
        .tx_count = tx_hashes.len,
        .tx_hashes = tx_hashes,
        .receipt_count = tx_hashes.len,
        .state_diff_count = 0,
    } };
}

fn testDropped(marker: u8, reason: []u8) Event {
    return .{ .rebase_tx_dropped = .{ .tx_hash = [_]u8{marker} ** 32, .reason = reason } };
}

test "NodeWith without extensions stores no hub or threads and emit is a no-op" {
    const Node = NodeWith(MockRuntime, .{});
    comptime std.debug.assert(Node.extension_count == 0);
    comptime std.debug.assert(!Node.has_extensions);
    try std.testing.expectEqual(0, @sizeOf(@FieldType(Node, "hub")));
    try std.testing.expectEqual(0, @sizeOf(@FieldType(Node, "threads")));
    try std.testing.expectEqual(0, @sizeOf(@FieldType(Node, "iterators")));
    try std.testing.expectEqual(@sizeOf(MockRuntime), @sizeOf(Node));

    var node: Node = undefined;
    try node.init(std.testing.allocator, .{ .chain_id = 7 });
    defer node.deinit();
    try node.startExtensions();
    node.emit(.{ .node_stopping = .{ .mode = .trusted } });
    node.stopExtensions();
    try std.testing.expectEqual(7, node.runtime.chain_id);
    try std.testing.expect(node.runtime.event_hub == null);
}

test "single extension receives emitted events" {
    const Node = NodeWith(MockRuntime, .{RecordingExtension(0)});
    comptime std.debug.assert(Node.extension_count == 1);

    var node: Node = undefined;
    try node.init(std.testing.allocator, .{});
    defer node.deinit();
    try std.testing.expect(node.runtime.event_hub.? == &node.hub);
    try node.startExtensions();
    try std.testing.expectError(error.ExtensionsAlreadyStarted, node.startExtensions());

    var tx_hashes = [_][32]u8{ [_]u8{0xaa} ** 32, [_]u8{0xbb} ** 32 };
    node.emit(testBlock(1, &tx_hashes));
    node.emit(testBlock(2, &tx_hashes));
    node.stopExtensions();

    const entry = node.runtime.records[0];
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, entry.block_numbers[0..entry.block_count]);
    try std.testing.expect(entry.tx_hashes_ok);
}

test "multiple extensions receive identical cloned events independently" {
    const Node = NodeWith(MockRuntime, .{ RecordingExtension(0), RecordingExtension(1) });
    comptime std.debug.assert(Node.extension_count == 2);

    var node: Node = undefined;
    try node.init(std.testing.allocator, .{});
    defer node.deinit();
    // Emitted before start: buffered, not lost.
    var host = "127.0.0.1".*;
    node.emit(.{ .node_started = .{ .mode = .trusted, .chain_id = 31337, .host = &host, .port = 8545 } });
    try node.startExtensions();

    var tx_hashes = [_][32]u8{ [_]u8{0xaa} ** 32, [_]u8{0xbb} ** 32 };
    for (1..4) |block_number| node.emit(testBlock(block_number, &tx_hashes));
    node.stopExtensions();

    for (node.runtime.records[0..2]) |entry| {
        try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, entry.block_numbers[0..entry.block_count]);
        try std.testing.expect(entry.host_ok);
        try std.testing.expect(entry.host_ptr != @intFromPtr(&host));
        try std.testing.expect(entry.tx_hashes_ok);
        try std.testing.expect(entry.tx_hashes_ptr != @intFromPtr(&tx_hashes));
    }
    for (node.iterators) |iterator| try std.testing.expectEqual(0, iterator.missedCount());
}

test "ring buffer drops oldest events and counts misses without leaking" {
    var hub = EventHub.init(std.testing.allocator);
    defer hub.deinit();
    const iterator = try hub.subscribe(2);

    var reason = "nonce too low".*;
    for (0..5) |marker| hub.emit(testDropped(@intCast(marker), &reason));
    try std.testing.expectEqual(3, iterator.missedCount());

    for ([_]u8{ 3, 4 }) |expected| {
        var event = iterator.tryNext() orelse return error.TestExpectedEvent;
        defer event.deinit(iterator.allocator);
        try std.testing.expectEqual(expected, event.rebase_tx_dropped.tx_hash[0]);
        try std.testing.expectEqualStrings("nonce too low", event.rebase_tx_dropped.reason);
        try std.testing.expect(@intFromPtr(event.rebase_tx_dropped.reason.ptr) != @intFromPtr(&reason));
    }
    try std.testing.expect(iterator.tryNext() == null);

    // Leave events buffered: hub.deinit must free them.
    hub.emit(testDropped(9, &reason));
}

test "EventIterator rejects zero capacity" {
    try std.testing.expectError(error.InvalidCapacity, EventIterator.init(std.testing.allocator, 0));
}

test "next blocks until events arrive and returns null after close and drain" {
    var hub = EventHub.init(std.testing.allocator);
    defer hub.deinit();
    const iterator = try hub.subscribe(DEFAULT_EVENT_CAPACITY);

    const Consumer = struct {
        fn run(events: *EventIterator, count: *usize) void {
            while (events.next()) |received| {
                var event = received;
                event.deinit(events.allocator);
                count.* += 1;
            }
        }
    };
    var count: usize = 0;
    const thread = try std.Thread.spawn(.{}, Consumer.run, .{ iterator, &count });

    var reason = "underpriced".*;
    for (0..3) |marker| hub.emit(testDropped(@intCast(marker), &reason));
    try std.testing.expect(hub.hasSubscribers());
    hub.closeAll();
    thread.join();

    try std.testing.expectEqual(3, count);
    try std.testing.expect(!hub.hasSubscribers());
    // Emitting to closed subscribers is ignored and leaks nothing.
    hub.emit(testDropped(7, &reason));
}

test "extensions that return or fail detach without affecting the node or peers" {
    const Node = NodeWith(MockRuntime, .{ FailingExtension, ReturningExtension, RecordingExtension(2) });

    var node: Node = undefined;
    try node.init(std.testing.allocator, .{ .chain_id = 5 });
    defer node.deinit();
    try node.startExtensions();

    var tx_hashes = [_][32]u8{ [_]u8{0xaa} ** 32, [_]u8{0xbb} ** 32 };
    for (1..4) |block_number| node.emit(testBlock(block_number, &tx_hashes));
    var spins: usize = 0;
    while ((!node.iterators[0].isDetached() or !node.iterators[1].isDetached()) and spins < 10_000) : (spins += 1) {
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    node.stopExtensions();

    try std.testing.expect(node.iterators[0].isDetached());
    try std.testing.expect(node.iterators[1].isDetached());
    try std.testing.expect(!node.iterators[2].isDetached());
    const entry = node.runtime.records[2];
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, entry.block_numbers[0..entry.block_count]);
    try std.testing.expectEqual(5, node.runtime.chain_id);

    // The node keeps emitting after every extension has stopped.
    node.emit(testBlock(4, &tx_hashes));
}

test "deinit closes iterators and joins blocked extension threads" {
    const Node = NodeWith(MockRuntime, .{ RecordingExtension(0), RecordingExtension(1) });

    var node: Node = undefined;
    try node.init(std.testing.allocator, .{});
    try node.startExtensions();
    var tx_hashes = [_][32]u8{ [_]u8{0xaa} ** 32, [_]u8{0xbb} ** 32 };
    node.emit(testBlock(1, &tx_hashes));
    // Extensions are blocked in next(); deinit must wake, join, and free.
    node.deinit();
}

test "deinit without startExtensions frees buffered events" {
    const Node = NodeWith(MockRuntime, .{RecordingExtension(0)});

    var node: Node = undefined;
    try node.init(std.testing.allocator, .{});
    var host = "127.0.0.1".*;
    node.emit(.{ .node_started = .{ .mode = .light, .chain_id = 1, .host = &host, .port = 8545 } });
    node.deinit();
}

test "Event clone and deinit own every slice field" {
    const allocator = std.testing.allocator;
    var host = "localhost".*;
    var url = "http://127.0.0.1:8545".*;
    var old_code = [_]u8{ 0x60, 0x00 };
    var new_code = [_]u8{ 0x60, 0x01, 0x00 };
    var reason = "reverted".*;
    var tx_hashes = [_][32]u8{ [_]u8{0xaa} ** 32, [_]u8{0xbb} ** 32 };

    const events = [_]Event{
        .{ .node_started = .{ .mode = .trusted, .chain_id = 1, .host = &host, .port = 1 } },
        testBlock(1, &tx_hashes),
        .{ .state_change = .{ .address = [_]u8{1} ** 20, .field = .code, .old_bytes = &old_code, .new_bytes = &new_code } },
        .{ .state_change = .{ .address = [_]u8{1} ** 20, .field = .storage, .storage_slot = 3, .old_u256 = 0, .new_u256 = 9 } },
        .{ .fork_changed = .{ .enabled = true, .url = &url, .block_number = 100, .follow = false } },
        .{ .fork_changed = .{ .enabled = false, .url = null, .block_number = null, .follow = false } },
        testDropped(1, &reason),
        .{ .chain_id_changed = .{ .old_chain_id = 1, .new_chain_id = 2 } },
    };
    for (events) |event| {
        var copy = try event.clone(allocator);
        defer copy.deinit(allocator);
        try std.testing.expectEqual(std.meta.activeTag(event), std.meta.activeTag(copy));
    }

    var copy = try events[2].clone(allocator);
    defer copy.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &new_code, copy.state_change.new_bytes.?);
    try std.testing.expect(@intFromPtr(copy.state_change.new_bytes.?.ptr) != @intFromPtr(&new_code));
}

test "Event clone frees partial copies on allocation failure" {
    var new_code = [_]u8{0x00};
    var old_code = [_]u8{0x01};
    const event: Event = .{ .state_change = .{
        .address = [_]u8{1} ** 20,
        .field = .code,
        .old_bytes = &old_code,
        .new_bytes = &new_code,
    } };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, event.clone(failing.allocator()));
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
}

test "mirror tags convert runtime enums and unions by tag name" {
    const RuntimeMode = enum { trusted, light };
    const RuntimeMining = union(enum) { auto: void, manual: void, interval: struct { block_time: u64 } };
    const RuntimeSync = enum { syncing, synced, err };

    try std.testing.expectEqual(ModeTag.light, ModeTag.from(RuntimeMode.light));
    try std.testing.expectEqual(MiningModeTag.interval, MiningModeTag.from(RuntimeMining{ .interval = .{ .block_time = 2 } }));
    try std.testing.expectEqual(MiningModeTag.auto, MiningModeTag.from(RuntimeMining.auto));
    try std.testing.expectEqual(SyncStatusTag.err, SyncStatusTag.from(RuntimeSync.err));
}
