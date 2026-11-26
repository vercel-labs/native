// The testharness API the WPT runner gives a page in place of /resources/testharness.js.
//
// WPT's own testharness.js is some five thousand lines of browser plumbing written for a running
// test system; the runner needs the API a page's tests use and a way to read the outcome. A test
// that fails is a failure, not a skip: only a page that doesn't compile stays skipped.
//
// The page's classic scripts share one scope here, so these are plain declarations. Once the page
// has loaded and every promise test has settled, the outcome is left on
// `window.__nativeTestharness` as JSON, which the runner's page loop reads.

var __hTests = [];
var __hPending = 0;
var __hLoaded = false;
var __hDone = false;
var __hSetup = [];
var __hTeardown = [];
var __hStatus = 0;
var __hMessage = "";
var __hCurrent = null;
var __hImplicitTest = null;
// Tests wait for the page's start: setup() runs first, as WPT's harness has it, so a test never
// reads what setup was going to make.
var __hStarted = false;
// Promise tests run one at a time, in registration order, as WPT's harness starts them.
var __hPromiseChain = Promise.resolve();

function __hTest(name, optional) {
  var t = {
    name: name,
    status: 0,
    message: "",
    optional: optional === true,
    _cleanups: [],
    _finished: false,
    _fail: function (e) {
      if (t.status !== 0) return;
      t.status = 1;
      t.message = e === null || e === undefined ? "failed"
        : (e.message !== undefined && e.message !== "") ? String(e.message) : String(e);
    },
    step: function (fn) {
      __hRun(t, fn);
    },
    step_func: function (fn) {
      return function () { __hRun(t, fn, arguments); };
    },
    step_func_done: function (fn) {
      return function () {
        __hRun(t, fn, arguments);
        t.done();
      };
    },
    step_timeout: function (fn, ms) {
      setTimeout(function () { __hRun(t, fn); }, ms === undefined ? 0 : ms);
      return 0;
    },
    force_timeout: function () { t._fail(new Error("forced timeout")); },
    unreached_func: function (message) {
      return function () { t._fail(new Error(message === undefined ? "unreached" : String(message))); };
    },
    add_cleanup: function (fn) { t._cleanups.push(fn); },
    done: function () {
      if (t._finished) return;
      t._finished = true;
      for (var i = 0; i < t._cleanups.length; i++) {
        try { t._cleanups[i](); } catch (e) { t._fail(e); }
      }
      __hPending--;
      __hMaybeSettle();
    },
  };
  __hTests.push(t);
  return t;
}

function __hRun(t, fn, args) {
  var prev = __hCurrent;
  __hCurrent = t;
  // A test's function runs with the test as `this`, so `this.add_cleanup(...)` works, as in the
  // real harness. A step function registered as a listener gets the listener's own arguments (the
  // event); a test function gets the test.
  try {
    if (args === undefined) fn.call(t, t);
    else fn.apply(t, args);
  } catch (e) { t._fail(e); }
  __hCurrent = prev;
}

function __hResult() {
  if (__hDone || !__hLoaded || __hPending > 0) return;
  __hDone = true;
  for (var i = 0; i < __hTeardown.length; i++) {
    try { __hTeardown[i](); } catch (e) { __hStatus = 1; __hMessage = String(e); }
  }
  var out = [];
  for (var k = 0; k < __hTests.length; k++) {
    out.push({ name: __hTests[k].name, status: __hTests[k].status, message: __hTests[k].message, optional: __hTests[k].optional });
  }
  if (out.length === 0 && __hStatus === 0) { __hStatus = 1; __hMessage = "no tests ran"; }
  window.__nativeTestharness = JSON.stringify({ status: __hStatus, message: __hMessage, tests: out });
}

function __hMaybeSettle() { __hResult(); }

// A page may declare one implicit test for the whole document (`setup({single_test: true})`, or
// simply assert at the top level and call done()), as WPT's harness has it.
function __hImplicit() {
  if (__hImplicitTest === null) {
    __hImplicitTest = __hTest(document.title === "" ? "page" : document.title, false);
    __hPending++;
  }
  __hCurrent = __hImplicitTest;
  return __hImplicitTest;
}

