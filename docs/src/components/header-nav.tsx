"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Sheet, SheetTrigger, SheetContent, SheetTitle } from "@/components/ui/sheet";

const links = [
  { name: "Home", href: "/" },
  { name: "Docs", href: "/introduction" },
  { name: "Components", href: "/components" },
];

function isCurrent(href: string, pathname: string): boolean {
  if (href === "/") return pathname === "/";
  if (href === "/components") return pathname === "/components" || pathname.startsWith("/components/");
  // Docs owns every other docs page.
  return pathname !== "/" && !pathname.startsWith("/components");
}

export function HeaderNav() {
  const pathname = usePathname();

  return (
    <nav aria-label="Site" className="hidden md:flex items-center gap-4">
      {links.map(({ name, href }) => {
        const current = isCurrent(href, pathname);
        return (
          <Link
            key={href}
            href={href}
            aria-current={current ? "page" : undefined}
            className={`label-14 transition-colors ${
              current ? "text-gray-1000" : "text-gray-900 hover:text-gray-1000"
            }`}
          >
            {name}
          </Link>
        );
      })}
    </nav>
  );
}

export function HeaderMobileMenu() {
  const [open, setOpen] = useState(false);
  const pathname = usePathname();

  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger
        aria-label="Open menu"
        className="md:hidden flex items-center text-gray-900 hover:text-gray-1000 transition-colors"
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <line x1="4" y1="6" x2="20" y2="6" />
          <line x1="4" y1="12" x2="20" y2="12" />
          <line x1="4" y1="18" x2="20" y2="18" />
        </svg>
      </SheetTrigger>
      <SheetContent side="right" className="overflow-y-auto overscroll-contain p-6">
        <SheetTitle className="sr-only">Site menu</SheetTitle>
        <nav aria-label="Site" className="mt-8">
          <ul className="space-y-0.5">
            {links.map(({ name, href }) => {
              const current = isCurrent(href, pathname);
              return (
                <li key={href}>
                  <Link
                    href={href}
                    onClick={() => setOpen(false)}
                    aria-current={current ? "page" : undefined}
                    className={`text-sm block py-2 transition-colors ${
                      current
                        ? "text-neutral-900 dark:text-neutral-100 font-medium"
                        : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
                    }`}
                  >
                    {name}
                  </Link>
                </li>
              );
            })}
          </ul>
        </nav>
      </SheetContent>
    </Sheet>
  );
}
