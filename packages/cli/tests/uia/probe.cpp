// A UI Automation client for tests/uia-patterns.ts: it reaches a running app's window by process
// id through IUIAutomation, the way a screen reader or agent-desktop does, and reads or acts on one
// element, found by its AutomationId, or by its name when the reference starts with "name:".
//
//   probe <pid> tree                     every element: control type, name, id, value, patterns
//   probe <pid> invoke|toggle|expand|collapse|select|scroll|focus <id>
//   probe <pid> setvalue <id> <text>     ValuePattern.SetValue
//   probe <pid> setrange <id> <number>   RangeValuePattern.SetValue
//   probe <pid> get <id> <what>          one property: name, value, toggle, expanded, selected,
//                                        range, heading, landmark, ariarole, ariaproperties,
//                                        description, localized, text, selection, readonly, offscreen
//   probe <pid> focused                  the focused element's AutomationId
//   probe <pid> frompoint <id>           the AutomationId of the element at the centre of <id>
//   probe <pid> document                 the window's first child: its control type and name
//
// Output is one line; a missing element prints NOTFOUND and exits 4.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <uiautomation.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>

static IUIAutomation *g_uia = NULL;

static void print_bstr(BSTR s) {
  if (!s) return;
  int n = WideCharToMultiByte(CP_UTF8, 0, s, (int)SysStringLen(s), NULL, 0, NULL, NULL);
  char *out = (char *)malloc((size_t)n + 1);
  if (!out) return;
  WideCharToMultiByte(CP_UTF8, 0, s, (int)SysStringLen(s), out, n, NULL, NULL);
  out[n] = 0;
  fputs(out, stdout);
  free(out);
}

static wchar_t *wide(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  wchar_t *out = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)(n > 0 ? n : 1));
  MultiByteToWideChar(CP_UTF8, 0, s, -1, out, n);
  return out;
}

/** The app's top-level window, by process id, waiting for it to appear. */
static IUIAutomationElement *window_of(int pid) {
  IUIAutomationElement *root = NULL;
  g_uia->GetRootElement(&root);
  VARIANT v;
  v.vt = VT_I4;
  v.lVal = pid;
  IUIAutomationCondition *cond = NULL;
  g_uia->CreatePropertyCondition(UIA_ProcessIdPropertyId, v, &cond);
  IUIAutomationElement *found = NULL;
  for (int i = 0; i < 100 && !found; i++) {
    root->FindFirst(TreeScope_Children, cond, &found);
    if (!found) Sleep(100);
  }
  cond->Release();
  root->Release();
  return found;
}

static IUIAutomationElement *by_name(IUIAutomationElement *window, const char *name) {
  VARIANT v;
  v.vt = VT_BSTR;
  wchar_t *w = wide(name);
  v.bstrVal = SysAllocString(w);
  free(w);
  IUIAutomationCondition *cond = NULL;
  g_uia->CreatePropertyCondition(UIA_NamePropertyId, v, &cond);
  IUIAutomationElement *found = NULL;
  window->FindFirst(TreeScope_Descendants, cond, &found);
  cond->Release();
  VariantClear(&v);
  return found;
}

static IUIAutomationElement *by_id(IUIAutomationElement *window, const char *id) {
  VARIANT v;
  v.vt = VT_BSTR;
  wchar_t *w = wide(id);
  v.bstrVal = SysAllocString(w);
  free(w);
  IUIAutomationCondition *cond = NULL;
  g_uia->CreatePropertyCondition(UIA_AutomationIdPropertyId, v, &cond);
  IUIAutomationElement *found = NULL;
  window->FindFirst(TreeScope_Descendants, cond, &found);
  cond->Release();
  VariantClear(&v);
  return found;
}

/** An element by its AutomationId, or by its name when the reference starts with "name:". */
static IUIAutomationElement *element_of(IUIAutomationElement *window, const char *ref) {
  if (strncmp(ref, "name:", 5) == 0) return by_name(window, ref + 5);
  return by_id(window, ref);
}

