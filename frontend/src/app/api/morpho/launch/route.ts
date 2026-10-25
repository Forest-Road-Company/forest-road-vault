import {marketLaunch} from "@/lib/morphoMarket";

export const dynamic = "force-dynamic";

/** Operational switches only; a true flag does not attest to current chain/book health. */
export async function GET() {
  return Response.json(marketLaunch(process.env), {headers: {"Cache-Control": "no-store"}});
}
