"use client";

/**
 * A contract-event watcher that recovers instead of failing silently forever.
 *
 * Over HTTP, viem's watcher polls eth_getLogs from the block after its last successful read to the
 * tip, and only moves that cursor forward after a read succeeds. After a long sleep (a laptop lid
 * closed for two weeks), that range is wider than the RPC proxy's 100,000-block eth_getLogs limit,
 * so every poll is refused, the range only grows, and the watcher never recovers. Any persistent
 * read error does the same.
 *
 * So on an error this restarts the watcher from the current block: once per `restartDelayMs` at most
 * (no tight loop), and never silently, since each restart is logged under a fixed label with the
 * error's class (never its message, which can carry an RPC URL). Nothing is lost that matters: the
 * card's own reads poll on their own interval, and the watcher only makes them refresh sooner.
 */

import {useCallback, useEffect, useRef, useState} from "react";
import type {Abi, Address, Log} from "viem";
import {useWatchContractEvent} from "wagmi";

type WatcherProps = {
  address: Address | undefined;
  abi: Abi;
  pollingInterval: number;
  onLogs: (logs: Log[]) => void;
};

function Watcher({onError, ...props}: WatcherProps & {onError: (error: Error) => void}) {
  useWatchContractEvent({...props, onError});
  return null;
}

export function RestartingEventWatcher({
  label,
  restartDelayMs,
  ...props
}: WatcherProps & {
  /** Fixed log label for this watcher, for example "redeem.queue_watcher". */
  label: string;
  /** The least time between restarts; defaults to the polling interval. */
  restartDelayMs?: number;
}) {
  const [generation, setGeneration] = useState(0);
  const pending = useRef<ReturnType<typeof setTimeout> | null>(null);
  const delay = restartDelayMs ?? props.pollingInterval;

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

  return <Watcher key={generation} {...props} onError={onError} />;
}
