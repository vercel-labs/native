// A table of number rows, looked up by id. Values that need more than a number and a unit (a
// max() expression, a clip rectangle) store the row's id with a dedicated unit, and the same
// row ids come out of the build and out of a runtime parse.
//
// The rows live in a Map rather than an array of arrays: scriptc treats an array held by a
// module-level object as immutable static data, so a table that grows is a map.

export class RowTable {
  private rows: Map<number, number[]> = new Map();
  private ids: Map<string, number> = new Map();
  private next: number = 0;

  /** Adds a row, sharing the id of an identical one; the id is the row's place in the table. */
  register(row: readonly number[]): number {
    const key = row.join(",");
    const hit = this.ids.get(key);
    if (hit !== undefined) return hit;
    const id = this.next++;
    this.put(id, row, key);
    return id;
  }

  /** Takes the rows the build emitted, whose ids are their indexes; later rows append to them. */
  load(rows: readonly (readonly number[])[]): void {
    this.rows = new Map();
    this.ids = new Map();
    for (let i = 0; i < rows.length; i++) this.put(i, rows[i], rows[i].join(","));
    this.next = rows.length;
  }

  row(id: number): readonly number[] | null {
    const row = this.rows.get(id);
    return row === undefined ? null : row;
  }

  /** Every row, in id order; the build emits this and the runtime reads back in `load`. */
  all(): number[][] {
    const out: number[][] = [];
    for (let id = 0; id < this.next; id++) {
      const row = this.rows.get(id);
      if (row !== undefined) out.push(row);
    }
    return out;
  }

  private put(id: number, row: readonly number[], key: string): void {
    const copy: number[] = [];
    for (const n of row) copy.push(n);
    this.rows.set(id, copy);
    this.ids.set(key, id);
  }
}
