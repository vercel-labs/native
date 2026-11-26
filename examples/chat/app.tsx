// Relay, a chat window with a streaming assistant: a question goes in, the
// reply arrives a word at a time, the list follows it down, and Stop cuts it
// short. React renders it, Tailwind styles it, and Send and Stop come from the
// UI SDK. Threads are kept in localStorage.

import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";

interface Message {
  id: string;
  role: string;
  text: string;
  at: string;
}

interface Thread {
  id: string;
  title: string;
  subtitle: string;
  messages: Message[];
}

const STORAGE_KEY = "relay.threads.v1";

const SEED: Thread[] = [
  {
    id: "t-release",
    title: "Release notes",
    subtitle: "Wren · workspace assistant",
    messages: [
      { id: "m1", role: "user", text: "Can you draft release notes for the 2.4 update?", at: "09:12" },
      { id: "m2", role: "assistant", text: "Sure. For 2.4 I'd lead with the new board filters, then the faster invoice table, then the smaller fixes. Want it in a friendly tone or something closer to changelog style?", at: "09:12" },
      { id: "m3", role: "user", text: "Friendly, three short paragraphs.", at: "09:13" },
    ],
  },
  {
    id: "t-bug",
    title: "Overdue invoice bug",
    subtitle: "Wren · workspace assistant",
    messages: [
      { id: "m4", role: "user", text: "The overdue count looks wrong on the invoices page.", at: "Yesterday" },
      { id: "m5", role: "assistant", text: "That count is built from the status field, not the due date, so anything marked Pending with a past due date won't be counted. I can point you at the filter that decides it.", at: "Yesterday" },
    ],
  },
  {
    id: "t-design",
    title: "Board design review",
    subtitle: "Wren · workspace assistant",
    messages: [
      { id: "m6", role: "assistant", text: "The board is ready for review when you are. The columns are 288 wide, cards share one shadow, and the composer sits under the last card in each column.", at: "Mon" },
    ],
  },
];

const REPLIES: { [key: string]: string } = {
  deploy: "The last deploy to production finished at 09:41 and every check is green. The web and API builds both shipped from the same commit, and the only warning was the usual one about an unused image asset. If you want, I can write the summary into #launches.",
  design: "Two things stand out on the board. The column headers could carry the card count in a quieter chip, since the bold number competes with the title. And the drag preview needs a stronger shadow so it reads as lifted above the other cards while it moves.",
  bug: "I traced it to the status filter. The tab counts are computed from every invoice once, but the list narrows to the filtered set, so the number on the tab and the rows underneath disagree whenever a search is active. One source of truth fixes both.",
};

const FALLBACK = "Here is what I know from the workspace. The last release went out on Friday with three fixes and one feature, and nothing has failed since. I would start with the release notes, then look at the open invoices: a few of them are past due but still marked Pending. Tell me which one you want to dig into and I will pull the details.";

function two(value: number): string {
  return value < 10 ? "0" + String(value) : String(value);
}

function clock(): string {
  const now = new Date();
  return two(now.getHours()) + ":" + two(now.getMinutes());
}

function replyFor(prompt: string): string {
  const text = prompt.toLowerCase();
  if (text.includes("deploy") || text.includes("release") || text.includes("ship")) return REPLIES.deploy;
  if (text.includes("design") || text.includes("board") || text.includes("card")) return REPLIES.design;
  if (text.includes("invoice") || text.includes("bug") || text.includes("overdue")) return REPLIES.bug;
  return FALLBACK;
}

function loadThreads(): Thread[] {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw === null || raw === "") {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(SEED));
    return SEED;
  }
  try {
    const parsed = JSON.parse(raw) as Thread[];
    if (Array.isArray(parsed) && parsed.length > 0) return parsed;
  } catch (error) {
    console.error("could not read saved threads", error);
  }
  return SEED;
}

const FIRST_THREADS = loadThreads();

