"use client";
import {useQuery} from "@tanstack/react-query";
import {fmtAmount} from "@/lib/format";

/** What /api/points/pendle answers (lib/pendlePoints.server.ts validates it before it gets here). */
type PendlePointsResponse =
  | {ok: true; enabled: false}
  | {
      ok: true;
      enabled: true;
      asOfBlock: string;
      asOfTimestamp: number;
      excluded: null | "protocol-exempt" | "jurisdiction-blocked";
      points: string;
      pointsPerDay: string;
      markets: {key: string; label: string; yt: string; sy: string; lp: string; points: string; pointsPerDay: string}[];
    };

/**
 * sUSDfr and USDfr deposited into Pendle leave the wallet, so PointsModule credits the market's SY
 * contract rather than the owner. The points site credits YT holders and LPs from the markets' own
 * events, and this card shows its answer for the connected wallet: the same points the weekly race
 * counts. Hidden until Pendle points are enabled.
 */
export function PendlePointsCard({wallet}: {wallet: `0x${string}`}) {
  const {data, isError} = useQuery({
    queryKey: ["pendle-points", wallet],
    queryFn: async (): Promise<PendlePointsResponse> => {
      const response = await fetch(`/api/points/pendle?wallet=${wallet}`);
      const body = (await response.json()) as PendlePointsResponse | {ok: false};
      if (!response.ok || !body.ok) throw new Error("Pendle points unavailable");
      return body;
    },
    refetchInterval: 60_000,
  });

  if (!isError && (!data || !data.enabled)) return null;

  const held = data?.enabled ? data.markets.filter((market) => market.points !== "0") : [];

  return (
    <div className="panel mt-5 p-6">
      <div className="flex flex-wrap items-baseline justify-between gap-3">
        <h3 className="font-display text-[15px] font-semibold tracking-tight text-ink">
          sUSDfr and USDfr held through Pendle
        </h3>
        <span className="font-mono text-[11px] text-accent">YT · LP</span>
      </div>
      {isError || !data?.enabled ? (
        <p className="mt-4 text-[13px] leading-relaxed text-ink-muted">
          Pendle points are temporarily unavailable. No zero balance has been assumed.
        </p>
      ) : data.excluded ? (
        <p className="mt-4 text-[13px] leading-relaxed text-ink-muted">
          {data.excluded === "protocol-exempt"
            ? "This address is a protocol address, so its Pendle positions do not earn points."
            : "This address is jurisdiction-blocked, so none of its Pendle positions earn points while that status stands."}
        </p>
      ) : (
        <>
          <p className="display mt-4 text-[32px] leading-none text-ink">{fmtAmount(BigInt(data.points), 18, 4)}</p>
          <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-ink-faint">
            points computed from Pendle events
          </p>
          <div className="mt-4 border-t border-line pt-3 font-mono text-[10.5px] leading-relaxed text-ink-faint">
            <p>
              Earning:{" "}
              <span className="text-ink-muted">{fmtAmount(BigInt(data.pointsPerDay), 18, 2)} a day</span> at the
              current holdings
            </p>
            {held.map((market) => (
              <p key={market.key}>
                {market.label}:{" "}
                <span className="text-ink-muted">
                  YT {fmtAmount(BigInt(market.yt), 18, 2)} · LP {fmtAmount(BigInt(market.lp), 18, 2)} · SY{" "}
                  {fmtAmount(BigInt(market.sy), 18, 2)}
                </span>
              </p>
            ))}
            <p>
              As of block <span className="text-ink-muted">{data.asOfBlock}</span>
            </p>
          </div>
        </>
      )}
      <p className="mt-3 max-w-[80ch] text-[11.5px] leading-relaxed text-ink-faint">
        sUSDfr or USDfr deposited into its market on Pendle moves to Pendle&apos;s contracts, and
        the on-chain ledger above records its points against them rather than against you. Forest Road
        credits you instead, from the markets&apos; own events: YT earns the underlying&apos;s points on your
        own maturity ramp, LP earns at Forest Road&apos;s rate for that market, and PT earns nothing. YT and
        LP stop at the market&apos;s expiry. These are the points the weekly race counts, computed by the
        Forest Road points site, and they are shown separately from the on-chain total above. Whether an
        address is a protocol address or jurisdiction-blocked is read at the block shown and applies to its
        whole Pendle history.
      </p>
    </div>
  );
}
