import type { SVGProps } from "react";

export function TokenIcon({ symbol, className = "h-6 w-6" }: { symbol?: string; className?: string }) {
  const s = symbol?.toUpperCase() ?? "";
  if (s.includes("ETH")) {
    return (
      <svg className={className} viewBox="0 0 32 32" fill="none">
        <circle cx="16" cy="16" r="16" fill="#627EEA" />
        <path d="M16.498 4v8.87l7.497 3.35L16.498 4z" fill="#fff" fillOpacity="0.6" />
        <path d="M16.498 4L9 16.22l7.498-3.35V4z" fill="#fff" />
        <path d="M16.498 21.968v6.027L24 17.616l-7.502 4.352z" fill="#fff" fillOpacity="0.6" />
        <path d="M16.498 27.995v-6.027L9 17.616l7.498 10.379z" fill="#fff" />
        <path d="M16.498 20.573l7.497-4.353-7.497-3.349v7.702z" fill="#fff" fillOpacity="0.2" />
        <path d="M9 16.22l7.498 4.353v-7.702L9 16.22z" fill="#fff" fillOpacity="0.6" />
      </svg>
    );
  }
  if (s.includes("MON")) {
    return (
      <svg className={className} viewBox="0 0 32 32" fill="none">
        <circle cx="16" cy="16" r="16" fill="#836EF9" />
        <path
          d="M16 6L24.66 11V21L16 26L7.34 21V11L16 6Z"
          fill="#0E100F"
          fillOpacity="0.8"
          stroke="#FBFAF9"
          strokeWidth="1.5"
        />
        <circle cx="16" cy="16" r="3.5" fill="#FBFAF9" />
      </svg>
    );
  }
  if (s.includes("USD") || s.includes("USDC")) {
    return (
      <svg className={className} viewBox="0 0 32 32" fill="none">
        <circle cx="16" cy="16" r="16" fill="#2775CA" />
        <path
          d="M16 7C11.03 7 7 11.03 7 16s4.03 9 9 9 9-4.03 9-9-4.03-9-9-9zm.8 14.3v1.7h-1.6v-1.7c-2-.2-3.1-1.3-3.2-2.8h1.8c.1.7.7 1.3 1.9 1.3 1.1 0 1.8-.6 1.8-1.4 0-.8-.6-1.2-2.1-1.6-2.1-.5-3.3-1.3-3.3-2.8 0-1.5 1.1-2.6 3.1-2.8V9.5h1.6v1.7c1.7.2 2.8 1.2 2.9 2.5h-1.8c-.1-.6-.6-1.1-1.6-1.1-1 0-1.6.5-1.6 1.2 0 .7.5 1.1 2 1.5 2.2.5 3.4 1.3 3.4 2.9 0 1.7-1.3 2.8-3.2 3.1z"
          fill="#fff"
        />
      </svg>
    );
  }
  if (s.includes("BTC")) {
    return (
      <svg className={className} viewBox="0 0 32 32" fill="none">
        <circle cx="16" cy="16" r="16" fill="#F7931A" />
        <path
          d="M22.5 14.1c.3-2-1.2-3.1-3.3-3.8l.7-2.7-1.6-.4-.7 2.7c-.4-.1-.8-.2-1.3-.3l.7-2.7-1.6-.4-.7 2.8c-.3-.1-.7-.2-1-.2l-2.2-.6-.4 1.7s1.2.3 1.2.3c.7.2.8.6.7 1l-.7 3c0 .1.1.1.1.1l-.1-.1-1 4.1c-.1.2-.3.6-.8.4 0 0-1.2-.3-1.2-.3l-.8 1.8 2.1.5c.4.1.8.2 1.1.3l-.7 2.9 1.6.4.7-2.8c.4.1.9.2 1.3.3l-.7 2.8 1.6.4.7-2.9c2.8.5 4.9.3 5.8-2.2.7-2 .1-3.1-1.4-3.9 1.1-.3 1.9-1.1 2.1-2.7zm-3.8 5.7c-.5 2-3.9.9-5 .6l.9-3.6c1.1.3 4.6.8 4.1 3zm.5-5.8c-.5 1.8-3.3.9-4.2.7l.8-3.3c.9.2 3.8.7 3.4 2.6z"
          fill="#fff"
        />
      </svg>
    );
  }
  return (
    <div className={`grid place-items-center rounded-full bg-primary/20 text-[10px] font-bold text-primary ${className}`}>
      {s.slice(0, 3) || "OPT"}
    </div>
  );
}
