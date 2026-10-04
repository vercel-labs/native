/** Portable component composition compiled with scriptc beside the app model.
 * These functions emit only primitive view records. Native owns measurement,
 * rendering, hit testing, and delivery of the declared message envelopes.
 */
import { textWordSelectionAtOffset as nscvWordSelection, textLineSelectionAtOffset as nscvLineSelection, caretSelectionAt as nscvSelection, applyTextInputEvent as nscvApplyTextEdit, sanitizedSingleLineTextInputEvent as nscvSanitizeTextInput, codeIndentationInsertion as nscvIndentation, parseCodeLineNumberSpec as nscvCodeLines, textClipboardRange as nscvClipboardRange, type TextInputEvent as NscvTextInputEvent } from "@native-sdk/core/text";

type NscViewNode = {
  end: number; kind: string; text: string; placeholder?: string; wrap?: boolean; submitOnEnter?: boolean;
  key?: string; keyInt?: number; keySlot?: number; globalKey?: string; globalKeyInt?: number;
  gap?: number; padding?: number; grow?: number; width?: number; height?: number; minWidth?: number;
  resizeDuration?: number; resizeEasing?: string; resizeOrigin?: number;
  value?: number; valueX?: number; axis?: string; overscroll?: string;
  image?: number; icon?: string; label?: string; role?: string;
  background?: string; foreground?: string; radius?: string; windowDrag?: boolean;
  main?: string; cross?: string; size?: string; variant?: string; checked?: boolean;
  disabled?: boolean; selected?: boolean; focusable?: boolean;
  expanded?: boolean; treeLevel?: number;
  listItemIndex?: number; listItemCount?: number;
  spanWeight?: string; spanColor?: string; spanScale?: number;
  codeLanguage?: string; codeLineDigits?: number;
  codeAddedLines?: readonly number[]; codeRemovedLines?: readonly number[];
  press?: number[]; hold?: number[]; toggle?: number[]; change?: number[]; drag?: number[]; scroll?: number;
  input?: number; valueChange?: number; resize?: number; submit?: number[]; dismiss?: number[];
  anchor?: string; anchorAlignment?: string; anchorOffset?: number; tooltipDelay?: number;
};

function nscvPush(nodes: NscViewNode[], node: NscViewNode): void {
  if (nodes.length >= 1024) throw new Error("compiled view exceeds 1024 nodes");
  nodes.push(node);
  node.end = nodes.length;
}

/** Text keyboard intent. Eight bytes: operation (0 newline, 1 edit, 2 submit),
 * multiline, phase (0 down, 1 up, 2 text), modifier bits (shift/control/alt/super),
 * macOS, submit-on-enter, normalized key, text-present. The two-byte result is
 * intent plus extend-selection: 0 none, 1 borrowed text, 2 newline, 3/4 deletion,
 * 5/6 previous/next, 7/8 start/end, 9/10 previous/next word, 11/12 word deletion,
 * 13 line-start deletion, 14 select-all, 15 submit, 16 document-start deletion.
 * Keys are 0 unknown, 1 Enter, 2 Return, 3 Backspace, 4 Delete, 5/6 Left/Right,
 * 7 Home, 8 End, 9 A. Native retains insert bytes and geometry.
 */
export function native_text_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 29) return nscvPointerIntent(request);
  if (request[0] === 28) return nscvSurfaceDismissal(request);
  if (request[0] === 27) return nscvTooltipPresentation(request);
  if (request[0] === 26) return nscvTooltipReconcile(request);
  if (request[0] === 25) return nscvTooltipPointer(request);
  if (request[0] === 24) return nscvTooltipIntent(request);
  if (request[0] === 23) return nscvTooltipBinding(request);
  if (request[0] === 22) return nscvFocusReturn(request);
  if (request[0] === 21) return nscvSurfaceScope(request);
  if (request[0] === 20) return nscvTabFocus(request);
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  if (request[0] === 3) return nscvTextPointerSelection(request);
  if (request[0] === 4) return nscvTextEdit(request);
  if (request[0] === 5) return nscvTextReconcile(request);
  if (request[0] === 6) return nscvTextInput(request);
  if (request[0] === 7) return nscvTextHistoryReplay(request);
  if (request[0] === 8) return nscvTextHistoryDelta(request);
  if (request[0] === 9) return nscvTextCompositionHistory(request);
  if (request[0] === 10) return nscvTextHistoryTimeline(request);
  if (request[0] === 11) return nscvCodeIndentation(request);
  if (request[0] === 12) return nscvTextClipboard(request);
  if (request[0] === 13) return nscvEditorShortcut(request);
  if (request[0] === 14) return nscvEditorBoundary(request);
  if (request.length !== 8 || request[0]! > 2 || request[1]! > 1 || request[2]! > 2 ||
      request[3]! > 15 || request[4]! > 1 || request[5]! > 1 || request[6]! > 9 || request[7]! > 1)
    throw new Error("invalid text policy request");
  const operation = request[0]!, multiline = request[1] === 1, phase = request[2]!, key = request[6]!;
  const shift = (request[3]! & 1) !== 0, control = (request[3]! & 2) !== 0;
  const alt = (request[3]! & 4) !== 0, meta = (request[3]! & 8) !== 0;
  const command = control || meta, navigation = command || alt;
  let intent = 0;
  if (operation === 0) {
    if (multiline && phase === 0 && request[7] === 0 && !navigation &&
        (key === 1 || key === 2) && !(request[5] === 1 && !shift)) intent = 2;
  } else if (operation === 2) {
    if (phase === 0 && key === 1) {
      if (multiline ? (command && !alt && !shift || request[5] === 1 && !navigation && !shift) : !navigation)
        intent = 15;
    }
  } else if (phase === 2) {
    if (request[7] === 1 && !command) intent = 1;
  } else if (phase === 0) {
    if (command && !alt && !shift && key === 9) intent = 14;
    else if (meta && !alt && (key === 5 || key === 6)) intent = key === 5 ? 7 : 8;
    else if (!meta && alt !== control && (key === 5 || key === 6)) intent = key === 5 ? 9 : 10;
    else if (!shift && (!meta || request[4] === 0 && control) && alt !== control && (key === 3 || key === 4))
      intent = key === 3 ? 11 : 12;
    else if (request[4] === 1 && meta && !control && !alt && key === 3) intent = multiline ? 13 : 16;
    else if (!navigation) {
      if (key === 3) intent = 3;
      else if (key === 4) intent = 4;
      else if (key === 5) intent = 5;
      else if (key === 6) intent = 6;
      else if (key === 7) intent = 7;
      else if (key === 8) intent = 8;
    }
  }
  const result = new Uint8Array(2);
  result[0] = intent; result[1] = shift ? 1 : 0;
  return result;
}

/** Shared press-and-hold coordination. Tag 19, operation (0 down, 1 release
 * or cancel, 2 timer fire, 3 disarm), facts (armed/fired/hold handler/tree).
 * Result bits cancel the timer, clear the gesture, arm, suppress the release,
 * or consume the timer fire. Native owns timer capabilities and handler data.
 */
function nscvPressHold(request: Uint8Array): Uint8Array {
  if (request.length !== 3 || request[1]! > 3 || request[2]! > 15)
    throw new Error("invalid press hold policy request");
  const operation = request[1]!, facts = request[2]!;
  const armed = (facts & 1) !== 0, fired = (facts & 2) !== 0;
  const result = new Uint8Array(1);
  if (operation === 2) {
    if (armed && !fired && (facts & 8) !== 0) result[0] = 16;
  } else {
    result[0] = 2 | (armed && !fired ? 1 : 0);
    if (operation === 0 && (facts & 4) !== 0) result[0] = result[0]! | 4;
    if (operation === 1 && fired) result[0] = result[0]! | 8;
  }
  return result;
}

/** Sequential/roving Tab focus. Header: tag 20, backward, count/current u16.
 * Each seven-byte node supplies visible/logical eligibility, radio/group and
 * selection bits, depth, parent and interactive-surface indices (all u16).
 * 65535 means absent. Identities and measured geometry remain native-owned.
 */
function nscvTabFocus(request: Uint8Array): Uint8Array {
  if (request.length < 6 || request[1]! > 1) throw new Error("invalid Tab focus request");
  const count = request[2]! | request[3]! << 8;
  const current = request[4]! | request[5]! << 8;
  if (count > 1024 || request.length !== 6 + 7 * count || current !== 65535 && current >= count)
    throw new Error("invalid Tab focus table");
  const flags: number[] = [], depths: number[] = [], parents: number[] = [], surfaces: number[] = [];
  const groups: number[] = [], stops: number[] = [], entries: number[] = [];
  for (let i = 0; i < count; i++) {
    const at = 6 + i * 7;
    const bits = request[at]!, depth = request[at + 1]! | request[at + 2]! << 8;
    const parent = request[at + 3]! | request[at + 4]! << 8;
    const surface = request[at + 5]! | request[at + 6]! << 8;
    if (bits > 31 || (bits & 12) === 12 || parent !== 65535 && parent >= i || surface !== 65535 && surface >= count)
      throw new Error("invalid Tab focus node");
    flags.push(bits); depths.push(depth); parents.push(parent); surfaces.push(surface);
    groups.push(65535); stops.push(65535); entries.push(65535);
    if ((bits & 4) !== 0) {
      let ancestor = parent;
      while (ancestor !== 65535) {
        if ((flags[ancestor]! & 8) !== 0) { groups[i] = ancestor; break; }
        ancestor = parents[ancestor]!;
      }
    }
  }
  for (let group = 0; group < count; group++) {
    if ((flags[group]! & 8) === 0) continue;
    let selected = false;
    for (let i = group + 1; i < count && depths[i]! > depths[group]!; i++) {
      if (groups[i] !== group) continue;
      const bits = flags[i]!;
      if (stops[group] === 65535 && (bits & 1) !== 0) stops[group] = i;
      if ((bits & 2) === 0) continue;
      if (entries[group] === 65535) entries[group] = i;
      if (!selected && (bits & 16) !== 0) { entries[group] = i; selected = true; }
    }
  }
  const scope = current === 65535 ? 65535 : groups[current]!;
  let walk = scope !== 65535 && stops[scope] !== 65535 ? stops[scope]! : current;
  let chosen = 65535;
  for (let attempts = 0; attempts <= count; attempts++) {
    const target = nscvTabNext(flags, parents, surfaces, walk, request[1] === 1);
    if (target === 65535) break;
    const targetScope = groups[target]!;
    if (targetScope !== 65535) {
      if (stops[targetScope] === 65535 || target !== stops[targetScope] || targetScope === scope) {
        walk = target;
        if (attempts === count && scope !== 65535) chosen = entries[scope]!;
        continue;
      }
      chosen = entries[targetScope] === 65535 ? target : entries[targetScope]!;
    } else chosen = target;
    break;
  }
  const result = new Uint8Array(2);
  result[0] = chosen & 255; result[1] = chosen >>> 8;
  return result;
}

/** Tooltip coordination. Tag 26, stage, bounded native facts; one-byte result.
 * Stages: 0 hover delta, 1 travel phase, 2 released pointer hold (had/shown/target),
 * 3 press phase (0 hover, 1 down, 2 move, 3 up, 4 cancel, 5 wheel), 4 point source (live/stored; result 0 none, 1 live, 2 stored),
 * 5 adoption point, 6 moved hover (delta/released/target), 7 stable hovered owner
 * (present/same), 8 binding delta (present/changed), 9 surviving keyboard owner
 * (present/focused/keyboard/same), 10 apex reseed (target/armed/shown/focus-owned),
 * 11 frame request (armed/transit present). Other results are 0 skip or 1 invoke the native capability.
 * Query each stage only after earlier fallible commits have succeeded.
 * Native keeps identities, clocks, geometry, storage and visibility commits.
 */
