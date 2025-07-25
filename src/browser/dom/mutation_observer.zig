// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;
const Loop = @import("../../runtime/loop.zig").Loop;

const Env = @import("../env.zig").Env;
const NodeList = @import("nodelist.zig").NodeList;

pub const Interfaces = .{
    MutationObserver,
    MutationRecord,
};

const Walker = @import("../dom/walker.zig").WalkerChildren;

// WEB IDL https://dom.spec.whatwg.org/#interface-mutationobserver
pub const MutationObserver = struct {
    loop: *Loop,
    cbk: Env.Function,
    arena: Allocator,
    connected: bool,
    scheduled: bool,
    loop_node: Loop.CallbackNode,

    // List of records which were observed. When the call scope ends, we need to
    // execute our callback with it.
    observed: std.ArrayListUnmanaged(MutationRecord),

    pub fn constructor(cbk: Env.Function, page: *Page) !MutationObserver {
        return .{
            .cbk = cbk,
            .loop = page.loop,
            .observed = .{},
            .connected = true,
            .scheduled = false,
            .arena = page.arena,
            .loop_node = .{ .func = callback },
        };
    }

    pub fn _observe(self: *MutationObserver, node: *parser.Node, options_: ?Options) !void {
        const arena = self.arena;
        var options = options_ orelse Options{};
        if (options.attributeFilter.len > 0) {
            options.attributeFilter = try arena.dupe([]const u8, options.attributeFilter);
        }

        const observer = try arena.create(Observer);
        observer.* = .{
            .node = node,
            .options = options,
            .mutation_observer = self,
            .event_node = .{ .id = self.cbk.id, .func = Observer.handle },
        };

        // register node's events
        if (options.childList or options.subtree) {
            _ = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMNodeInserted",
                &observer.event_node,
                false,
            );
            _ = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMNodeRemoved",
                &observer.event_node,
                false,
            );
        }
        if (options.attr()) {
            _ = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMAttrModified",
                &observer.event_node,
                false,
            );
        }
        if (options.cdata()) {
            _ = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMCharacterDataModified",
                &observer.event_node,
                false,
            );
        }
        if (options.subtree) {
            _ = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMSubtreeModified",
                &observer.event_node,
                false,
            );
        }
    }

    fn callback(node: *Loop.CallbackNode, _: *?u63) void {
        const self: *MutationObserver = @fieldParentPtr("loop_node", node);
        if (self.connected == false) {
            self.scheduled = true;
            return;
        }
        self.scheduled = false;

        const records = self.observed.items;
        if (records.len == 0) {
            return;
        }

        defer self.observed.clearRetainingCapacity();

        var result: Env.Function.Result = undefined;
        self.cbk.tryCall(void, .{records}, &result) catch {
            log.debug(.user_script, "callback error", .{
                .err = result.exception,
                .stack = result.stack,
                .source = "mutation observer",
            });
        };
    }

    // TODO
    pub fn _disconnect(self: *MutationObserver) !void {
        self.connected = false;
    }

    // TODO
    pub fn _takeRecords(_: *const MutationObserver) ?[]const u8 {
        return &[_]u8{};
    }
};

pub const MutationRecord = struct {
    type: []const u8,
    target: *parser.Node,
    added_nodes: NodeList = .{},
    removed_nodes: NodeList = .{},
    previous_sibling: ?*parser.Node = null,
    next_sibling: ?*parser.Node = null,
    attribute_name: ?[]const u8 = null,
    attribute_namespace: ?[]const u8 = null,
    old_value: ?[]const u8 = null,

    pub fn get_type(self: *const MutationRecord) []const u8 {
        return self.type;
    }

    pub fn get_addedNodes(self: *MutationRecord) *NodeList {
        return &self.added_nodes;
    }

    pub fn get_removedNodes(self: *MutationRecord) *NodeList {
        return &self.removed_nodes;
    }

    pub fn get_target(self: *const MutationRecord) *parser.Node {
        return self.target;
    }

    pub fn get_attributeName(self: *const MutationRecord) ?[]const u8 {
        return self.attribute_name;
    }

    pub fn get_attributeNamespace(self: *const MutationRecord) ?[]const u8 {
        return self.attribute_namespace;
    }

    pub fn get_previousSibling(self: *const MutationRecord) ?*parser.Node {
        return self.previous_sibling;
    }

    pub fn get_nextSibling(self: *const MutationRecord) ?*parser.Node {
        return self.next_sibling;
    }

    pub fn get_oldValue(self: *const MutationRecord) ?[]const u8 {
        return self.old_value;
    }
};

const Options = struct {
    childList: bool = false,
    attributes: bool = false,
    characterData: bool = false,
    subtree: bool = false,
    attributeOldValue: bool = false,
    characterDataOldValue: bool = false,
    attributeFilter: [][]const u8 = &.{},

    fn attr(self: Options) bool {
        return self.attributes or self.attributeOldValue or self.attributeFilter.len > 0;
    }

    fn cdata(self: Options) bool {
        return self.characterData or self.characterDataOldValue;
    }
};

