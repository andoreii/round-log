import { handleSubmission } from "./index.ts";

const env = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "public-key",
  ROUND_LOG_GITHUB_TOKEN: "server-only-token",
};
const submission = {
  upload_id: "upload", round_id: "round", revision: 1, state: "pending",
  duplicate: false, dispatch_needed: true,
};
const auth = () => Response.json({ id: "owner", is_anonymous: false });
const post = (body = "{}") => new Request("https://example.test/submit-round", {
  method: "POST",
  headers: { Authorization: "Bearer user-token", "Content-Type": "application/json" },
  body,
});
function assert(condition: unknown): asserts condition {
  if (!condition) throw new Error("Assertion failed");
}
function responses(...items: Response[]): typeof fetch {
  return (() => {
    const next = items.shift();
    if (!next) throw new Error("Unexpected request");
    return Promise.resolve(next);
  }) as typeof fetch;
}

Deno.test("requires POST and a signed-in, non-anonymous user", async () => {
  assert((await handleSubmission(new Request("https://example.test"), env)).status === 405);
  const unsigned = new Request("https://example.test", { method: "POST", body: "{}" });
  assert((await handleSubmission(unsigned, env)).status === 401);
  const denied = responses(Response.json({ id: "guest", is_anonymous: true }));
  assert((await handleSubmission(post(), env, denied)).status === 401);
});

Deno.test("bounds and validates JSON without trusting Content-Length", async () => {
  for (const [body, status] of [["{", 400], ["[]", 422], ['"' + "x".repeat(65536) + '"', 413]] as const) {
    assert((await handleSubmission(post(body), env, responses(auth()))).status === status);
  }
});

Deno.test("uses caller auth for storage and a fixed empty-input workflow dispatch", async () => {
  const calls: [string, RequestInit | undefined][] = [];
  const pending = [auth(), Response.json(submission), new Response(null, { status: 204 })];
  const send = ((url: string, options?: RequestInit) => {
    calls.push([url, options]);
    return Promise.resolve(pending.shift()!);
  }) as typeof fetch;
  const response = await handleSubmission(post('{"notes":"private"}'), env, send);
  assert(response.status === 202 && (await response.json()).dispatch === "queued");
  assert((calls[1][1]?.headers as Record<string, string>).Authorization === "Bearer user-token");
  assert(calls[2][0].endsWith("/andoreii/round-log/actions/workflows/process-rounds.yml/dispatches"));
  assert(calls[2][1]?.body === '{"ref":"main"}');
});

Deno.test("an unavailable dispatch cannot lose an accepted upload", async () => {
  for (const status of [200, 403]) {
    const send = responses(auth(), Response.json(submission), new Response(null, { status }));
    const response = await handleSubmission(post(), env, send);
    const body = await response.json();
    assert(response.status === 202 && body.upload_id === "upload" && body.state === "pending");
    assert(body.dispatch === (status === 200 ? "queued" : "unavailable"));
  }
  const send = responses(auth(), Response.json(submission));
  const missingToken = { ...env, ROUND_LOG_GITHUB_TOKEN: undefined };
  assert((await (await handleSubmission(post(), missingToken, send)).json()).code === "dispatch_not_configured");
});

Deno.test("does not dispatch finished or throttled duplicate submissions", async () => {
  for (const state of ["processed", "invalid", "pending"]) {
    const existing = { ...submission, state, duplicate: true, dispatch_needed: false };
    const send = responses(auth(), Response.json(existing));
    const response = await handleSubmission(post(), env, send);
    assert(response.status === 202);
    assert((await response.json()).dispatch === (state === "pending" ? "deferred" : "not_needed"));
  }
});

Deno.test("maps revision conflicts without exposing database error details", async () => {
  const send = responses(auth(), Response.json({ code: "22023", message: "revision_conflict", details: "private" }, { status: 400 }));
  const response = await handleSubmission(post(), env, send);
  assert(response.status === 409 && await response.text() === '{"code":"revision_conflict"}');
});
