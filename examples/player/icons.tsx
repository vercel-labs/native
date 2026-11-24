// Inline SVG icons for the player, drawn with a single stroke weight.
import type { ReactNode } from "react";

type IconProps = { className?: string };

function base(className: string | undefined, children: ReactNode, filled = false) {
  return (
    <svg viewBox="0 0 24 24" fill={filled ? "currentColor" : "none"} stroke={filled ? "none" : "currentColor"} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" className={className} aria-hidden="true">
      {children}
    </svg>
  );
}

export function IconPlay({ className }: IconProps) {
  return base(className, <path d="M8 5.5v13a1 1 0 0 0 1.52.86l10.2-6.5a1 1 0 0 0 0-1.72L9.52 4.64A1 1 0 0 0 8 5.5Z" />, true);
}

export function IconPause({ className }: IconProps) {
  return base(className, <><rect x="6.5" y="5" width="4" height="14" rx="1.3" /><rect x="13.5" y="5" width="4" height="14" rx="1.3" /></>, true);
}

export function IconNext({ className }: IconProps) {
  return base(className, <><path d="M6 6.2v11.6a1 1 0 0 0 1.56.83L16 12.9V18a1 1 0 0 0 2 0V6a1 1 0 0 0-2 0v5.1L7.56 5.37A1 1 0 0 0 6 6.2Z" /><path d="M18 6v12" /></>);
}

export function IconPrev({ className }: IconProps) {
  return base(className, <><path d="M18 6.2v11.6a1 1 0 0 1-1.56.83L8 12.9V18a1 1 0 0 1-2 0V6a1 1 0 0 1 2 0v5.1l8.44-5.73A1 1 0 0 1 18 6.2Z" /><path d="M6 6v12" /></>);
}

export function IconShuffle({ className }: IconProps) {
  return base(className, <><path d="M3.5 6.5h3.2c1 0 1.9.5 2.5 1.3l6.1 8.4c.6.8 1.5 1.3 2.5 1.3h2.7" /><path d="m17.5 4.5 3 3-3 3" /><path d="M3.5 17.5h3.2c1 0 1.9-.5 2.5-1.3l1.3-1.8" /><path d="m17.5 14.5 3 3-3 3" /><path d="M14.6 8.6 16 6.9c.6-.8 1.5-1.3 2.5-1.3h2.7" /></>);
}

export function IconRepeat({ className }: IconProps) {
  return base(className, <><path d="M4 10.5V9a3 3 0 0 1 3-3h11" /><path d="m15.5 3.5 2.5 2.5-2.5 2.5" /><path d="M20 13.5V15a3 3 0 0 1-3 3H6" /><path d="m8.5 20.5-2.5-2.5 2.5-2.5" /></>);
}

export function IconVolume({ className }: IconProps) {
  return base(className, <><path d="M4 9.5h3.2L12 5.5v13L7.2 14.5H4a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1Z" /><path d="M15.5 9a4.2 4.2 0 0 1 0 6" /><path d="M18 6.6a7.5 7.5 0 0 1 0 10.8" /></>);
}

export function IconMuted({ className }: IconProps) {
  return base(className, <><path d="M4 9.5h3.2L12 5.5v13L7.2 14.5H4a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1Z" /><path d="m16 9.5 5 5M21 9.5l-5 5" /></>);
}

export function IconHeart({ className, filled }: IconProps & { filled?: boolean }) {
  return base(className, <path d="M12 20.2S3.8 15.4 3.8 9.6A4.4 4.4 0 0 1 8.2 5.2c1.6 0 3 .9 3.8 2.2.8-1.3 2.2-2.2 3.8-2.2a4.4 4.4 0 0 1 4.4 4.4c0 5.8-8.2 10.6-8.2 10.6Z" />, filled);
}

export function IconSearch({ className }: IconProps) {
  return base(className, <><circle cx="11" cy="11" r="6.5" /><path d="m16 16 4 4" /></>);
}

export function IconHome({ className }: IconProps) {
  return base(className, <><path d="M3 10.5 12 3l9 7.5" /><path d="M5.5 9.5V21h13V9.5" /><path d="M9.5 21v-6h5v6" /></>);
}

export function IconGrid({ className }: IconProps) {
  return base(className, <><rect x="3.5" y="3.5" width="7" height="7" rx="1.4" /><rect x="13.5" y="3.5" width="7" height="7" rx="1.4" /><rect x="3.5" y="13.5" width="7" height="7" rx="1.4" /><rect x="13.5" y="13.5" width="7" height="7" rx="1.4" /></>);
}

export function IconMic({ className }: IconProps) {
  return base(className, <><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0" /><path d="M12 18v3" /></>);
}

export function IconList({ className }: IconProps) {
  return base(className, <><path d="M8.5 6.5h12M8.5 12h12M8.5 17.5h12" /><circle cx="4.2" cy="6.5" r="1.1" fill="currentColor" stroke="none" /><circle cx="4.2" cy="12" r="1.1" fill="currentColor" stroke="none" /><circle cx="4.2" cy="17.5" r="1.1" fill="currentColor" stroke="none" /></>);
}

export function IconPlus({ className }: IconProps) {
  return base(className, <path d="M12 5v14M5 12h14" />);
}

export function IconChevronLeft({ className }: IconProps) {
  return base(className, <path d="m14.5 5-7 7 7 7" />);
}

export function IconMore({ className }: IconProps) {
  return base(className, <><circle cx="5" cy="12" r="1.4" fill="currentColor" stroke="none" /><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" /><circle cx="19" cy="12" r="1.4" fill="currentColor" stroke="none" /></>);
}

export function IconQueue({ className }: IconProps) {
  return base(className, <><path d="M4 6.5h11M4 11.5h11M4 16.5h7" /><path d="M19 8.5v10.2" /><circle cx="17" cy="18.5" r="2.1" /></>);
}

export function IconArrowRight({ className }: IconProps) {
  return base(className, <><path d="M4 12h15" /><path d="m14 6.5 5.5 5.5-5.5 5.5" /></>);
}
