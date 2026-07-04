# Renderer tour

Every block and inline form the native renderer supports, on one page.

## Headings scale from the body token

### So a theme change rescales everything at once

Paragraphs flow and wrap at the pane width. Inline forms compose freely: **bold**, *italic*, ***both***, `code`, ~~struck~~, [a link](https://example.com/tour), and a bare URL like https://example.com/bare — trailing punctuation is trimmed correctly (https://example.com/trim).

## Lists

- Bullets nest by two-space indent
  - Second level
    - Third level, still real widgets
- Ordered lists keep their numbers

1. First
2. Second
3. Third

- [x] Task items render as real (disabled) checkboxes
- [ ] Their state is display-only — the document owns it

## Code

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("fenced code keeps its whitespace\n", .{});
}
```

## Quotes and rules

> Blockquotes get a leading bar and muted text.
> Multiple lines fold into one quote block.

---

## Tables

| Alignment | Demo       |   Right |
| :-------- | :--------: | ------: |
| start     |  center    |     end |
| `code`    | **bold**   | [link](https://example.com/cell) |
| escaped \| pipe | *italic* | 42 |

## Details

<details>
<summary>Collapsed by default</summary>

The body only renders while expanded — the flag lives in the app model, indexed by document order.

</details>

<details>
<summary>A second one, independently tracked</summary>

Toggling one never disturbs the other.

</details>

![Images render as their alt text](https://example.com/diagram.png)