function nscvTooltipReconcile(request: Uint8Array): Uint8Array {
  if (request.length !== 3 || request[1]! > 11) throw new Error("invalid tooltip reconciliation request");
  const stage = request[1]!, facts = request[2]!;
  const limit = stage === 2 || stage === 6 ? 7 : stage === 4 || stage === 7 || stage === 8 ? 3 : stage === 9 || stage === 10 ? 15 : stage === 1 || stage === 3 ? 5 : stage === 11 ? 3 : 1;
  if (facts > limit) throw new Error("invalid tooltip reconciliation facts");
  let action = 0;
  if (stage === 1) action = facts === 0 || facts === 2 ? 1 : 0;
  else if (stage === 3) action = facts === 1 ? 1 : 0;
  else if (stage === 11) action = facts !== 0 ? 1 : 0;
  else if (stage === 2) action = (facts & 1) !== 0 && (facts & 2) === 0 && (facts & 4) !== 0 ? 1 : 0;
  else if (stage === 4) action = (facts & 1) !== 0 ? 1 : (facts & 2) !== 0 ? 2 : 0;
  else if (stage === 6) action = (facts & 1) !== 0 || (facts & 6) === 6 ? 1 : 0;
  else if (stage === 7 || stage === 8) action = facts === 3 ? 1 : 0;
  else if (stage === 9) action = facts === 15 ? 1 : 0;
  else if (stage === 10) action = (facts & 1) !== 0 && ((facts & 2) !== 0 || (facts & 4) !== 0 && (facts & 8) === 0) ? 1 : 0;
  else action = facts;
  const result = new Uint8Array(1); result[0] = action;
  return result;
}

/** Tooltip presentation and adoption. Tag 27, stage.
 * Stage 0: little-endian u16 count and one fact byte per node (tooltip,
 * anchored, identity present, shown identity match). Results: 0 keep authored
 * visibility, 1 show, 2 hide. Batch at the native 1024-node limit.
 * Stages 1/2: armed/shown slot presence and binding survival; one-byte actions
 * clear armed (1), clear shown (2), clear warmth (4), clear transit (8).
 * A prospective shown query only reads the verdict; native commits the live
 * prune after adoption succeeds, armed before shown. IDs and clocks stay native.
 */
function nscvTooltipPresentation(request: Uint8Array): Uint8Array {
  if (request.length < 3 || request[1]! > 2) throw new Error("invalid tooltip presentation request");
  const stage = request[1]!;
  if (stage === 0) {
    if (request.length < 4) throw new Error("invalid tooltip presentation request");
    const count = request[2]! | request[3]! << 8;
    if (count > 1024 || request.length !== 4 + count) throw new Error("invalid tooltip presentation count");
    const result = new Uint8Array(count);
    for (let index = 0; index < count; index++) {
      const facts = request[4 + index]!;
      if (facts > 15) throw new Error("invalid tooltip presentation facts");
      result[index] = (facts & 3) !== 3 ? 0 : (facts & 12) === 12 ? 1 : 2;
    }
    return result;
  }
  if (request.length !== 3 || request[2]! > 3) throw new Error("invalid tooltip presentation facts");
  const result = new Uint8Array(1);
  result[0] = request[2] === 1 ? (stage === 1 ? 5 : 14) : 0;
  return result;
}

/** Surface dismissal. Tag 28, stage, native containment facts.
 * 0: present/hidden -> dismiss. 1: route-in-surface/anchored/anchor-present/
 * route-in-anchor -> outside dismissal. 2: focus-in-surface -> return focus.
 * 3: ring/hover/press descendants AFTER focus return -> clear ring (1),
 * keyboard provenance (2), hover (4), cursor (8), and press (16).
 * 4: u16 listener count and descendant bytes -> copied keep flags, at most
 * the native 32-entry hover depth. Native retains identities and commits.
 */
function nscvSurfaceDismissal(request: Uint8Array): Uint8Array {
  if (request.length < 3 || request[1]! > 4) throw new Error("invalid surface dismissal request");
  const stage = request[1]!;
  if (stage === 4) {
    if (request.length < 4) throw new Error("invalid surface dismissal request");
    const count = request[2]! | request[3]! << 8;
    if (count > 32 || request.length !== 4 + count) throw new Error("invalid surface dismissal count");
    const result = new Uint8Array(count);
    for (let index = 0; index < count; index++) {
      const descendant = request[4 + index]!;
      if (descendant > 1) throw new Error("invalid surface dismissal facts");
      result[index] = descendant === 0 ? 1 : 0;
    }
    return result;
  }
  const limit = stage === 0 ? 3 : stage === 1 ? 15 : stage === 2 ? 1 : 7;
  if (request.length !== 3 || request[2]! > limit) throw new Error("invalid surface dismissal facts");
  const facts = request[2]!;
  const result = new Uint8Array(1);
  result[0] = stage === 0 ? (facts === 1 ? 1 : 0) :
    stage === 1 ? ((facts & 1) === 0 && (facts & 14) !== 14 ? 1 : 0) :
    stage === 2 ? facts : ((facts & 1) !== 0 ? 3 : 0) |
      ((facts & 2) !== 0 ? 12 : 0) | ((facts & 4) !== 0 ? 16 : 0);
  return result;
}

/** Pointer intent. Tag 29, stage, phase (hover/down/move/up/cancel/wheel),
 * bounded native facts and the stable little-endian u16 widget-kind code.
 * 0: present/eligible press target -> choose target (1), ring (2), spend
 * keyboard provenance (4), and apply pointer focus (8).
 * 1: proven/touch/inside -> hover/press/cursor source selectors and containment
 * actions: earn proof (1), store point (2), re-hit chain (4), clear chain (8),
 * clear live proof (16). Sources 0 keep, 1 clear/arrow, 2 routed/raw, 3 fresh.
 * 2: chart sample present -> retain point unless cancelled.
 * 3: hover/press/detail/cursor changed -> commit (1), sync cursor (2), dirty (4).
 * 4: proven/inside -> consumed secondary retirement, preserving stored id/point.
 * 5: focus/ring changed -> commit focus. Native owns identities and capabilities.
 */
function nscvPointerIntent(request: Uint8Array): Uint8Array {
  if (request.length !== 6 || request[1]! > 5 || request[2]! > 5)
    throw new Error("invalid pointer intent request");
  const stage = request[1]!, phase = request[2]!, facts = request[3]!;
  const kind = request[4]! | request[5]! << 8;
  const limit = stage === 1 || stage === 4 ? 7 : stage === 3 ? 15 : stage === 2 ? 1 : 3;
  if (facts > limit || (stage === 0 ? kind > 62 : kind !== 0) ||
      ((stage === 3 || stage === 5) && phase !== 0)) throw new Error("invalid pointer intent facts");
  const result = new Uint8Array(stage === 1 ? 4 : 1);
  if (stage === 0) {
    if (phase === 1) {
      const present = (facts & 1) !== 0;
      result[0] = 12 | (present && (facts & 2) !== 0 ? 1 : 0) |
        (present && (kind >= 35 && kind <= 39 || kind === 62) ? 2 : 0);
    }
  } else if (stage === 1) {
    const proven = (facts & 1) !== 0;
    if (phase === 0 || phase === 2) {
      result[0] = 3; result[2] = 3;
      result[3] = phase === 0 && (facts & 2) === 0 ? 7 : proven ? 6 : 0;
    } else if (phase === 1) {
      result[0] = 2; result[1] = 2; result[2] = 2; result[3] = proven ? 6 : 0;
    } else if (phase === 3) {
      result[0] = 3; result[1] = 1; result[2] = 3;
      result[3] = proven ? ((facts & 4) !== 0 ? 6 : 24) : 0;
    } else if (phase === 4) {
      result[0] = 1; result[1] = 1; result[2] = 1; result[3] = proven ? 24 : 0;
    } else result[3] = proven ? 2 : 0;
  } else if (stage === 2) result[0] = phase !== 4 && facts !== 0 ? 1 : 0;
  else if (stage === 3) {
    const interaction = (facts & 7) !== 0, cursor = (facts & 8) !== 0;
    result[0] = (interaction || cursor ? 1 : 0) | (cursor ? 2 : 0) | (interaction ? 4 : 0);
  } else if (stage === 4) result[0] = (facts & 1) !== 0 &&
    (phase === 4 || phase === 3 && (facts & 4) === 0) ? 24 : 0;
  else result[0] = facts !== 0 ? 1 : 0;
  return result;
}

/** Pointer tooltip intent. Tag 25, cause, little-endian u16 native facts.
 * Hover facts: shown/focus-owned/target/shown-match/armed/armed-match/content/
 * corridor/allowed/zero-delay/warm/nonzero-warm-window. Actions: disarm/hide
 * with warmth/reveal/arm. Travel facts: shown/focus-owned/owner/content/corridor;
 * actions: clear transit/remember point/renew transit/hide with warmth.
 * Frame expiry facts: allowed/shown/focus-owned/transit-expired; actions:
 * disarm+clear transit/hide with warmth. Promotion facts: armed/dwell-expired;
 * action: promote. Content reconciliation uses shown/focus-owned/owner/content
 * facts and the travel actions, without a corridor or empty-slot mutation.
 * Two frame calls preserve separate native visibility commits.
 * Full-width identities, clock arithmetic, geometry and storage remain native.
 */
function nscvTooltipPointer(request: Uint8Array): Uint8Array {
  if (request.length !== 4 || request[1]! > 4) throw new Error("invalid tooltip pointer request");
  const cause = request[1]!, facts = request[2]! | request[3]! << 8;
  const limit = cause === 0 ? 4095 : cause === 1 ? 31 : cause === 3 ? 3 : 15;
  if (facts > limit) throw new Error("invalid tooltip pointer facts");
  let actions = 0;
  if (cause === 0) {
    const target = (facts & 4) !== 0, shownMatches = (facts & 8) !== 0;
    const content = (facts & 64) !== 0;
    const hide = (facts & 1) !== 0 && (facts & 2) === 0 && !shownMatches &&
      !content && (target || (facts & 128) === 0);
    if (hide) actions |= 2;
    if ((facts & 16) !== 0 && (facts & 32) === 0) actions |= 1;
    if (target && !shownMatches && !content && (facts & 256) !== 0) {
      // A hide opens warmth before the new target earns its dwell.
      if ((facts & 512) !== 0 || (hide ? (facts & 2048) !== 0 : (facts & 1024) !== 0)) actions |= 4;
      else if ((facts & 32) === 0) actions |= 8;
    }
  } else if (cause === 1) {
    if ((facts & 1) === 0 || (facts & 2) !== 0) actions = 1;
    else if ((facts & (4 | 8)) !== 0) actions = 1 | 2;
    else if ((facts & 16) !== 0) actions = 4;
    else actions = 8;
  } else if (cause === 2) {
    if ((facts & 1) === 0) actions = 1;
    else if ((facts & 2) !== 0 && (facts & 4) === 0 && (facts & 8) !== 0) actions = 2;
  } else if (cause === 3) {
    if (facts === 3) actions = 1;
  } else if ((facts & 1) !== 0 && (facts & 2) === 0) {
    actions = (facts & (4 | 8)) !== 0 ? 1 | 2 : 8;
  }
  const result = new Uint8Array(1); result[0] = actions;
  return result;
}

/** Tooltip intent. Tag 24, cause (focus/press/activation/programmatic focus/
 * blur/pointer close/dismissal), facts byte: shown, focus-owned, target present,
 * shown matches target, armed matches target, focus matches owner, reveal allowed.
 * Result flags: clear armed/shown, reveal focus, clear warmth/transit, consume
 * standing keyboard intent, visibility changed. IDs, clocks, register writes,
 * visibility commits and OS effects remain native; no JS numeric ID conversion.
 */
function nscvTooltipIntent(request: Uint8Array): Uint8Array {
  if (request.length !== 3 || request[1]! > 6 || request[2]! > 127)
    throw new Error("invalid tooltip intent request");
  const cause = request[1]!, facts = request[2]!;
  const shown = (facts & 1) !== 0, focusOwned = (facts & 2) !== 0;
  const target = (facts & 4) !== 0, shownMatches = (facts & 8) !== 0;
  const armedMatches = (facts & 16) !== 0, focusMatches = (facts & 32) !== 0;
  let flags = 0;
  if (cause === 0) {
    if (shown && focusOwned && !shownMatches) flags |= 2 | 64;
    if (target && (facts & 64) !== 0) {
      flags |= 4 | 16;
      if (!shownMatches) flags |= 64;
      if (armedMatches) flags |= 1;
    }
  } else if (cause === 1 || cause === 4) {
    flags = 1 | 8 | 16;
    if (shown || cause === 4) flags |= 2;
    if (shown) flags |= 64;
  } else if (cause === 2 || cause === 6) {
    if (target || cause === 6) {
      if (armedMatches) flags |= 1;
      if (shownMatches) { flags |= 2 | 16; if (shown) flags |= 64; }
      if (cause === 2) {
        if (armedMatches || shownMatches) {
          flags |= 8;
          if (focusMatches) flags |= 32;
        }
      } else if (shownMatches && focusMatches) flags |= 32;
    }
  } else if (cause === 3) {
    if (shown && focusOwned) flags = 2 | 64;
  } else {
    flags = 1 | 8 | 16;
    if (shown && !focusOwned) flags |= 2 | 64;
  }
  const result = new Uint8Array(1); result[0] = flags;
  return result;
}