static void print_prop(IUIAutomationElement *e, PROPERTYID id) {
  VARIANT v;
  VariantInit(&v);
  if (FAILED(e->GetCurrentPropertyValue(id, &v))) return;
  if (v.vt == VT_BSTR) print_bstr(v.bstrVal);
  else if (v.vt == VT_I4) printf("%ld", (long)v.lVal);
  else if (v.vt == VT_BOOL) printf("%s", v.boolVal ? "true" : "false");
  else if (v.vt == VT_R8) printf("%g", v.dblVal);
  VariantClear(&v);
}

static const struct { PATTERNID id; const char *name; } PATTERNS[] = {
  {UIA_InvokePatternId, "Invoke"}, {UIA_TogglePatternId, "Toggle"}, {UIA_ValuePatternId, "Value"},
  {UIA_RangeValuePatternId, "RangeValue"}, {UIA_ExpandCollapsePatternId, "ExpandCollapse"},
  {UIA_SelectionItemPatternId, "SelectionItem"}, {UIA_ScrollItemPatternId, "ScrollItem"},
  {UIA_TextPatternId, "Text"},
};

static void dump(IUIAutomationTreeWalker *walker, IUIAutomationElement *e, int depth) {
  for (int i = 0; i < depth; i++) fputs("  ", stdout);
  CONTROLTYPEID type = 0;
  e->get_CurrentControlType(&type);
  BSTR name = NULL, id = NULL;
  e->get_CurrentName(&name);
  e->get_CurrentAutomationId(&id);
  printf("%d name=[", (int)type);
  print_bstr(name);
  printf("] id=[");
  print_bstr(id);
  printf("] aria=[");
  print_prop(e, UIA_AriaRolePropertyId);
  printf("]");
  SysFreeString(name);
  SysFreeString(id);
  IUIAutomationValuePattern *value = NULL;
  if (SUCCEEDED(e->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&value))) && value) {
    BSTR text = NULL;
    value->get_CurrentValue(&text);
    printf(" value=[");
    print_bstr(text);
    printf("]");
    SysFreeString(text);
    value->Release();
  }
  printf(" patterns=");
  int any = 0;
  for (size_t k = 0; k < sizeof PATTERNS / sizeof PATTERNS[0]; k++) {
    IUnknown *p = NULL;
    if (SUCCEEDED(e->GetCurrentPattern(PATTERNS[k].id, &p)) && p) {
      printf("%s%s", any ? "," : "", PATTERNS[k].name);
      any = 1;
      p->Release();
    }
  }
  printf("\n");
  IUIAutomationElement *child = NULL;
  walker->GetFirstChildElement(e, &child);
  while (child) {
    dump(walker, child, depth + 1);
    IUIAutomationElement *next = NULL;
    walker->GetNextSiblingElement(child, &next);
    child->Release();
    child = next;
  }
}

template <typename T>
static T *pattern(IUIAutomationElement *e, PATTERNID id) {
  T *p = NULL;
  if (FAILED(e->GetCurrentPatternAs(id, IID_PPV_ARGS(&p)))) return NULL;
  return p;
}

static int done(HRESULT hr) {
  printf(SUCCEEDED(hr) ? "DONE\n" : "FAILED 0x%08lx\n", (unsigned long)hr);
  return SUCCEEDED(hr) ? 0 : 1;
}