function setup(fn) {
  // WPT runs a setup callback when the harness starts, which is before the page's tests run
  // because they are deferred there. Our tests run in script order, so setup is run where it is
  // called — every WPT page calls it before the tests that depend on its fixtures.
  if (typeof fn === "function") {
    __hSetup.push(fn);
    try { fn(); } catch (e) { __hStatus = 1; __hMessage = String(e); }
    return;
  }
  if (fn !== null && typeof fn === "object" && fn.single_test === true) __hImplicit();
}
function promise_setup(fn) { setup(fn); }
function teardown(fn) { __hTeardown.push(fn); }
function add_completion_callback(fn) { void fn; }
function add_result_callback(fn) { void fn; }
function add_start_callback(fn) { void fn; }
// The driver WPT tests call for browser-side answers. The accessibility queries come from the
// runtime's engine, so a role and name test reads what the bridge will read; the input ones go
// through the DOM's own methods.
// The actions a page builds with test_driver.Actions (WebDriver's action sequences, serialized by
// resources/testdriver-actions.js) run through the same pointer, key and wheel path the host's
// own input takes, so every event they send is trusted.
var __hPointerX = 0;
var __hPointerY = 0;
var __hPointerMods = 0;
var __hClickCount = 0;
var __hLastClickAt = 0;

function __hCenter(el) {
  var r = el.getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
}

function __hActionPoint(a) {
  var origin = a.origin;
  if (origin === undefined || origin === null || origin === "viewport") return { x: a.x, y: a.y };
  if (origin === "pointer") return { x: __hPointerX + a.x, y: __hPointerY + a.y };
  var c = __hCenter(origin);
  return { x: c.x + a.x, y: c.y + a.y };
}

function __hRunAction(a) {
  if (a === null || a === undefined) return;
  var type = a.type;
  if (type === "keyDown") { __hPointerMods = actionKey(String(a.value), __hPointerMods, true); return; }
  if (type === "keyUp") { __hPointerMods = actionKey(String(a.value), __hPointerMods, false); return; }
  if (type === "pointerMove") {
    var p = __hActionPoint(a);
    __hPointerX = p.x;
    __hPointerY = p.y;
    pointerMove(__hPointerX, __hPointerY, __hPointerMods);
    return;
  }
  if (type === "pointerDown") {
    __hClickCount++;
    if (__hClickCount > 1 && performance.now() - __hLastClickAt > 500) __hClickCount = 1;
    pointerDown(__hPointerX, __hPointerY, __hClickCount, __hPointerMods);
    return;
  }
  if (type === "pointerUp") {
    __hLastClickAt = performance.now();
    pointerUp(__hPointerX, __hPointerY, __hClickCount, __hPointerMods);
    return;
  }
  if (type === "scroll" || type === "wheel") {
    var q = __hActionPoint(a);
    __hPointerX = q.x;
    __hPointerY = q.y;
    wheel(__hPointerX, __hPointerY, a.deltaY === undefined ? 0 : a.deltaY, a.deltaX === undefined ? 0 : a.deltaX);
    return;
  }
}

function __hRunActions(actions) {
  frame();
  return new Promise(function (resolve, reject) {
    try {
      var ticks = 0;
      var seqs = [];
      var i;
      for (i = 0; i < actions.length; i++) {
        var seq = actions[i].actions === undefined ? [] : actions[i].actions;
        seqs.push(seq);
        if (seq.length > ticks) ticks = seq.length;
      }
      // The ticks run back to back: the page sees the sequence as one turn of input, and an
      // action never waits on a frame the page cannot draw.
      for (var t = 0; t < ticks; t++) {
        for (var j = 0; j < seqs.length; j++) if (t < seqs[j].length) __hRunAction(seqs[j][t]);
      }
      resolve();
    } catch (e) {
      reject(e);
    }
  });
}

