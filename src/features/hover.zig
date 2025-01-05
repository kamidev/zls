//! Implementation of [`textDocument/hover`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_hover)

const std = @import("std");
const Ast = std.zig.Ast;

const ast = @import("../ast.zig");
const types = @import("lsp").types;
const offsets = @import("../offsets.zig");
const tracy = @import("tracy");

const Analyser = @import("../analysis.zig");
const DocumentStore = @import("../DocumentStore.zig");

const data = @import("version_data");

fn hoverSymbol(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    decl_handle: Analyser.DeclWithHandle,
    markup_kind: types.MarkupKind,
) error{OutOfMemory}!?[]const u8 {
    var doc_strings: std.ArrayListUnmanaged([]const u8) = .empty;
    return hoverSymbolRecursive(analyser, arena, decl_handle, markup_kind, &doc_strings);
}

fn hoverSymbolRecursive(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    decl_handle: Analyser.DeclWithHandle,
    markup_kind: types.MarkupKind,
    doc_strings: *std.ArrayListUnmanaged([]const u8),
) error{OutOfMemory}!?[]const u8 {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const handle = decl_handle.handle;
    const tree = handle.tree;

    var type_references: Analyser.ReferencedType.Set = .empty;
    var reference_collector: Analyser.ReferencedType.Collector = .{ .referenced_types = &type_references };
    if (try decl_handle.docComments(arena)) |doc|
        try doc_strings.append(arena, doc);

    var is_fn = false;

    const def_str = switch (decl_handle.decl) {
        .ast_node => |node| def: {
            if (try analyser.resolveVarDeclAlias(.{ .node = node, .handle = handle })) |result| {
                return try hoverSymbolRecursive(analyser, arena, result, markup_kind, doc_strings);
            }

            switch (tree.nodes.items(.tag)[node]) {
                .global_var_decl,
                .local_var_decl,
                .aligned_var_decl,
                .simple_var_decl,
                => {
                    const var_decl = tree.fullVarDecl(node).?;
                    var struct_init_buf: [2]Ast.Node.Index = undefined;
                    var type_node: Ast.Node.Index = 0;

                    if (var_decl.ast.type_node != 0) {
                        type_node = var_decl.ast.type_node;
                    } else if (tree.fullStructInit(&struct_init_buf, var_decl.ast.init_node)) |struct_init| {
                        if (struct_init.ast.type_expr != 0)
                            type_node = struct_init.ast.type_expr;
                    }

                    if (type_node != 0)
                        try analyser.referencedTypesFromNode(
                            .{ .node = type_node, .handle = handle },
                            &reference_collector,
                        );

                    break :def try Analyser.getVariableSignature(arena, tree, var_decl, true);
                },
                .container_field,
                .container_field_init,
                .container_field_align,
                => {
                    const field = tree.fullContainerField(node).?;
                    var converted = field;
                    converted.convertToNonTupleLike(tree.nodes);
                    if (converted.ast.type_expr != 0)
                        try analyser.referencedTypesFromNode(
                            .{ .node = converted.ast.type_expr, .handle = handle },
                            &reference_collector,
                        );

                    break :def Analyser.getContainerFieldSignature(tree, field) orelse return null;
                },
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                .fn_decl,
                => {
                    is_fn = true;
                    var buf: [1]Ast.Node.Index = undefined;
                    const fn_proto = tree.fullFnProto(&buf, node).?;
                    break :def Analyser.getFunctionSignature(tree, fn_proto);
                },
                .test_decl => {
                    const test_name_token, const test_name = ast.testDeclNameAndToken(tree, node) orelse return null;
                    _ = test_name_token;
                    break :def test_name;
                },
                else => {
                    return null;
                },
            }
        },
        .function_parameter => |pay| def: {
            const param = pay.get(tree).?;

            if (param.type_expr != 0) // zero for `anytype` and extern C varargs `...`
                try analyser.referencedTypesFromNode(
                    .{ .node = param.type_expr, .handle = handle },
                    &reference_collector,
                );

            break :def ast.paramSlice(tree, param, false);
        },
        .optional_payload,
        .error_union_payload,
        .error_union_error,
        .for_loop_payload,
        .assign_destructure,
        .switch_payload,
        .label,
        .error_token,
        => tree.tokenSlice(decl_handle.nameToken()),
    };

    var resolved_type_str: []const u8 = "unknown";
    if (try decl_handle.resolveType(analyser)) |resolved_type| {
        if (try resolved_type.docComments(arena)) |doc|
            try doc_strings.append(arena, doc);
        try analyser.referencedTypes(
            resolved_type,
            &reference_collector,
        );
        resolved_type_str = try std.fmt.allocPrint(arena, "{}", .{resolved_type.fmt(analyser, .{ .truncate_container_decls = false })});
    }
    const referenced_types: []const Analyser.ReferencedType = type_references.keys();

    var hover_text: std.ArrayListUnmanaged(u8) = .empty;
    const writer = hover_text.writer(arena);
    if (markup_kind == .markdown) {
        for (doc_strings.items) |doc|
            try writer.print("{s}\n\n", .{doc});
        if (is_fn) {
            try writer.print("```zig\n{s}\n```", .{def_str});
        } else {
            try writer.print("```zig\n{s}\n```\n```zig\n({s})\n```", .{ def_str, resolved_type_str });
        }
        if (referenced_types.len > 0)
            try writer.print("\n\n" ++ "Go to ", .{});
        for (referenced_types, 0..) |ref, index| {
            if (index > 0)
                try writer.print(" | ", .{});
            const source_index = offsets.tokenToIndex(ref.handle.tree, ref.token);
            const line = 1 + std.mem.count(u8, ref.handle.tree.source[0..source_index], "\n");
            try writer.print("[{s}]({s}#L{d})", .{ ref.str, ref.handle.uri, line });
        }
    } else {
        for (doc_strings.items) |doc|
            try writer.print("{s}\n\n", .{doc});
        if (is_fn) {
            try writer.print("{s}", .{def_str});
        } else {
            try writer.print("{s}\n({s})", .{ def_str, resolved_type_str });
        }
    }

    return hover_text.items;
}