/** Tooltip binding. Tag 23, mode (ownership/pointer binding/focus binding),
 * count/owner/tooltip u16, granted pointer/focus eligibility bits. Each node
 * supplies anchored-tooltip bit and parent u16. Hidden stamps deliberately
 * do not affect ownership; the last mounted direct child wins, then the
 * owner's parent's child. Result is a u16 index or 65535 for no live binding.
 * Native retains full-width IDs, geometry, intent registers and adoption.
 */
function nscvTooltipBinding(request: Uint8Array): Uint8Array {
  if (request.length < 9 || request[1]! > 2 || request[8]! > 3)
    throw new Error("invalid tooltip binding request");
  const count = request[2]! | request[3]! << 8;
  const owner = request[4]! | request[5]! << 8, tooltip = request[6]! | request[7]! << 8;
  if (count > 1024 || request.length !== 9 + count * 3 ||
      owner !== 65535 && owner >= count || tooltip !== 65535 && tooltip >= count)
    throw new Error("invalid tooltip binding table");
  const parents: number[] = [], children: number[] = [], anchored: boolean[] = [];
  for (let i = 0; i < count; i++) {
    const at = 9 + i * 3, bits = request[at]!, parent = request[at + 1]! | request[at + 2]! << 8;
    if (bits > 1 || parent !== 65535 && parent >= i) throw new Error("invalid tooltip binding node");
    parents.push(parent); children.push(65535); anchored.push(bits === 1);
    if (bits === 1 && parent !== 65535) children[parent] = i;
  }
  let chosen = 65535;
  if (owner !== 65535) {
    const parent = parents[owner]!;
    chosen = children[owner] !== 65535 ? children[owner]! : parent === 65535 ? 65535 : children[parent]!;
    if (request[1] !== 0 && (tooltip === 65535 || !anchored[tooltip] || chosen !== tooltip ||
        (request[8]! & (request[1] === 1 ? 1 : 2)) === 0)) chosen = 65535;
  }
  const result = new Uint8Array(2);
  result[0] = chosen & 255; result[1] = chosen >>> 8;
  return result;
}

/** Focus return. Tag 22, mode (surface/focused descendant), count u16,
 * subject index u16. Three-byte nodes: eligible/anchored/dismissible flags,
 * parent u16. Native supplies exact visibility eligibility and keeps IDs.
 * Result is one u16 retained index; 65535 means no focus return.
 */
function nscvFocusReturn(request: Uint8Array): Uint8Array {
  if (request.length < 6 || request[1]! > 1) throw new Error("invalid focus return request");
  const count = request[2]! | request[3]! << 8, subject = request[4]! | request[5]! << 8;
  if (count > 1024 || request.length !== 6 + count * 3 || subject !== 65535 && subject >= count)
    throw new Error("invalid focus return table");
  const flags: number[] = [], parents: number[] = [];
  for (let i = 0; i < count; i++) {
    const at = 6 + i * 3, bits = request[at]!, parent = request[at + 1]! | request[at + 2]! << 8;
    if (bits > 7 || parent !== 65535 && parent >= i) throw new Error("invalid focus return node");
    flags.push(bits); parents.push(parent);
  }
  let surface = subject, chosen = 65535;
  if (request[1] === 1 && subject !== 65535) {
    surface = parents[subject]!;
    while (surface !== 65535 && (flags[surface]! & 6) !== 6) surface = parents[surface]!;
  }
  if (surface !== 65535 && (flags[surface]! & 2) !== 0) {
    const anchor = parents[surface]!;
    if (anchor !== 65535) {
      if ((flags[anchor]! & 1) !== 0) chosen = anchor;
      else {
        for (let i = 0; i < count; i++) {
          if (i !== surface && parents[i] === anchor && (flags[i]! & 1) !== 0) { chosen = i; break; }
        }
      }
    }
  }
  const result = new Uint8Array(2);
  result[0] = chosen & 255; result[1] = chosen >>> 8;
  return result;
}

/** Anchored surface selection. Header: tag 21, scope (any/interactive/menu),
 * count u16. Seven-byte nodes: kind (none/interactive/menu/tooltip) plus
 * hidden bit 4 and anchored bit 8, parent u16, effective paint layer i32.
 * Result: topmost index, then child/target/owned-menu index tables (u16).
 * Native retains opaque identities, geometry and dismissal side effects.
 */
function nscvSurfaceScope(request: Uint8Array): Uint8Array {
  if (request.length < 4 || request[1]! > 2) throw new Error("invalid surface scope request");
  const count = request[2]! | request[3]! << 8, scope = request[1]!;
  if (count > 1024 || request.length !== 4 + 7 * count) throw new Error("invalid surface scope table");
  const flags: number[] = [], parents: number[] = [], layers: number[] = [];
  const hidden: boolean[] = [], children: number[] = [], targets: number[] = [];
  for (let i = 0; i < count; i++) {
    const at = 4 + i * 7, bits = request[at]!, parent = request[at + 1]! | request[at + 2]! << 8;
    if (bits > 15 || parent !== 65535 && parent >= i) throw new Error("invalid surface scope node");
    const layer = request[at + 3]! | request[at + 4]! << 8 | request[at + 5]! << 16 | request[at + 6]! << 24;
    flags.push(bits); parents.push(parent); layers.push(layer); children.push(65535); targets.push(65535);
    hidden.push((bits & 4) !== 0 || parent !== 65535 && hidden[parent]!);
  }
  let topmost = 65535;
  for (let i = 0; i < count; i++) {
    const bits = flags[i]!;
    if ((bits & 12) !== 8 || !nscvSurfaceInScope(bits & 3, scope)) continue;
    const parent = parents[i]!;
    if (parent !== 65535) {
      const previous = children[parent]!;
      if (previous === 65535 || layers[previous]! <= layers[i]!) children[parent] = i;
    }
    if (!hidden[i] && (topmost === 65535 || layers[topmost]! <= layers[i]!)) topmost = i;
  }
  const result = new Uint8Array(2 + count * 6);
  result[0] = topmost & 255; result[1] = topmost >>> 8;
  for (let i = 0; i < count; i++) {
    const bits = flags[i]!, parent = parents[i]!;
    // An out-of-scope visible ancestor shields the rest of its chain.
    const target = (bits & 3) !== 0 && (bits & 4) === 0
      ? nscvSurfaceInScope(bits & 3, scope) ? i : 65535
      : children[i] !== 65535 ? children[i]! : parent === 65535 ? 65535 : targets[parent]!;
    targets[i] = target;
    const sibling = parent === 65535 ? 65535 : children[parent]!;
    const owned = scope !== 2 ? 65535 : children[i] !== 65535 ? children[i]! : sibling === i ? 65535 : sibling;
    const at = 2 + i * 6;
    result[at] = children[i]! & 255; result[at + 1] = children[i]! >>> 8;
    result[at + 2] = target & 255; result[at + 3] = target >>> 8;
    result[at + 4] = owned & 255; result[at + 5] = owned >>> 8;
  }
  return result;
}

function nscvSurfaceInScope(kind: number, scope: number): boolean {
  return kind !== 0 && (scope === 0 || scope === 1 && kind !== 3 || scope === 2 && kind === 2);
}

function nscvTabDescendant(parents: readonly number[], node: number, surface: number): boolean {
  let cursor = node;
  while (cursor !== 65535) {
    if (cursor === surface) return true;
    cursor = parents[cursor]!;
  }
  return false;
}

function nscvTabScan(flags: readonly number[], parents: readonly number[], start: number, stop: number, backward: boolean, surface: number): number {
  for (let i = start; backward ? i > stop : i < stop; i += backward ? -1 : 1) {
    if ((flags[i]! & 1) !== 0 && (surface === 65535 || nscvTabDescendant(parents, i, surface))) return i;
  }
  return 65535;
}

function nscvTabNext(flags: readonly number[], parents: readonly number[], surfaces: readonly number[], current: number, backward: boolean): number {
  const count = flags.length;
  if (current === 65535) return nscvTabScan(flags, parents, backward ? count - 1 : 0, backward ? -1 : count, backward, 65535);
  const surface = surfaces[current]!;
  if (surface !== 65535) {
    const first = nscvTabScan(flags, parents, backward ? current - 1 : current + 1, backward ? -1 : count, backward, surface);
    if (first !== 65535) return first;
    const wrap = nscvTabScan(flags, parents, backward ? count - 1 : surface, backward ? current - 1 : current + 1, backward, surface);
    if (wrap !== 65535) return wrap;
  }
  const first = nscvTabScan(flags, parents, backward ? current - 1 : current + 1, backward ? -1 : count, backward, 65535);
  return first !== 65535 ? first : nscvTabScan(flags, parents, backward ? count - 1 : 0, current, backward, 65535);
}

/** Shared control intent: tag 15, kind (0 composed, 1 button, 2 icon button,
 * 3 select, 4 combo, 5 accordion, 6 checkbox, 7 switch, 8 toggle, 9 toggle
 * button, 10 radio, 11 list item, 12 menu item, 13 cell, 14 segment,
 * 15 slider, 16 divider, 17 grid, 18 scroll, 19 list, 20 data grid, 21 table),
 * key (0 other, 1 Enter, 2 Space, 3 Up, 4 Down, 5 Left, 6 Right, 7 Home,
 * 8 End), flags (tree row/focus moved/radio selection/command/focusable/
 * declared press/virtualized), expanded (0 absent, 1 false, 2 true).
 * Native grants eligible key-downs and supplies focus stamps. Result is
 * 0 none, 1 press, 2 toggle, 3 select, 4 specialized planner; second byte
 * carries press/toggle/select action bits. Shift remains eligible.
 */
function nscvKeyboardControl(request: Uint8Array): Uint8Array {
  if (request.length !== 5 || request[1]! > 21 || request[2]! > 8 ||
      request[3]! > 127 || request[4]! > 2) throw new Error("invalid keyboard control request");
  const kind = request[1]!, key = request[2]!, flags = request[3]!, expanded = request[4]!;
  const activation = key === 1 || key === 2, navigation = key >= 3;
  let intent = 0, actions = 0;
  if ((flags & 1) !== 0) {
    if (activation || navigation && (flags & 2) !== 0) intent = 3;
    else if (expanded === 2 && key === 5 || expanded === 1 && key === 6) intent = 2;
  }
  if (intent === 0 && kind === 10 && (flags & 4) !== 0 && navigation) intent = 3;
  if (intent === 0) {
    if (kind === 1 || kind === 2) intent = activation ? 1 : 0;
    else if (kind === 3 || kind === 4) intent = activation || (key === 3 || key === 4) && expanded !== 2 ? 1 : 0;
    else if (kind >= 5 && kind <= 9) intent = activation ? 2 : 0;
    else if (kind >= 10 && kind <= 14) intent = activation ? 3 : 0;
    else if (kind >= 15) intent = kind !== 17 || (flags & 64) !== 0 ? 4 : 0;
    else if ((flags & 48) === 48 && activation) intent = 1;
  }
  if (intent === 1) actions = 1;
  else if (intent === 2) actions = 2;
  else if (intent === 3) actions = 4 | ((flags & 8) !== 0 ? 1 : 0);
  const result = new Uint8Array(2); result[0] = intent; result[1] = actions; return result;
}

/** Shared semantic intent: tag 16, the same kind projection as tag 15,
 * action (0 press, 1 toggle, 2 select, 3 increment, 4 decrement), granted
 * action bits (press/toggle/select/increment/decrement), tree-row flag.
 * Native checks disabled/hidden state and supplies advertised actions.
 * Press on selectable rows selects and presses; an explicit select
 * carries press only when granted. Result uses tag 15's intent/action
 * vocabulary, with 4 delegating eligible steps to shared operation 18.
 * The same resolution serves public semantic APIs and pointer handlers.
 */
