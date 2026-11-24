// Inline SVG icons, drawn with the same stroke and size as the rest of the app.
import type { ReactNode } from "react";

type IconProps = { className?: string };

function base(className: string | undefined, children: ReactNode) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden="true">
      {children}
    </svg>
  );
}

function IconHome({ className }: IconProps) {
  return base(className, <><path d="M3 10.5 12 3l9 7.5" /><path d="M5.5 9.5V21h13V9.5" /><path d="M9.5 21v-6h5v6" /></>);
}

function IconFolder({ className }: IconProps) {
  return base(className, <path d="M3.5 6.5A1.5 1.5 0 0 1 5 5h4l2 2.5h8A1.5 1.5 0 0 1 20.5 9v9A1.5 1.5 0 0 1 19 19.5H5A1.5 1.5 0 0 1 3.5 18z" />);
}

function IconChart({ className }: IconProps) {
  return base(className, <><path d="M4 20V4" /><path d="M4 20h16" /><path d="M8 16v-5" /><path d="M12.5 16V7" /><path d="M17 16v-8" /></>);
}

function IconUsers({ className }: IconProps) {
  return base(className, <><circle cx="9" cy="8" r="3.25" /><path d="M3.5 20c0-3 2.5-5 5.5-5s5.5 2 5.5 5" /><circle cx="17" cy="9" r="2.5" /><path d="M16 15.2c2.6.2 4.5 1.9 4.5 4.8" /></>);
}

function IconSettings({ className }: IconProps) {
  return base(className, <><circle cx="12" cy="12" r="3" /><path d="M12 3v2.2M12 18.8V21M4.2 7.5l1.9 1.1M17.9 15.4l1.9 1.1M4.2 16.5l1.9-1.1M17.9 8.6l1.9-1.1" /></>);
}

function IconSearch({ className }: IconProps) {
  return base(className, <><circle cx="11" cy="11" r="6.5" /><path d="m16 16 4 4" /></>);
}

function IconPlus({ className }: IconProps) {
  return base(className, <path d="M12 5v14M5 12h14" />);
}

function IconBell({ className }: IconProps) {
  return base(className, <><path d="M6 9.5a6 6 0 0 1 12 0c0 4 1.5 5.5 1.5 5.5h-15S6 13.5 6 9.5Z" /><path d="M10 18.5a2.2 2.2 0 0 0 4 0" /></>);
}

function IconUp({ className }: IconProps) {
  return base(className, <><path d="M12 19V5" /><path d="m6 11 6-6 6 6" /></>);
}

function IconDown({ className }: IconProps) {
  return base(className, <><path d="M12 5v14" /><path d="m6 13 6 6 6-6" /></>);
}

function IconMore({ className }: IconProps) {
  return base(className, <><circle cx="5" cy="12" r="1.2" fill="currentColor" /><circle cx="12" cy="12" r="1.2" fill="currentColor" /><circle cx="19" cy="12" r="1.2" fill="currentColor" /></>);
}

function IconCheck({ className }: IconProps) {
  return base(className, <path d="m5 12.5 4.5 4.5L19 7" />);
}

function IconX({ className }: IconProps) {
  return base(className, <path d="M6 6l12 12M18 6 6 18" />);
}

function IconGlobe({ className }: IconProps) {
  return base(className, <><circle cx="12" cy="12" r="8.5" /><path d="M3.5 12h17" /><path d="M12 3.5c2.4 2.4 3.6 5.2 3.6 8.5s-1.2 6.1-3.6 8.5c-2.4-2.4-3.6-5.2-3.6-8.5s1.2-6.1 3.6-8.5Z" /></>);
}

function IconSpark({ className }: IconProps) {
  return base(className, <path d="M12 3.5 13.7 9l5.5 1.7-5.5 1.7L12 18l-1.7-5.6L4.8 10.7 10.3 9z" />);
}

export { IconBell, IconChart, IconCheck, IconDown, IconFolder, IconGlobe, IconHome, IconMore, IconPlus, IconSearch, IconSettings, IconSpark, IconUp, IconUsers, IconX };
