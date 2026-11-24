// The value syntaxes of HTML's date, month, week, time and datetime-local fields, the segments a
// user edits, and the arithmetic behind min, max, step and stepUp()/stepDown().
//
// A field's value is its canonical string (or ""). A segment list is the editable view of it: one
// number per segment, in the order the field draws them, with null for a segment the user hasn't
// filled in yet. Parsing is strict about the syntax of each state and about the days a month has,
// as HTML's microsyntaxes are. Calendar arithmetic is done on day numbers rather than through
// Date's local-time constructors, so a value means the same thing in every time zone.

export type DateKind = "date" | "month" | "week" | "time" | "datetime-local";

/** The date-and-time state a type attribute names, or null for another kind of field. */
export function dateKindOf(type: string): DateKind | null {
  const t = type.toLowerCase();
  if (t === "date" || t === "month" || t === "week" || t === "time" || t === "datetime-local") return t;
  return null;
}

export interface DateParts {
  year: number;
  /** 1 to 12. */
  month: number;
  /** 1 to the days in the month. */
  day: number;
  hour: number;
  minute: number;
  second: number;
  millisecond: number;
}

const MONTH_NAMES = ["January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"];

/** The full name of a month, 1 to 12. */
export function monthName(month: number): string {
  return month >= 1 && month <= 12 ? MONTH_NAMES[month - 1] : "";
}

/** The index of the month a typed name starts with, 1 to 12, or 0 when none does. */
export function monthFromName(text: string): number {
  const s = text.trim().toLowerCase();
  if (s === "") return 0;
  for (let i = 0; i < MONTH_NAMES.length; i++) {
    if (MONTH_NAMES[i].toLowerCase().startsWith(s)) return i + 1;
  }
  return 0;
}

export function isLeapYear(y: number): boolean {
  return y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
}

export function daysInMonth(y: number, m: number): number {
  if (m < 1 || m > 12) return 0;
  if (m === 2) return isLeapYear(y) ? 29 : 28;
  return m === 4 || m === 6 || m === 9 || m === 11 ? 30 : 31;
}

/** Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's days_from_civil). */
export function daysFromCivil(y: number, m: number, d: number): number {
  const yy = y - (m <= 2 ? 1 : 0);
  const era = Math.floor(yy / 400);
  const yoe = yy - era * 400;
  const mp = m + (m > 2 ? -3 : 9);
  const doy = Math.floor((153 * mp + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
}

/** The civil date a day number names, as year, month and day. */
export function civilFromDays(z: number): number[] {
  const zz = z + 719468;
  const era = Math.floor(zz / 146097);
  const doe = zz - era * 146097;
  const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp + (mp < 10 ? 3 : -9);
  return [y + (m <= 2 ? 1 : 0), m, d];
}

/** The day of the week, 0 for Sunday through 6 for Saturday. 1970-01-01 was a Thursday. */
export function dayOfWeek(days: number): number {
  return ((days + 4) % 7 + 7) % 7;
}

/** The day number of the Monday that starts week 1 of a year. */
export function firstWeekStart(y: number): number {
  const jan4 = daysFromCivil(y, 1, 4);
  return jan4 - ((dayOfWeek(jan4) + 6) % 7);
}

/** How many ISO weeks a year has: 53 when it starts on a Thursday, or a leap year on a Wednesday. */
export function weeksInYear(y: number): number {
  const jan1 = daysFromCivil(y, 1, 1);
  const dow = dayOfWeek(jan1);
  return dow === 4 || (isLeapYear(y) && dow === 3) ? 53 : 52;
}

/** The ISO week a day number falls in, as [year, week]. */
export function weekOfDays(days: number): number[] {
  // The week belongs to the year its Thursday falls in.
  const thursday = days - ((dayOfWeek(days) + 6) % 7) + 3;
  const year = civilFromDays(thursday)[0];
  const week = Math.floor((days - firstWeekStart(year)) / 7) + 1;
  return [year, week];
}

/** The day number of a Monday of an ISO week. */
export function weekStartDays(y: number, week: number): number {
  return firstWeekStart(y) + (week - 1) * 7;
}

const TWO = /^(\d{4,})-(\d\d)$/;
const DATE = /^(\d{4,})-(\d\d)-(\d\d)$/;
const WEEK = /^(\d{4,})-W(\d\d)$/;
const TIME = /^(\d\d):(\d\d)(?::(\d\d)(?:\.(\d{1,3}))?)?$/;
const DATE_TIME = /^(\d{4,})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d)(?:\.(\d{1,3}))?)?$/;

