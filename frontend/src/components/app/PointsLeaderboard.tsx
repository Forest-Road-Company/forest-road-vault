"use client";
import {useState} from "react";
import {useQuery} from "@tanstack/react-query";
import {useAccount} from "wagmi";
import {EXPLORER_BASE_URL} from "@/config/contracts";
import {fmtAmount, shortAddress} from "@/lib/format";

type Row = {rank: number; wallet: `0x${string}`; points: string; onchain: string; pendle: string; morpho: string};

/** What /api/points/leaderboard answers (lib/pointsLeaderboard.server.ts builds and checks it). */
export type LeaderboardResponse =
  | {ok: true; enabled: false}
  | {
      ok: true;
      enabled: true;
      asOfBlock: string;
      asOfTimestamp: string;
      pendle: {enabled: false} | {enabled: true; asOfBlock: string; asOfTimestamp: number};
      morpho: {enabled: boolean; withheld: number};
      ranked: number;
      rankedPoints: string;
      truncated: boolean;
      rows: Row[];
      forestRoad: {wallets: number; points: string};
      venues: {key: string; label: string; address: `0x${string}`; note: string; points: string}[];
      notRanked: {jurisdictionBlocked: number; belowOnePoint: number};
    };

/** Rows shown at first, and added by each "Show more". */
export const LEADERBOARD_STEP = 25;
/** How soon a failed answer is asked for again (the server answers 503 while a cold instance indexes). */
export const LEADERBOARD_RETRY_MS = 60_000;

/** The server answered with a failure: each answer is a full load on it, so it is not asked again at once. */
class LeaderboardRefused extends Error {}
/** The server's 503: a cold instance is still discovering participants and will answer shortly. */
class LeaderboardCatchingUp extends LeaderboardRefused {}

const ONE_POINT = 10n ** 18n;
/** Whole points, truncated and never rounded up; a holding under one point reads "<1", not a ranked "0". */
const pts = (raw: string) => {
  const value = BigInt(raw);
  return value > 0n && value < ONE_POINT ? "<1" : fmtAmount(value, 18, 0);
};
const unit = (raw: string) => (["1", "<1"].includes(pts(raw)) ? "point" : "points");
const ptsLabel = (raw: string) => `${pts(raw)} ${unit(raw)}`;
const count = (n: number, one: string, many: string) => `${n.toLocaleString("en-US")} ${n === 1 ? one : many}`;
const utc = (seconds: number) => `${new Date(seconds * 1000).toISOString().slice(0, 16).replace("T", " ")} UTC`;
const explorer = (address: string) => (EXPLORER_BASE_URL ? `${EXPLORER_BASE_URL}/address/${address}` : null);

/** Azeret Mono's contextual alternates draw "0x" before a digit as "0×"; an address must read as typed. */
const ADDRESS_FONT = "font-mono [font-variant-ligatures:no-contextual]";

function WalletLink({wallet}: {wallet: string}) {
  const href = explorer(wallet);
  return href ? (
    <a href={href} target="_blank" rel="noreferrer" className={`${ADDRESS_FONT} text-accent underline-offset-4 hover:underline`}>
      {shortAddress(wallet)}
    </a>
  ) : (
    <span className={ADDRESS_FONT}>{shortAddress(wallet)}</span>
  );
}

/**
 * The public points leaderboard: every wallet ranked by its on-chain points plus the points Forest
 * Road computes for sUSDfr and USDfr held through Pendle and Morpho. Forest Road's own wallets and the
 * venue contracts that hold tokens for many people are reported below the table, never ranked. Hidden
 * on a testnet build, where the server answers that it is off.
 */
