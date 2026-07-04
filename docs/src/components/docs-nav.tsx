"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { navSections } from "@/lib/docs-navigation";

function Sidebar() {
  const pathname = usePathname();

  return (
    <aside className="hidden w-56 shrink-0 lg:block">
      <nav className="fixed top-16 w-56 h-[calc(100vh-4rem)] overflow-y-auto py-8 pr-4 space-y-6">
        {navSections.map((section) => (
          <div key={section.title}>
            <div className="mb-2 px-3 label-12 font-medium uppercase tracking-wider text-gray-900">
              {section.title}
            </div>
            <div className="space-y-0.5">
              {section.items.map(({ href, name }) => {
                const active = pathname === href;
                return (
                  <Link
                    key={href}
                    href={href}
                    className={`block rounded-md px-3 py-1.5 text-sm transition-colors ${
                      active
                        ? "bg-gray-alpha-100 font-medium text-gray-1000"
                        : "text-gray-900 hover:text-gray-1000"
                    }`}
                  >
                    {name}
                  </Link>
                );
              })}
            </div>
          </div>
        ))}
      </nav>
    </aside>
  );
}

export function DocsNav({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();

  // The homepage is a full-width landing page without the docs sidebar.
  if (pathname === "/") {
    return <main>{children}</main>;
  }

  return (
    <div className="mx-auto max-w-5xl px-6 py-8 lg:py-12">
      <div className="flex gap-12">
        <Sidebar />
        <main className="min-w-0 flex-1">
          <article className="max-w-none">{children}</article>
        </main>
      </div>
    </div>
  );
}
