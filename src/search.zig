const std = @import("std");

// an inverted index over any xitdb cursor: a sorted map from word to the
// sorted set of doc keys whose text holds it. a doc key is opaque bytes whose
// sort order is the order results come back in.

// the shortest word indexed or queried. a single character would expand to
// hundreds of words under prefix matching.
const min_word_len = 2;
// a longer word is truncated to this rather than skipped, so a prefix query
// still reaches it.
const max_word_len = 32;
// how many distinct words one document contributes.
const max_words_per_doc = 64;
// how much of a document is tokenized.
pub const max_indexed_bytes = 4 * 1024;
// how many indexed words one typed word expands to.
const max_expansions = 50;
// the largest doc key, so results are read into a buffer rather than allocated.
pub const max_doc_key_len = 64;

// index `text` under `doc_key`.
pub fn add(
    comptime DB: type,
    index: DB.SortedMap(.read_write),
    allocator: std.mem.Allocator,
    doc_key: []const u8,
    text: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (try tokenize(arena.allocator(), text)) |word| {
        const set = try DB.SortedSet(.read_write).init(try index.putCursor(word));
        try set.put(doc_key);
    }
}

// drop `doc_key`'s postings. the caller supplies the text again, so no forward
// index is stored.
pub fn remove(
    comptime DB: type,
    index: DB.SortedMap(.read_write),
    allocator: std.mem.Allocator,
    doc_key: []const u8,
    text: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (try tokenize(arena.allocator(), text)) |word| {
        if (null == try index.getCursor(word)) continue;
        const set = try DB.SortedSet(.read_write).init(try index.putCursor(word));
        _ = try set.remove(doc_key);
        if (0 == try set.count()) _ = try index.remove(word);
    }
}

// the doc keys holding every typed word, in key order. a stream, so callers
// stop at their page size.
pub fn Query(comptime DB: type) type {
    return struct {
        // one per typed word; empty when nothing can match
        terms: []Term,
        // the key the next result starts from, plus room for the one byte that
        // steps past a returned key
        pos: [max_doc_key_len + 1]u8 = undefined,
        pos_len: usize = 0,
        // whether `pos` holds a key that was already returned
        returned: bool = false,

        const Self = @This();

        // one typed word: the doc keys of every indexed word it expands to,
        // merged into one ascending stream.
        const Term = struct {
            postings: []Posting,

            // the smallest doc key at or after `key`, or null when the term is
            // exhausted.
            fn seek(self: *Term, key: []const u8) !?[]const u8 {
                var best: ?[]const u8 = null;
                for (self.postings) |*posting| {
                    try posting.advance(key);
                    if (posting.done) continue;
                    const current = posting.key[0..posting.key_len];
                    if (best) |found| {
                        if (std.mem.order(u8, current, found) == .lt) best = current;
                    } else best = current;
                }
                return best;
            }
        };

        // one indexed word's doc keys, positioned at the current one.
        const Posting = struct {
            set: DB.SortedSet(.read_only),
            key: [max_doc_key_len]u8 = undefined,
            key_len: usize = 0,
            done: bool = false,
            started: bool = false,

            // move to the first key at or after `key`. seeking rather than
            // stepping keeps the cost proportional to the results.
            fn advance(self: *Posting, key: []const u8) !void {
                if (self.done) return;
                if (self.started and std.mem.order(u8, self.key[0..self.key_len], key) != .lt) return;
                var iter = try self.set.iteratorFrom(key);
                self.started = true;
                const cursor = (try iter.next()) orelse {
                    self.done = true;
                    return;
                };
                const pair = try cursor.readKeyValuePair();
                self.key_len = (try pair.key_cursor.readBytes(&self.key)).len;
            }
        };

        pub fn init(index: DB.SortedMap(.read_only), aa: std.mem.Allocator, text: []const u8) !Self {
            var terms: std.ArrayList(Term) = .empty;
            for (try tokenize(aa, text)) |word| {
                var postings: std.ArrayList(Posting) = .empty;
                var iter = try index.iteratorFrom(word);
                while (try iter.next()) |cursor| {
                    if (postings.items.len == max_expansions) break;
                    const pair = try cursor.readKeyValuePair();
                    var buffer: [max_word_len]u8 = undefined;
                    const indexed = try pair.key_cursor.readBytes(&buffer);
                    if (!std.mem.startsWith(u8, indexed, word)) break;
                    try postings.append(aa, .{ .set = try DB.SortedSet(.read_only).init(pair.value_cursor) });
                }
                // a word nothing starts with rules out every document
                if (postings.items.len == 0) return .{ .terms = &.{} };
                try terms.append(aa, .{ .postings = postings.items });
            }
            return .{ .terms = terms.items };
        }

        // start the next result at `key` rather than the first one.
        pub fn seek(self: *Self, key: []const u8) void {
            @memcpy(self.pos[0..key.len], key);
            self.pos_len = key.len;
            self.returned = false;
        }

        pub fn next(self: *Self) !?[]const u8 {
            if (self.terms.len == 0) return null;
            if (self.returned) {
                // doc keys are at most max_doc_key_len, so appending a byte
                // lands strictly after the one just returned
                self.pos[self.pos_len] = 0;
                self.pos_len += 1;
                self.returned = false;
            }
            // intersect by seeking: a term that lands past the candidate makes
            // its key the new candidate and the others seek up to it.
            var i: usize = 0;
            while (i < self.terms.len) {
                const key = (try self.terms[i].seek(self.pos[0..self.pos_len])) orelse return null;
                if (std.mem.order(u8, key, self.pos[0..self.pos_len]) == .gt) {
                    @memcpy(self.pos[0..key.len], key);
                    self.pos_len = key.len;
                    i = 0;
                    continue;
                }
                i += 1;
            }
            self.returned = true;
            return self.pos[0..self.pos_len];
        }
    };
}

// the unique lowercased words of `text`, in the order they first appear.
fn tokenize(aa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var words: std.StringArrayHashMapUnmanaged(void) = .empty;
    const limit = @min(text.len, max_indexed_bytes);
    var i: usize = 0;
    while (i < limit) {
        if (!isWordByte(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < limit and isWordByte(text[i])) i += 1;
        const word = text[start..@min(i, start + max_word_len)];
        if (word.len < min_word_len) continue;
        const lowered = try aa.alloc(u8, word.len);
        _ = std.ascii.lowerString(lowered, word);
        try words.put(aa, lowered, {});
        if (words.count() == max_words_per_doc) break;
    }
    return words.keys();
}

// a word is a run of ascii alphanumerics and non-ascii bytes.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte >= 0x80;
}
