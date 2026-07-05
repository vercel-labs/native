# Native SDK gpu-components example

This example is a retained GPU widget lab for trying the finished native-first component surface:

- Native toolbar shell view with native-sdk-rendered sidebar, status strip, and GPU component surface.
- Buttons, icon buttons, text, icons, fields, checkbox, toggle, slider, progress, segmented control, lists, scroll views, popovers, menus, tooltips, and data grids.
- Built-in component catalog in the house style: Accordion, Alert, Avatar, Badge, Breadcrumb, Bubble, Button, Button Group, Card, Checkbox, Combobox, Dialog, Drawer, Dropdown Menu, Input, Pagination, Progress, Radio Group, Resizable, Select, Separator, Sheet, Skeleton, Slider, Spinner, Switch, Table, Tabs, Textarea, Toggle, Toggle Group, and Tooltip.
- Retained widget semantics for focus, press, toggle, select, text editing, scrolling, and data-grid roles.
- Token-driven rounded corners, shadows, blur, typography, color, and scroll physics.

Run with the macOS system backend. The GPU component lab defaults to `ReleaseFast`; pass `-Doptimize=Debug` only when debugging renderer internals.

```sh
native dev
```

Run the headless canvas and scene tests:

```sh
native test -Dplatform=null
```