fn hoverDefinitionLabel(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    pos_index: usize,
    loc: offsets.Loc,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const name = offsets.locToSlice(handle.tree.source, loc);
    const decl = (try Analyser.lookupLabel(handle, name, pos_index)) orelse return null;

    return .{
        .contents = .{
            .MarkupContent = .{
                .kind = markup_kind,
                .value = (try hoverSymbol(analyser, arena, decl, markup_kind)) orelse return null,
            },
        },
        .range = offsets.locToRange(handle.tree.source, loc, offset_encoding),
    };
}

fn hoverDefinitionBuiltin(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    pos_index: usize,
    name_loc: offsets.Loc,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!?types.Hover {
    _ = analyser;
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const name = offsets.locToSlice(handle.tree.source, name_loc);

    var contents: std.ArrayListUnmanaged(u8) = .empty;
    var writer = contents.writer(arena);

    if (std.mem.eql(u8, name, "@cImport")) blk: {
        const index = for (handle.cimports.items(.node), 0..) |cimport_node, index| {
            const main_token = handle.tree.nodes.items(.main_token)[cimport_node];
            const cimport_loc = offsets.tokenToLoc(handle.tree, main_token);
            if (cimport_loc.start <= pos_index and pos_index <= cimport_loc.end) break index;
        } else break :blk;

        const source = handle.cimports.items(.source)[index];

        switch (markup_kind) {
            .plaintext, .unknown_value => {
                try writer.print(
                    \\{s}
                    \\
                , .{source});
            },
            .markdown => {
                try writer.print(
                    \\```c
                    \\{s}
                    \\```
                    \\
                , .{source});
            },
        }
    }

    const builtin = data.builtins.get(name) orelse return null;

    switch (markup_kind) {
        .plaintext, .unknown_value => {
            try writer.print(
                \\{s}
                \\{s}
            , .{ builtin.signature, builtin.documentation });
        },
        .markdown => {
            try writer.print(
                \\```zig
                \\{s}
                \\```
                \\{s}
            , .{ builtin.signature, builtin.documentation });
        },
    }

    return .{
        .contents = .{
            .MarkupContent = .{
                .kind = markup_kind,
                .value = contents.items,
            },
        },
        .range = offsets.locToRange(handle.tree.source, name_loc, offset_encoding),
    };
}

fn hoverDefinitionGlobal(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    pos_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const name_loc = Analyser.identifierLocFromIndex(handle.tree, pos_index) orelse return null;
    const name = offsets.locToSlice(handle.tree.source, name_loc);
    const decl = (try analyser.lookupSymbolGlobal(handle, name, pos_index)) orelse return null;

    return .{
        .contents = .{
            .MarkupContent = .{
                .kind = markup_kind,
                .value = (try hoverSymbol(analyser, arena, decl, markup_kind)) orelse return null,
            },
        },
        .range = offsets.locToRange(handle.tree.source, name_loc, offset_encoding),
    };
}

fn hoverDefinitionEnumLiteral(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const name_loc = Analyser.identifierLocFromIndex(handle.tree, source_index) orelse return null;
    const name = offsets.locToSlice(handle.tree.source, name_loc);
    const decl = (try analyser.getSymbolEnumLiteral(arena, handle, source_index, name)) orelse return null;

    return .{
        .contents = .{
            .MarkupContent = .{
                .kind = markup_kind,
                .value = (try hoverSymbol(analyser, arena, decl, markup_kind)) orelse return null,
            },
        },
        .range = offsets.locToRange(handle.tree.source, name_loc, offset_encoding),
    };
}

fn hoverDefinitionFieldAccess(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    loc: offsets.Loc,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const name_loc = Analyser.identifierLocFromIndex(handle.tree, source_index) orelse return null;
    const name = offsets.locToSlice(handle.tree.source, name_loc);
    const held_loc = offsets.locMerge(loc, name_loc);
    const decls = (try analyser.getSymbolFieldAccesses(arena, handle, source_index, held_loc, name)) orelse return null;

    var content: std.ArrayListUnmanaged([]const u8) = try .initCapacity(arena, decls.len);

    for (decls) |decl| {
        content.appendAssumeCapacity(try hoverSymbol(analyser, arena, decl, markup_kind) orelse continue);
    }

    return .{
        .contents = .{ .MarkupContent = .{
            .kind = markup_kind,
            .value = switch (content.items.len) {
                0 => return null,
                1 => content.items[0],
                else => try std.mem.join(arena, "\n\n", content.items),
            },
        } },
        .range = offsets.locToRange(handle.tree.source, name_loc, offset_encoding),
    };
}

fn hoverNumberLiteral(
    handle: *DocumentStore.Handle,
    token_index: Ast.TokenIndex,
    arena: std.mem.Allocator,
    markup_kind: types.MarkupKind,
    client_name: ?[]const u8,
) error{OutOfMemory}!?[]const u8 {
    const tree = handle.tree;
    // number literals get tokenized separately from their minus sign
    const is_negative = tree.tokens.items(.tag)[token_index -| 1] == .minus;
    const num_slice = tree.tokenSlice(token_index);
    const number = blk: {
        if (tree.tokens.items(.tag)[token_index] == .char_literal) {
            switch (std.zig.parseCharLiteral(num_slice)) {
                .success => |value| break :blk value,
                else => return null,
            }
        }
        switch (std.zig.parseNumberLiteral(num_slice)) {
            .int => |value| break :blk value,
            else => return null,
        }
    };

    // Zed currently doesn't render markdown unless wrapped in code blocks
    // Remove this when this issue is closed https://github.com/zed-industries/zed/issues/5386
    const is_zed = if (client_name) |name| std.mem.startsWith(u8, name, "Zed") else false;
    switch (markup_kind) {
        .markdown => return try std.fmt.allocPrint(arena,
            \\{[md_ticks]s}| Base | {[value]s:<[count]} |
            \\| ---- | {[dash]s:-<[count]} |
            \\| BIN  | {[sign]s}0b{[number]b:<[len]} |
            \\| OCT  | {[sign]s}0o{[number]o:<[len]} |
            \\| DEC  | {[sign]s}{[number]d:<[len]}   |
            \\| HEX  | {[sign]s}0x{[number]X:<[len]} |{[md_ticks]s}
        , .{
            .md_ticks = if (is_zed) "\n```" else "",
            .sign = if (is_negative) "-" else "",
            .dash = "-",
            .value = "Value",
            .number = number,
            .count = @max(@bitSizeOf(@TypeOf(number)) - @clz(number) + "0x".len + @intFromBool(is_negative), "Value".len),
            .len = @max(@bitSizeOf(@TypeOf(number)) - @clz(number), "Value".len - "0x".len),
        }),
        .plaintext, .unknown_value => return try std.fmt.allocPrint(
            arena,
            \\BIN: {[sign]s}0b{[number]b}
            \\OCT: {[sign]s}0o{[number]o}
            \\DEC: {[sign]s}{[number]d}
            \\HEX: {[sign]s}0x{[number]X}
        ,
            .{ .sign = if (is_negative) "-" else "", .number = number },
        ),
    }
}

fn hoverDefinitionNumberLiteral(
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
    client_name: ?[]const u8,
) !?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const tree = handle.tree;
    const token_index = offsets.sourceIndexToTokenIndex(tree, source_index);
    const num_loc = offsets.tokenToLoc(tree, token_index);
    const hover_text = (try hoverNumberLiteral(handle, token_index, arena, markup_kind, client_name)) orelse return null;

    return .{
        .contents = .{ .MarkupContent = .{
            .kind = markup_kind,
            .value = hover_text,
        } },
        .range = offsets.locToRange(handle.tree.source, num_loc, offset_encoding),
    };
}

pub fn hover(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
    client_name: ?[]const u8,
) !?types.Hover {
    const pos_context = try Analyser.getPositionContext(arena, handle.tree, source_index, true);

    const response = switch (pos_context) {
        .builtin => |loc| try hoverDefinitionBuiltin(analyser, arena, handle, source_index, loc, markup_kind, offset_encoding),
        .var_access => try hoverDefinitionGlobal(analyser, arena, handle, source_index, markup_kind, offset_encoding),
        .field_access => |loc| try hoverDefinitionFieldAccess(analyser, arena, handle, source_index, loc, markup_kind, offset_encoding),
        .label_access, .label_decl => |loc| try hoverDefinitionLabel(analyser, arena, handle, source_index, loc, markup_kind, offset_encoding),
        .enum_literal => try hoverDefinitionEnumLiteral(analyser, arena, handle, source_index, markup_kind, offset_encoding),
        .number_literal, .char_literal => try hoverDefinitionNumberLiteral(arena, handle, source_index, markup_kind, offset_encoding, client_name),
        else => null,
    };

    return response;
}