function yearOk(y: number): boolean {
  return y > 0 && y <= 275760;
}

function timeParts(hour: number, minute: number, second: number, frac: string | undefined): DateParts | null {
  if (hour > 23 || minute > 59 || second > 59) return null;
  let millisecond = 0;
  if (frac !== undefined) {
    // A fraction has one to three digits, and "1" is a tenth of a second and "12" a hundredth.
    millisecond = Number((frac + "00").slice(0, 3));
  }
  return { year: 0, month: 0, day: 0, hour, minute, second, millisecond };
}

/** The parts a string names under a kind's syntax, or null when it is not a valid value. */
export function parseDateText(kind: DateKind, text: string): DateParts | null {
  const s = text;
  if (kind === "date") {
    const m = DATE.exec(s);
    if (m === null) return null;
    const y = Number(m[1]);
    const mo = Number(m[2]);
    const d = Number(m[3]);
    if (!yearOk(y) || mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo)) return null;
    return { year: y, month: mo, day: d, hour: 0, minute: 0, second: 0, millisecond: 0 };
  }
  if (kind === "month") {
    const m = TWO.exec(s);
    if (m === null) return null;
    const y = Number(m[1]);
    const mo = Number(m[2]);
    if (!yearOk(y) || mo < 1 || mo > 12) return null;
    return { year: y, month: mo, day: 1, hour: 0, minute: 0, second: 0, millisecond: 0 };
  }
  if (kind === "week") {
    const m = WEEK.exec(s);
    if (m === null) return null;
    const y = Number(m[1]);
    const w = Number(m[2]);
    if (!yearOk(y) || w < 1 || w > weeksInYear(y)) return null;
    const days = weekStartDays(y, w);
    const civil = civilFromDays(days);
    return { year: civil[0], month: civil[1], day: civil[2], hour: 0, minute: 0, second: 0, millisecond: 0 };
  }
  if (kind === "time") {
    const m = TIME.exec(s);
    if (m === null) return null;
    return timeParts(Number(m[1]), Number(m[2]), m[3] === undefined ? 0 : Number(m[3]), m[4]);
  }
  const m = DATE_TIME.exec(s);
  if (m === null) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (!yearOk(y) || mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo)) return null;
  const t = timeParts(Number(m[4]), Number(m[5]), m[6] === undefined ? 0 : Number(m[6]), m[7]);
  if (t === null) return null;
  t.year = y;
  t.month = mo;
  t.day = d;
  return t;
}

/** A year as the at-least-four-digit text a value writes it with. */
function yearText(y: number): string {
  let s = String(y);
  while (s.length < 4) s = "0" + s;
  return s;
}

/** Two digits of a small number. */
function two(n: number): string {
  return n < 10 ? "0" + n : String(n);
}

/** A time as its canonical text: seconds and a fraction only when they are not zero. */
export function timeText(hour: number, minute: number, second: number, millisecond: number): string {
  let s = two(hour) + ":" + two(minute);
  if (second !== 0 || millisecond !== 0) {
    s += ":" + two(second);
    if (millisecond !== 0) {
      let frac = String(millisecond);
      while (frac.length < 3) frac = "0" + frac;
      while (frac.length > 1 && frac[frac.length - 1] === "0") frac = frac.slice(0, frac.length - 1);
      s += "." + frac;
    }
  }
  return s;
}

