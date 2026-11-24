// Custom properties registered from script (CSS.registerProperty), which the style engine reads:
// a registered property can be made non-inheriting, and can carry an initial value. Kept apart
// from both the CSS object and the style engine so either can read it without importing the other.

export interface RegisteredProperty {
  readonly name: string;
  readonly syntax: string;
  readonly inherits: boolean;
  readonly initialValue: string | null;
}

const REGISTERED: Map<string, RegisteredProperty> = new Map();

/** Registers a custom property; the caller has checked the name and that it isn't taken. */
export function registerCustomProperty(name: string, syntax: string, inherits: boolean, initialValue: string | null): void {
  REGISTERED.set(name, { name, syntax, inherits, initialValue });
}

export function registeredProperty(name: string): RegisteredProperty | null {
  const p = REGISTERED.get(name);
  return p === undefined ? null : p;
}

export function registrationCount(): number {
  return REGISTERED.size;
}

/** Every registration, in the order they were made. */
export function registrations(): RegisteredProperty[] {
  const out: RegisteredProperty[] = [];
  for (const p of REGISTERED.values()) out.push(p);
  return out;
}

/** Forgets every registration: a new document in this process registers its own. */
export function clearRegistrations(): void {
  REGISTERED.clear();
}