// test_driver.Actions: the builder WPT tests use for pointer, key and wheel sequences. The page's
// own copy of resources/testdriver-actions.js is not compiled here; this builds the same shape of
// sequence and hands it to action_sequence, which drives the runtime's input path.
function __hActions(defaultTickDuration) {
  this.duration = defaultTickDuration === undefined ? 16 : defaultTickDuration;
  this.ticks = [{}];
  this.tick = 0;
}
__hActions.prototype.ButtonType = { LEFT: 0, MIDDLE: 1, RIGHT: 2, BACK: 3, FORWARD: 4 };
__hActions.prototype.__tickFor = function (slot) {
  var cur = this.ticks[this.tick];
  if (cur[slot] !== undefined) {
    this.tick++;
    if (this.ticks[this.tick] === undefined) this.ticks[this.tick] = {};
    cur = this.ticks[this.tick];
  }
  return cur;
};
__hActions.prototype.addTick = function () {
  this.tick++;
  if (this.ticks[this.tick] === undefined) this.ticks[this.tick] = {};
  return this;
};
__hActions.prototype.pointerMove = function (x, y, opts) {
  opts = opts === undefined || opts === null ? {} : opts;
  this.__tickFor("pointer").pointer = { type: "pointerMove", x: x, y: y,
    origin: opts.origin === undefined ? "viewport" : opts.origin };
  return this;
};
__hActions.prototype.pointerDown = function (opts) {
  opts = opts === undefined || opts === null ? {} : opts;
  this.__tickFor("pointer").pointer = { type: "pointerDown",
    button: opts.button === undefined ? 0 : opts.button };
  return this;
};
__hActions.prototype.pointerUp = function (opts) {
  opts = opts === undefined || opts === null ? {} : opts;
  this.__tickFor("pointer").pointer = { type: "pointerUp",
    button: opts.button === undefined ? 0 : opts.button };
  return this;
};
__hActions.prototype.pointerCancel = function (opts) {
  this.__tickFor("pointer").pointer = { type: "pointerCancel" };
  return this;
};
__hActions.prototype.keyDown = function (value) {
  this.__tickFor("key").key = { type: "keyDown", value: value };
  return this;
};
__hActions.prototype.keyUp = function (value) {
  this.__tickFor("key").key = { type: "keyUp", value: value };
  return this;
};
__hActions.prototype.pause = function (opts) {
  var ms = this.duration;
  if (typeof opts === "number") ms = opts;
  else if (opts !== undefined && opts !== null && opts.duration !== undefined) ms = opts.duration;
  this.__tickFor("none").none = { type: "pause", duration: ms };
  return this;
};
__hActions.prototype.scroll = function (x, y, deltaX, deltaY, opts) {
  opts = opts === undefined || opts === null ? {} : opts;
  this.__tickFor("wheel").wheel = { type: "scroll", x: x, y: y, deltaX: deltaX, deltaY: deltaY,
    origin: opts.origin === undefined ? "viewport" : opts.origin };
  return this;
};
__hActions.prototype.serialize = function () {
  var slots = ["pointer", "key", "wheel", "none"];
  var out = [];
  for (var s = 0; s < slots.length; s++) {
    var acts = [];
    for (var t = 0; t < this.ticks.length; t++) {
      var a = this.ticks[t][slots[s]];
      acts.push(a === undefined ? { type: "pause" } : a);
    }
    out.push({ type: slots[s], actions: acts });
  }
  return out;
};
__hActions.prototype.send = function () {
  return test_driver.action_sequence(this.serialize());
};

var test_driver = {
  get_computed_role: function (element) {
    return Promise.resolve(accessibleNode(element).role);
  },
  get_computed_label: function (element) {
    return Promise.resolve(accessibleNode(element).name);
  },
  click: function (element) {
    if (element === null || element === undefined) return Promise.resolve();
    frame();
    var c = __hCenter(element);
    __hPointerX = c.x;
    __hPointerY = c.y;
    pointerMove(c.x, c.y, 0);
    pointerDown(c.x, c.y, 1, 0);
    pointerUp(c.x, c.y, 1, 0);
    return Promise.resolve();
  },
  hover: function (element) {
    if (element !== null && element !== undefined) {
      frame();
      var c = __hCenter(element);
      __hPointerX = c.x;
      __hPointerY = c.y;
      pointerMove(c.x, c.y, 0);
    }
    return Promise.resolve();
  },
  focus: function (element) {
    if (element !== null && element !== undefined && typeof element.focus === "function") element.focus();
    return Promise.resolve();
  },
  send_keys: function (element, keys) {
    __nativeSendKeys(element, keys);
    return Promise.resolve();
  },
  action_sequence: function (actions) { return __hRunActions(actions === undefined ? [] : actions); },
  get_computed_accessibility_tree: function (element) {
    var a = accessibleNode(element);
    return Promise.resolve({ role: a.role, name: a.name });
  },
  get_accessibility_properties_for_element: function (element) {
    return Promise.resolve(accessibilityProperties(element));
  },
  get_accessibility_properties_for_accessibility_node: function (id) {
    return Promise.resolve(accessibilityPropertiesForNode(id));
  },
};
test_driver.Actions = __hActions;
function test_timeout() { return 10000; }
function test_set_timeout(ms) { void ms; }
function step_timeout(fn, ms) { setTimeout(fn, ms === undefined ? 0 : ms); return 0; }