/** The canonical value text of parts under a kind's syntax. */
export function formatDateText(kind: DateKind, p: DateParts): string {
  if (kind === "date") return yearText(p.year) + "-" + two(p.month) + "-" + two(p.day);
  if (kind === "month") return yearText(p.year) + "-" + two(p.month);
  if (kind === "time") return timeText(p.hour, p.minute, p.second, p.millisecond);
  const time = timeText(p.hour, p.minute, p.second, p.millisecond);
  if (kind === "week") {
    const days = daysFromCivil(p.year, p.month, p.day);
    const w = weekOfDays(days);
    return yearText(w[0]) + "-W" + two(w[1]);
  }
  return yearText(p.year) + "-" + two(p.month) + "-" + two(p.day) + "T" + time;
}

/** The value a string is under a kind's syntax: its canonical text, or "" when it isn't valid. */
export function sanitizeDateText(kind: DateKind, text: string): string {
  const p = parseDateText(kind, text);
  return p === null ? "" : formatDateText(kind, p);
}

// ---------------------------------------------------------------------------
// Segments
//
// A field draws one segment per value component, in its locale's order (the runtime draws them as
// en-US does). Each segment carries the separators drawn before it, its digit count and the range
// its number takes.

export type SegmentKey = "month" | "day" | "year" | "week" | "hour" | "minute" | "second" | "ampm";

export interface SegmentDef {
  key: SegmentKey;
  /** The text drawn before the segment's own value, such as the "/" between date parts. */
  prefix: string;
  /** The most digits the segment takes. */
  digits: number;
  min: number;
  max: number;
  /** The grey text a segment with no value shows. */
  placeholder: string;
  /** A month segment in a month field shows the month's name rather than its number. */
  monthName: boolean;
}

function dateSegments(): SegmentDef[] {
  return [
    { key: "month", prefix: "", digits: 2, min: 1, max: 12, placeholder: "mm", monthName: false },
    { key: "day", prefix: "/", digits: 2, min: 1, max: 31, placeholder: "dd", monthName: false },
    { key: "year", prefix: "/", digits: 4, min: 1, max: 275760, placeholder: "yyyy", monthName: false },
  ];
}

/** The segments a field of a kind draws, with seconds only when its step needs them. */
export function segmentsFor(kind: DateKind, withSeconds: boolean): SegmentDef[] {
  if (kind === "date") return dateSegments();
  if (kind === "month") {
    return [
      { key: "month", prefix: "", digits: 2, min: 1, max: 12, placeholder: "Month", monthName: true },
      { key: "year", prefix: " ", digits: 4, min: 1, max: 275760, placeholder: "Year", monthName: false },
    ];
  }
  if (kind === "week") {
    return [
      { key: "week", prefix: "Week ", digits: 2, min: 1, max: 53, placeholder: "ww", monthName: false },
      { key: "year", prefix: ", ", digits: 4, min: 1, max: 275760, placeholder: "yyyy", monthName: false },
    ];
  }
  const time: SegmentDef[] = [
    { key: "hour", prefix: "", digits: 2, min: 1, max: 12, placeholder: "hh", monthName: false },
    { key: "minute", prefix: ":", digits: 2, min: 0, max: 59, placeholder: "mm", monthName: false },
  ];
  if (withSeconds) {
    time.push({ key: "second", prefix: ":", digits: 2, min: 0, max: 59, placeholder: "ss", monthName: false });
  }
  time.push({ key: "ampm", prefix: " ", digits: 2, min: 0, max: 1, placeholder: "AM/PM", monthName: false });
  if (kind === "time") return time;
  const dateTime = dateSegments().concat(time);
  // The time follows the date after a comma, as Chrome's en-US order draws it.
  dateTime[dateSegments().length].prefix = ", ";
  return dateTime;
}

