const canvas = @import("canvas");

const Model = struct {};
const Msg = union(enum) { one, two };

const sources = [_]canvas.ui_markup.SourceFile{
    .{
        .path = "app.native",
        .source =
        \\<import src="components/broken.native"/>
        \\<use template="broken" />
        ,
    },
    .{
        .path = "components/broken.native",
        .source = "<column><text>component files cannot define a view root</text></column>",
    },
};

const View = canvas.CompiledMarkupImports(Model, Msg, "app.native", &sources);

comptime {
    _ = View.document;
}