function nscvSemanticControl(request: Uint8Array): Uint8Array {
  if (request.length !== 5 || request[1]! > 21 || request[2]! > 4 ||
      request[3]! > 31 || request[4]! > 1) throw new Error("invalid semantic control request");
  const kind = request[1]!, action = request[2]!, granted = request[3]!;
  let intent = 0, actions = 0;
  if (action === 0 && (granted & 1) !== 0) {
    intent = (granted & 4) !== 0 && (request[4] === 1 || kind >= 10 && kind <= 14) ? 3 : 1;
    actions = intent === 3 ? 5 : 1;
  } else if (action === 1 && (granted & 2) !== 0) { intent = 2; actions = 2; }
  else if (action === 2 && (granted & 4) !== 0) { intent = 3; actions = 4 | (granted & 1); }
  else if ((action === 3 && (granted & 8) !== 0 || action === 4 && (granted & 16) !== 0) &&
      (kind === 15 || kind >= 17)) intent = 4;
  const result = new Uint8Array(2); result[0] = intent; result[1] = actions; return result;
}

/** Semantic derivation: tag 17, LE u16 stable widgetKindCode, flags
 * (disabled/read-only/treeitem/authored-focusable/command), LE u16 authored
 * actions. Action bits are focus/press/toggle/increment/decrement/set_text/
 * set_selection/select/drag/drop_files/dismiss. The five-byte result contains
 * LE u16 merged actions, LE u16 defaults, and default focusability. Read-only
 * removes set_text from merged actions only; disabled clears all three results.
 * Native supplies facts and retains eligibility, topology and result ownership.
 */
function nscvSemanticActions(request: Uint8Array): Uint8Array {
  if (request.length !== 6 || request[1]! > 62 || request[2] !== 0 ||
      request[3]! > 31 || request[5]! > 7) throw new Error("invalid semantic actions request");
  const result = new Uint8Array(5);
  if ((request[3]! & 1) !== 0) return result;
  const kind = request[1]!, flags = request[3]!;
  const tree = (flags & 4) !== 0, command = (flags & 16) !== 0;
  const focusable = tree || kind === 6 || kind === 14 || kind >= 31 && kind <= 39 ||
    kind === 41 || kind === 42 || kind === 44 || kind >= 46 && kind <= 51 || kind === 58 || kind === 62;
  let defaults = focusable || (flags & 8) !== 0 ? 1 : 0;
  if (kind === 31 || kind === 33 || kind === 34) defaults |= 2;
  else if (kind === 41) defaults |= 2 | 128;
  else if (kind === 14 || kind === 32 || kind === 47 || kind === 49 || kind === 50) defaults |= 4;
  else if (kind === 48 || kind === 42 || kind === 44 || kind === 46) defaults |= 128 | (command ? 2 : 0);
  else if (kind >= 35 && kind <= 39) defaults |= 32 | 64 | (kind === 38 ? 2 : 0);
  else if (kind === 51) defaults |= 8 | 16;
  else if (kind === 16) defaults |= 256;
  else if (kind === 58) defaults |= 256 | 8 | 16;
  else if (kind >= 19 && kind <= 21 || kind >= 23 && kind <= 25 || kind === 40) defaults |= 1024;
  if (tree) defaults |= 128 | (command ? 2 : 0);
  let actions = defaults | request[4]! | (request[5]! << 8);
  if ((flags & 2) !== 0) actions &= ~32;
  result[0] = actions & 255; result[1] = actions >>> 8;
  result[2] = defaults & 255; result[3] = defaults >>> 8;
  result[4] = focusable ? 1 : 0;
  return result;
}

/** Shared step intents: tag 18, kind from tag 15, mode (0 keyboard control,
 * 1 semantic increment, 2 semantic decrement, 3 scroll keyboard), key from
 * tag 15 plus 9 PageUp/10 PageDown, flags (shift/virtualized/horizontal axes/
 * both axes/sideways-only overflow), then current value and measured viewport
 * width/height f32LE. Native grants eligibility and measures overflow facts.
 * Existing numeric
 * policies retain each f32 arithmetic stage. The 16-byte copied result is
 * kind (0 none, 1 value, 2 scroll by, 3 start, 4 end), increment/decrement
 * bits, two zero bytes, then value/dx/dy f32LE. Keyboard value action bits
 * compare the unclamped step; semantic bits retain the requested direction.
 */
function nscvStepControl(request: Uint8Array): Uint8Array {
  if (request.length !== 17 || request[1]! > 21 || request[2]! > 3 ||
      request[3]! > 10 || request[4]! > 31 || (request[4]! & 12) === 12) throw new Error("invalid step control request");
  const kind = request[1]!, mode = request[2]!, key = request[3]!, flags = request[4]!;
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const current = wire.getFloat32(5, true), width = wire.getFloat32(9, true), height = wire.getFloat32(13, true);
  const result = new Uint8Array(16), out = new DataView(result.buffer);
  const semantic = mode === 1 || mode === 2;
  if (mode === 0 && (kind === 15 || kind === 16) || semantic && kind === 15) {
    let operation = 0;
    if (semantic) operation = mode === 1 ? 3 : 2;
    else if (key === 5 || kind === 15 && key === 4) operation = (flags & 1) !== 0 ? 4 : 2;
    else if (key === 6 || kind === 15 && key === 3) operation = (flags & 1) !== 0 ? 5 : 3;
    else if (key === 7) operation = 6;
    else if (key === 8) operation = 7;
    else return result;
    const input = new Uint8Array(kind === 15 ? 14 : 26);
    input[0] = operation + (kind === 16 ? 1 : 0);
    new DataView(input.buffer).setFloat32(2, current, true);
    const valueBytes = kind === 15 ? nscvSliderPolicy(input) : nscvSplitPolicy(input);
    const value = new DataView(valueBytes.buffer, valueBytes.byteOffset, valueBytes.byteLength).getFloat32(0, true);
    result[0] = 1;
    result[1] = semantic ? (mode === 1 ? 1 : 2) : (value > current ? 1 : value < current ? 2 : 0);
    out.setFloat32(4, Math.max(0, Math.min(1, value)), true);
    return result;
  }
  if (mode !== 3 && !(kind >= 17 && kind <= 21)) return result;
  if (!semantic && (key === 7 || key === 8)) {
    result[0] = key === 7 ? 3 : 4; result[1] = key === 7 ? 2 : 1;
    return result;
  }
  const operation = semantic ? (mode === 1 ? 11 : 10) :
    key === 5 ? 4 : key === 6 ? 5 : key === 3 ? 6 : key === 4 ? 7 : key === 9 ? 8 : key === 10 ? 9 : 0;
  if (operation === 0) return result;
  const input = new Uint8Array(26), args = new DataView(input.buffer);
  input[0] = 128 + operation;
  const horizontal = kind === 18 && (flags & 2) === 0 && (flags & 4) !== 0;
  const dual = kind === 18 && (flags & 2) === 0 && (flags & 8) !== 0;
  const primary = horizontal || dual && (flags & 16) !== 0;
  input[1] = 1 | (semantic ? (primary ? 8 : 0) : (horizontal ? 8 : 0) | (dual ? 16 : 0));
  args.setFloat32(6, width, true); args.setFloat32(10, height, true);
  const deltaBytes = nscvScrollPolicy(input);
  const delta = new DataView(deltaBytes.buffer, deltaBytes.byteOffset, deltaBytes.byteLength);
  const x = delta.getFloat32(0, true), y = delta.getFloat32(4, true), step = y !== 0 ? y : x;
  result[0] = 2;
  result[1] = semantic ? (mode === 1 ? 1 : 2) : (step > 0 ? 1 : step < 0 ? 2 : 0);
  out.setFloat32(8, x, true); out.setFloat32(12, y, true);
  return result;
}

/** Editor shortcuts: tag 13, mode (0 clipboard, 1 history), phase
 * (0 down, 1 up, 2 text), modifier bits (shift/control/alt/super), key
 * (0 unknown, 1 C, 2 X, 3 V, 4 Z). One-byte result: 0 none;
 * clipboard 1 Copy/2 Cut/3 Paste, history 1 Undo/2 Redo. Native retains
 * eligibility, OS transport and history lookup. History uses the host's
 * primary/super projection; a raw control flag alone remains inert.
 */
function nscvEditorShortcut(request: Uint8Array): Uint8Array {
  if (request.length !== 5 || request[1]! > 1 || request[2]! > 2 ||
      request[3]! > 15 || request[4]! > 4) throw new Error("invalid editor shortcut request");
  const bits = request[3]!, key = request[4]!;
  const shift = (bits & 1) !== 0, control = (bits & 2) !== 0;
  const alt = (bits & 4) !== 0, meta = (bits & 8) !== 0;
  let action = 0;
  if (request[2] === 0 && !alt) {
    if (request[1] === 0 && (control || meta) && !shift && key >= 1 && key <= 3) action = key;
    else if (request[1] === 1 && meta && key === 4) action = shift ? 2 : 1;
  }
  const result = new Uint8Array(1); result[0] = action; return result;
}

/** Editor boundaries: tag 14, kind (0 textarea, 1 entry, 2 search, 3 combo),
 * phase (0 down, 1 up, 2 text), shift/control/alt/super bits, normalized key
 * (0 unknown, 1 Escape, 2 Up, 3 Down), text-present, composition, expanded.
 * Result: 0 fall through, 1 consume without edit, 2 cancel composition,
 * 3 clear, 4 start, 5 end; second byte extends selection. Escape deliberately
 * ignores text payloads. Closed combo arrows open before any caret edit.
 */
function nscvEditorBoundary(request: Uint8Array): Uint8Array {
  if (request.length !== 8 || request[1]! > 3 || request[2]! > 2 ||
      request[3]! > 15 || request[4]! > 3 || request[5]! > 1 ||
      request[6]! > 1 || request[7]! > 1) throw new Error("invalid editor boundary request");
  const kind = request[1]!, bits = request[3]!, key = request[4]!;
  const shift = (bits & 1) !== 0, navigation = (bits & 14) !== 0;
  let action = 0;
  if (request[2] === 0 && !navigation) {
    if (key === 1 && !shift) action = request[6] === 1 ? 2 : kind >= 2 ? 3 : 1;
    else if (kind !== 0 && request[5] === 0 && !(kind === 3 && request[7] === 0)) {
      if (key === 2) action = 4;
      else if (key === 3) action = 5;
    }
  }
  const result = new Uint8Array(2); result[0] = action; result[1] = shift ? 1 : 0; return result;
}

/** Clipboard selection: tag 12, selection-present and two reserved bytes,
 * LE u32 source length, exact LE u64 anchor/focus, then source bytes. Native
 * keeps focus/eligibility and clipboard transport. The 12-byte result holds
 * LE u32 flags (1 Copy/Cut range, 2 Select All), start and end; it is copied
 * before the compiler arena resets. Huge offsets clamp without f64 rounding.
 */