function App() {
  const [threads, setThreads] = useState<Thread[]>(FIRST_THREADS);
  const [activeId, setActiveId] = useState<string>(FIRST_THREADS[0].id);
  const [draft, setDraft] = useState("");
  const [streamingId, setStreamingId] = useState<string | null>(null);
  const messagesRef = useRef<HTMLDivElement>(null);
  const timerRef = useRef<number>(0);
  const stickToBottom = useRef<boolean>(true);

  const active = threads.find((thread) => thread.id === activeId) ?? threads[0];

  useEffect(() => {
    const el = messagesRef.current;
    if (el !== null && stickToBottom.current) el.scrollTop = el.scrollHeight;
  }, [threads, streamingId]);

  useEffect(() => {
    return () => {
      if (timerRef.current !== 0) clearInterval(timerRef.current);
    };
  }, []);

  // Every change to a thread - a message, a streamed reply, the count after Clear - is written
  // back, so reloading the app shows the conversation the user left.
  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(threads));
  }, [threads]);

  function onScroll(event: any): void {
    const el = event.target;
    stickToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
  }

  function startStream(threadId: string, messageId: string, full: string): void {
    const words = full.split(" ");
    let count = 0;
    setStreamingId(messageId);
    stickToBottom.current = true;
    timerRef.current = window.setInterval(() => {
      count++;
      const text = words.slice(0, count).join(" ");
      setThreads((previous) => previous.map((thread) => {
        if (thread.id !== threadId) return thread;
        return {
          id: thread.id,
          title: thread.title,
          subtitle: thread.subtitle,
          messages: thread.messages.map((message) => {
            if (message.id !== messageId) return message;
            return { id: message.id, role: message.role, text: text, at: message.at };
          }),
        };
      }));
      if (count >= words.length) {
        clearInterval(timerRef.current);
        timerRef.current = 0;
        setStreamingId(null);
      }
    }, 34);
  }

  function stopStream(): void {
    if (timerRef.current !== 0) clearInterval(timerRef.current);
    timerRef.current = 0;
    setStreamingId(null);
  }

  function send(): void {
    const text = draft.trim();
    if (text === "" || streamingId !== null) return;
    const threadId = active.id;
    const stamp = clock();
    const userMessage: Message = { id: "m-" + String(Date.now()), role: "user", text: text, at: stamp };
    const replyId = "m-" + String(Date.now() + 1);
    const replyMessage: Message = { id: replyId, role: "assistant", text: "", at: stamp };
    setThreads(threads.map((thread) => {
      if (thread.id !== threadId) return thread;
      return { id: thread.id, title: thread.title, subtitle: thread.subtitle, messages: [...thread.messages, userMessage, replyMessage] };
    }));
    setDraft("");
    startStream(threadId, replyId, replyFor(text));
  }

  function newThread(): void {
    const id = "t-" + String(Date.now());
    const fresh: Thread = { id: id, title: "New conversation", subtitle: "Wren · workspace assistant", messages: [] };
    setThreads([fresh, ...threads]);
    setActiveId(id);
    stickToBottom.current = true;
  }

  function clearThread(): void {
    stopStream();
    setThreads(threads.map((thread) => {
      if (thread.id !== activeId) return thread;
      return { id: thread.id, title: thread.title, subtitle: thread.subtitle, messages: [] };
    }));
  }

  const total = active.messages.length;

  return (
    <div className="flex h-screen bg-slate-50 font-sans text-slate-900">
      <aside className="flex w-64 shrink-0 flex-col bg-slate-950 text-slate-100">
        <div className="flex items-center gap-2.5 px-5 pb-4 pt-5">
          <span className="grid h-8 w-8 place-items-center rounded-lg bg-indigo-500 text-sm font-bold text-white">R</span>
          <div>
            <p className="text-[15px] font-semibold tracking-tight">Relay</p>
            <p className="text-[10.5px] uppercase tracking-wider text-slate-500">Workspace chat</p>
          </div>
        </div>
        <div className="px-4 pb-3">
          <button type="button" id="new-thread" onClick={newThread} className="flex w-full items-center gap-2 rounded-lg border border-white/10 bg-white/5 px-3 py-2 text-left text-[12.5px] font-medium text-slate-300 hover:bg-white/10">
            <span className="text-[15px] leading-none">+</span> New conversation
          </button>
        </div>
        <p className="px-5 pb-1 text-[10.5px] font-medium uppercase tracking-wider text-slate-500">Recent</p>
        <div className="min-h-0 flex-1 overflow-y-auto px-3 pb-4">
          {threads.map((thread) => (
            <button
              key={thread.id}
              type="button"
              onClick={() => { setActiveId(thread.id); stickToBottom.current = true; }}
              className={"mb-1 block w-full rounded-xl px-3 py-2.5 text-left " + (thread.id === active.id ? "bg-white/10" : "hover:bg-white/5")}
            >
              <span className="block truncate text-[13px] font-medium text-slate-100">{thread.title}</span>
              <span className="mt-0.5 block truncate text-[11px] text-slate-500">{thread.messages.length === 0 ? "No messages yet" : thread.messages[thread.messages.length - 1].text}</span>
            </button>
          ))}
        </div>
        <div className="flex items-center gap-2 border-t border-white/10 px-4 py-3">
          <span className="grid h-7 w-7 place-items-center rounded-full bg-slate-700 text-[10px] font-semibold">CT</span>
          <div>
            <p className="text-[12px] font-medium text-slate-200">Chris Tate</p>
            <p className="text-[10px] text-emerald-400">Online</p>
          </div>
        </div>
      </aside>

      <main className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-16 shrink-0 items-center gap-3 border-b border-slate-200 bg-white px-6">
          <div className="grid h-9 w-9 place-items-center rounded-full bg-gradient-to-br from-indigo-500 to-violet-600 text-[11px] font-semibold text-white">W</div>
          <div>
            <h1 className="text-[15px] font-semibold tracking-tight">Wren</h1>
            <p className="text-[11.5px] text-slate-500">{streamingId === null ? "Answers in a moment" : "Typing…"}</p>
          </div>
          <div className="ml-auto flex items-center gap-3">
            <p id="message-count" className="text-[11.5px] text-slate-400">{total} {total === 1 ? "message" : "messages"}</p>
            <button type="button" id="clear-thread" onClick={clearThread} className="rounded-lg border border-slate-200 px-2.5 py-1.5 text-[11.5px] font-medium text-slate-500 hover:bg-slate-50">Clear</button>
          </div>
        </header>

        <div id="messages" ref={messagesRef} onScroll={onScroll} className="min-h-0 flex-1 overflow-y-auto px-6 py-5">
          <div className="mx-auto flex max-w-2xl flex-col gap-4">
            {active.messages.map((message) => (
              <div key={message.id} className={"flex gap-3 " + (message.role === "user" ? "flex-row-reverse" : "")}>
                <span className={"mt-0.5 grid h-7 w-7 shrink-0 place-items-center rounded-full text-[9.5px] font-semibold " + (message.role === "user" ? "bg-slate-900 text-white" : "bg-gradient-to-br from-indigo-500 to-violet-600 text-white")}>
                  {message.role === "user" ? "CT" : "W"}
                </span>
                <div className={"max-w-[80%] " + (message.role === "user" ? "items-end text-right" : "")}>
                  <div className={"inline-block rounded-2xl px-4 py-2.5 text-left text-[13.5px] leading-6 whitespace-pre-wrap " + (message.role === "user" ? "rounded-br-md bg-indigo-600 text-white" : "rounded-bl-md border border-slate-200 bg-white text-slate-700 shadow-sm")}>
                    {message.text === "" ? <span className="inline-flex gap-1 py-1"><span className="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400"></span><span className="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400"></span><span className="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400"></span></span> : message.text}
                  </div>
                  <p className="mt-1 text-[10.5px] text-slate-400">{message.at}</p>
                </div>
              </div>
            ))}
            {active.messages.length === 0 && (
              <div className="py-16 text-center">
                <p className="text-[15px] font-medium text-slate-700">Start a conversation</p>
                <p className="mt-1 text-[12.5px] text-slate-500">Ask about the release, the board or an open invoice.</p>
              </div>
            )}
          </div>
        </div>

        <div className="shrink-0 border-t border-slate-200 bg-white px-6 py-3">
          <div className="mx-auto flex max-w-2xl items-end gap-2">
            <textarea
              id="composer"
              value={draft}
              onInput={(event: any) => setDraft(String(event.target.value))}
              onKeyDown={(event: any) => {
                if (event.key === "Enter" && !event.shiftKey) {
                  event.preventDefault();
                  send();
                }
              }}
              rows={2}
              placeholder="Message Wren…"
              className="min-h-[44px] flex-1 resize-none rounded-xl border border-slate-200 bg-slate-50 px-3.5 py-2.5 text-[13.5px] leading-6 text-slate-700 outline-none placeholder:text-slate-400 focus:border-indigo-300 focus:bg-white focus:ring-4 focus:ring-indigo-50"
            ></textarea>
            {streamingId === null ? (
              <Button id="send" onClick={send} className="inline-flex h-[44px] items-center rounded-xl bg-indigo-600 px-4 text-[13px] font-medium text-white shadow-sm hover:bg-indigo-500">
                Send
              </Button>
            ) : (
              <Button id="stop" onClick={stopStream} className="inline-flex h-[44px] items-center rounded-xl border border-slate-200 bg-white px-4 text-[13px] font-medium text-slate-600 hover:bg-slate-50">
                Stop
              </Button>
            )}
          </div>
          <p className="mx-auto mt-2 max-w-2xl text-[10.5px] text-slate-400">Enter sends · Shift+Enter for a new line · replies stream in a word at a time</p>
        </div>
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