int main(int argc, char **argv) {
  if (argc < 3) return 2;
  CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (FAILED(CoCreateInstance(__uuidof(CUIAutomation), NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&g_uia)))) return 3;
  int pid = atoi(argv[1]);
  const char *cmd = argv[2];
  IUIAutomationElement *window = window_of(pid);
  if (!window) {
    printf("NOWINDOW\n");
    return 4;
  }
  if (strcmp(cmd, "tree") == 0) {
    IUIAutomationTreeWalker *walker = NULL;
    g_uia->get_RawViewWalker(&walker);
    dump(walker, window, 0);
    return 0;
  }
  if (strcmp(cmd, "document") == 0) {
    IUIAutomationTreeWalker *walker = NULL;
    g_uia->get_ControlViewWalker(&walker);
    IUIAutomationElement *child = NULL;
    walker->GetFirstChildElement(window, &child);
    // The window's own title bar and system buttons come first in some sessions: find the document.
    while (child) {
      CONTROLTYPEID type = 0;
      child->get_CurrentControlType(&type);
      if (type == UIA_DocumentControlTypeId) break;
      IUIAutomationElement *next = NULL;
      walker->GetNextSiblingElement(child, &next);
      child->Release();
      child = next;
    }
    if (!child) {
      printf("NODOCUMENT\n");
      return 4;
    }
    BSTR name = NULL;
    child->get_CurrentName(&name);
    printf("Document name=[");
    print_bstr(name);
    printf("]\n");
    return 0;
  }
  if (strcmp(cmd, "focused") == 0) {
    IUIAutomationElement *f = NULL;
    g_uia->GetFocusedElement(&f);
    if (f) {
      print_prop(f, UIA_AutomationIdPropertyId);
      printf(" ");
      print_prop(f, UIA_ControlTypePropertyId);
    }
    printf("\n");
    return 0;
  }
  if (argc < 4) return 2;
  IUIAutomationElement *e = element_of(window, argv[3]);
  if (!e) {
    printf("NOTFOUND\n");
    return 4;
  }
  if (strcmp(cmd, "invoke") == 0) {
    IUIAutomationInvokePattern *p = pattern<IUIAutomationInvokePattern>(e, UIA_InvokePatternId);
    return p ? done(p->Invoke()) : done(E_NOINTERFACE);
  }
  if (strcmp(cmd, "toggle") == 0) {
    IUIAutomationTogglePattern *p = pattern<IUIAutomationTogglePattern>(e, UIA_TogglePatternId);
    return p ? done(p->Toggle()) : done(E_NOINTERFACE);
  }
  if (strcmp(cmd, "expand") == 0 || strcmp(cmd, "collapse") == 0) {
    IUIAutomationExpandCollapsePattern *p = pattern<IUIAutomationExpandCollapsePattern>(e, UIA_ExpandCollapsePatternId);
    return p ? done(cmd[0] == 'e' ? p->Expand() : p->Collapse()) : done(E_NOINTERFACE);
  }
  if (strcmp(cmd, "select") == 0) {
    IUIAutomationSelectionItemPattern *p = pattern<IUIAutomationSelectionItemPattern>(e, UIA_SelectionItemPatternId);
    return p ? done(p->Select()) : done(E_NOINTERFACE);
  }
  if (strcmp(cmd, "scroll") == 0) {
    IUIAutomationScrollItemPattern *p = pattern<IUIAutomationScrollItemPattern>(e, UIA_ScrollItemPatternId);
    return p ? done(p->ScrollIntoView()) : done(E_NOINTERFACE);
  }
  if (strcmp(cmd, "focus") == 0) return done(e->SetFocus());
  if (strcmp(cmd, "setvalue") == 0 && argc >= 5) {
    IUIAutomationValuePattern *p = pattern<IUIAutomationValuePattern>(e, UIA_ValuePatternId);
    if (!p) return done(E_NOINTERFACE);
    wchar_t *w = wide(argv[4]);
    BSTR b = SysAllocString(w);
    free(w);
    return done(p->SetValue(b));
  }
  if (strcmp(cmd, "setrange") == 0 && argc >= 5) {
    IUIAutomationRangeValuePattern *p = pattern<IUIAutomationRangeValuePattern>(e, UIA_RangeValuePatternId);
    return p ? done(p->SetValue(atof(argv[4]))) : done(E_NOINTERFACE);
  }
  if (strcmp(cmd, "frompoint") == 0) {
    RECT r;
    e->get_CurrentBoundingRectangle(&r);
    POINT at = {(r.left + r.right) / 2, (r.top + r.bottom) / 2};
    IUIAutomationElement *hit = NULL;
    g_uia->ElementFromPoint(at, &hit);
    if (hit) print_prop(hit, UIA_AutomationIdPropertyId);
    printf("\n");
    return 0;
  }
  if (strcmp(cmd, "get") == 0 && argc >= 5) {
    const char *what = argv[4];
    if (strcmp(what, "name") == 0) print_prop(e, UIA_NamePropertyId);
    else if (strcmp(what, "id") == 0) print_prop(e, UIA_AutomationIdPropertyId);
    else if (strcmp(what, "type") == 0) print_prop(e, UIA_ControlTypePropertyId);
    else if (strcmp(what, "heading") == 0) print_prop(e, UIA_HeadingLevelPropertyId);
    else if (strcmp(what, "landmark") == 0) print_prop(e, UIA_LandmarkTypePropertyId);
    else if (strcmp(what, "ariarole") == 0) print_prop(e, UIA_AriaRolePropertyId);
    else if (strcmp(what, "ariaproperties") == 0) print_prop(e, UIA_AriaPropertiesPropertyId);
    else if (strcmp(what, "description") == 0) print_prop(e, UIA_FullDescriptionPropertyId);
    else if (strcmp(what, "localized") == 0) print_prop(e, UIA_LocalizedControlTypePropertyId);
    else if (strcmp(what, "offscreen") == 0) print_prop(e, UIA_IsOffscreenPropertyId);
    else if (strcmp(what, "value") == 0) {
      IUIAutomationValuePattern *p = pattern<IUIAutomationValuePattern>(e, UIA_ValuePatternId);
      BSTR s = NULL;
      if (p && SUCCEEDED(p->get_CurrentValue(&s))) print_bstr(s);
    } else if (strcmp(what, "readonly") == 0) {
      IUIAutomationValuePattern *p = pattern<IUIAutomationValuePattern>(e, UIA_ValuePatternId);
      BOOL ro = TRUE;
      if (p) p->get_CurrentIsReadOnly(&ro);
      printf("%s", ro ? "true" : "false");
    } else if (strcmp(what, "toggle") == 0) {
      IUIAutomationTogglePattern *p = pattern<IUIAutomationTogglePattern>(e, UIA_TogglePatternId);
      ToggleState s = ToggleState_Off;
      if (p && SUCCEEDED(p->get_CurrentToggleState(&s))) printf("%s", s == ToggleState_On ? "on" : s == ToggleState_Off ? "off" : "mixed");
    } else if (strcmp(what, "expanded") == 0) {
      IUIAutomationExpandCollapsePattern *p = pattern<IUIAutomationExpandCollapsePattern>(e, UIA_ExpandCollapsePatternId);
      ExpandCollapseState s = ExpandCollapseState_LeafNode;
      if (p && SUCCEEDED(p->get_CurrentExpandCollapseState(&s))) printf("%s", s == ExpandCollapseState_Expanded ? "expanded" : "collapsed");
    } else if (strcmp(what, "selected") == 0) {
      IUIAutomationSelectionItemPattern *p = pattern<IUIAutomationSelectionItemPattern>(e, UIA_SelectionItemPatternId);
      BOOL s = FALSE;
      if (p && SUCCEEDED(p->get_CurrentIsSelected(&s))) printf("%s", s ? "true" : "false");
    } else if (strcmp(what, "range") == 0) {
      IUIAutomationRangeValuePattern *p = pattern<IUIAutomationRangeValuePattern>(e, UIA_RangeValuePatternId);
      double v = 0, lo = 0, hi = 0;
      if (p) {
        p->get_CurrentValue(&v);
        p->get_CurrentMinimum(&lo);
        p->get_CurrentMaximum(&hi);
        printf("%g %g %g", v, lo, hi);
      }
    } else if (strcmp(what, "text") == 0 || strcmp(what, "selection") == 0) {
      IUIAutomationTextPattern *p = pattern<IUIAutomationTextPattern>(e, UIA_TextPatternId);
      if (p) {
        IUIAutomationTextRange *range = NULL;
        if (what[0] == 't') p->get_DocumentRange(&range);
        else {
          IUIAutomationTextRangeArray *ranges = NULL;
          p->GetSelection(&ranges);
          int n = 0;
          if (ranges) ranges->get_Length(&n);
          if (n > 0) ranges->GetElement(0, &range);
        }
        BSTR s = NULL;
        if (range && SUCCEEDED(range->GetText(-1, &s))) print_bstr(s);
      }
    } else if (strcmp(what, "rect") == 0) {
      RECT r;
      e->get_CurrentBoundingRectangle(&r);
      printf("%ld %ld %ld %ld", r.left, r.top, r.right - r.left, r.bottom - r.top);
    }
    printf("\n");
    return 0;
  }
  return 2;
}
