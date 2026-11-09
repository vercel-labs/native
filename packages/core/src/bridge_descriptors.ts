/** Portable bridge descriptors over decoded facts and borrowed byte extents. */
function nscvBridgeDescriptors(request: Uint8Array): Uint8Array {
  if (request.length < 96 || request[0] !== 87 || request[1] !== 1 || request[2]! > 5)
    throw new Error("invalid bridge descriptor header");
  const mode = request[2]!, w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const word = (at: number): number => w.getUint32(at, true);
  const result = new Uint8Array(64), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, mode, true);
  let status = 0;
  if (mode === 0) {
    const family = request[3]!;
    if (family > 7 || request.length !== 96 + (word(12) !== 0 ? 64 : Math.min(word(8), 64))) throw new Error("invalid bridge enum extent");
    const names = family === 0 ? ["webview", "toolbar", "titlebar_accessory", "sidebar", "statusbar", "split", "stack", "button", "icon_button", "list_item", "checkbox", "toggle", "segmented_control", "text_field", "search_field", "label", "spacer", "gpu_surface", "progress_indicator"]
      : family === 1 ? ["standard", "hidden_inset", "hidden_inset_tall", "chromeless"]
      : family === 2 ? ["none", "metal", "direct2d", "software"]
      : family === 3 ? ["none", "bgra8_unorm"]
      : family === 4 ? ["none", "timer"]
      : family === 5 ? ["none", "opaque", "premultiplied"]
      : family === 6 ? ["none", "srgb", "display_p3"]
      : ["main_webview", "child_webviews", "native_views", "native_control_commands", "menus", "tray", "shortcuts", "dialogs", "clipboard_text", "clipboard_rich_data", "open_url", "reveal_path", "notifications", "recent_documents", "credentials", "file_drops", "app_activation_events", "gpu_surfaces", "gpu_surface_scroll_drivers", "context_menus", "view_surface_adoption", "audio_playback", "audio_streaming", "audio_spectrum", "microphone_capture", "system_audio_capture", "window_hide_on_close", "video_playback", "global_shortcuts", "keyboard_input"];
    const aliases = family === 0 ? ["titlebarAccessory", "iconButton", "listItem", "segmentedControl", "textField", "searchField", "gpuSurface", "progressIndicator"]
      : family === 1 ? ["hiddenInset", "hiddenInsetTall"]
      : family === 7 ? ["mainWebView", "childWebViews", "nativeViews", "nativeControlCommands", "clipboardText", "clipboardRichData", "openUrl", "revealPath", "recentDocuments", "fileDrops", "appActivationEvents", "gpuSurfaces", "gpuSurfaceScrollDrivers", "contextMenus", "viewSurfaceAdoption", "audioPlayback", "audioStreaming", "audioSpectrum", "microphoneCapture", "systemAudioCapture", "windowHideOnClose", "videoPlayback", "globalShortcuts", "keyboardInput"] : [];
    const ordinals = family === 0 ? [2, 8, 9, 12, 13, 14, 17, 18] : family === 1 ? [1, 2] : family === 7 ? [0, 1, 2, 3, 8, 9, 10, 11, 13, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29] : [];
    let selected = 0;
    if (word(12) === 0) for (let group = 0; group < 2; group++) {
      const values = group === 0 ? names : aliases;
      for (let index = 0; index < values.length; index++) {
        const name = values[index]!;
        let equal = name.length === word(8);
        if (equal) for (let i = 0; i < name.length; i++) if (request[96 + i] !== name.charCodeAt(i)) equal = false;
        if (equal) selected = 1 + (group === 0 ? index : ordinals[index]!);
      }
    }
    out.setUint32(16, selected, true);
  } else if (mode === 1) {
    if (request.length !== 96 || request[4]! > 2) throw new Error("invalid GPU descriptor extent");
    const defaults = [1, 1, 1, 1, 1], counts = [4, 2, 2, 3, 3];
    for (let i = 0; i < 5; i++) {
      const value = word(16 + i * 4);
      if (value !== 4294967295 && value > counts[i]!) throw new Error("invalid GPU enum verdict");
      if (value === 0 && status === 0) status = 8;
      out.setUint32(16 + i * 4, value === 4294967295 ? defaults[i]! : value === 0 ? 0 : value - 1, true);
    }
    out.setUint32(36, request[4] === 1 ? 0 : 1, true);
  } else if (mode === 2) {
    if (request.length !== 96 || request[3]! > 1 || request[4]! > 1 || request[5]! > 1) throw new Error("invalid bridge window facts");
    const web = request[3] === 1;
    if (request[4] === 1 && request[5] === 0) status = web ? 1 : 3;
    else if (request[4] === 1 && (word(16) !== word(24) || word(20) !== word(28))) status = web ? 2 : 4;
    result.set(request.subarray(16, 24), 16);
  } else if (mode === 3) {
    if (request.length !== 96) throw new Error("invalid bridge frame extent");
    for (let i = 3; i < 10; i++) if (request[i]! > 1) throw new Error("invalid bridge frame flags");
    const web = request[3] === 1, present = request[5] === 1;
    if (!present && !web) { if (request[4] === 1) status = 5; }
    else if (request[6] === 0 || request[7] === 0) status = web ? 6 : 5;
    else {
      result.set(request.subarray(16, 48), 16);
      if (request[8] === 0) out.setFloat64(16, 0, true);
      if (request[9] === 0) out.setFloat64(24, 0, true);
      const x = out.getFloat64(16, true), y = out.getFloat64(24, true), width = out.getFloat64(32, true), height = out.getFloat64(40, true);
      if (x < 0 || y < 0 || (web ? width <= 0 || height <= 0 : width < 0 || height < 0)) status = web ? 6 : 5;
      out.setUint32(12, 1, true);
    }
  } else if (mode === 4) {
    if (request.length !== 96 || request[3]! > 1 || request[4]! > 1 || request[5]! > 1) throw new Error("invalid bridge layer facts");
    const web = request[3] === 1;
    out.setUint32(12, web || request[4] === 1 ? 1 : 0, true);
    if (request[4] === 1) {
      const layer = w.getFloat64(16, true);
      if (request[5] === 0 || !Number.isFinite(layer) || Math.trunc(layer) !== layer || layer < -2147483648 || layer > 2147483647) status = web ? 6 : 5;
      else result.set(request.subarray(16, 24), 16);
    }
  } else {
    const count = word(8), final = request[3]!, prior = word(40);
    if (final > 1 || count > 256 || request.length !== 96 + count || prior > 4) throw new Error("invalid bridge origin chunk");
    const endLow = word(24) + count, carry = endLow > 4294967295 ? 1 : 0, endHigh = word(28) + carry, low = endLow - carry * 4294967296;
    if (endHigh > word(20) || endHigh === word(20) && low > word(16) || final === 1 && (endHigh !== word(20) || low !== word(16))) throw new Error("invalid bridge origin extent");
    if (word(24) === 0 && word(28) === 0 && request[48] === 97 && request[49] === 98 && request[50] === 111 && request[51] === 117 && request[52] === 116 && request[53] === 58) out.setUint32(12, 1, true);
    else {
      let state = prior, found = false, invalid = false, positionLow = low, positionHigh = endHigh;
      for (let i = 0; i < count; i++) {
        const ch = request[96 + i]!;
        if (state === 3 || state === 4) {
          if (ch === 47 || ch === 63 || ch === 35) {
            invalid = state === 3; found = true;
            const position = word(24) + i, positionCarry = position > 4294967295 ? 1 : 0;
            positionLow = position - positionCarry * 4294967296; positionHigh = word(28) + positionCarry;
            break;
          }
          state = 4;
        } else if (state === 2 && ch === 47) state = 3;
        else if (state === 1 && ch === 47) state = 2;
        else state = ch === 58 ? 1 : 0;
      }
      if (!found && final === 0) status = 2;
      else if (invalid || !found && state !== 4 || positionHigh > word(36) || positionHigh === word(36) && positionLow > word(32)) status = 6;
      out.setUint32(16, positionLow, true); out.setUint32(20, positionHigh, true); out.setUint32(24, state, true);
    }
  }
  out.setUint32(8, status, true);
  return result;
}
