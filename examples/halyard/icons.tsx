// Inline SVG icons for Halyard, drawn at 16px with a 1.75 stroke.
import type { ReactNode } from "react";

type IconProps = { className?: string };

function base(className: string | undefined, children: ReactNode) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden="true">
      {children}
    </svg>
  );
}

function IconSearch({ className }: IconProps) {
  return base(className, <><circle cx="11" cy="11" r="6.5" /><path d="m16 16 4 4" /></>);
}

function IconInbox({ className }: IconProps) {
  return base(className, <><path d="M4 13.5 6.5 5h11L20 13.5V19H4z" /><path d="M4 13.5h4l1.5 2.5h5L16 13.5h4" /></>);
}

function IconUser({ className }: IconProps) {
  return base(className, <><circle cx="12" cy="8" r="3.5" /><path d="M5 20c.5-3.5 3.3-5.5 7-5.5s6.5 2 7 5.5" /></>);
}

function IconStack({ className }: IconProps) {
  return base(className, <><path d="M12 3.5 20 8l-8 4.5L4 8z" /><path d="m4 12 8 4.5L20 12" /><path d="m4 16 8 4.5L20 16" /></>);
}

function IconPlus({ className }: IconProps) {
  return base(className, <path d="M12 5v14M5 12h14" />);
}

function IconCommand({ className }: IconProps) {
  return base(className, <><path d="M9 6.5A2.5 2.5 0 1 0 6.5 9H9zM15 6.5A2.5 2.5 0 1 1 17.5 9H15zM9 17.5A2.5 2.5 0 1 1 6.5 15H9zM15 17.5a2.5 2.5 0 1 0 2.5-2.5H15z" /><path d="M9 9h6v6H9z" /></>);
}

function IconCircle({ className }: IconProps) {
  return base(className, <circle cx="12" cy="12" r="7.5" />);
}

function IconHalf({ className }: IconProps) {
  return base(className, <><circle cx="12" cy="12" r="7.5" /><path d="M12 4.5v15" /><path d="M12 4.5a7.5 7.5 0 0 1 0 15z" fill="currentColor" stroke="none" /></>);
}

function IconCheckCircle({ className }: IconProps) {
  return base(className, <><circle cx="12" cy="12" r="7.5" /><path d="m8.5 12 2.5 2.5 4.5-5" /></>);
}

function IconCheck({ className }: IconProps) {
  return base(className, <path d="m5 12.5 4.5 4.5L19 7" />);
}

function IconGrip({ className }: IconProps) {
  return base(className, <><circle cx="9" cy="6" r="1.1" fill="currentColor" /><circle cx="15" cy="6" r="1.1" fill="currentColor" /><circle cx="9" cy="12" r="1.1" fill="currentColor" /><circle cx="15" cy="12" r="1.1" fill="currentColor" /><circle cx="9" cy="18" r="1.1" fill="currentColor" /><circle cx="15" cy="18" r="1.1" fill="currentColor" /></>);
}

function IconMore({ className }: IconProps) {
  return base(className, <><circle cx="5.5" cy="12" r="1.25" fill="currentColor" /><circle cx="12" cy="12" r="1.25" fill="currentColor" /><circle cx="18.5" cy="12" r="1.25" fill="currentColor" /></>);
}

function IconFilter({ className }: IconProps) {
  return base(className, <path d="M4 6h16l-6 7.5V19l-4 1.5v-7z" />);
}

function IconChevronDown({ className }: IconProps) {
  return base(className, <path d="m6 9.5 6 6 6-6" />);
}

function IconChevronRight({ className }: IconProps) {
  return base(className, <path d="m9.5 6 6 6-6 6" />);
}

function IconArrowUp({ className }: IconProps) {
  return base(className, <><path d="M12 19V5" /><path d="m6 11 6-6 6 6" /></>);
}

function IconArrowDown({ className }: IconProps) {
  return base(className, <><path d="M12 5v14" /><path d="m6 13 6 6 6-6" /></>);
}

function IconComment({ className }: IconProps) {
  return base(className, <path d="M4.5 6.5A2 2 0 0 1 6.5 4.5h11a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-6l-4.5 3.5v-3.5h-.5a2 2 0 0 1-2-2z" />);
}

function IconCal({ className }: IconProps) {
  return base(className, <><rect x="4" y="5.5" width="16" height="14" rx="2" /><path d="M8 3.5v4M16 3.5v4M4 10h16" /></>);
}

function IconTag({ className }: IconProps) {
  return base(className, <><path d="M4.5 4.5h6l9 9-6 6-9-9z" /><circle cx="8.5" cy="8.5" r="1.4" /></>);
}

function IconBolt({ className }: IconProps) {
  return base(className, <path d="M13 3 5 13.5h6L10.5 21 19 10h-6z" />);
}

function IconAt({ className }: IconProps) {
  return base(className, <><circle cx="12" cy="12" r="3.5" /><path d="M15.5 8v5a2.5 2.5 0 0 0 5 0v-1a8.5 8.5 0 1 0-3.5 6.8" /></>);
}

function IconClose({ className }: IconProps) {
  return base(className, <path d="M6 6l12 12M18 6 6 18" />);
}

function IconLogo({ className }: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="none" className={className} aria-hidden="true">
      <path d="M12 2.5 21 7.2v9.6L12 21.5 3 16.8V7.2z" fill="currentColor" opacity="0.16" />
      <path d="M12 2.5 21 7.2v9.6L12 21.5 3 16.8V7.2z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
      <path d="M8.2 8v8M15.8 8v8M8.2 12h7.6" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" />
    </svg>
  );
}

export {
  IconArrowDown,
  IconArrowUp,
  IconAt,
  IconBolt,
  IconCal,
  IconCheck,
  IconCheckCircle,
  IconChevronDown,
  IconChevronRight,
  IconCircle,
  IconClose,
  IconCommand,
  IconComment,
  IconFilter,
  IconGrip,
  IconHalf,
  IconInbox,
  IconLogo,
  IconMore,
  IconPlus,
  IconSearch,
  IconStack,
  IconTag,
  IconUser,
};
