# Rich Textarea

Paragraph-scoped attributed editing on the existing `TextBuffer` path.

- Markup: `<rich-textarea>` (stamps `WidgetRuntimeFlags.rich_editor`)
- Style ops: `@native-sdk/core/text-attr` (Zig twin: `text_attr.zig`)
- v1 non-goals: nested spans, multi-block GFM, Lexical parity

```bash
native run examples/rich-textarea
```

Dogfood app for the attributed-editing design before upstream merge.