/** The segment values a complete set of parts gives, in segment order. */
export function segmentValues(spec: SegmentDef[], p: DateParts): number[] {
  // A week field names a week of a week-numbering year, which its year segment shows: the year of
  // the week's Thursday, not of the Monday the value starts on.
  const weekField = segmentIndexOf(spec, "week") >= 0;
  const weekYear = weekField ? weekOfDays(daysFromCivil(p.year, p.month, p.day)) : [p.year, 1];
  const out: number[] = [];
  for (let i = 0; i < spec.length; i++) {
    const s = spec[i];
    if (s.key === "month") out.push(p.month);
    else if (s.key === "day") out.push(p.day);
    else if (s.key === "year") out.push(weekField ? weekYear[0] : p.year);
    // A 12-hour segment shows 12 at noon and midnight, not 0.
    else if (s.key === "hour") out.push(p.hour % 12 === 0 ? 12 : p.hour % 12);
    else if (s.key === "minute") out.push(p.minute);
    else if (s.key === "second") out.push(p.second);
    else if (s.key === "ampm") out.push(p.hour < 12 ? 0 : 1);
    else {
      // A week segment shows the ISO week of the month field's day, which for a week value is its
      // Monday.
      const w = weekOfDays(daysFromCivil(p.year, p.month, p.day));
      out.push(w[1]);
    }
  }
  return out;
}

/** The parts a complete list of segment values names, or null when they don't make a valid value. */
export function partsFromSegments(spec: SegmentDef[], vals: (number | null)[]): DateParts | null {
  const p: DateParts = { year: 1970, month: 1, day: 1, hour: 0, minute: 0, second: 0, millisecond: 0 };
  let hour12 = -1;
  let pm = -1;
  let week = -1;
  for (let i = 0; i < spec.length; i++) {
    const v = vals[i];
    if (v === null) return null;
    const s = spec[i];
    if (s.key === "month") p.month = v;
    else if (s.key === "day") p.day = v;
    else if (s.key === "year") p.year = v;
    else if (s.key === "hour") hour12 = v;
    else if (s.key === "minute") p.minute = v;
    else if (s.key === "second") p.second = v;
    else if (s.key === "ampm") pm = v;
    else week = v;
  }
  if (week >= 0) {
    if (week < 1 || week > weeksInYear(p.year)) return null;
    // A week value names the Monday of its ISO week, whatever order the segments came in.
    const civil = civilFromDays(weekStartDays(p.year, week));
    p.month = civil[1];
    p.day = civil[2];
  }
  if (hour12 < 0) {
    // A date field's parts have no time: its value starts at midnight.
    p.hour = 0;
  } else {
    if (hour12 < 1 || hour12 > 12) return null;
    if (pm >= 0) {
      // A 12-hour segment shows 12 for noon and midnight, which the hour count wraps from.
      p.hour = hour12 % 12 + (pm === 1 ? 12 : 0);
    } else {
      p.hour = hour12;
    }
  }
  if (p.month < 1 || p.month > 12 || p.day < 1 || p.day > daysInMonth(p.year, p.month)) return null;
  if (p.hour > 23 || p.minute > 59 || p.second > 59) return null;
  return p;
}

/** The value text complete segment values make, or null when they are not complete or valid. */
export function textFromSegments(kind: DateKind, spec: SegmentDef[], vals: (number | null)[]): string | null {
  const p = partsFromSegments(spec, vals);
  if (p === null) return null;
  return formatDateText(kind, p);
}

/** The text a segment draws: a month's name in a month field, AM or PM, or a padded number. */
export function segmentValueText(s: SegmentDef, v: number): string {
  if (s.key === "ampm") return v === 1 ? "PM" : "AM";
  if (s.monthName) return monthName(v);
  if (s.key === "year") return yearText(v);
  return two(v);
}

/** The most a segment's number can be, which a day takes from the month it sits in. */
export function segmentMax(spec: SegmentDef[], vals: (number | null)[], index: number): number {
  const s = spec[index];
  if (s.key !== "day") return s.max;
  const month = valueOfKey(spec, vals, "month");
  const year = valueOfKey(spec, vals, "year");
  return daysInMonth(year === null ? 1970 : year, month === null ? 1 : month);
}

/** A segment's value by its key, or null when the field has no such segment or it is empty. */
export function valueOfKey(spec: SegmentDef[], vals: (number | null)[], key: SegmentKey): number | null {
  for (let i = 0; i < spec.length; i++) if (spec[i].key === key) return vals[i];
  return null;
}

