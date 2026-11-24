import type { ReactNode } from "react";

type IconProps = { className?: string };

function base(className: string | undefined, children: ReactNode) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden="true">
      {children}
    </svg>
  );
}

function IconUser({ className }: IconProps) {
  return base(className, <><circle cx="12" cy="8" r="3.5" /><path d="M4.5 20c0-3.4 3-5.5 7.5-5.5s7.5 2.1 7.5 5.5" /></>);
}

function IconBell({ className }: IconProps) {
  return base(className, <><path d="M6 9.5a6 6 0 0 1 12 0c0 4 1.5 5.5 1.5 5.5h-15S6 13.5 6 9.5Z" /><path d="M10 18.5a2.2 2.2 0 0 0 4 0" /></>);
}

function IconLock({ className }: IconProps) {
  return base(className, <><rect x="5" y="10" width="14" height="10" rx="2" /><path d="M8.5 10V7.5a3.5 3.5 0 0 1 7 0V10" /><path d="M12 14v2" /></>);
}

function IconCard({ className }: IconProps) {
  return base(className, <><rect x="3" y="5.5" width="18" height="13" rx="2.5" /><path d="M3 10h18" /><path d="M7 15h4" /></>);
}

function IconCheck({ className }: IconProps) {
  return base(className, <path d="m5 12.5 4.5 4.5L19 7" />);
}

function IconX({ className }: IconProps) {
  return base(className, <path d="M6 6l12 12M18 6 6 18" />);
}

function IconChevron({ className }: IconProps) {
  return base(className, <path d="m9 6 6 6-6 6" />);
}

function IconCamera({ className }: IconProps) {
  return base(className, <><path d="M4 8.5A2.5 2.5 0 0 1 6.5 6h1.7l1.2-2h5.2l1.2 2h1.7A2.5 2.5 0 0 1 20 8.5v9A2.5 2.5 0 0 1 17.5 20h-11A2.5 2.5 0 0 1 4 17.5z" /><circle cx="12" cy="13" r="3.2" /></>);
}

function IconShield({ className }: IconProps) {
  return base(className, <><path d="M12 3.5 19 6v5.6c0 4-2.9 6.9-7 8.9-4.1-2-7-4.9-7-8.9V6z" /><path d="m9 12 2.2 2.2L15.5 10" /></>);
}

function IconLaptop({ className }: IconProps) {
  return base(className, <><rect x="4.5" y="5.5" width="15" height="10" rx="1.5" /><path d="M3 19h18" /></>);
}

function IconSpark({ className }: IconProps) {
  return base(className, <path d="M12 3.5 13.7 9l5.5 1.7-5.5 1.7L12 18l-1.7-5.6L4.8 10.7 10.3 9z" />);
}

export { IconBell, IconCamera, IconCard, IconCheck, IconChevron, IconLaptop, IconLock, IconShield, IconSpark, IconUser, IconX };