// A completion function a page may hand to an event listener or a timer: run, then finish the test.
function step_func(fn) {
  return function () {
    if (__hCurrent !== null) __hRun(__hCurrent, fn, arguments);
    else fn.apply(this, arguments);
  };
}
function step_func_done(fn) {
  return function () {
    var t = __hCurrent === null ? __hImplicit() : __hCurrent;
    __hRun(t, fn, arguments);
    t.done();
  };
}

function test(fn, name) {
  // Synchronous, in script order, as WPT registers and starts a test while the page runs: code
  // after test() must see its effect. Only the report waits for the page's load.
  var t = __hTest(name === undefined ? (fn.name || "test") : name, false);
  __hRun(t, fn);
  return t;
}

function async_test(fn, name) {
  // WPT's form also allows async_test("name") when the test is driven by a listener it
  // registers later, so a string first argument is the name and there is no test function.
  if (typeof fn !== "function" && fn !== undefined && fn !== null) {
    name = fn;
    fn = undefined;
  }
  var t = __hTest(name === undefined ? ((fn !== undefined && fn !== null && fn.name) || "async_test") : String(name), false);
  __hPending++;
  if (fn !== undefined && fn !== null) __hRun(t, fn);
  return t;
}

function promise_test(fn, name, properties) {
  var optional = properties !== undefined && properties !== null && properties.optional === true;
  var t = __hTest(name === undefined ? (fn.name || "promise_test") : name, optional);
  __hPending++;
  __hPromiseChain = __hPromiseChain.then(function () {
    return new Promise(function (settle) {
      var prev = __hCurrent;
      __hCurrent = t;
      var p;
      try { p = fn(t); } catch (e) { t._fail(e); __hCurrent = prev; __hPending--; __hMaybeSettle(); settle(); return; }
      __hCurrent = prev;
      Promise.resolve(p).then(function () { __hPending--; __hMaybeSettle(); settle(); },
        function (e) { t._fail(e); __hPending--; __hMaybeSettle(); settle(); });
    });
  });
  return t;
}

function promise_rejects(t, code, p, message) {
  return Promise.resolve(p).then(
    function () { t._fail(new Error((message === undefined ? "" : message + ": ") + "promise resolved")); },
    function (e) {
      if (code === undefined || code === null) return;
      var name = __hErrorName(e);
      if (name !== __hDomName(code)) t._fail(new Error((message === undefined ? "" : message + ": ") + "expected " + code + ", got " + name));
    });
}
function promise_rejects_dom(t, name, p, message) { return promise_rejects(t, name, p, message); }
function promise_rejects_exactly(t, expected, p, message) {
  return Promise.resolve(p).then(
    function () { t._fail(new Error((message === undefined ? "" : message + ": ") + "promise resolved")); },
    function (e) { if (!__hSame(e, expected)) t._fail(new Error((message === undefined ? "" : message + ": ") + "expected the promise to reject with " + format_value(expected) + ", got " + format_value(e))); });
}
function promise_rejects_js(t, ctor, p, message) {
  return Promise.resolve(p).then(
    function () { t._fail(new Error((message === undefined ? "" : message + ": ") + "promise resolved")); },
    function (e) { if (!(e instanceof ctor)) t._fail(new Error("expected " + ctor.name + ", got " + String(e))); });
}

