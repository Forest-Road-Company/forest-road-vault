import {cleanup, renderHook, waitFor} from "@testing-library/react";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {useMorphoSafe} from "./useMorphoSafe";

const h = vi.hoisted(() => ({SDK: vi.fn(), info: vi.fn()}));
vi.mock("@safe-global/safe-apps-sdk", () => ({default: h.SDK}));
const info = {safeAddress: "0x1111111111111111111111111111111111111111", chainId: 1, threshold: 1,
  owners: ["0x2222222222222222222222222222222222222222"], isReadOnly: false};
beforeEach(() => {
  h.SDK.mockReset();h.info.mockReset();h.info.mockResolvedValue(info);
  h.SDK.mockImplementation(function () {return {safe: {getInfo: h.info}};});
  vi.stubGlobal("parent", {});
});
afterEach(() => {cleanup();vi.unstubAllGlobals();});

describe("Safe app origin and identity", () => {
  it("accepts only the exact canonical HTTPS parent origin", async () => {
    const {result} = renderHook(useMorphoSafe);await waitFor(() => expect(result.current.context?.address).toBe(info.safeAddress));
    const options = h.SDK.mock.calls[0][0];expect(options.debug).toBe(false);expect(options.allowedDomains).toHaveLength(1);
    const origin = options.allowedDomains[0] as RegExp;expect(origin.test("https://app.safe.global")).toBe(true);
    for (const untrusted of ["http://app.safe.global", "https://app.safe.global.evil", "https://evil.app.safe.global", "https://app.safe.global:444", "https://example.com"]) {
      expect(origin.test(untrusted)).toBe(false);
    }
    expect(result.current.context).toMatchObject({threshold: 1, owners: info.owners, chainId: 1});
  });
  it("does not initialise the SDK outside an iframe", async () => {
    vi.stubGlobal("parent", window);const {result} = renderHook(useMorphoSafe);
    expect(result.current.context).toBeNull();expect(h.SDK).not.toHaveBeenCalled();
  });
  it.each([
    {chainId: 5}, {safeAddress: "invalid"}, {threshold: 0}, {threshold: 2}, {threshold: 1.5},
    {owners: undefined}, {owners: ["invalid"]},
  ])("rejects unverifiable Safe information %j", async changed => {
    h.info.mockResolvedValue({...info, ...changed});const {result} = renderHook(useMorphoSafe);
    await waitFor(() => expect(result.current.error).toMatch(/Connect an Ethereum Safe/));expect(result.current.context).toBeNull();
  });
  it("fails closed when the host cannot return Safe information", async () => {
    h.info.mockRejectedValue(new Error("host unavailable"));const {result} = renderHook(useMorphoSafe);
    await waitFor(() => expect(result.current.error).toMatch(/Connect an Ethereum Safe/));expect(result.current.context).toBeNull();
  });
});