const Observer = struct {
    node: *parser.Node,
    options: Options,

    // reference back to the MutationObserver so that we can access the arena
    // and batch the mutation records.
    mutation_observer: *MutationObserver,

    event_node: parser.EventNode,

    fn appliesTo(
        self: *const Observer,
        target: *parser.Node,
        event_type: MutationEventType,
        event: *parser.MutationEvent,
    ) !bool {
        if (event_type == .DOMAttrModified and self.options.attributeFilter.len > 0) {
            const attribute_name = try parser.mutationEventAttributeName(event);
            for (self.options.attributeFilter) |needle| blk: {
                if (std.mem.eql(u8, attribute_name, needle)) {
                    break :blk;
                }
            }
            return false;
        }

        // mutation on any target is always ok.
        if (self.options.subtree) {
            return true;
        }

        // if target equals node, alway ok.
        if (target == self.node) {
            return true;
        }

        // no subtree, no same target and no childlist, always noky.
        if (!self.options.childList) {
            return false;
        }

        // target must be a child of o.node
        const walker = Walker{};
        var next: ?*parser.Node = null;
        while (true) {
            next = walker.get_next(self.node, next) catch break orelse break;
            if (next.? == target) {
                return true;
            }
        }

        return false;
    }

    fn handle(en: *parser.EventNode, event: *parser.Event) void {
        const self: *Observer = @fieldParentPtr("event_node", en);
        self._handle(event) catch |err| {
            log.err(.web_api, "handle error", .{ .err = err, .source = "mutation observer" });
        };
    }

    fn _handle(self: *Observer, event: *parser.Event) !void {
        var mutation_observer = self.mutation_observer;

        const node = blk: {
            const event_target = try parser.eventTarget(event) orelse return;
            break :blk parser.eventTargetToNode(event_target);
        };

        const mutation_event = parser.eventToMutationEvent(event);
        const event_type = blk: {
            const t = try parser.eventType(event);
            break :blk std.meta.stringToEnum(MutationEventType, t) orelse return;
        };

        if (try self.appliesTo(node, event_type, mutation_event) == false) {
            return;
        }

        var record = MutationRecord{
            .target = self.node,
            .type = event_type.recordType(),
        };

        const arena = mutation_observer.arena;
        switch (event_type) {
            .DOMAttrModified => {
                record.attribute_name = parser.mutationEventAttributeName(mutation_event) catch null;
                if (self.options.attributeOldValue) {
                    record.old_value = parser.mutationEventPrevValue(mutation_event) catch null;
                }
            },
            .DOMCharacterDataModified => {
                if (self.options.characterDataOldValue) {
                    record.old_value = parser.mutationEventPrevValue(mutation_event) catch null;
                }
            },
            .DOMNodeInserted => {
                if (parser.mutationEventRelatedNode(mutation_event) catch null) |related_node| {
                    try record.added_nodes.append(arena, related_node);
                }
            },
            .DOMNodeRemoved => {
                if (parser.mutationEventRelatedNode(mutation_event) catch null) |related_node| {
                    try record.removed_nodes.append(arena, related_node);
                }
            },
        }

        try mutation_observer.observed.append(arena, record);

        if (mutation_observer.scheduled == false) {
            mutation_observer.scheduled = true;
            _ = try mutation_observer.loop.timeout(0, &mutation_observer.loop_node);
        }
    }
};

const MutationEventType = enum {
    DOMAttrModified,
    DOMCharacterDataModified,
    DOMNodeInserted,
    DOMNodeRemoved,

    fn recordType(self: MutationEventType) []const u8 {
        return switch (self) {
            .DOMAttrModified => "attributes",
            .DOMCharacterDataModified => "characterData",
            .DOMNodeInserted => "childList",
            .DOMNodeRemoved => "childList",
        };
    }
};

const testing = @import("../../testing.zig");
test "Browser.DOM.MutationObserver" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "new MutationObserver(() => {}).observe(document, { childList: true });", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\ var nb = 0;
            \\ var mrs;
            \\ new MutationObserver((mu) => {
            \\    mrs = mu;
            \\    nb++;
            \\ }).observe(document.firstElementChild, { attributes: true, attributeOldValue: true });
            \\ document.firstElementChild.setAttribute("foo", "bar");
            \\ // ignored b/c it's about another target.
            \\ document.firstElementChild.firstChild.setAttribute("foo", "bar");
            ,
            null,
        },
        .{ "nb", "1" },
        .{ "mrs[0].type", "attributes" },
        .{ "mrs[0].target == document.firstElementChild", "true" },
        .{ "mrs[0].target.getAttribute('foo')", "bar" },
        .{ "mrs[0].attributeName", "foo" },
        .{ "mrs[0].oldValue", "null" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\ var node = document.getElementById("para").firstChild;
            \\ var nb2 = 0;
            \\ var mrs2;
            \\ new MutationObserver((mu) => {
            \\     mrs2 = mu;
            \\     nb2++;
            \\ }).observe(node, { characterData: true, characterDataOldValue: true });
            \\ node.data = "foo";
            ,
            null,
        },
        .{ "nb2", "1" },
        .{ "mrs2[0].type", "characterData" },
        .{ "mrs2[0].target == node", "true" },
        .{ "mrs2[0].target.data", "foo" },
        .{ "mrs2[0].oldValue", " And" },
    }, .{});

    // tests that mutation observers that have a callback which trigger the
    // mutation observer don't crash.
    // https://github.com/lightpanda-io/browser/issues/550
    try runner.testCases(&.{
        .{
            \\ var node = document.getElementById("para");
            \\ new MutationObserver(() => {
            \\     node.innerText = 'a';
            \\ }).observe(document, { subtree:true,childList:true });
            \\ node.innerText = "2";
            ,
            null,
        },
        .{ "node.innerText", "a" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\ var node = document.getElementById("para");
            \\ var attrWatch = 0;
            \\ new MutationObserver(() => {
            \\     attrWatch++;
            \\ }).observe(document, { attributeFilter: ["name"], subtree: true });
            \\ node.setAttribute("id", "1");
            ,
            null,
        },
        .{ "attrWatch", "0" },
        .{ "node.setAttribute('name', 'other');", null },
        .{ "attrWatch", "1" },
    }, .{});
}