// The runtime's DOM errors carry their DOMException name at the front of the message (there is no
// DOMException class), so a test naming the expected error reads the name from there too.
// The legacy DOMException code constants a test may name ("INVALID_CHARACTER_ERR") read as the
// exception's own name ("InvalidCharacterError"), which is what the runtime's errors carry.
function __hDomName(code) {
  if (typeof code !== "string" || code.indexOf("_") < 0) return code;
  var parts = code.toLowerCase().split("_");
  if (parts[parts.length - 1] === "err") parts.pop();
  var out = "";
  for (var i = 0; i < parts.length; i++) out += parts[i].charAt(0).toUpperCase() + parts[i].slice(1);
  return out + "Error";
}

function __hErrorName(e) {
  if (e === null || e === undefined) return String(e);
  var name = e.name;
  if (name === undefined || name === "Error" || name === "") {
    var m = /^([A-Za-z][A-Za-z]*Error):/.exec(String(e.message === undefined ? e : e.message));
    if (m !== null) return m[1];
  }
  return name === undefined ? String(e) : name;
}

function format_value(v) {
  if (v === undefined) return "undefined";
  if (v === null) return "null";
  if (typeof v === "string") return JSON.stringify(v);
  if (typeof v === "object") {
    try { return JSON.stringify(v); } catch (e) { return String(v); }
  }
  return String(v);
}

function __hFail(kind, a, b, message) {
  var t = __hCurrent === null ? __hImplicit() : __hCurrent;
  var m = (message === undefined ? "" : message + ": ") + "expected " + format_value(b) + ", got " + format_value(a);
  if (t === null) {
    throw new Error(kind + ": " + m);
  }
  t._fail(new Error(kind + ": " + m));
}

function __hSame(a, b) {
  if (a === b) return true;
  return a !== a && b !== b;
}

