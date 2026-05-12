const _token = process.env.FC_TOKEN;
if (!_token) throw new Error("FC_TOKEN environment variable is required.");

export const TOKEN:    string = _token;
export const PORT:     number = Number(process.env.PORT ?? 8080);
export const STALE_MS: number = 30_000;
