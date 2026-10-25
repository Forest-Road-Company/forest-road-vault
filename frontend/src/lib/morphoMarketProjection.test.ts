import {describe, expect, it, vi, afterEach} from "vitest";
import {assertMarketQuoteCurrent, isMarketQuoteCurrent} from "./morphoMarketProjection";

const issuedAt = 1_792_500_000_123;
const quote = {issuedAt, expiresAt: issuedAt + 300_000};
afterEach(() => vi.restoreAllMocks());

describe("explicit issued-quote expiry", () => {
  it.each([issuedAt, quote.expiresAt - 1])("accepts a live quote at %s", now => {
    expect(isMarketQuoteCurrent(quote, now)).toBe(true);
    expect(() => assertMarketQuoteCurrent(quote, now)).not.toThrow();
  });
  it.each([issuedAt - 1, quote.expiresAt, quote.expiresAt + 1, NaN, Infinity, 0.5])("rejects an expired or unverifiable clock at %s", now => {
    expect(isMarketQuoteCurrent(quote, now)).toBe(false);
    expect(() => assertMarketQuoteCurrent(quote, now)).toThrow(/Quote expired/);
  });
  it.each([
    {issuedAt: NaN, expiresAt: quote.expiresAt},
    {issuedAt, expiresAt: Infinity},
    {issuedAt: -1, expiresAt: 299_999},
    {issuedAt, expiresAt: quote.expiresAt - 1},
    {issuedAt, expiresAt: quote.expiresAt + 1},
    {issuedAt: undefined, expiresAt: quote.expiresAt},
  ])("fails closed for malformed timing %j", timing => {
    expect(isMarketQuoteCurrent(timing as typeof quote, issuedAt)).toBe(false);
  });
  it("uses the exact current clock when the handoff guard omits an override", () => {
    vi.spyOn(Date, "now").mockReturnValue(quote.expiresAt - 1);
    expect(isMarketQuoteCurrent(quote)).toBe(true);
    expect(() => assertMarketQuoteCurrent(quote)).not.toThrow();
    vi.mocked(Date.now).mockReturnValue(quote.expiresAt);
    expect(() => assertMarketQuoteCurrent(quote)).toThrow(/Refresh and review/);
  });
});