function nscvTextClipboard(request: Uint8Array): Uint8Array {
  const budget = 512 * 1024;
  if (request.length < 24 || request.length > 24 + budget || request[1]! > 1 ||
      request[2] !== 0 || request[3] !== 0) throw new Error("invalid text clipboard request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const length = data.getUint32(4, true);
  if (length > budget || request.length !== 24 + length) throw new Error("invalid text clipboard budget");
  const offset = (at: number): number => data.getUint32(at + 4, true) !== 0 ? length : Math.min(data.getUint32(at, true), length);
  const range = nscvClipboardRange(request.subarray(24), request[1] === 1 ? nscvSelection(offset(8), offset(16)) : null);
  const result = new Uint8Array(12), out = new DataView(result.buffer);
  out.setUint32(0, (range !== null ? 1 : 0) | (length > 0 ? 2 : 0), true);
  if (range !== null) { out.setUint32(4, range.start, true); out.setUint32(8, range.end, true); }
  return result;
}

/** Code Tab: tag 11, three reserved zero bytes, LE u32 caret, UTF-8 source.
 * Result is one byte: 0 for a tab, or a space width from 2 through 8.
 * Native keeps eligibility, key delivery and static insertion bytes.
 */
function nscvCodeIndentation(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request.length > 8 + 512 * 1024 ||
      request[1] !== 0 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid code indentation request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const insertion = nscvIndentation(request.subarray(8), data.getUint32(4, true));
  const result = new Uint8Array(1);
  result[0] = insertion[0] === 9 ? 0 : insertion.length;
  return result;
}

/** Editable no-wrap code lowers to a textarea plus renderer metadata.
 * Count its terminal caret line and omit the gutter beyond 10,000 source
 * lines, matching the retained native code component's line budget.
 */
function nscvCodeEditor(node: NscViewNode, numbered: boolean, addedSpec: Uint8Array, removedSpec: Uint8Array): void {
  let lines = 1;
  for (let i = 0; i < node.text.length; i += 1) if (node.text.charCodeAt(i) === 10) lines += 1;
  const terminal = node.text.length > 0 && node.text.charCodeAt(node.text.length - 1) === 10;
  let digits = 0;
  if (numbered && lines - (terminal ? 1 : 0) <= 10000) {
    digits = 1;
    let remaining = lines;
    while (remaining >= 10) { remaining = Math.floor(remaining / 10); digits += 1; }
  }
  node.codeLineDigits = digits;
  const added = nscvCodeLines(addedSpec), removed = nscvCodeLines(removedSpec);
  if (added === null || removed === null) throw new Error("invalid code diff line specification");
  for (const line of added) {
    if (removed.includes(line)) throw new Error("code diff added and removed lines overlap");
  }
  if (added.length !== 0 || removed.length !== 0) {
    node.codeAddedLines = added; node.codeRemovedLines = removed;
  }
}

/** Tagged pointer request: 3, multiline, click count (2/3), mode
 * (0 fresh click/1 drag/2 Shift extension), then offset and anchor run's
 * start/end as LE u32, followed by borrowed UTF-8 text. Result is four LE
 * u32 values: oriented selection anchor/focus and retained anchor run.
 */
function nscvTextPointerSelection(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request.length > 16 + 512 * 1024 || request[1]! > 1 ||
      request[2]! < 2 || request[2]! > 3 || request[3]! > 2) throw new Error("invalid text pointer policy request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const text = request.subarray(16), offset = data.getUint32(4, true);
  const unit = (at: number): { readonly anchor: number; readonly focus: number } => {
    if (request[2] === 2) return nscvWordSelection(text, at);
    if (request[1] === 1) return nscvLineSelection(text, at);
    return nscvSelection(0, text.length);
  };
  const selected = unit(offset);
  let start = Math.min(selected.anchor, selected.focus), end = Math.max(selected.anchor, selected.focus);
  if (request[3] === 1) {
    const a = Math.min(data.getUint32(8, true), text.length), b = Math.min(data.getUint32(12, true), text.length);
    start = Math.min(a, b); end = Math.max(a, b);
  } else if (request[3] === 2) {
    const anchor = unit(data.getUint32(8, true));
    start = Math.min(anchor.anchor, anchor.focus); end = Math.max(anchor.anchor, anchor.focus);
  }
  let anchor = start, focus = end;
  if (selected.anchor < start) { anchor = end; focus = selected.anchor; }
  else if (selected.focus > end) { anchor = start; focus = selected.focus; }
  const result = new Uint8Array(16), out = new DataView(result.buffer);
  out.setUint32(0, anchor, true); out.setUint32(4, focus, true);
  out.setUint32(8, start, true); out.setUint32(12, end, true);
  return result;
}

/** Tagged reducer request: 4, event (the SDK text event order), caret direction,
 * extend, composition-present, cursor-present, two reserved zero bytes;
 * then LE u32 text length, anchor/focus, composition start/end, event arguments,
 * and capacity. UTF-8 source and insert/preedit bytes follow the 40-byte header.
 * Result: LE u32 flags (1 accepted, 2 retain original text), anchor/focus,
 * composition-present/start/end, then edited bytes. Four zero bytes refuse
 * an over-capacity edit. Native keeps storage, history and painted affinity.
 */
function nscvTextEdit(request: Uint8Array): Uint8Array {
  const budget = 512 * 1024;
  if (request.length < 40 || request.length > 40 + 2 * budget || request[1]! > 12 ||
      request[2]! > 5 || request[3]! > 1 || request[4]! > 1 || request[5]! > 1 ||
      request[6] !== 0 || request[7] !== 0) throw new Error("invalid text reducer request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const length = data.getUint32(8, true), capacity = data.getUint32(36, true);
  if (length > budget || request.length < 40 + length || request.length - 40 - length > budget || capacity > budget)
    throw new Error("invalid text reducer budget");
  const text = request.subarray(40, 40 + length), inserted = request.subarray(40 + length);
  const selection = nscvSelection(data.getUint32(12, true), data.getUint32(16, true));
  const composition = nscvSelection(data.getUint32(20, true), data.getUint32(24, true));
  const args = nscvSelection(data.getUint32(28, true), data.getUint32(32, true));
  let edit: NscvTextInputEvent;
  switch (request[1]) {
    case 0: edit = { kind: "insert_text", text: inserted }; break;
    case 1: edit = { kind: "delete_backward" }; break;
    case 2: edit = { kind: "delete_forward" }; break;
    case 3: edit = { kind: "delete_word_backward" }; break;
    case 4: edit = { kind: "delete_word_forward" }; break;
    case 5: edit = { kind: "delete_to_start" }; break;
    case 6: edit = { kind: "delete_to_line_start" }; break;
    case 7: edit = { kind: "clear" }; break;
    case 8: edit = { kind: "move_caret", move: {
      direction: request[2] === 0 ? "previous" : request[2] === 1 ? "next" :
        request[2] === 2 ? "previous_word" : request[2] === 3 ? "next_word" : request[2] === 4 ? "start" : "end",
      extend: request[3] === 1 } }; break;
    case 9: edit = { kind: "set_selection", selection: args }; break;
    case 10: edit = { kind: "set_composition", text: inserted, cursor: request[5] === 1 ? args.anchor : null }; break;
    case 11: edit = { kind: "commit_composition" }; break;
    default: edit = { kind: "cancel_composition" }; break;
  }
  const next = nscvApplyTextEdit({ text, selection,
    composition: request[4] === 1 ? { start: composition.anchor, end: composition.focus } : null }, edit, capacity);
  if (next === null) return new Uint8Array(4);
  const retained = next.text === text;
  const result = new Uint8Array(24 + (retained ? 0 : next.text.length)), out = new DataView(result.buffer);
  out.setUint32(0, retained ? 3 : 1, true);
  out.setUint32(4, next.selection.anchor, true); out.setUint32(8, next.selection.focus, true);
  out.setUint32(12, next.composition !== null ? 1 : 0, true);
  out.setUint32(16, next.composition !== null ? next.composition.start : 0, true);
  out.setUint32(20, next.composition !== null ? next.composition.end : 0, true);
  if (!retained) result.set(next.text, 24);
  return result;
}

/** Rebuild policy: tag 5, source-unchanged, source-matches-retained, reserved;
 * source flags (selection/composition/downstream), retained selection flags
 * (present/downstream), previous source selection flags, reserved. Four LE
 * u64 offsets follow: source anchor/focus, retained anchor/focus. Compare
 * their u32 halves exactly, including offsets beyond JS's safe integers.
 * Result bits retain text, retain native scroll/cache state, retain selection
 * and composition, and retain affinity. Native owns bytes and caret geometry.
 */
function nscvTextReconcile(request: Uint8Array): Uint8Array {
  if (request.length !== 40 || request[1]! > 1 || request[2]! > 1 || request[3] !== 0 ||
      request[4]! > 7 || request[5]! > 3 || request[6]! > 3 || request[7] !== 0)
    throw new Error("invalid text reconcile request");
  const result = new Uint8Array(1);
  if (request[1] === 0 && request[2] === 0) return result;
  let flags = 2 | (request[1] === 1 ? 1 : 0);
  const sourceSelection = (request[4]! & 1) !== 0;
  if (!sourceSelection && (request[4]! & 2) === 0) flags |= 4;
  else if (sourceSelection && (request[5]! & 1) !== 0) {
    const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
    const echoed = data.getUint32(8, true) === data.getUint32(24, true) &&
      data.getUint32(12, true) === data.getUint32(28, true) &&
      data.getUint32(16, true) === data.getUint32(32, true) &&
      data.getUint32(20, true) === data.getUint32(36, true);
    const downstream = (request[4]! & 4) !== 0;
    const affinityChanged = (request[6]! & 1) !== 0 ? downstream !== ((request[6]! & 2) !== 0) : downstream;
    if (echoed && !affinityChanged) flags |= 8;
  }
  result[0] = flags;
  return result;
}

/** New input: tag 6, mode (0 insert/1 composition/2 paste), single-line,
 * cursor-present, LE u32 cursor/available paste bytes/reserved zero, then
 * input bytes. Sanitize before applying the paste limit. The result's LE
 * u32 flags (1 present/2 borrowed prefix/4 cursor-present/8 truncated),
 * cursor and length precede copied bytes. Native copies before arena reset.
 */
function nscvTextInput(request: Uint8Array): Uint8Array {
  const budget = 512 * 1024;
  if (request.length < 16 || request.length > 16 + budget || request[1]! > 2 ||
      request[2]! > 1 || request[3]! > 1) throw new Error("invalid text input request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[1]!, available = data.getUint32(8, true);
  if (available > budget || data.getUint32(12, true) !== 0 ||
      mode !== 1 && (request[3] !== 0 || data.getUint32(4, true) !== 0))
    throw new Error("invalid text input arguments");
  const source = request.subarray(16);
  const rawCursor = data.getUint32(4, true);
  const cursorOffset = rawCursor >= 0 && rawCursor <= 4294967295 ? Math.trunc(rawCursor) : 0;
  const event: NscvTextInputEvent = mode === 1 ?
    { kind: "set_composition", text: source, cursor: request[3] === 1 ? cursorOffset : null } :
    { kind: "insert_text", text: source };
  const sanitized = request[2] === 1 ? nscvSanitizeTextInput(event) : event;
  if (sanitized === null) return new Uint8Array(12);
  if (sanitized.kind !== "insert_text" && sanitized.kind !== "set_composition")
    throw new Error("invalid prepared text event");
  let text = sanitized.text;
  const borrowed = text === source;
  const truncated = mode === 2 && text.length > available;
  if (truncated) {
    let end = available;
    while (end > 0 && end < text.length && (text[end]! & 0xc0) === 0x80) end -= 1;
    text = text.subarray(0, end);
  }
  const cursor = sanitized.kind === "set_composition" ? sanitized.cursor : null;
  const result = new Uint8Array(12 + (borrowed ? 0 : text.length)), out = new DataView(result.buffer);
  out.setUint32(0, 1 | (borrowed ? 2 : 0) | (cursor !== null ? 4 : 0) | (truncated ? 8 : 0), true);
  out.setUint32(4, cursor === null ? 0 : cursor, true); out.setUint32(8, text.length, true);
  if (!borrowed) result.set(text, 12);
  return result;
}

/** History replay: tag 7, mode (0 start/1 continue/2 commit), redo,
 * before/after byte-match bits and current/before/after affinity bits.
 * Three exact LE u64 anchor/focus pairs follow at byte 8. LE u32 prefix,
 * removed length and inserted length at byte 56 precede retained payloads.
 * The 24-byte result carries action (none/clear/complete/insert/backward/
 * forward/selection), affinity and exact u64 selection. Native retains
 * history bytes and applies one step before re-reading the entry by serial.
 */
function nscvTextHistoryReplay(request: Uint8Array): Uint8Array {
  const budget = 512 * 1024;
  if (request.length < 68 || request[1]! > 2 || request[2]! > 1 || request[3]! > 3 ||
      request[4]! > 7 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
    throw new Error("invalid text history request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const prefix = data.getUint32(56, true), removed = data.getUint32(60, true), inserted = data.getUint32(64, true);
  if (removed + inserted > budget || prefix + removed > budget || prefix + inserted > budget ||
      request.length !== 68 + removed + inserted) throw new Error("invalid text history budget");
  const redo = request[2] === 1, mode = request[1]!, desired = redo ? 40 : 24;
  const currentAffinity = request[4]! & 1, desiredAffinity = (request[4]! >> (redo ? 2 : 1)) & 1;
  const equal = (a: number, b: number): boolean => data.getUint32(a, true) === data.getUint32(b, true) &&
    data.getUint32(a + 4, true) === data.getUint32(b + 4, true) &&
    data.getUint32(a + 8, true) === data.getUint32(b + 8, true) &&
    data.getUint32(a + 12, true) === data.getUint32(b + 12, true);
  const at = (a: number, anchor: number, focus: number): boolean => data.getUint32(a, true) === anchor &&
    data.getUint32(a + 4, true) === 0 && data.getUint32(a + 8, true) === focus && data.getUint32(a + 12, true) === 0;
  const single = (start: number, length: number): boolean => {
    if (length === 0) return false;
    let offset = length - 1;
    while (offset > 0 && (request[start + offset]! & 0xc0) === 0x80) offset -= 1;
    return offset === 0;
  };
  const targetMatches = (request[3]! & (redo ? 2 : 1)) !== 0;
  const sourceMatches = (request[3]! & (redo ? 1 : 2)) !== 0;
  const selectionMatches = currentAffinity === desiredAffinity && equal(8, desired);
  const result = new Uint8Array(24), out = new DataView(result.buffer);
  if (mode === 2) { result[0] = targetMatches && selectionMatches ? 2 : 0; return result; }
  if (mode === 1 && targetMatches) {
    if (selectionMatches) result[0] = 2;
    else { result[0] = 6; result[1] = desiredAffinity; result.set(request.subarray(desired, desired + 16), 8); }
    return result;
  }
  if (!sourceMatches) { result[0] = 1; return result; }
  const oldLength = redo ? removed : inserted, newLength = redo ? inserted : removed;
  if (!redo && removed === 0 && single(68 + removed, inserted) && at(8, prefix + inserted, prefix + inserted) &&
      desiredAffinity === 0 && at(desired, prefix, prefix)) result[0] = 4;
  else if ((!redo && inserted === 0 || redo && removed === 0) && at(8, prefix, prefix) &&
      desiredAffinity === 0 && at(desired, prefix + newLength, prefix + newLength)) result[0] = 3;
  else if (redo && inserted === 0 && single(68, removed) && desiredAffinity === 0 && at(desired, prefix, prefix) &&
      at(8, prefix + removed, prefix + removed)) result[0] = 4;
  else if (redo && inserted === 0 && single(68, removed) && desiredAffinity === 0 && at(desired, prefix, prefix) &&
      at(8, prefix, prefix)) result[0] = 5;
  else if (currentAffinity !== 0 || !at(8, prefix, prefix + oldLength)) {
    result[0] = 6; out.setUint32(8, prefix, true); out.setUint32(16, prefix + oldLength, true);
  } else result[0] = 3;
  return result;
}

/** History recording: tag 8, provisional, composition-present, reserved;
 * LE u32 before/after lengths, snapped replacement start/end and preedit end
 * precede both text buffers. Result: record flag, common prefix, removed end
 * and inserted end. Native copies these offsets before its history mutation.
 */
function nscvTextHistoryDelta(request: Uint8Array): Uint8Array {
  const budget = 512 * 1024;
  if (request.length < 24 || request[1]! > 1 || request[2]! > 1 || request[3] !== 0)
    throw new Error("invalid text history delta request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const beforeLength = data.getUint32(4, true), afterLength = data.getUint32(8, true);
  if (beforeLength > budget || afterLength > budget || request.length !== 24 + beforeLength + afterLength)
    throw new Error("invalid text history delta budget");
  const before = request.subarray(24, 24 + beforeLength), after = request.subarray(24 + beforeLength);
  let prefix = 0, beforeEnd = before.length, afterEnd = after.length;
  const result = new Uint8Array(16), out = new DataView(result.buffer);
  if (request[1] === 1) {
    if (request[2] === 0) return result;
    prefix = data.getUint32(12, true); beforeEnd = data.getUint32(16, true); afterEnd = data.getUint32(20, true);
    if (prefix > beforeEnd || beforeEnd > before.length || prefix > afterEnd || afterEnd > after.length)
      throw new Error("invalid text history composition range");
    // Retain adjacent delimiters before later previews can complete a CRLF.
    if (prefix > 0 && before[prefix - 1] === 13) prefix -= 1;
    if (beforeEnd < before.length && afterEnd < after.length && before[beforeEnd] === 10 && after[afterEnd] === 10) {
      beforeEnd += 1; afterEnd += 1;
    }
  } else {
    const shared = Math.min(before.length, after.length);
    while (prefix < shared && before[prefix] === after[prefix]) prefix += 1;
    prefix = Math.min(nscvHistoryCaretOffset(before, prefix), nscvHistoryCaretOffset(after, prefix));
    let suffix = 0;
    while (suffix < before.length - prefix && suffix < after.length - prefix &&
        before[before.length - suffix - 1] === after[after.length - suffix - 1]) suffix += 1;
    while (suffix > 0 && (nscvHistoryCaretOffset(before, before.length - suffix) !== before.length - suffix ||
        nscvHistoryCaretOffset(after, after.length - suffix) !== after.length - suffix)) suffix -= 1;
    beforeEnd = before.length - suffix; afterEnd = after.length - suffix;
    if (beforeEnd === prefix && afterEnd === prefix) return result;
  }
  out.setUint32(0, 1, true); out.setUint32(4, prefix, true);
  out.setUint32(8, beforeEnd, true); out.setUint32(12, afterEnd, true);
  return result;
}

function nscvHistoryCaretOffset(text: Uint8Array, offset: number): number {
  let cursor = Math.min(offset, text.length);
  while (cursor > 0 && cursor < text.length && (text[cursor]! & 0xc0) === 0x80) cursor -= 1;
  if (cursor > 0 && cursor < text.length && text[cursor] === 10 && text[cursor - 1] === 13) cursor -= 1;
  return cursor;
}

/** Composition history update: tag 9, active, original-byte-match witness,
 * reserved; LE u32 prefix, removed length, original/current text lengths and
 * history capacity. Result: action (0 discard/1 retain/2 remove no-op/3 commit),
 * inserted end and length. Native retains the original removed bytes, hashes,
 * selections and pool compaction; no text payload crosses this boundary.
 */
function nscvTextCompositionHistory(request: Uint8Array): Uint8Array {
  if (request.length !== 24 || request[1]! > 1 || request[2]! > 1 || request[3] !== 0)
    throw new Error("invalid text composition history request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const prefix = data.getUint32(4, true), removed = data.getUint32(8, true);
  const beforeLength = data.getUint32(12, true), afterLength = data.getUint32(16, true);
  const capacity = data.getUint32(20, true), budget = 512 * 1024;
  if (beforeLength > budget || afterLength > budget || capacity > budget)
    throw new Error("invalid text composition history budget");
  const result = new Uint8Array(12), out = new DataView(result.buffer);
  if (prefix + removed > beforeLength) return result;
  const suffix = beforeLength - prefix - removed;
  if (afterLength < prefix + suffix) return result;
  const end = afterLength - suffix, inserted = end - prefix;
  if (removed + inserted > capacity) return result;
  out.setUint32(0, request[1] === 1 ? 1 : afterLength === beforeLength && request[2] === 1 ? 2 : 3, true);
  out.setUint32(4, end, true); out.setUint32(8, inserted, true);
  return result;
}

/** Timeline: tag 10, three reserved bytes, LE u32 count, then up to 128
 * ordered entry witnesses (target/kind/applied/provisional/before/after bits).
 * Native compares exact identities and length/hash boundaries. Result: LE
 * u32 flags (matching timeline/Undo available/Redo available), then nearest
 * Undo/Redo indices plus one; zero means absent. No retained bytes cross.
 */
function nscvTextHistoryTimeline(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[1] !== 0 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid text history timeline request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = data.getUint32(4, true);
  if (count > 128 || request.length !== 8 + count) throw new Error("invalid text history timeline count");
  let undo = 0, redo = 0, valid = true;
  for (let index = 0; index < count; index++) {
    const flags = request[8 + index]!;
    if (flags > 63) throw new Error("invalid text history timeline entry");
    if ((flags & 1) === 0) continue;
    if ((flags & 2) === 0 || (flags & 8) !== 0) { valid = false; continue; }
    if ((flags & 4) !== 0) undo = index + 1;
    else if (redo === 0) redo = index + 1;
  }
  const canUndo = undo !== 0 && (request[7 + undo]! & 32) !== 0;
  const canRedo = redo !== 0 && (request[7 + redo]! & 16) !== 0;
  const matches = valid && (undo !== 0 ? canUndo : redo !== 0 ? canRedo : true);
  const result = new Uint8Array(12), out = new DataView(result.buffer);
  out.setUint32(0, (matches ? 1 : 0) | (canUndo ? 2 : 0) | (canRedo ? 4 : 0), true);
  out.setUint32(4, undo, true); out.setUint32(8, redo, true);
  return result;
}

function nscvTooltipDelay(value: number): number {
  if (!Number.isInteger(value) || value < 0 || value > 2147483647) throw new Error("invalid tooltip delay");
  return value;
}

function nscvInteger(value: number): number {
  if (!Number.isSafeInteger(value)) throw new Error("compiled view key is not an exact integer");
  return value;
}

function nscvVariant(value: string): string {
  if (value === "default" || value === "primary" || value === "secondary" || value === "ghost" ||
      value === "destructive" || value === "outline") return value;
  throw new Error("unknown component variant");
}

function nscvLoopKeys(nodes: NscViewNode[], first: number, base: string | number): void {
  let slot = 0;
  for (let i = first; i < nodes.length; i = nodes[i]!.end) {
    const node = nodes[i]!;
    if (node.key === undefined && node.keyInt === undefined && node.globalKey === undefined && node.globalKeyInt === undefined) {
      if (typeof base === "number") node.keyInt = base;
      else node.key = base;
      node.keySlot = slot;
    }
    slot++;
  }
}

function nscvStepper(nodes: NscViewNode[], root: NscViewNode, active: number, labels: string[]): void {
  if (!Number.isSafeInteger(active)) throw new Error("stepper active is not an exact integer");
  active = Math.max(0, active);
  root.kind = "row"; root.gap = 8; root.cross = "center"; root.role = "list";
  nscvPush(nodes, root);
  for (let index = 0; index < labels.length; index++) {
    const state = index < active ? "completed" : index === active ? "active" : "pending";
    const item: NscViewNode = { end: 0, kind: "row", text: "", keyInt: index,
      gap: 6, cross: "center", selected: state === "active", role: "listitem",
      label: labels[index]! + " (" + state + ")", listItemIndex: index, listItemCount: labels.length };
    nscvPush(nodes, item);
    nscvPush(nodes, { end: 0, kind: "badge", text: state === "completed" ? "" : String(index + 1),
      icon: state === "completed" ? "check" : "", variant: state === "pending" ? "outline" : "primary" });
    const title: NscViewNode = { end: 0, kind: "text", text: labels[index]! };
    if (state === "active") title.spanWeight = "bold";
    if (state === "pending") title.foreground = "text_muted";
    nscvPush(nodes, title);
    item.end = nodes.length;
    if (index + 1 < labels.length) nscvPush(nodes, { end: 0, kind: "separator", text: "", grow: 1 });
  }
  root.end = nodes.length;
}

type NscTimelineItem = {
  root: NscViewNode; title: string; description: string; meta: string;
  indicator: string; icon: string; variant: string; connector: boolean;
};

function nscvTimelineItem(nodes: NscViewNode[], options: NscTimelineItem): void {
  const root = options.root;
  root.kind = "stack"; root.role = "listitem"; root.label = options.title;
  root.focusable = root.press !== undefined;
  nscvPush(nodes, root);
  const row: NscViewNode = { end: 0, kind: "row", text: "", gap: 10, padding: 8 };
  nscvPush(nodes, row);
  const lead: NscViewNode = { end: 0, kind: "column", text: "", cross: "center" };
  if (options.connector) lead.gap = 4;
  nscvPush(nodes, lead);
  const dot = options.indicator.length === 0 && options.icon.length === 0;
  nscvPush(nodes, { end: 0, kind: "badge", text: options.indicator, icon: options.icon,
    variant: options.variant, width: dot ? 10 : 0, height: dot ? 10 : 0 });
  if (options.connector) nscvPush(nodes, { end: 0, kind: "separator", text: "", grow: 1, width: 1 });
  lead.end = nodes.length;
  const content: NscViewNode = { end: 0, kind: "column", text: "", grow: 1, gap: 2 };
  nscvPush(nodes, content);
  nscvPush(nodes, { end: 0, kind: "text", text: options.title, spanWeight: "bold" });
  if (options.description.length > 0) nscvPush(nodes, { end: 0, kind: "text", text: options.description,
    wrap: true, foreground: "text_muted" });
  if (options.meta.length > 0) nscvPush(nodes, { end: 0, kind: "text", text: options.meta,
    spanColor: "text_muted", spanScale: 0.9 });
  content.end = nodes.length;
  if (root.press !== undefined) nscvPush(nodes, { end: 0, kind: "text", text: "›", foreground: "text_muted" });
  row.end = nodes.length;
  root.end = nodes.length;
}

/** Retained radio policy wire v1: operation, subject u16, count u16,
 * followed by parent u16, kind (0 other/1 radio/2 group), flags
 * (1 logical focus/2 visible focus/4 selected). Index 65535 means absent.
 * Operations: 0 scope, 1 logical entry, 2 visible stop, 3 visible entry,
 * 4 previous, 5 next, 6 first, 7 last, 8 selection clear mask.
 * Target responses are u16 indices; selection responds with one byte per node.
 * Native supplies geometry eligibility; this pure function chooses scopes,
 * selection clearing, and authored-order roving focus without reading Model.
 */
export function native_radio_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid radio policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 || operation > 8) throw new Error("invalid radio policy request");
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const parent = (i: number): number => read(5 + i * 4);
  const scope = (i: number): number => {
    let ancestor = parent(i);
    for (let depth = 0; ancestor !== 65535 && depth < count; depth++) {
      if (ancestor >= i) throw new Error("invalid radio policy parent");
      if (kind(ancestor) === 2) return ancestor;
      ancestor = parent(ancestor);
    }
    return 65535;
  };
  const group = kind(subject) === 2 ? subject : scope(subject);
  if (operation === 8) {
    const result = new Uint8Array(count);
    for (let i = 0; i < count; i++) {
      if (i !== subject && kind(i) === 1 && (flags(i) & 4) !== 0 && scope(i) === group &&
          (group !== 65535 || parent(i) === parent(subject))) result[i] = 1;
    }
    return result;
  }
  let target = 65535;
  if (operation === 0) target = scope(subject);
  else if (group !== 65535) {
    const eligible: number[] = [];
    for (let i = 0; i < count; i++) {
      const mask = operation === 2 || operation === 3 ? 2 : 1;
      if (kind(i) === 1 && scope(i) === group && (flags(i) & mask) !== 0) eligible.push(i);
    }
    if (eligible.length > 0) {
      target = eligible[0]!;
      if (operation === 1 || operation === 3) {
        for (const i of eligible) if ((flags(i) & 4) !== 0) { target = i; break; }
      } else if (operation === 7) target = eligible[eligible.length - 1]!;
      else if (operation === 4 || operation === 5) {
        target = subject;
        if (operation === 4) {
          target = eligible[eligible.length - 1]!;
          for (const i of eligible) if (i < subject) target = i;
        } else {
          target = eligible[0]!;
          for (const i of eligible) if (i > subject) { target = i; break; }
        }
      }
    } else if (operation === 4 || operation === 5) target = subject;
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Tabs wire: operation u8 (0 scope, 4 previous, 5 next, 6 first,
 * 7 last, 8 selection clear mask), subject/count u16LE, then
 * parent u16LE, kind (0 other/1 segment/2 tabs), flags (2 visible,
 * 4 selected). Segments share their direct parent; arrows do not wrap.
 * Native owns visibility, applied selection, and focus presentation.
 */
export function native_tabs_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid tabs policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 ||
      ![0, 4, 5, 6, 7, 8].includes(operation)) throw new Error("invalid tabs policy request");
  const parent = (i: number): number => read(5 + i * 4);
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const group = parent(subject);
  if (operation === 8) {
    const result = new Uint8Array(count);
    for (let i = 0; i < count; i++) if (i !== subject && kind(i) === 1 &&
      parent(i) === group && (flags(i) & 4) !== 0) result[i] = 1;
    return result;
  }
  let target = 65535;
  if (operation === 0) target = group < count && kind(group) === 2 ? group : 65535;
  else {
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      if (operation === 6) { target = i; break; }
      if (operation === 7 || operation === 4 && i < subject) target = i;
      if (operation === 5 && i > subject) { target = i; break; }
    }
    if (target === 65535 && (operation === 4 || operation === 5)) target = subject;
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Lower direct button triggers after structural if/for expansion, matching
 * native markup. Nested buttons and toggle-button contracts stay distinct.
 */
function nscvTabs(nodes: NscViewNode[], first: number): void {
  for (let i = first + 1; i < nodes[first]!.end; i = nodes[i]!.end) {
    if (nodes[i]!.kind === "button") nodes[i]!.kind = "segmented_control";
  }
}

function nscvTreeLevel(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0 || value > 65535) throw new Error("tree-level requires an integer from 0 to 65535");
  return value;
}

/** A split's two panes are counted after structural expansion. The native
 * consumer synthesizes the divider without changing authored pane keys.
 */
function nscvSplit(nodes: NscViewNode[], first: number): void {
  const root = nodes[first]!;
  if ((root.resizeEasing !== undefined || root.resizeOrigin !== undefined) && (root.resizeDuration ?? 0) === 0) throw new Error("split resize options require nonzero resize-duration");
  let count = 0;
  for (let i = first + 1; i < nodes[first]!.end; i = nodes[i]!.end) count++;
  if (count !== 2) throw new Error("split requires exactly two panes");
}

function nscvResizeDuration(value: number): number {
  if (!Number.isInteger(value) || value < 0 || value > 4294967295) throw new Error("resize-duration requires a nonnegative u32 integer");
  return value;
}

/** Retained list wire: operation u8, subject/count u16LE, then parent
 * u16LE, kind (0 other/1 list item/2 list), flags (1 logical focus,
 * 2 visible focus/4 selected). Arrows (4 previous/5 next) traverse direct
 * list children logically, allowing native scroll reveal. Home/End (6/7)
 * retain visible same-parent targets; 8 clears selected same-parent items,
 * including bare items. Arrows do not wrap or activate the landed row.
 */
export function native_list_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid list policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 ||
      ![4, 5, 6, 7, 8].includes(operation)) throw new Error("invalid list policy request");
  const parent = (i: number): number => read(5 + i * 4);
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const group = parent(subject);
  if (operation === 8) {
    const result = new Uint8Array(count);
    for (let i = 0; i < count; i++) if (i !== subject && kind(i) === 1 &&
      parent(i) === group && (flags(i) & 4) !== 0) result[i] = 1;
    return result;
  }
  let target = 65535;
  if (operation === 6 || operation === 7) {
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      target = i;
      if (operation === 6) break;
    }
  } else if (group < count && kind(group) === 2) {
    target = subject;
    let previous = 65535, sawSubject = false;
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 1) === 0) continue;
      if (sawSubject) { target = i; break; }
      if (i === subject) {
        if (operation === 4) { if (previous !== 65535) target = previous; break; }
        sawSubject = true;
      } else previous = i;
    }
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Retained menu wire: operation u8, subject/count u16LE, then parent
 * u16LE, kind (0 other/1 menu item/2 menu surface/3 list item), flags
 * (2 visible focus/4 selected state or value/8 selected state).
 * Entry (2 first/3 last)
 * prefers a selected visible descendant, including list items. Arrows
 * (4 previous/5 next) traverse visible direct menu children without wrapping;
 * 6/7 preserve visible same-parent Home/End. Selection (8) returns a
 * committed-choice byte followed by a sibling clear mask: action menus
 * without a selected row never acquire a checkmark on activation.
 */
export function native_menu_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid menu policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 ||
      ![2, 3, 4, 5, 6, 7, 8].includes(operation)) throw new Error("invalid menu policy request");
  const parent = (i: number): number => read(5 + i * 4);
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const group = parent(subject);
  if (operation === 8) {
    const result = new Uint8Array(count + 1);
    for (let i = 0; i < count; i++) if (kind(i) === 1 && parent(i) === group && (flags(i) & 4) !== 0) {
      result[0] = 1;
      if (i !== subject) result[i + 1] = 1;
    }
    return result;
  }
  let target = 65535;
  if (operation === 2 || operation === 3) {
    for (let i = 0; i < count; i++) {
      if ((kind(i) !== 1 && kind(i) !== 3) || (flags(i) & 2) === 0) continue;
      let ancestor = parent(i), inside = false;
      for (let steps = 0; steps < count && ancestor < count; steps++) {
        if (ancestor === subject) { inside = true; break; }
        ancestor = parent(ancestor);
      }
      if (!inside) continue;
      if ((flags(i) & 8) !== 0) { target = i; break; }
      if (operation === 3 || target === 65535) target = i;
    }
  } else if (operation === 6 || operation === 7) {
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      target = i;
      if (operation === 6) break;
    }
  } else if (group < count && kind(group) === 2) {
    target = subject;
    let previous = 65535, sawSubject = false;
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      if (sawSubject) { target = i; break; }
      if (i === subject) {
        if (operation === 4) { if (previous !== 65535) target = previous; break; }
        sawSubject = true;
      } else previous = i;
    }
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Toggle state requests: operation 8 (activate), 9 (chip reconcile), or
 * 10 (checkbox/switch/toggle reconcile), then
 * flags (1 current/source selected, 2 previous source selected, 4 retained
 * selected). A source asserted now or previously wins; otherwise retain
 * the uncontrolled chip state. Checkboxes, switches, and plain toggles
 * always preserve retained state on rebuild. Results are one selected byte.
 * Focus requests: operation 4/5 (Left/Right), 6/7 (Home/End), subject/count
 * u16LE, then parent u16LE, kind (0 other/1 toggle/2 toggle group/3 button
 * group), flags (2 visible focus). Arrows stay on visible direct children
 * without wrapping; Home/End preserve native same-parent edges.
 */
