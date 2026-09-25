import {
  calculateHistoricalNetDefaultMetrics,
  type HistoricalNetDefaultMetrics,
} from "@/lib/book";

type OriginatedArgs = {tokenId?: bigint; classId?: bigint};
type FundedArgs = {tokenId?: bigint; principal?: bigint};
type LossArgs = {classId?: bigint; loss?: bigint};
type FeeArgs = {fee?: bigint};
type VaultFeeArgs = {feeAssets?: bigint};

export interface TransparencyHistory {
  asOfBlock: bigint;
  revenue: {
    originationFees: bigint;
    interestFees: bigint;
    performanceFees: bigint;
    managementFees: bigint;
  };
  credit: HistoricalNetDefaultMetrics;
}

export interface TransparencyHistoryWire {
  ok: true;
  asOfBlock: string;
  revenue: {
    originationFees: string;
    interestFees: string;
    performanceFees: string;
    managementFees: string;
  };
  credit: {
    fundedPrincipal: string;
    netLoss: string;
    rateBps: string | null;
    byClass: Array<{
      classId: number;
      fundedPrincipal: string;
      netLoss: string;
      rateBps: string | null;
    }>;
  };
}

function required(value: bigint | undefined, field: string): bigint {
  if (value === undefined) throw new Error(`incomplete ${field} event`);
  return value;
}

function sumFees(events: readonly FeeArgs[], field: string): bigint {
  return events.reduce((sum, event) => sum + required(event.fee, field), 0n);
}

function sumVaultFees(events: readonly VaultFeeArgs[], field: string): bigint {
  return events.reduce((sum, event) => sum + required(event.feeAssets, field), 0n);
}

export function summarizeTransparencyHistory(input: {
  asOfBlock: bigint;
  classIds: readonly number[];
  originated: readonly OriginatedArgs[];
  funded: readonly FundedArgs[];
  losses: readonly LossArgs[];
  originationFees: readonly FeeArgs[];
  distributions: readonly FeeArgs[];
  performanceFees: readonly VaultFeeArgs[];
  managementFees: readonly VaultFeeArgs[];
}): TransparencyHistory {
  const classByToken = new Map<bigint, number>();
  for (const event of input.originated) {
    const tokenId = required(event.tokenId, "Originated");
    const classId = Number(required(event.classId, "Originated"));
    classByToken.set(tokenId, classId);
  }

  const funded = input.funded.map((event) => {
    const tokenId = required(event.tokenId, "Funded");
    const principal = required(event.principal, "Funded");
    const classId = classByToken.get(tokenId);
    if (classId === undefined) throw new Error(`missing origination for funded facility ${tokenId}`);
    return {classId, principal};
  });
  const losses = input.losses.map((event) => ({
    classId: Number(required(event.classId, "LossRealized")),
    loss: required(event.loss, "LossRealized"),
  }));

  return {
    asOfBlock: input.asOfBlock,
    revenue: {
      originationFees: sumFees(input.originationFees, "OriginationFeeCharged"),
      interestFees: sumFees(input.distributions, "Distributed"),
      performanceFees: sumVaultFees(input.performanceFees, "PerformanceFeeAccrued"),
      managementFees: sumVaultFees(input.managementFees, "ManagementFeeAccrued"),
    },
    credit: calculateHistoricalNetDefaultMetrics(funded, losses, input.classIds),
  };
}

export function serializeTransparencyHistory(history: TransparencyHistory): TransparencyHistoryWire {
  return {
    ok: true,
    asOfBlock: history.asOfBlock.toString(),
    revenue: {
      originationFees: history.revenue.originationFees.toString(),
      interestFees: history.revenue.interestFees.toString(),
      performanceFees: history.revenue.performanceFees.toString(),
      managementFees: history.revenue.managementFees.toString(),
    },
    credit: {
      fundedPrincipal: history.credit.fundedPrincipal.toString(),
      netLoss: history.credit.netLoss.toString(),
      rateBps: history.credit.rateBps?.toString() ?? null,
      byClass: [...history.credit.byClass.entries()].map(([classId, metrics]) => ({
        classId,
        fundedPrincipal: metrics.fundedPrincipal.toString(),
        netLoss: metrics.netLoss.toString(),
        rateBps: metrics.rateBps?.toString() ?? null,
      })),
    },
  };
}

function record(value: unknown, field: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function decimal(value: unknown, field: string): bigint {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${field} must be an unsigned decimal string`);
  }
  return BigInt(value);
}

function nullableDecimal(value: unknown, field: string): bigint | null {
  return value === null ? null : decimal(value, field);
}

export function parseTransparencyHistoryResponse(value: unknown): TransparencyHistory {
  const root = record(value, "history response");
  if (root.ok !== true) throw new Error("history response was not successful");
  const revenue = record(root.revenue, "revenue");
  const credit = record(root.credit, "credit");
  if (!Array.isArray(credit.byClass)) throw new Error("credit.byClass must be an array");
  const byClass = new Map<number, {fundedPrincipal: bigint; netLoss: bigint; rateBps: bigint | null}>();
  for (const rawSlice of credit.byClass) {
    const slice = record(rawSlice, "credit class");
    if (!Number.isSafeInteger(slice.classId) || Number(slice.classId) <= 0) {
      throw new Error("credit classId must be a positive integer");
    }
    const classId = Number(slice.classId);
    if (byClass.has(classId)) throw new Error(`duplicate credit class ${classId}`);
    byClass.set(classId, {
      fundedPrincipal: decimal(slice.fundedPrincipal, "credit class fundedPrincipal"),
      netLoss: decimal(slice.netLoss, "credit class netLoss"),
      rateBps: nullableDecimal(slice.rateBps, "credit class rateBps"),
    });
  }
  return {
    asOfBlock: decimal(root.asOfBlock, "asOfBlock"),
    revenue: {
      originationFees: decimal(revenue.originationFees, "originationFees"),
      interestFees: decimal(revenue.interestFees, "interestFees"),
      performanceFees: decimal(revenue.performanceFees, "performanceFees"),
      managementFees: decimal(revenue.managementFees, "managementFees"),
    },
    credit: {
      fundedPrincipal: decimal(credit.fundedPrincipal, "fundedPrincipal"),
      netLoss: decimal(credit.netLoss, "netLoss"),
      rateBps: nullableDecimal(credit.rateBps, "rateBps"),
      byClass,
    },
  };
}
