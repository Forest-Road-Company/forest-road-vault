import {cleanup, render, screen, waitFor} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {renderToString} from "react-dom/server";
import {afterEach, describe, expect, it, vi} from "vitest";

import {CuratorInterestForm} from "./CuratorInterestForm";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("curator interest form hydration guard", () => {
  it("renders its submit button disabled before client handlers exist", () => {
    const html = renderToString(<CuratorInterestForm />);
    expect(html).toMatch(/<button[^>]+type="submit"[^>]+disabled=""/);
  });

  it("enables after hydration and surfaces a rejected request without navigating", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: false,
      json: async () => ({ok: false, error: "An email address is required."}),
    });
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();
    render(<CuratorInterestForm />);

    const submit = screen.getByRole("button", {name: "Register interest"});
    await waitFor(() => expect(submit).toBeEnabled());
    await user.click(submit);

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/curators/interest",
      expect.objectContaining({method: "POST"}),
    );
    expect(await screen.findByRole("alert")).toHaveTextContent("An email address is required.");
  });
});
