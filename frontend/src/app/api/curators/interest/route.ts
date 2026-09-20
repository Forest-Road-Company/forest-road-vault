import { createHmac } from "node:crypto";
import {BlobPreconditionFailedError, del, put} from "@vercel/blob";

/**
 * Records one registration of interest in the curator programme.
 *
 * WHAT IT IS NOT. It takes no capital, quotes no terms and opens nothing. It stores a contact
 * and a stated preference so Forest Road can follow up on eligibility and, if both sides agree,
 * an agreement. The client copy says so and this route holds to it.
 *
 * WHERE IT STORES, AND WHY. Vercel Blob, first-party and provisioned on this project. Every
 * submission is its own private JSON object under a prefix derived from an HMAC of the address
 * under a server-held secret, so submissions for one address group together without the key
 * being computable by anyone who merely guesses the address. Records are appended, never
 * overwritten: a repeat submission cannot destroy an earlier one, and the response never says
 * whether an address was seen before, so the route is not an oracle for who registered.
 *
 * IT FAILS LOUDLY. An unconfigured store returns 503 and the visitor is told, rather than seeing
 * a thank-you for a registration that went nowhere.
 *
 * NOTHING PERSONAL IS LOGGED. The address, organisation and note go to the store and nowhere
 * else. Error paths log the failure class only.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const EMAIL = /^[^@\s]{1,64}@[^@\s.]{1,63}(\.[^@\s.]{1,63})+$/;
const MAX_EMAIL = 254;
const CHAINS = new Set(["solana", "ethereum", "canton", "other"]);
const SIZES = new Set(["under-250k", "250k-1m", "1m-5m", "over-5m", "undisclosed"]);
const SOURCE_WINDOW_MS = 10 * 60_000;
const SOURCE_SLOTS = 16;
const SOURCE_SLOT_MS = SOURCE_WINDOW_MS / SOURCE_SLOTS;

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function text(value: unknown, max: number): string {
  if (typeof value !== "string") return "";
  // Control characters are never part of a name, a wallet or a note.
  return value.replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, max);
}

function digest(secret: string, value: string): string {
  return createHmac("sha256", secret).update(value).digest("hex");
}

function sourceAddress(request: Request): string {
  // Vercel sets this header at the trusted edge. A missing header shares the conservative
  // "unknown" bucket; no caller-supplied address is ever stored.
  return (request.headers.get("x-vercel-forwarded-for")?.split(",")[0]?.trim() || "unknown").slice(0, 128);
}

function conflict(error: unknown): boolean {
  return error instanceof BlobPreconditionFailedError
    || (error instanceof Error
      && (error.name === "BlobPreconditionFailedError" || /already exists|overwrite/i.test(error.message)));
}

type Admission = {gates: string[]};

async function releaseGates(gates: string[]) {
  if (gates.length === 0) return;
  await del(gates);
}

async function admit(request: Request, secret: string): Promise<Response | Admission> {
  const now = Date.now();
  const sourceDigest = digest(secret, `source:${sourceAddress(request)}`);
  // Sixteen fixed sub-windows in ten minutes bound the route to one conditional Blob write for an
  // admitted or refused request. The Vercel edge rule independently enforces the wider 16/10m cap.
  const sourceSlot = Math.floor(now / SOURCE_SLOT_MS);
  const sourceGate = `curators-rate/source/${sourceDigest}/${sourceSlot}.json`;
  try {
    await put(sourceGate, "{}", {
      access: "private",
      contentType: "application/json",
      addRandomSuffix: false,
      allowOverwrite: false,
    });
  } catch (error) {
    if (!conflict(error)) throw error;
    const retryAfter = Math.max(1, Math.ceil(((sourceSlot + 1) * SOURCE_SLOT_MS - now) / 1_000));
    return new Response(JSON.stringify({ok: false, error: "Please wait before submitting again."}), {
      status: 429,
      headers: {
        "content-type": "application/json",
        "cache-control": "no-store",
        "retry-after": String(retryAfter),
      },
    });
  }
  return {gates: [sourceGate]};
}

export async function POST(request: Request) {
  if (!process.env.BLOB_READ_WRITE_TOKEN || !process.env.CURATOR_INTEREST_KEY_SECRET) {
    return json(
      { ok: false, error: "Registration is not available right now. Please try again shortly." },
      503,
    );
  }

  // The whole form is under two kilobytes; anything larger is not a registration.
  const length = Number(request.headers.get("content-length") ?? "0");
  if (length > 8_192) return json({ ok: false, error: "Malformed request." }, 413);
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    return json({ ok: false, error: "Malformed request." }, 415);
  }
  const origin = request.headers.get("origin");
  if (origin) {
    try {
      if (new URL(origin).origin !== new URL(request.url).origin) {
        return json({ ok: false, error: "Malformed request." }, 403);
      }
    } catch {
      return json({ ok: false, error: "Malformed request." }, 403);
    }
  }
  let parsed: unknown;
  try {
    const body = await request.text();
    if (body.length > 8_192) return json({ ok: false, error: "Malformed request." }, 413);
    parsed = JSON.parse(body) as unknown;
  } catch {
    return json({ ok: false, error: "Malformed request." }, 400);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return json({ ok: false, error: "Malformed request." }, 400);
  }
  const raw = parsed as Record<string, unknown>;

  // This deliberately non-semantic trap is not a contact field. Refuse visibly if a browser
  // extension fills it; a real registration must never receive success without durable storage.
  if (text(raw.faxExtension, 200)) return json({ok: false, error: "Malformed request."}, 400);

  const email = typeof raw.email === "string" ? raw.email.trim().toLowerCase() : "";
  if (!email) return json({ ok: false, error: "An email address is required." }, 400);
  if (email.length > MAX_EMAIL || !EMAIL.test(email)) {
    return json({ ok: false, error: "That does not look like an email address." }, 400);
  }
  const chain = typeof raw.chain === "string" && CHAINS.has(raw.chain) ? raw.chain : "other";
  const size = typeof raw.size === "string" && SIZES.has(raw.size) ? raw.size : "undisclosed";
  const organisation = text(raw.organisation, 120);
  const wallet = text(raw.wallet, 64);
  const note = text(raw.note, 1000);

  const emailDigest = digest(process.env.CURATOR_INTEREST_KEY_SECRET, email);
  const prefix = `curators/${emailDigest}`;
  const key = `${prefix}/${new Date().toISOString().replace(/[:.]/g, "-")}.json`;

  let admissionGates: string[] = [];
  try {
    const admission = await admit(request, process.env.CURATOR_INTEREST_KEY_SECRET);
    if (admission instanceof Response) return admission;
    admissionGates = admission.gates;
    await put(
      key,
      JSON.stringify({
        email,
        organisation,
        chain,
        size,
        wallet,
        note,
        submittedAt: new Date().toISOString(),
        source: "forestroadvault.com /curators",
      }),
      {
        access: "private",
        contentType: "application/json",
        addRandomSuffix: true,
        allowOverwrite: false,
      },
    );
  } catch (error) {
    // A storage failure must not leave a successful-looking admission gate that blocks retries.
    if (admissionGates.length > 0) {
      try {
        await releaseGates(admissionGates);
      } catch {
        console.error("curators.interest.release failed: BlobError");
      }
    }
    const name = error instanceof Error ? error.name : "UnknownError";
    console.error(`curators.interest.put failed: ${name}`);
    const permanent = name === "BlobStoreSuspendedError" || name === "BlobStoreNotFoundError";
    return json(
      {
        ok: false,
        error: permanent
          ? "Registration is not available right now. Please try again shortly."
          : "We could not record that just now. Please try again in a moment.",
      },
      permanent ? 503 : 502,
    );
  }

  return json({ ok: true }, 200);
}

export async function GET() {
  return json({ ok: false, error: "Method not allowed." }, 405);
}
