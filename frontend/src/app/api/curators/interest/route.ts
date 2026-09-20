import { createHmac } from "node:crypto";
import {BlobPreconditionFailedError, del, list, put} from "@vercel/blob";

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
const EMAIL_WINDOW_MS = 5 * 60_000;
const SOURCE_WINDOW_MS = 10 * 60_000;
const SOURCE_SLOTS = 16;

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

type Admission = {duplicate: boolean; gates: string[]};

async function releaseGates(gates: string[]) {
  if (gates.length === 0) return;
  await del(gates);
}

async function admit(request: Request, secret: string, emailDigest: string): Promise<Response | Admission> {
  const now = Date.now();
  const sourceDigest = digest(secret, `source:${sourceAddress(request)}`);
  const sourceWindow = Math.floor(now / SOURCE_WINDOW_MS);
  let sourceGate: string | null = null;
  // Claim the first free source slot. The previous digest-selected slot could reject the second
  // legitimate colleague behind one office NAT even when fifteen slots were still free.
  for (let sourceSlot = 0; sourceSlot < SOURCE_SLOTS; sourceSlot += 1) {
    const pathname = `curators-rate/source/${sourceDigest}/${sourceWindow}/${sourceSlot}.json`;
    try {
      await put(pathname, "{}", {
        access: "private",
        contentType: "application/json",
        addRandomSuffix: false,
        allowOverwrite: false,
      });
      sourceGate = pathname;
      break;
    } catch (error) {
      if (!conflict(error)) throw error;
    }
  }
  if (sourceGate === null) {
    return new Response(JSON.stringify({ok: false, error: "Please wait before submitting again."}), {
      status: 429,
      headers: {
        "content-type": "application/json",
        "cache-control": "no-store",
        "retry-after": "600",
      },
    });
  }

  const emailGate = `curators-rate/email/${emailDigest}/${Math.floor(now / EMAIL_WINDOW_MS)}.json`;
  try {
    await put(emailGate, "{}", {
      access: "private",
      contentType: "application/json",
      addRandomSuffix: false,
      allowOverwrite: false,
    });
  } catch (error) {
    try {
      await releaseGates([sourceGate]);
    } catch {
      console.error("curators.interest.release failed: BlobError");
    }
    if (conflict(error)) {
      const existing = await list({prefix: `curators/${emailDigest}/`, limit: 1});
      if (existing.blobs.length > 0) {
        // A prior registration for this normalized email is durable. The same success response
        // for first and repeat submissions avoids a five-minute recency oracle.
        return {duplicate: true, gates: []};
      }
      // The gate is stale or another request has not committed its record yet. Remove the stale
      // gate and fail visibly; a success response is reserved for durable data.
      await releaseGates([emailGate]);
      throw new Error("AdmissionInProgress");
    }
    throw error;
  }
  return {duplicate: false, gates: [sourceGate, emailGate]};
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
    const admission = await admit(request, process.env.CURATOR_INTEREST_KEY_SECRET, emailDigest);
    if (admission instanceof Response) return admission;
    if (admission.duplicate) return json({ok: true}, 200);
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
