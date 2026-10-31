/**
Escape RegExp special characters.

@example
```
import escapeStringRegexp from 'escape-string-regexp';

const escapedString = escapeStringRegexp('How much $ for a 🦄?');
//=> 'How much \\$ for a 🦄\\?'

new RegExp(escapedString);
```
*/
export default function escapeStringRegexp(string: string): string;