export function native_toggle_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  if (request.length === 0) throw new Error("invalid toggle policy request");
  const operation = request[0]!;
  if (operation === 8 || operation === 9 || operation === 10) {
    if (request.length !== 2 || request[1]! > 7) throw new Error("invalid toggle state request");
    const flags = request[1]!, source = (flags & 1) !== 0;
    let selected = !source;
    if (operation === 9) selected = (source || (flags & 2) !== 0) ? source : (flags & 4) !== 0;
    if (operation === 10) selected = (flags & 4) !== 0;
    const result = new Uint8Array(1);
    result[0] = selected ? 1 : 0;
    return result;
  }
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid toggle focus request");
  const subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 ||
      ![4, 5, 6, 7].includes(operation)) throw new Error("invalid toggle focus request");
  const parent = (i: number): number => read(5 + i * 4);
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const group = parent(subject);
  let target = 65535;
  if (group < count && (kind(group) === 2 || kind(group) === 3)) {
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      if (operation === 6) { target = i; break; }
      if (operation === 7 || operation === 4 && i < subject) target = i;
      if (operation === 5 && i > subject) { target = i; break; }
    }
    if (target === 65535 && (operation === 4 || operation === 5)) target = subject;
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Accordion state requests: operation 8 (activate) or 9 (reconcile),
 * then flags (1 current/source open, 2 previous source open, 4 retained
 * open, 8 previous source present). A source flip wins; an unchanged or
 * absent previous source preserves retained expansion. Native owns the
 * disclosure animation, geometry, and concealed-content eligibility.
 */
