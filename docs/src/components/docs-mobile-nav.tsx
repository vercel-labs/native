"use client";

import { useState, useMemo } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Sheet, SheetTrigger, SheetContent, SheetTitle } from "@/components/ui/sheet";
import { allDocsPages, navSections } from "@/lib/docs-navigation";

export function DocsMobileNav() {
  const [open, setOpen] = useState(false);
  const pathname = usePathname();

  const currentPage = useMemo(() => {
    return allDocsPages.find((page) => page.href === pathname) ?? allDocsPages[0];
  }, [pathname]);

  // The homepage is a full-width landing page without the docs chrome.
  if (pathname === "/") {
    return null;
  }

  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger
        aria-label="Open table of contents"
        className="lg:hidden sticky top-16 z-40 w-full px-6 py-3 bg-background-100/80 backdrop-blur-sm border-b border-gray-alpha-400 flex items-center justify-between focus:outline-none"
      >
        <div className="label-14 font-medium text-gray-1000">
          {currentPage.name}
        </div>
        <div className="w-8 h-8 flex items-center justify-center">
          <svg
            className="h-4 w-4 text-gray-900"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <line x1="8" y1="6" x2="21" y2="6" />
            <line x1="8" y1="12" x2="21" y2="12" />
            <line x1="8" y1="18" x2="21" y2="18" />
            <line x1="3" y1="6" x2="3.01" y2="6" />
            <line x1="3" y1="12" x2="3.01" y2="12" />
            <line x1="3" y1="18" x2="3.01" y2="18" />
          </svg>
        </div>
      </SheetTrigger>
      <SheetContent side="left" className="overflow-y-auto p-6" showCloseButton={false}>
        <SheetTitle className="mb-6">Table of Contents</SheetTitle>
        <nav className="space-y-6">
          {navSections.map((section) => (
            <div key={section.title}>
              <div className="mb-2 text-xs font-medium uppercase tracking-wider text-neutral-400 dark:text-neutral-500">
                {section.title}
              </div>
              <ul className="space-y-0.5">
                {section.items.map((item) => (
                  <li key={item.href}>
                    <Link
                      href={item.href}
                      onClick={() => setOpen(false)}
                      className={`text-sm block py-2 transition-colors ${
                        pathname === item.href
                          ? "text-neutral-900 dark:text-neutral-100 font-medium"
                          : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
                      }`}
                    >
                      {item.name}
                    </Link>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </nav>
      </SheetContent>
    </Sheet>
  );
}
