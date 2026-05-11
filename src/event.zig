const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const mrg = xit.merge;

pub const event_id_size: usize = 32;

pub const EventKind = enum {
    issue,
};

pub const EventData = union(EventKind) {
    issue: struct {
        title: []const u8,
        description: []const u8,
        tags: []const u8,
    },

    pub fn read(
        comptime DB: type,
        comptime hash_kind: hash.HashKind,
        allocator: std.mem.Allocator,
        map: DB.HashMap(.read_only),
        kind: EventKind,
    ) !EventData {
        return switch (kind) {
            .issue => .{
                .issue = .{
                    .title = try readBytes(DB, hash_kind, allocator, map, "title"),
                    .description = try readBytes(DB, hash_kind, allocator, map, "description"),
                    .tags = try readBytes(DB, hash_kind, allocator, map, "tags"),
                },
            },
        };
    }

    fn readBytes(
        comptime DB: type,
        comptime hash_kind: hash.HashKind,
        allocator: std.mem.Allocator,
        map: DB.HashMap(.read_only),
        field_name: []const u8,
    ) ![]const u8 {
        const cursor = try map.getCursor(hash.hashInt(hash_kind, field_name)) orelse return error.NotFound;
        return try cursor.readBytesAlloc(allocator, null);
    }
};

pub const Event = struct {
    id: [event_id_size * 2]u8,
    data: EventData,
};

/// associates an Event with a git object id.
/// we save this oid in the database so we can reliably re-consume
/// events if their oid changed. this can happen if the branch
/// is rebased and force-pushed.
pub fn RepoEvent(comptime hash_kind: hash.HashKind) type {
    return struct {
        parent_oid: ?[hash.byteLen(hash_kind)]u8,
        oid: [hash.byteLen(hash_kind)]u8,
        event: ?Event, // if null, this is a merge commit
    };
}

pub fn randomId(random: std.Random) [event_id_size]u8 {
    var id_bytes: [event_id_size]u8 = undefined;
    random.bytes(&id_bytes);
    return id_bytes;
}

