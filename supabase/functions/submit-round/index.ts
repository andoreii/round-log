type Environment = {
  SUPABASE_URL?: string;
  SUPABASE_PUBLISHABLE_KEY?: string;
  SUPABASE_ANON_KEY?: string;
  ROUND_LOG_GITHUB_TOKEN?: string;
};

type Submission = {
  upload_id: string;
  round_id: string;
  revision: number;
  state: "pending" | "processed" | "invalid";
  duplicate: boolean;
  dispatch_needed: boolean;
};

const MAX_BODY_BYTES = 64 * 1024;
const WORKFLOW_URL =
  "https://api.github.com/repos/andoreii/round-log/actions/workflows/process-rounds.yml/dispatches";

function reply(status: number, body: object): Response {
  return Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

export async function handleSubmission(
  request: Request,
  env: Environment = Deno.env.toObject(),
  send: typeof fetch = fetch,
): Promise<Response> {
  if (request.method !== "POST") {
    const response = reply(405, { code: "method_not_allowed" });
    response.headers.set("Allow", "POST");
    return response;
  }

  const authorization = request.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+$/i.test(authorization)) {
    return reply(401, { code: "authentication_required" });
  }
  const baseUrl = env.SUPABASE_URL?.replace(/\/$/, "");
  const apiKey = env.SUPABASE_PUBLISHABLE_KEY ?? env.SUPABASE_ANON_KEY;
  if (!baseUrl || !apiKey) {
    return reply(503, { code: "submission_unavailable" });
  }

  const headers = { apikey: apiKey, Authorization: authorization };
  try {
    const auth = await send(`${baseUrl}/auth/v1/user`, {
      headers,
      signal: AbortSignal.timeout(10_000),
      redirect: "error",
    });
    if (!auth.ok) {
      return auth.status === 401 || auth.status === 403
        ? reply(401, { code: "authentication_required" })
        : reply(503, { code: "authentication_unavailable" });
    }
    const user = await auth.json();
    if (!user.id || user.is_anonymous === true) {
      return reply(401, { code: "authentication_required" });
    }
  } catch {
    return reply(503, { code: "authentication_unavailable" });
  }

  if (request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
    return reply(415, { code: "json_required" });
  }
  const contentLength = Number(request.headers.get("Content-Length"));
  if (contentLength > MAX_BODY_BYTES) {
    return reply(413, { code: "submission_too_large" });
  }
  let payload: unknown;
  const reader = request.body?.getReader();
  if (!reader) return reply(400, { code: "invalid_json" });
  try {
    let size = 0;
    const chunks: Uint8Array[] = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY_BYTES) {
        await reader.cancel();
        return reply(413, { code: "submission_too_large" });
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    return reply(400, { code: "invalid_json" });
  } finally {
    reader.releaseLock();
  }
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
    return reply(422, { code: "invalid_envelope" });
  }

  let submission: Submission;
  try {
    // The caller's JWT lets the database derive ownership through auth.uid().
    const saved = await send(`${baseUrl}/rest/v1/rpc/submit_round`, {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({ payload }),
      signal: AbortSignal.timeout(15_000),
      redirect: "error",
    });
    if (!saved.ok) {
      const error = await saved.json();
      if (saved.status === 401 || error.code === "42501") {
        return reply(401, { code: "authentication_required" });
      }
      if (error.code === "22023") {
        return error.message === "revision_conflict" || error.message === "created_at_conflict"
          ? reply(409, { code: error.message })
          : reply(422, { code: "invalid_envelope" });
      }
      return reply(503, { code: "submission_unavailable" });
    }
    submission = await saved.json();
  } catch {
    return reply(503, { code: "submission_unavailable" });
  }

  const result = {
    upload_id: submission.upload_id,
    round_id: submission.round_id,
    revision: submission.revision,
    state: submission.state,
    duplicate: submission.duplicate,
  };
  if (submission.state !== "pending" || !submission.dispatch_needed) {
    return reply(202, {
      ...result,
      dispatch: submission.state === "pending" ? "deferred" : "not_needed",
    });
  }
  if (!env.ROUND_LOG_GITHUB_TOKEN) {
    return reply(202, { ...result, dispatch: "unavailable", code: "dispatch_not_configured" });
  }
  try {
    const dispatched = await send(WORKFLOW_URL, {
      method: "POST",
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${env.ROUND_LOG_GITHUB_TOKEN}`,
        "Content-Type": "application/json",
        "User-Agent": "round-log",
        "X-GitHub-Api-Version": "2026-03-10",
      },
      body: JSON.stringify({ ref: "main" }),
      signal: AbortSignal.timeout(10_000),
      redirect: "error",
    });
    if (dispatched.status === 200 || dispatched.status === 204) {
      return reply(202, { ...result, dispatch: "queued" });
    }
  } catch {
    // The upload is already durable; retrying the same snapshot is safe.
  }
  return reply(202, { ...result, dispatch: "unavailable", code: "dispatch_failed" });
}

if (import.meta.main) Deno.serve((request) => handleSubmission(request));