export function PointsLeaderboard() {
  const {address} = useAccount();
  const [shown, setShown] = useState(LEADERBOARD_STEP);
  const {data, error, isError} = useQuery({
    queryKey: ["points-leaderboard"],
    queryFn: async (): Promise<LeaderboardResponse> => {
      const response = await fetch("/api/points/leaderboard");
      if (response.status === 503) throw new LeaderboardCatchingUp("Leaderboard catching up");
      if (!response.ok) throw new LeaderboardRefused("Leaderboard unavailable");
      const body = (await response.json()) as LeaderboardResponse | {ok: false};
      if (!body.ok) throw new LeaderboardRefused("Leaderboard unavailable");
      return body;
    },
    refetchInterval: (query) => (query.state.status === "error" ? LEADERBOARD_RETRY_MS : 300_000),
    // The interval above asks a failing server again; only a request that never reached it is retried at once.
    retry: (failures, failure) => failures < 1 && !(failure instanceof LeaderboardRefused),
    refetchOnWindowFocus: false,
  });

  if (data && !data.enabled) return null;
  if (isError && !data) {
    return (
      <div className="panel p-6" role="status">
        <p className="text-[13px] leading-relaxed text-ink-muted">
          {error instanceof LeaderboardCatchingUp
            ? "The leaderboard is catching up with the chain and will appear here shortly. No ranking is shown from a partial view."
            : "The leaderboard is temporarily unavailable. No ranking is shown from a partial view."}
        </p>
      </div>
    );
  }
  if (!data) {
    return (
      <div className="panel p-6" aria-busy="true" role="status">
        <p className="text-[13px] leading-relaxed text-ink-muted">Loading the leaderboard…</p>
      </div>
    );
  }

  const me = address?.toLowerCase();
  const myIndex = me ? data.rows.findIndex((row) => row.wallet.toLowerCase() === me) : -1;
  const mine = myIndex >= 0 ? data.rows[myIndex] : undefined;
  const visible = data.rows.slice(0, shown);
  const venues = data.venues.filter((venue) => venue.points !== "0");
  const sources = ["on-chain", data.pendle.enabled ? "Pendle" : null, data.morpho.enabled ? "Morpho" : null].filter(Boolean);
  const showPendle = data.pendle.enabled;
  const showMorpho = data.morpho.enabled;
  const withheld = data.morpho.withheld;

  return (
    <div className="panel p-6">
      <div className="flex flex-wrap items-baseline justify-between gap-3">
        <h3 className="font-display text-[15px] font-semibold tracking-tight text-ink">
          {count(data.ranked, "wallet ranked", "wallets ranked")}
        </h3>
        <span className="font-mono text-[11px] text-accent">{sources.join(" · ")}</span>
      </div>
      {showPendle ? null : (
        <p className="mt-2 text-[12px] leading-relaxed text-ink-muted" data-testid="leaderboard-pendle-off">
          Pendle points are not included in this ranking right now, so wallets holding sUSDfr or USDfr through Pendle
          rank on their other points only.
        </p>
      )}

      {me ? (
        <p className="mt-3 text-[13px] leading-relaxed text-ink-muted" data-testid="leaderboard-you">
          {mine
            ? `Your wallet ranks #${mine.rank.toLocaleString("en-US")} of ${data.ranked.toLocaleString("en-US")}, with ${ptsLabel(mine.points)} in total at block ${data.asOfBlock}.`
            : data.truncated
              ? `Your wallet is not in the top ${data.rows.length.toLocaleString("en-US")}.`
              : `Your wallet has no ranked points at block ${data.asOfBlock}.`}
          {mine && myIndex >= shown ? (
            <>
              {" "}
              <button
                type="button"
                onClick={() => setShown(Math.ceil((myIndex + 1) / LEADERBOARD_STEP) * LEADERBOARD_STEP)}
                className="font-semibold text-accent underline-offset-4 hover:underline"
              >
                Show my row
              </button>
            </>
          ) : null}
        </p>
      ) : null}
      {isError ? (
        <p className="mt-2 text-[12px] leading-relaxed text-ink-faint" role="status">
          The latest refresh failed; this board still stands as of block {data.asOfBlock}.
        </p>
      ) : null}

      {data.rows.length === 0 ? (
        <p className="mt-4 text-[13px] leading-relaxed text-ink-muted">No wallet is ranked yet.</p>
      ) : (
        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-[13px]">
            <caption className="sr-only">Points leaderboard, most points first</caption>
            <thead>
              <tr className="text-left text-ink-faint">
                <th scope="col" className="py-1.5 pr-3 font-medium">Rank</th>
                <th scope="col" className="py-1.5 pr-3 font-medium">Wallet</th>
                <th scope="col" className="py-1.5 pr-3 text-right font-medium">Points</th>
                <th scope="col" className="hidden py-1.5 pr-3 text-right font-medium md:table-cell">On-chain</th>
                {showPendle ? <th scope="col" className="hidden py-1.5 pr-3 text-right font-medium md:table-cell">Pendle</th> : null}
                {showMorpho ? <th scope="col" className="hidden py-1.5 text-right font-medium md:table-cell">Morpho</th> : null}
              </tr>
            </thead>
            <tbody>
              {visible.map((row) => {
                const isMe = row.wallet.toLowerCase() === me;
                return (
                  <tr
                    key={row.wallet}
                    className={`border-t border-line ${isMe ? "bg-accent-faint" : ""}`}
                    aria-current={isMe ? "true" : undefined}
                  >
                    <td className="py-1.5 pr-3 font-mono text-ink-muted">{row.rank}</td>
                    <td className="py-1.5 pr-3">
                      <WalletLink wallet={row.wallet} />
                      {isMe ? <span className="ml-2 text-[11px] font-semibold text-accent">You</span> : null}
                    </td>
                    <td className="py-1.5 pr-3 text-right font-mono text-ink">{pts(row.points)}</td>
                    <td className="hidden py-1.5 pr-3 text-right font-mono text-ink-muted md:table-cell">{pts(row.onchain)}</td>
                    {showPendle ? (
                      <td className="hidden py-1.5 pr-3 text-right font-mono text-ink-muted md:table-cell">{pts(row.pendle)}</td>
                    ) : null}
                    {showMorpho ? (
                      <td className="hidden py-1.5 text-right font-mono text-ink-muted md:table-cell">{pts(row.morpho)}</td>
                    ) : null}
                  </tr>
                );
              })}
            </tbody>
          </table>
          {shown < data.rows.length ? (
            <button
              type="button"
              onClick={() => setShown((n) => n + LEADERBOARD_STEP)}
              className="mt-3 text-[12px] font-semibold text-accent underline-offset-4 hover:underline"
            >
              Show more
            </button>
          ) : null}
          {data.truncated ? (
            <p className="mt-2 text-[12px] text-ink-faint">
              The list holds the top {data.rows.length.toLocaleString("en-US")} of {data.ranked.toLocaleString("en-US")} ranked wallets.
            </p>
          ) : null}
        </div>
      )}

      <div className="mt-5 border-t border-line pt-3">
        <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-ink-faint">Not ranked</p>
        <ul className="mt-2 space-y-1.5 text-[12px] leading-relaxed text-ink-faint">
          {data.forestRoad.wallets > 0 ? (
            <li>
              Forest Road wallets ({data.forestRoad.wallets}):{" "}
              <span className="font-mono text-ink-muted">{pts(data.forestRoad.points)}</span> {unit(data.forestRoad.points)}
            </li>
          ) : null}
          {venues.map((venue) => (
            <li key={venue.key}>
              {venue.label} (<WalletLink wallet={venue.address} />):{" "}
              <span className="font-mono text-ink-muted">{pts(venue.points)}</span> {unit(venue.points)}
              <span className="block text-[11px]">{venue.note}</span>
            </li>
          ))}
          {data.notRanked.jurisdictionBlocked > 0 ? (
            <li>Jurisdiction-blocked wallets: {data.notRanked.jurisdictionBlocked.toLocaleString("en-US")}</li>
          ) : null}
          {data.notRanked.belowOnePoint > 0 ? (
            <li>Wallets with less than one point: {data.notRanked.belowOnePoint.toLocaleString("en-US")}</li>
          ) : null}
        </ul>
        {withheld > 0 ? (
          <p className="mt-2 text-[11.5px] leading-relaxed text-ink-faint">
            Morpho points are held back for {count(withheld, "wallet", "wallets")} until the PointsModule is reconciled
            for {withheld === 1 ? "it" : "them"}; {withheld === 1 ? "its" : "their"} other points still count.
          </p>
        ) : null}
      </div>

      <p className="mt-4 max-w-[80ch] text-[11.5px] leading-relaxed text-ink-faint">
        On-chain points are each wallet&apos;s points as the PointsModule reports them at finalized block{" "}
        <span className="text-ink-muted">{data.asOfBlock}</span> ({utc(Number(data.asOfTimestamp))}), read directly from
        the contract. Before anything is shown, the sUSDfr, USDfr and first-loss balances the PointsModule tracks for
        every wallet found must add up exactly to its own tracked totals at that block, so no current holder is missed.
        {data.morpho.enabled
          ? " Morpho points are computed by Forest Road from Morpho Blue’s events at the same block."
          : " Morpho points are not included in this answer."}
        {data.pendle.enabled
          ? ` Pendle points are computed by the Forest Road points site from the markets’ events, as of block ${data.pendle.asOfBlock} (${utc(data.pendle.asOfTimestamp)}).`
          : " Pendle points are not included in this answer."}{" "}
        Addresses the protocol exempts, such as the vault, the redemption queue and the reserves, earn no points, and
        jurisdiction-blocked wallets are not ranked. Points are not a token, and neither points nor a rank carry any
        promise of value or conversion.
      </p>
    </div>
  );
}