pub fn consume(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(.xit, repo_opts),
    repo_events: []RepoEvent(repo_opts.hash),
) !void {
    const DB = rp.Repo(.xit, repo_opts).DB;

    const Ctx = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        repo: *rp.Repo(.xit, repo_opts),
        repo_events: []RepoEvent(repo_opts.hash),

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            const moment = try DB.HashMap(.read_write).init(cursor.*);

            // the last_object_id represents the object id that was last consumed
            var last_object_id_maybe: ?[hash.byteLen(repo_opts.hash)]u8 = null;
            if (try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id"))) |last_object_id_cursor| {
                var last_object_id_buffer: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                _ = try last_object_id_cursor.readBytes(&last_object_id_buffer);
                last_object_id_maybe = last_object_id_buffer;
            }

            // the list with all of haxy's state, including materialized views.
            // the reason it is a list is so we can keep every previous haxy
            // state, making it easy to revert to an older state if the user
            // rebases some of the past commits.
            const haxy_cursor = try moment.putCursor(hash.hashInt(repo_opts.hash, "haxy"));
            const haxy = try DB.ArrayList(.read_write).init(haxy_cursor);

            // add a new item to the haxy list created above.
            // we call the item haxy_moments. it is a map of object id to haxy moment.
            // in other words, it maps each object id to a hash map containing the
            // state that the database was in when that object id was consumed.
            var haxy_moments_cursor = try haxy.appendCursor();
            // use the previous haxy_moments as the basis for this one if it exists
            if (try haxy.getCursor(-2)) |last_haxy_moments_cursor| {
                try haxy_moments_cursor.write(.{ .slot = last_haxy_moments_cursor.slot() });
            }
            var haxy_moments = try DB.HashMap(.read_write).init(haxy_moments_cursor);

            // if this branch was rebased and force pushed, we need to detect that and
            // properly revert the haxy state to the last valid state. we detect this
            // by simply asking if the last event is a descendent of the last event
            // we consumed. if it isn't, then we know the haxy state needs to be reverted.
            // from that point on, the rest of the events should be descendents so we no
            // longer need to even check. this boolean lets us know if that has happened.
            var checked_for_rebase = false;

            // iterate over the events in reverse order
            // (they are sorted by most recent events first)
            for (0..ctx.repo_events.len) |i| {
                const repo_event = ctx.repo_events[ctx.repo_events.len - i - 1];

                // if this object id has already been consumed, skip it
                if (null != try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &repo_event.oid))) {
                    continue;
                }

                if (!checked_for_rebase) {
                    checked_for_rebase = true;

                    if (last_object_id_maybe) |*last_object_id| {
                        var moment_read_only = moment.readOnly();
                        const state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = &ctx.repo.core, .extra = .{ .moment = &moment_read_only } };

                        // if the last event isn't a descendent of the last event that
                        // we consumed, the branch was rebased so we need to revert the
                        // haxy state back to where it was when this event's parent was
                        // consumed. from that point on, we can consume the rest of the
                        // events on top of that state.
                        _ = mrg.getDescendent(
                            .xit,
                            repo_opts,
                            state,
                            ctx.io,
                            ctx.allocator,
                            &std.fmt.bytesToHex(last_object_id, .lower),
                            &std.fmt.bytesToHex(ctx.repo_events[0].oid, .lower),
                        ) catch |err| switch (err) {
                            error.DescendentNotFound => {
                                if (repo_event.parent_oid) |*parent_oid| {
                                    const old_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, parent_oid)) orelse return error.CursorNotFound;
                                    const old_moment = try DB.HashMap(.read_only).init(old_moment_cursor);

                                    const old_moment_index_cursor = try old_moment.getCursor(hash.hashInt(repo_opts.hash, "moment-index")) orelse return error.CursorNotFound;
                                    const old_moment_index = try old_moment_index_cursor.readUint();

                                    // resize the haxy list so we truncate all the moments that were
                                    // created after the parent_oid was consumed
                                    try haxy.slice(old_moment_index + 1);

                                    // make a new haxy moment and set its initial value to the last haxy moment
                                    haxy_moments_cursor = try haxy.appendCursor();
                                    const old_haxy_moments_cursor = try haxy.getCursor(old_moment_index) orelse return error.CursorNotFound;
                                    try haxy_moments_cursor.write(.{ .slot = old_haxy_moments_cursor.slot() });
                                    haxy_moments = try DB.HashMap(.read_write).init(haxy_moments_cursor);

                                    last_object_id_maybe = parent_oid.*;
                                } else {
                                    // the branch was rebased all the way to the very beginning.
                                    // we have a repo event with no parent, which means it is now
                                    // the very first event. all we need to do is set the haxy list
                                    // to be empty and make a new haxy_moments map to work with.

                                    try haxy.slice(0);
                                    haxy_moments_cursor = try haxy.appendCursor();
                                    haxy_moments = try DB.HashMap(.read_write).init(haxy_moments_cursor);

                                    last_object_id_maybe = null;
                                }
                            },
                            else => |e| return e,
                        };
                    } else {
                        if (repo_event.parent_oid) |_| {
                            // there is no last_object_id, but this event has a parent.
                            // this is an invalid state. if the event has a parent, that
                            // implies that an event has already been processed, but
                            // if that's true then there would be a last_object_id.
                            return error.UnexpectedParent;
                        }
                    }
                }

                // create a moment for this object id
                var haxy_moment_cursor = try haxy_moments.putCursor(hash.bytesToInt(repo_opts.hash, &repo_event.oid));

                // if there was a previous object id, make this haxy moment's initial value to it.
                // this efficiently "clones" the map so we make further modifications based on it.
                if (last_object_id_maybe) |*last_object_id| {
                    if (try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, last_object_id))) |last_haxy_moment_cursor| {
                        try haxy_moment_cursor.write(.{ .slot = last_haxy_moment_cursor.slot() });
                    }
                }

                const haxy_moment = try DB.HashMap(.read_write).init(haxy_moment_cursor);

                // associate this moment with the index it will first appear at in the haxy list.
                // this will be important later so we can truncate that list if the user ever
                // rebases starting at this object id.
                try haxy_moment.put(hash.hashInt(repo_opts.hash, "moment-index"), .{ .uint = try haxy.count() - 1 });

                // consume the event into the views map.
                // if the event is null, it was just a merge commit
                // so we don't need to update any views.
                if (repo_event.event) |event| {
                    // get the id of the current event as bytes
                    var current_event_id: [event_id_size]u8 = undefined;
                    _ = try std.fmt.hexToBytes(&current_event_id, &event.id);

                    switch (event.data) {
                        .issue => |data| {
                            const event_id_to_issue_cursor = try haxy_moment.putCursor(hash.hashInt(repo_opts.hash, "event-id->issue"));
                            const event_id_to_issue = try DB.HashMap(.read_write).init(event_id_to_issue_cursor);

                            const issue_cursor = try event_id_to_issue.putCursor(hash.hashInt(repo_opts.hash, &current_event_id));
                            const issue = try DB.HashMap(.read_write).init(issue_cursor);

                            try upsert(DB, repo_opts.hash, issue, @TypeOf(data), data);
                        },
                    }
                }

                // the current object id is now the last one
                last_object_id_maybe = repo_event.oid;

                // prevent any of the data created above from being mutated by future iterations of this loop
                try cursor.db.freeze();
            }

            if (last_object_id_maybe) |*last_object_id| {
                try moment.put(hash.hashInt(repo_opts.hash, "haxy-last-object-id"), .{ .bytes = last_object_id });
            }
        }
    };

    try repo.core.db_file.lock(io, .exclusive);
    defer repo.core.db_file.unlock(io);

    // create a new transaction in the database that runs the above-defined Ctx function
    const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
    try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
        .io = io,
        .allocator = allocator,
        .repo = repo,
        .repo_events = repo_events,
    });
}

