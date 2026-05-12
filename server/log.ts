export type LogTag = "WS" | "AUTH" | "HTTP" | "CMD" | "ERR";

const COLORS: Record<LogTag, string> = {
  WS:   "\x1b[36m",
  AUTH: "\x1b[33m",
  HTTP: "\x1b[90m",
  CMD:  "\x1b[32m",
  ERR:  "\x1b[31m",
};

function ts() {
  return new Date().toLocaleTimeString("en-GB");
}

export function log(tag: LogTag, msg: string) {
  console.log(`${ts()}  ${COLORS[tag]}${tag.padEnd(4)}\x1b[0m  ${msg}`);
}
