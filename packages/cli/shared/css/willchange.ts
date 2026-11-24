// The will-change lists, one row per value: each entry is the id of a property the page names,
// or one of the three keyword sentinels. The row id is what a declaration stores (unit U_LIST).

import { RowTable } from "./rows.ts";

/** The keyword entries' sentinels; a property's own id is never negative. */
export const WC_LIST_AUTO = -1;
export const WC_LIST_CONTENTS = -2;
export const WC_LIST_SCROLL_POSITION = -3;

export const willChangeRows = new RowTable();
