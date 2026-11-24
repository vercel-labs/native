import { GeistSans } from "geist/font/sans";
import { Geist_Mono as createMono } from "next/font/google";

// Geist Sans is loaded from the `geist` npm package (local woff2) rather than
// Google Fonts so the full font-feature-settings — e.g. the `ss11` alternate
// "I" enabled in the geistdocs theme — are available. The package hardcodes the
// `--font-geist-sans` variable; it's aliased to `--font-sans` in geistdocs.css.
export const sans = GeistSans;

export const mono = createMono({
  variable: "--font-mono",
  subsets: ["latin"],
  weight: "variable",
  display: "swap",
});