fn upsert(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    map: DB.HashMap(.read_write),
    comptime Data: type,
    data: Data,
) !void {
    switch (@typeInfo(Data)) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                try upsertField(DB, hash_kind, map, field.name, field.type, @field(data, field.name));
            }
        },
        else => @compileError("upsert expects a struct"),
    }
}

fn upsertField(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    map: DB.HashMap(.read_write),
    comptime field_name: []const u8,
    comptime Field: type,
    value: Field,
) !void {
    const key = hash.hashInt(hash_kind, field_name);

    switch (@typeInfo(Field)) {
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                try upsertBytes(DB, hash_kind, map, key, value);
            } else {
                @compileError("unsupported upsert field type: " ++ @typeName(Field));
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                try upsertBytes(DB, hash_kind, map, key, &value);
            } else {
                @compileError("unsupported upsert field type: " ++ @typeName(Field));
            }
        },
        .int => |int_info| switch (int_info.signedness) {
            .unsigned => {
                if (try map.getCursor(key)) |value_cursor| {
                    if (try value_cursor.readUint() == value) {
                        return;
                    }
                }

                try map.put(key, .{ .uint = value });
            },
            .signed => {
                if (try map.getCursor(key)) |value_cursor| {
                    if (try value_cursor.readInt() == value) {
                        return;
                    }
                }

                try map.put(key, .{ .int = value });
            },
        },
        else => @compileError("unsupported upsert field type: " ++ @typeName(Field)),
    }
}

fn upsertBytes(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    map: DB.HashMap(.read_write),
    key: hash.HashInt(hash_kind),
    value: []const u8,
) !void {
    var existing_cursor_maybe = try map.getCursor(key);
    if (existing_cursor_maybe) |*existing_cursor| {
        if (try bytesEqual(DB, existing_cursor, value)) {
            return;
        }
    }

    var value_cursor = try map.putCursor(key);
    var write_buffer: [1024]u8 = undefined;
    var writer = try value_cursor.writer(&write_buffer);
    try writer.interface.writeAll(value);
    try writer.finish();
}

fn bytesEqual(
    comptime DB: type,
    cursor: *DB.Cursor(.read_only),
    value: []const u8,
) !bool {
    var read_buffer: [1024]u8 = undefined;
    var reader = try cursor.reader(&read_buffer);
    if (reader.size != value.len) {
        return false;
    }

    var chunk_buffer: [1024]u8 = undefined;
    var offset: usize = 0;
    while (offset < value.len) {
        const chunk_len = @min(chunk_buffer.len, value.len - offset);
        try reader.interface.readSliceAll(chunk_buffer[0..chunk_len]);
        if (!std.mem.eql(u8, chunk_buffer[0..chunk_len], value[offset .. offset + chunk_len])) {
            return false;
        }
        offset += chunk_len;
    }

    return true;
}
