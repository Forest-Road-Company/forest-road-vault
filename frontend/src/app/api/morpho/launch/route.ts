import {methodNotAllowed} from "@/lib/httpMethod.server";
import {marketLaunch} from "@/lib/morphoMarket";

export const dynamic = "force-dynamic";

/** Operational switches only; a true flag does not attest to current chain/book health. */
export async function GET() {
  return Response.json(marketLaunch(process.env), {headers: {"Cache-Control": "no-store"}});
}

const refuse = () => methodNotAllowed("GET");
export {refuse as POST, refuse as PUT, refuse as PATCH, refuse as DELETE, refuse as OPTIONS};