function assert_true(v, message) { if (v !== true) __hFail("assert_true", v, true, message); }
function assert_false(v, message) { if (v !== false) __hFail("assert_false", v, false, message); }
function assert_equals(a, b, message) {
  if (__hSame(a, b)) return;
  if (typeof a === "object" && typeof b === "object" && a !== null && b !== null && format_value(a) === format_value(b)) return;
  __hFail("assert_equals", a, b, message);
}
function assert_not_equals(a, b, message) { if (__hSame(a, b)) __hFail("assert_not_equals", a, b, message); }
function assert_array_equals(a, b, message) {
  var ok = a !== null && b !== null && a.length === b.length;
  if (ok) for (var i = 0; i < a.length; i++) if (!__hSame(a[i], b[i])) { ok = false; break; }
  if (!ok) __hFail("assert_array_equals", a, b, message);
}
function assert_object_equals(a, b, message) {
  if (format_value(a) !== format_value(b)) __hFail("assert_object_equals", a, b, message);
}
function assert_in_array(v, a, message) { if (a.indexOf(v) < 0) __hFail("assert_in_array", v, a, message); }
function assert_less_than(a, b, message) { if (!(a < b)) __hFail("assert_less_than", a, b, message); }
function assert_greater_than(a, b, message) { if (!(a > b)) __hFail("assert_greater_than", a, b, message); }
function assert_less_than_equal(a, b, message) { if (!(a <= b)) __hFail("assert_less_than_equal", a, b, message); }
function assert_greater_than_equal(a, b, message) { if (!(a >= b)) __hFail("assert_greater_than_equal", a, b, message); }
function assert_between_exclusive(v, lo, hi, message) { if (!(v > lo && v < hi)) __hFail("assert_between_exclusive", v, lo, message); }
function assert_approx_equals(a, b, epsilon, message) { if (!(Math.abs(a - b) <= epsilon)) __hFail("assert_approx_equals", a, b, message); }
function assert_unreached(message) {
  var t = __hCurrent;
  if (t === null) throw new Error(message === undefined ? "unreached" : message);
  t._fail(new Error(message === undefined ? "unreached" : message));
}
function assert_throws(code, fn, message) {
  var threw = false;
  var err = null;
  try { fn(); } catch (e) { threw = true; err = e; }
  if (!threw) { __hFail("assert_throws", "no exception", code, message); return; }
  if (code === undefined || code === null) return;
  var name = __hErrorName(err);
  if (name !== __hDomName(code)) __hFail("assert_throws", name, code, message);
}
function assert_throws_dom(name, fn, message) { assert_throws(name, fn, message); }
// The thrown value must be exactly `expected`, as WPT's assert_throws_exactly has it.
function assert_throws_exactly(expected, fn, message) {
  var threw = false;
  var err = null;
  try { fn(); } catch (e) { threw = true; err = e; }
  if (!threw) { __hFail("assert_throws_exactly", "no exception", expected, message); return; }
  if (!__hSame(err, expected)) __hFail("assert_throws_exactly", err, expected, message);
}
function assert_throws_js(ctor, fn, message) {
  var ok = false;
  try { fn(); } catch (e) { ok = e instanceof ctor; }
  if (!ok) __hFail("assert_throws_js", "no exception of " + ctor.name, ctor.name, message);
}
function assert_does_not_throw(fn, message) {
  try { fn(); } catch (e) { __hFail("assert_does_not_throw", String(e), "no exception", message); }
}
function assert_idl_attribute(obj, name, message) { if (!(name in obj)) __hFail("assert_idl_attribute", name, "a member", message); }
function assert_own_property(obj, name, message) {
  if (!Object.prototype.hasOwnProperty.call(obj, name)) __hFail("assert_own_property", name, "an own property", message);
}
function assert_no_own_property(obj, name, message) {
  if (Object.prototype.hasOwnProperty.call(obj, name)) __hFail("assert_no_own_property", name, "no own property", message);
}
function assert_class_string(obj, name, message) {
  var tag = obj === null ? "null" : Object.prototype.toString.call(obj);
  if (tag !== "[object " + name + "]") __hFail("assert_class_string", tag, "[object " + name + "]", message);
}
function assert_readonly(obj, name, message) {
  // WPT's check: assigning leaves the value alone (non-strict) or throws (strict); either is
  // readonly. A writable property takes the new value and the test fails.
  var before = obj[name];
  var probe = before === 1 ? 2 : 1;
  try { obj[name] = probe; } catch (e) { return; }
  if (obj[name] !== before) __hFail("assert_readonly", obj[name], before, message);
}
function assert_implements(condition, message) {
  if (!condition) __hFail("assert_implements", condition, true, message === undefined ? "the API isn't implemented" : message);
}
function assert_implements_optional(condition, message) { void condition; void message; }
function assert_node(node, expected, message) {
  var ok = true;
  if (expected !== null && expected !== undefined) {
    if (expected.nodeType !== undefined && node.nodeType !== expected.nodeType) ok = false;
    if (expected.localName !== undefined && node.localName !== expected.localName) ok = false;
    if (Array.isArray(expected)) ok = expected.length === node.length;
  }
  if (!ok) __hFail("assert_node", node === null ? "null" : node.nodeName, expected, message);
}
function assert_pre_comment() { }

// WPT's own helpers a page may lean on: the legacy end-of-tests call, the table-driven
// generate_tests(), and the runner's request for garbage collection (nothing to collect here).
function done() {
  var t = __hImplicit();
  if (!t._finished) t.done();
  __hLoaded = true;
  __hMaybeSettle();
}
function generate_tests(make_test, tests) {
  // WPT's form: each row is [test name, ...arguments], and make_test is called with the
  // arguments inside a test named by the first element.
  for (var i = 0; i < tests.length; i++) {
    var row = tests[i];
    if (row === null || row === undefined || row.length < 1) continue;
    var args = row.slice(1);
    test(function () { make_test.apply(null, args); }, String(row[0]));
  }
}
function garbageCollect() { }

// The page's own load listeners run first: some of them register the tests.
window.addEventListener("load", function () {
  setTimeout(function () { __hStart(); }, 0);
});

function __hStart() {
  __hLoaded = true;
  __hStarted = true;
  // Setup callbacks already ran where the page called them, and tests ran in script order; only
  // the completion (and a single-test page's own done) waits for the load.
  // A single-test page is over once it has loaded, unless its own done() comes later.
  if (__hImplicitTest !== null && !__hImplicitTest._finished) __hImplicitTest.done();
  __hMaybeSettle();
}
