/** Control paint programs over copied observations. Native executes explicit
 * drawing/font/icon capabilities and owns the resulting text and path storage. */
function nscvControlCommands(request: Uint8Array): Uint8Array {
  if (request.length !== 32 || request[0] !== 45 || request[1] !== 1 || request[2]! > 16 || request[3] !== 0)
    throw new Error("invalid control command header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const flags = w.getUint32(4, true), family = request[2]!;
  if (flags > 1048575) throw new Error("invalid control command facts");
  const focused = (flags & 1) !== 0, text = (flags & 2) !== 0, placeholder = (flags & 4) !== 0;
  const icon = (flags & 8) !== 0, committed = (flags & 16) !== 0;
  const selected = committed || w.getFloat32(8, true) >= 0.5;
  const background = (flags & 32) !== 0, border = (flags & 64) !== 0;
  const clip = (flags & 128) !== 0, selection = (flags & 256) !== 0;
  const selectionRange = (flags & 512) !== 0, composition = (flags & 1024) !== 0;
  const compositionRange = (flags & 2048) !== 0, underline = (flags & 4096) !== 0;
  const bar = (flags & 8192) !== 0, clear = (flags & 16384) !== 0;
  const chevron = (flags & 32768) !== 0, check = (flags & 65536) !== 0;
  const seam = (flags & 131072) !== 0, combobox = (flags & 262144) !== 0;
  if (selectionRange && !selection || compositionRange && !composition)
    throw new Error("invalid control editing observations");
  const result = new Uint8Array(200), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  let count = 0;
  // fill, stroke, focus, icon, text, selection, selected glyphs, composition,
  // caret, clip, unclip, mark, seam clip, seam unclip, shadow.
  const emit = (op: number, slot: number, variant: number = 0): void => {
    if (count >= 16) throw new Error("control command capacity exceeded");
    const at = 8 + count * 12;
    out.setUint32(at, op, true); out.setUint32(at + 4, slot, true); out.setUint32(at + 8, variant, true); count++;
  };
  switch (family) {
    case 0: case 1: // command buttons, including flush seam clips
      emit(0, 1);
      if (w.getFloat32(12, true) > 0) {
        if (seam) emit(12, 0);
        emit(1, 2);
        if (seam) emit(13, 0);
      }
      if (focused) emit(2, family === 0 ? 3 : 15);
      if (icon) emit(3, family === 0 ? 5 : 3, family === 0 ? 0 : 1);
      if (family === 0 ? !icon || text : !icon && text) emit(4, family === 0 ? 4 : 3, icon ? 1 : 0);
      break;
    case 2: // selects reserve the chevron before resolving placeholder ink
      emit(0, 1); emit(1, 2); if (focused) emit(2, 6);
      if (text || placeholder) emit(4, 3, text ? 0 : 2);
      if (chevron) emit(3, 4, 3);
      break;
    case 3: case 5: { // editing fields and search/combobox chrome
      const search = family === 5, limit = search ? 1 : 4;
      emit(0, 1); emit(1, 2); if (focused) emit(2, search ? 14 : 7);
      if (search && (flags & 524288) !== 0) emit(3, 3, 2);
      if (clip) emit(9, search ? 7 : 16);
      if (selectionRange) emit(5, search ? 8 : 3, (search ? 0 : 13) | (limit << 8));
      if (text || placeholder) emit(4, search ? 9 : selection || composition ? 4 : 3, text ? 0 : 2);
      if (selectionRange) emit(6, 0, limit);
      if (compositionRange) emit(7, search ? 10 : 5, (search ? 0 : 10) | (limit << 8));
      if (focused && selection && !selectionRange) emit(8, search ? 11 : 6);
      if (clip) emit(10, 0);
      if (search && combobox && chevron) emit(3, 12, 4);
      if (search && clear) emit(3, 15, 6);
      break;
    }
    case 4: // input group focus means focus within
      emit(0, 1); emit(1, 2); if (focused) emit(2, 3);
      break;
    case 6:
      if (w.getFloat32(20, true) !== 0 || w.getFloat32(24, true) !== 0 || w.getFloat32(28, true) !== 0) emit(14, 1);
      emit(0, 2); if (text) emit(4, 3);
      break;
    case 7: case 8: // menu attention and commitment remain independent
      if (w.getFloat32(16, true) > 0) emit(0, 1);
      if (family === 8 && focused) emit(2, 2);
      if (icon) emit(3, 4);
      emit(4, 3, icon ? 1 : 0);
      if (family === 7 && committed && check) emit(3, 12, 5);
      break;
    case 9: case 10: // cell chrome is shared with span-carrying cells
      if (w.getFloat32(16, true) > 0) emit(0, 1);
      if (border) emit(1, 2);
      if (focused) emit(2, 3);
      if (family === 10 && text) emit(4, 4);
      break;
    case 11:
      if (!underline && selected) { emit(0, 1, 1); emit(1, 2); }
      else if (background) emit(0, 1);
      if (underline && selected && bar) emit(0, 2, 3);
      if (focused) emit(2, 4);
      if (underline && icon) emit(3, 5);
      if (!(underline && icon) || text) emit(4, 3, underline && icon ? 1 : 0);
      break;
    case 12: case 13:
      emit(0, 1, family === 12 && selected ? 1 : 0);
      emit(1, 2, family === 12 && selected ? 1 : 0);
      if (focused) emit(2, 3);
      if (selected) emit(11, 4, family === 12 ? 0 : 1);
      if (text) emit(4, family === 12 ? 6 : 5);
      break;
    case 14:
      emit(0, 1, selected ? 1 : 0);
      if (w.getFloat32(12, true) > 0) emit(1, 2);
      emit(0, 3, selected ? 5 : 4);
      if (focused) emit(2, 4);
      if (text) emit(4, 5);
      break;
    case 15:
      emit(0, 1);
      if (bar) emit(0, 2, 3);
      emit(0, 3, 4); emit(1, 4, 1); if (focused) emit(2, 5, 2);
      break;
    case 16:
      if (background) emit(0, 1);
      if (bar) emit(0, 2, 3);
      break;
  }
  out.setUint32(4, count, true); return result;
}
