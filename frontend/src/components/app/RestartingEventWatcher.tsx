"use client";

/**
 * A contract-event watcher that polls `eth_blockNumber` + `eth_getLogs` directly over HTTP and
 * recovers instead of failing silently forever.
 *
 * Unlike wagmi's `useWatchContractEvent`, this never probes `eth_newFilter` (which `/api/rpc`
 * deliberately refuses with -32601) and starts polling logs on the first interval rather than
 * wasting two polling intervals on filter fallback. After a long sleep (a laptop lid closed for
 * two weeks), the catch-up range can exceed the RPC proxy's 100,000-block `eth_getLogs` limit; on
 * any read error this restarts from the current block once per `restartDelayMs` at most (no tight
 * loop), logging a fixed label with the error's class (never its message, which can carry an RPC
 * URL). Nothing is lost that matters: the card's own reads poll on their own interval, and the
 * watcher only makes them refresh sooner.
 */

import {useCallback, useEffect, useRef, useState} from "react";
import type {Abi, Address, Log} from "viem";
import {usePublicClient} from "wagmi";

type WatcherProps = {
  address: Address | undefined;
  abi: Abi;
  pollingInterval: number;
  onLogs: (logs: Log[]) => void;
};

export function RestartingEventWatcher({
  label,
  restartDelayMs,
  address,
  abi,
  pollingInterval,
  onLogs,
}: WatcherProps & {
  /** Fixed log label for this watcher, for example "redeem.queue_watcher". */
  label: string;
  /** The least time between restarts; defaults to the polling interval. */
  restartDelayMs?: number;
}) {
  const publicClient = usePublicClient();
  const [generation, setGeneration] = useState(0);
  const pending = useRef<ReturnType<typeof setTimeout> | null>(null);
  const onLogsRef = useRef(onLogs);
  const delay = restartDelayMs ?? pollingInterval;

  useEffect(() => {
    onLogsRef.current = onLogs;
  }, [onLogs]);

  useEffect(
    () => () => {
      if (pending.current) clearTimeout(pending.current);
    },
    [],
  );

  const onError = useCallback(
    (error: Error) => {
      if (pending.current) return;
      console.warn(`${label}_restart ${error.name}`);
      pending.current = setTimeout(() => {
        pending.current = null;
        setGeneration((current) => current + 1);
      }, delay);
    },
    [delay, label],
  );

  useEffect(() => {
    if (!publicClient || !address) return;
    let cancelled = false;
    let inFlight = false;
    let previousBlockNumber: bigint | null = null;

    const tick = async () => {
      if (cancelled || inFlight) return;
      inFlight = true;
      try {
        const blockNumber = await publicClient.getBlockNumber();
        if (cancelled) return;
        if (previousBlockNumber === null) {
          previousBlockNumber = blockNumber;
          return;
        }
        if (blockNumber <= previousBlockNumber) return;
        const logs = await publicClient.getContractEvents({
          address,
          abi,
          fromBlock: previousBlockNumber + 1n,
          toBlock: blockNumber,
        });
        if (cancelled) return;
        previousBlockNumber = blockNumber;
        if (logs.length > 0) onLogsRef.current(logs as Log[]);
      } catch (err) {
        if (cancelled) return;
        onError(err instanceof Error ? err : new Error(String(err)));
      } finally {
        inFlight = false;
      }
    };

    void tick();
    const interval = setInterval(() => void tick(), pollingInterval);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [publicClient, address, abi, pollingInterval, onError, generation]);

  return null;
}