export function native_accordion_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  if (request.length !== 2 || (request[0] !== 8 && request[0] !== 9) || request[1]! > 15) {
    throw new Error("invalid accordion state request");
  }
  const flags = request[1]!, source = (flags & 1) !== 0;
  const moved = (flags & 8) !== 0 && source !== ((flags & 2) !== 0);
  const selected = request[0] === 8 ? !source : moved ? source : (flags & 4) !== 0;
  const result = new Uint8Array(1);
  result[0] = selected ? 1 : 0;
  return result;
}

/** Slider wire: operation u8, flags (1 previous source present, 2 pressed),
 * then current/source, previous source, and retained value as f32LE.
 * Operations: 0 clamp an applied value, 1 reconcile, 2/3 small decrement/
 * increment, 4/5 coarse decrement/increment, 6 Home, 7 End. Keyboard step
 * results are unclamped so native action flags retain their edge behavior.
 * Source changes win unless a drag is pressed; unchanged or absent history
 * preserves retained state. Native owns geometry and input eligibility.
 */
export function native_slider_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  return nscvSliderPolicy(request);
}

function nscvSliderPolicy(request: Uint8Array): Uint8Array {
  if (request.length !== 14 || request[0]! > 7 || request[1]! > 3) {
    throw new Error("invalid slider policy request");
  }
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const operation = request[0]!, flags = request[1]!;
  const current = wire.getFloat32(2, true), previous = wire.getFloat32(6, true), retained = wire.getFloat32(10, true);
  if (!Number.isFinite(current) || !Number.isFinite(previous) || !Number.isFinite(retained)) {
    throw new Error("non-finite slider policy value");
  }
  let value = current;
  if (operation === 1 && ((flags & 1) === 0 || current === previous || (flags & 2) !== 0)) value = retained;
  if (operation === 2 || operation === 3 || operation === 4 || operation === 5) {
    const step = Math.fround(operation < 4 ? 0.05 : 0.1);
    value = Math.fround(current + (operation === 2 || operation === 4 ? -step : step));
  }
  if (operation === 6) value = 0;
  if (operation === 7) value = 1;
  if (operation < 2) value = Math.max(0, Math.min(1, value));
  const result = new Uint8Array(4);
  new DataView(result.buffer).setFloat32(0, value, true);
  return result;
}

