// Cascade layers. A style sheet declares a tree of layers, and the tree's shape decides the order
// their declarations take in the cascade (CSS Cascade 5, §6.4): a layer's own rules come after
// the rules of its sublayers, and a layer declared later comes after an earlier one. Rules outside
// every layer are in an implicit final layer at the top level.
//
// The parser adds layers as it meets them, in document order across every author sheet, and the
// order is worked out once the whole document has been parsed: a `@layer a, b;` statement may
// name layers that are only declared later, and it fixes their order when it comes first.

export interface Layer {
  /** The layer this one is nested in, or -1 at the top level. */
  parent: number;
  /** Sublayers, in the order they were first declared. */
  children: number[];
  /** The layer's own name; "" for an anonymous layer, whose name nothing can refer to. */
  name: string;
}

export class LayerRegistry {
  readonly layers: Layer[] = [];
  /** Top-level layers, in declaration order. */
  readonly top: number[] = [];
  /** A named layer by its parent and name, so `@layer a.b` and `@layer a { @layer b {} }` meet. */
  private readonly byName = new Map<string, number>();

  /** Declares a (possibly dotted) name inside `parent` and returns its deepest layer. */
  declare(parent: number, dotted: string): number {
    let at = parent;
    for (const part of dotted.split(".")) {
      const key = `${at}\u0000${part}`;
      let id = this.byName.get(key);
      if (id === undefined) {
        id = this.add(at, part);
        this.byName.set(key, id);
      }
      at = id;
    }
    return at;
  }

  /** Declares a new anonymous layer inside `parent`; each `@layer { }` block is a layer of its own. */
  anonymous(parent: number): number {
    return this.add(parent, "");
  }

  private add(parent: number, name: string): number {
    const id = this.layers.length;
    this.layers.push({ parent, children: [], name });
    if (parent < 0) this.top.push(id);
    else this.layers[parent].children.push(id);
    return id;
  }

  /**
   * The cascade position of every layer: a number that rises with the layer's priority for
   * normal declarations, in the flattened order the tree gives. `count` is the position of the
   * unlayered rules, which come after every explicit layer.
   */
  order(): { key: number[]; count: number } {
    const key = new Array<number>(this.layers.length).fill(0);
    let next = 0;
    // A layer's sublayers come first, and its own rules after them, as an implicit final
    // sublayer of the layer. The walk is iterative — a name may carry thousands of dotted parts,
    // and the tree they make is deeper than the stack can hold — with a negative marker standing
    // for "this layer's sublayers are done".
    const stack: number[] = [];
    for (let i = this.top.length - 1; i >= 0; i--) stack.push(this.top[i]);
    while (stack.length > 0) {
      const id = stack.pop() as number;
      if (id < 0) {
        key[-id - 1] = next++;
        continue;
      }
      stack.push(-id - 1);
      const kids = this.layers[id].children;
      for (let k = kids.length - 1; k >= 0; k--) stack.push(kids[k]);
    }
    return { key, count: next };
  }
}
