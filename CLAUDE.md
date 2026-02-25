# CLAUDE.md

## Project Context

- **We maintain voltaire (`../voltaire`) and guillotine-mini (`../guillotine-mini`).** They are upstream dependencies and we own them. Fix any issues in those repos directly rather than working around them.

## Zig Style

- **No local type aliases.** Do not create `const Foo = bar.Foo` aliases at the top of files. Always use the fully qualified path inline (e.g. `std.mem.Allocator`, `primitives.Address`, `primitives.AccountState.AccountState`). The only exception is the import itself (`const std = @import("std")`).
- **No stored allocators.** Do not store an allocator in a struct. Instead, pass the allocator explicitly to the methods that actually need it.