/** Split wire: operation u8, flags (1 previous source present, 2 declared
 * tween, 4 armed tween), then value, available width, first/second minimum,
 * previous source, and retained fraction as f32LE. Operations: 0 layout,
 * 1 applied clamp, 2 reconcile, 3/4 small decrement/increment, 5/6 coarse
 * decrement/increment, 7 Home, 8 End. Native owns geometry, capture, timing,
 * eligibility and mutation. Each arithmetic stage preserves native f32.
 */
export function native_split_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  return nscvSplitPolicy(request);
}

function nscvSplitPolicy(request: Uint8Array): Uint8Array {
  if (request.length !== 26 || request[0]! > 8 || request[1]! > 7) throw new Error("invalid split policy request");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const operation = request[0]!, flags = request[1]!;
  const current = wire.getFloat32(2, true), available = wire.getFloat32(6, true);
  const first = wire.getFloat32(10, true), second = wire.getFloat32(14, true);
  const previous = wire.getFloat32(18, true), retained = wire.getFloat32(22, true);
  if (![available, first, second, previous, retained].every(value => Number.isFinite(value)) || operation !== 0 && !Number.isFinite(current)) {
    throw new Error("non-finite split policy value");
  }
  let value = current;
  if (operation === 2 && (flags & 1) !== 0 && (current === previous || (flags & 6) !== 0)) value = retained;
  if (operation === 3 || operation === 4 || operation === 5 || operation === 6) {
    const step = Math.fround(operation < 5 ? 0.05 : 0.1);
    value = Math.fround(current + (operation === 3 || operation === 5 ? -step : step));
  }
  if (operation === 7) value = 0;
  if (operation === 8) value = 1;
  if (operation === 0 || operation === 1) {
    if (operation === 1) value = Math.max(value, Math.fround(0.0001));
    value = !Number.isFinite(value) || value <= 0 ? 0.5 : Math.min(value, 1);
    let low = 0, high = 1;
    if (available > 0) {
      low = Math.max(0, Math.min(1, Math.fround(Math.max(0, first) / available)));
      high = Math.max(0, Math.min(1, Math.fround(1 - Math.fround(Math.max(0, second) / available))));
      if (low > high) {
        const mid = Math.fround(low / Math.max(Math.fround(low + Math.fround(1 - high)), Math.fround(0.0001)));
        low = mid; high = mid;
      }
    }
    value = Math.max(low, Math.min(high, value));
  }
  const result = new Uint8Array(4);
  new DataView(result.buffer).setFloat32(0, value, true);
  return result;
}

/** Resizable wire: operation u8 (0 drag, 1 retained reconcile), then
 * panel height, current/retained width, and drag delta as f32LE. The
 * minimum is max(48, height); authored width seeds fresh panels and
 * retained width wins every enabled rebuild. Native owns capture,
 * eligibility and mutation; neighboring and descendant frames stay put.
 */
export function native_resizable_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  if (request.length !== 13 || request[0]! > 1) throw new Error("invalid resizable policy request");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const height = wire.getFloat32(1, true), current = wire.getFloat32(5, true), delta = wire.getFloat32(9, true);
  // Zig @max chooses the other operand for NaN, including retained data.
  const minimum = Number.isNaN(height) ? 48 : Math.max(48, height);
  const candidate = request[0] === 0 ? Math.fround(current + delta) : current;
  const value = Number.isNaN(candidate) ? minimum : Math.max(minimum, candidate);
  const result = new Uint8Array(4);
  new DataView(result.buffer).setFloat32(0, value, true);
  return result;
}

/** Scroll wire: tagged operation u8 (128 + operation), flags (1 granted axis, 2 previous source,
 * 4 retained offset, 8 horizontal keymap, 16 dual keymap), then six f32LE:
 * current/source, viewport, content, delta/authored source, previous source,
 * retained offset. Results are two f32LE (scalar in X, keyboard delta X/Y).
 * Operations: 0 layout clamp, 1 discrete move, 2 reconcile, 3 programmatic
 * clamp, 4..9 Left/Right/Up/Down/PageUp/PageDown, 10/11 assistive decrement/
 * increment, 12/13 Home/End, 14 can consume. Keyboard uses viewport/content
 * slots for width/height. OS offsets and wheel/kinetic physics remain native.
 */
export function native_scroll_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  return nscvScrollPolicy(request);
}

function nscvScrollPolicy(request: Uint8Array): Uint8Array {
  if (request.length !== 26 || request[0]! < 128 || request[0]! > 142 || request[1]! > 31) {
    throw new Error("invalid scroll policy request");
  }
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const operation = request[0]! - 128, flags = request[1]!;
  const current = wire.getFloat32(2, true), viewport = wire.getFloat32(6, true);
  const content = wire.getFloat32(10, true), delta = wire.getFloat32(14, true);
  const previous = wire.getFloat32(18, true), retained = wire.getFloat32(22, true);
  const nonnegative = (value: number): number => Number.isNaN(value) ? 0 : Math.max(0, value);
  const maximum = Math.max(0, Math.fround(nonnegative(content) - nonnegative(viewport)));
  let x = current, y = 0;
  if (operation === 0 || operation === 3) {
    const moved = (flags & 2) === 0 || delta !== previous;
    const echo = (flags & 4) !== 0 && delta === retained;
    if (operation === 0 || moved && !echo) {
      x = (flags & 1) !== 0 ? Math.min(maximum, nonnegative(current)) : 0;
    }
  } else if (operation === 1) {
    x = (flags & 1) !== 0 ? Math.min(maximum, nonnegative(Math.fround(current + delta))) : 0;
  } else if (operation === 2) {
    if ((flags & 7) === 7 && current === previous) x = retained;
  } else if (operation >= 4 && operation <= 11) {
    const horizontal = (flags & 8) !== 0 || (flags & 16) !== 0 && (operation === 4 || operation === 5);
    const extent = horizontal ? viewport : content;
    const line = Math.max(24, Math.fround(extent * Math.fround(0.35)));
    const page = Math.max(line, Math.fround(extent * Math.fround(0.85)));
    const step = operation >= 8 ? page : line;
    const signed = operation === 4 || operation === 6 || operation === 8 || operation === 10 ? -step : step;
    x = horizontal ? signed : 0; y = horizontal ? 0 : signed;
  } else if (operation === 12 || operation === 13) {
    x = (flags & 1) !== 0 && operation === 13 ? maximum : 0;
  } else if (operation === 14) {
    x = delta === 0 ? 0 : current < 0 ? (delta > 0 ? 1 : 0) : current > maximum ? (delta < 0 ? 1 : 0) :
      delta > 0 ? (current < maximum ? 1 : 0) : (current > 0 ? 1 : 0);
  }
  const result = new Uint8Array(8), out = new DataView(result.buffer);
  out.setFloat32(0, x, true); out.setFloat32(4, y, true);
  return result;
}

/** Retained tree wire: operation u8, subject/count u16LE, then parent
 * u16LE, kind bits (1 treeitem/2 tree scope), flags (1 logical focus,
 * 4 selected/8 expanded), and tree-level u16LE per node. Operations:
 * 0 nearest scope, 4 previous, 5 next, 6 first, 7 last, 8 selection clear
 * mask, 9 Left, 10 Right. Index 65535 means no target/disclosure intent.
 * Traversal preserves native preorder and flat-level/nested hierarchy;
 * geometry eligibility and applied state remain native. Expansion and
 * the presence of child rows remain model-owned.
 */
export function native_tree_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 15) return nscvKeyboardControl(request);
  if (request[0] === 16) return nscvSemanticControl(request);
  if (request[0] === 17) return nscvSemanticActions(request);
  if (request[0] === 18) return nscvStepControl(request);
  if (request[0] === 19) return nscvPressHold(request);
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid tree policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 6 ||
      ![0, 4, 5, 6, 7, 8, 9, 10].includes(operation)) throw new Error("invalid tree policy request");
  const parent = (i: number): number => read(5 + i * 6);
  const kind = (i: number): number => request[7 + i * 6]!;
  const flags = (i: number): number => request[8 + i * 6]!;
  const level = (i: number): number => read(9 + i * 6);
  for (let i = 0; i < count; i++) if (parent(i) !== 65535 && parent(i) >= i) throw new Error("invalid tree policy parent");
  const scope = (i: number): number => {
    for (let p = parent(i); p !== 65535; p = parent(p)) if ((kind(p) & 2) !== 0) return p;
    return 65535;
  };
  const descendant = (i: number, ancestor: number): boolean => {
    for (let p = parent(i); p !== 65535; p = parent(p)) if (p === ancestor) return true;
    return false;
  };
  const row = (i: number): boolean => (kind(i) & 1) !== 0;
  const focus = (i: number): boolean => row(i) && (flags(i) & 1) !== 0;
  const group = scope(subject);
  if (operation === 8) {
    const result = new Uint8Array(count);
    for (let i = 0; i < count; i++) if (i !== subject && row(i) && (flags(i) & 4) !== 0 && scope(i) === group) result[i] = 1;
    return result;
  }
  let target = 65535;
  if (operation === 0) target = group;
  else if (group !== 65535 && row(subject)) {
    if (operation >= 4 && operation <= 7) {
      for (let i = group + 1; i < count && descendant(i, group); i++) {
        if (!focus(i)) continue;
        if (operation === 6) { target = i; break; }
        if (operation === 7 || operation === 4 && i < subject) target = i;
        if (operation === 5 && i > subject) { target = i; break; }
      }
      if (target === 65535 && (operation === 4 || operation === 5)) target = subject;
    } else if (operation === 9 && (flags(subject) & 8) === 0) {
      target = subject;
      if (level(subject) > 1) {
        for (let i = subject - 1; i > group; i--) {
          if (!row(i)) continue;
          if (level(i) === level(subject) - 1) { if (focus(i)) target = i; break; }
          if (level(i) !== 0 && level(i) < level(subject) - 1) break;
        }
      } else {
        for (let p = parent(subject); p !== 65535 && p !== group; p = parent(p)) {
          if (focus(p)) { target = p; break; }
        }
      }
    } else if (operation === 10 && (flags(subject) & 8) !== 0) {
      target = subject;
      if (level(subject) > 0) {
        for (let i = subject + 1; i < count && descendant(i, group); i++) {
          if (!row(i)) continue;
          if (level(i) === level(subject) + 1 && focus(i)) target = i;
          break;
        }
      } else {
        for (let i = subject + 1; i < count && descendant(i, subject); i++) {
          if (focus(i)) { target = i; break; }
        }
      }
    }
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}