/** The index of a segment by its key, or -1 when the field has no such segment. */
export function segmentIndexOf(spec: SegmentDef[], key: SegmentKey): number {
  for (let i = 0; i < spec.length; i++) if (spec[i].key === key) return i;
  return -1;
}

/**
 * A segment moved one value up or down, wrapping at its ends. A day wraps inside its month, an
 * hour inside its day, and a month inside its year; an empty segment takes the default the
 * neighbouring segments suggest, which is the month and year they show.
 */
export function adjustSegment(spec: SegmentDef[], vals: (number | null)[], index: number, delta: number): (number | null)[] {
  const out = vals.slice();
  const s = spec[index];
  let v = out[index];
  if (s.key === "ampm") {
    // Moving AM or PM flips the half of the day.
    out[index] = v === null ? (delta > 0 ? 1 : 0) : (v === 1 ? 0 : 1);
    return out;
  }
  if (v === null) v = defaultForSegment(spec, out, index);
  if (s.key === "hour") {
    // A 12-hour segment wraps between 12 and 1, which flips AM and PM with it.
    const before = Math.floor((v - 1) / 12);
    let n = ((v - 1 + delta) % 12 + 12) % 12 + 1;
    const after = Math.floor((v - 1 + delta) / 12);
    if (before !== after) {
      const ai = segmentIndexOf(spec, "ampm");
      if (ai >= 0) {
        const a = out[ai];
        out[ai] = a === null ? (delta > 0 ? 1 : 0) : (a === 1 ? 0 : 1);
      }
    }
    out[index] = n;
    return out;
  }
  const max = segmentMax(spec, out, index);
  const min = s.min;
  let n = v + delta;
  const span = max - min + 1;
  if (n > max) n = min + ((n - min) % span);
  if (n < min) n = max - ((max - n) % span);
  out[index] = n;
  // A day that no longer fits its month (31 in April) steps back to the month's last day.
  if (s.key === "month") {
    const dayAt = segmentIndexOf(spec, "day");
    if (dayAt >= 0 && out[dayAt] !== null) {
      const limit = daysInMonth(valueOfKey(spec, out, "year") ?? 1970, n);
      if (out[dayAt]! > limit) out[dayAt] = limit;
    }
  }
  // An hour changes the AM/PM a field shows, which is derived from it on every draw.
  return out;
}

/** The number an empty segment starts from when a key moves it: the field's today, or noon. */
function defaultForSegment(spec: SegmentDef[], vals: (number | null)[], index: number): number {
  const now = new Date();
  const s = spec[index];
  if (s.key === "month") return valueOfKey(spec, vals, "month") ?? now.getMonth() + 1;
  if (s.key === "day") return valueOfKey(spec, vals, "day") ?? now.getDate();
  if (s.key === "year") return valueOfKey(spec, vals, "year") ?? now.getFullYear();
  if (s.key === "week") {
    const days = daysFromCivil(now.getFullYear(), now.getMonth() + 1, now.getDate());
    return weekOfDays(days)[1];
  }
  if (s.key === "hour") return now.getHours() % 12 === 0 ? 12 : now.getHours() % 12;
  if (s.key === "minute") return now.getMinutes();
  if (s.key === "second") return now.getSeconds();
  return now.getHours() < 12 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// Positions
//
// A value converted to a number on its type's stepping timeline: milliseconds since the epoch for
// date, datetime-local and week (from the Monday), milliseconds since midnight for time, and
// months since January 1970 for month. stepUp()/stepDown() and min/max/step checks all work here.

export function positionOf(kind: DateKind, p: DateParts): number {
  if (kind === "time") return ((p.hour * 60 + p.minute) * 60 + p.second) * 1000 + p.millisecond;
  if (kind === "month") return (p.year - 1970) * 12 + (p.month - 1);
  const days = daysFromCivil(p.year, p.month, p.day);
  if (kind === "week") {
    const w = weekOfDays(days);
    return weekStartDays(w[0], w[1]) * 86400000;
  }
  if (kind === "date") return days * 86400000;
  return days * 86400000 + ((p.hour * 60 + p.minute) * 60 + p.second) * 1000 + p.millisecond;
}

/** The parts a position names, or null when it is outside the range a date can be written for. */
export function partsFromPosition(kind: DateKind, pos: number): DateParts | null {
  if (!isFinite(pos)) return null;
  if (kind === "time") {
    let ms = Math.floor(pos % 86400000);
    if (ms < 0) ms += 86400000;
    const secs = Math.floor(ms / 1000);
    return {
      year: 1970, month: 1, day: 1,
      hour: Math.floor(secs / 3600), minute: Math.floor(secs / 60) % 60,
      second: secs % 60, millisecond: ms - secs * 1000,
    };
  }
  if (kind === "month") {
    const months = Math.floor(pos);
    const year = 1970 + Math.floor(months / 12);
    if (year < 1 || year > 275760) return null;
    return { year, month: months - Math.floor(months / 12) * 12 + 1, day: 1, hour: 0, minute: 0, second: 0, millisecond: 0 };
  }
  const days = Math.floor(pos / 86400000);
  const civil = civilFromDays(days);
  if (civil[0] < 1 || civil[0] > 275760) return null;
  if (kind === "date" || kind === "week") {
    return { year: civil[0], month: civil[1], day: civil[2], hour: 0, minute: 0, second: 0, millisecond: 0 };
  }
  let ms = Math.floor(pos - days * 86400000);
  if (ms < 0) ms += 86400000;
  const secs = Math.floor(ms / 1000);
  return {
    year: civil[0], month: civil[1], day: civil[2],
    hour: Math.floor(secs / 3600), minute: Math.floor(secs / 60) % 60,
    second: secs % 60, millisecond: ms - secs * 1000,
  };
}

/** The step attribute's unit in a kind's timeline: a day, a week, a second or a month. */
export function stepScale(kind: DateKind): number {
  if (kind === "date") return 86400000;
  if (kind === "week") return 604800000;
  if (kind === "month") return 1;
  return 1000;
}

/** The step a field takes with no usable step attribute, in its timeline's units. */
export function defaultStep(kind: DateKind): number {
  if (kind === "date") return 86400000;
  if (kind === "week") return 604800000;
  if (kind === "month") return 1;
  return 60000;
}

/**
 * The step a field takes, in its timeline's units, or 0 for `step="any"` or a step that isn't a
 * positive number. A step attribute is a number of seconds, which the kind's scale turns into its
 * own units.
 */
export function stepSize(kind: DateKind, stepAttr: string | null): number {
  if (stepAttr === null) return defaultStep(kind);
  const text = stepAttr.trim().toLowerCase();
  if (text === "any") return 0;
  if (!/^[+]?(\d+(\.\d+)?|\.\d+)$/.test(text)) return defaultStep(kind);
  const n = Number(text);
  if (!isFinite(n) || n <= 0) return defaultStep(kind);
  return n * stepScale(kind);
}

/** Whether the step attribute is `any`, which leaves no steps to take. */
export function stepIsAny(stepAttr: string | null): boolean {
  return stepAttr !== null && stepAttr.trim().toLowerCase() === "any";
}

/** The position a field with no value starts from: today, this week, this month, or now. */
export function defaultPosition(kind: DateKind, now: Date): number {
  const days = daysFromCivil(now.getFullYear(), now.getMonth() + 1, now.getDate());
  if (kind === "time") return ((now.getHours() * 60 + now.getMinutes()) * 60 + now.getSeconds()) * 1000 + now.getMilliseconds();
  if (kind === "month") return (now.getFullYear() - 1970) * 12 + now.getMonth();
  if (kind === "week") {
    const w = weekOfDays(days);
    return weekStartDays(w[0], w[1]) * 86400000;
  }
  if (kind === "date") return days * 86400000;
  return days * 86400000 + ((now.getHours() * 60 + now.getMinutes()) * 60 + now.getSeconds()) * 1000 + now.getMilliseconds();
}

/** A value's position along its timeline, or NaN when it has none. */
export function valuePosition(kind: DateKind, text: string): number {
  const p = parseDateText(kind, text);
  return p === null ? NaN : positionOf(kind, p);
}

/** The value a position makes, or "" when it falls outside the range a value can name. */
export function textFromPosition(kind: DateKind, pos: number): string {
  const p = partsFromPosition(kind, pos);
  return p === null ? "" : formatDateText(kind, p);
}

/**
 * The value `n` steps from a field's current one, or null when the move is refused: a field
 * outside its min/max doesn't step, and a min above its max has no range to step in.
 */
export function stepValue(
  kind: DateKind, text: string, n: number, stepAttr: string | null, minText: string, maxText: string,
): string | null {
  const step = stepSize(kind, stepAttr);
  if (step === 0) return null;
  const min = valuePosition(kind, minText);
  const max = valuePosition(kind, maxText);
  if (!isNaN(min) && !isNaN(max) && min > max) return null;
  const current = valuePosition(kind, text);
  if (!isNaN(current)) {
    if (!isNaN(min) && current < min) return null;
    if (!isNaN(max) && current > max) return null;
  }
  // A week's steps run from the Monday of 1970's first week, so a step lands on a Monday; the
  // other kinds have their zero point at a whole unit already.
  const zero = kind === "week" ? weekStartDays(1970, 1) * 86400000 : 0;
  const base = isNaN(min) ? zero : min;
  const pos = isNaN(current) ? defaultPosition(kind, new Date()) : current;
  const q = (pos - base) / step;
  const k = n > 0 ? Math.floor(q + 1e-9) + n : Math.ceil(q - 1e-9) + n;
  let target = base + k * step;
  if (!isNaN(max) && target > max) {
    target = base + Math.floor((max - base) / step + 1e-9) * step;
  }
  if (!isNaN(min) && target < min) {
    target = base + Math.ceil((min - base) / step - 1e-9) * step;
  }
  if (!isNaN(min) && target < min - 1e-9) return null;
  if (!isNaN(max) && target > max + 1e-9) return null;
  return textFromPosition(kind, target);
}

/** The month a Date's milliseconds names, as the month count valueAsNumber uses. */
export function monthIndexFromMs(ms: number): number {
  const civil = civilFromDays(Math.floor(ms / 86400000));
  return (civil[0] - 1970) * 12 + civil[1] - 1;
}

/** A value's milliseconds where valueAsNumber wants them, or NaN for an empty or unusable value. */
export function dateValueAsNumber(kind: DateKind, text: string): number {
  const p = parseDateText(kind, text);
  return p === null ? NaN : positionOf(kind, p);
}

/** The value a valueAsNumber write makes, or "" when the number names no representable value. */
export function dateTextFromNumber(kind: DateKind, n: number): string {
  if (!isFinite(n)) return "";
  if (kind === "time") {
    // A time wraps around the day, so a negative number counts back from midnight.
    let ms = n % 86400000;
    if (ms < 0) ms += 86400000;
    return textFromPosition(kind, ms);
  }
  if (kind === "month") return textFromPosition(kind, Math.floor(n));
  if (kind === "date") return textFromPosition(kind, Math.floor(n / 86400000) * 86400000);
  if (kind === "week") {
    const day = Math.floor(n / 86400000);
    const w = weekOfDays(day);
    return textFromPosition(kind, weekStartDays(w[0], w[1]) * 86400000);
  }
  // datetime-local keeps whole seconds, as a value's text does.
  return textFromPosition(kind, Math.floor(n / 1000) * 1000);
}

/**
 * The milliseconds a Date names for valueAsDate, or NaN when the type takes no Date (a
 * datetime-local field) or the date falls outside the value's range.
 */
export function dateValueOfParts(kind: DateKind, text: string): number {
  if (kind === "datetime-local") return NaN;
  const p = parseDateText(kind, text);
  if (p === null) return NaN;
  // A month stands for its first day, so its Date is that midnight rather than a month count.
  if (kind === "month") return daysFromCivil(p.year, p.month, 1) * 86400000;
  return positionOf(kind, p);
}
