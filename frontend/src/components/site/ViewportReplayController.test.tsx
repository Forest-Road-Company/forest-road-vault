import { act, cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ViewportReplayController } from "./ViewportReplayController";

let intersectionCallback: IntersectionObserverCallback;
const observerState: { current?: MockIntersectionObserver } = {};

class MockIntersectionObserver implements IntersectionObserver {
  readonly root = null;
  readonly rootMargin = "-8% 0px -8% 0px";
  readonly thresholds = [0];
  observe = vi.fn();
  unobserve = vi.fn();
  disconnect = vi.fn();
  takeRecords = vi.fn(() => []);

  constructor(callback: IntersectionObserverCallback) {
    intersectionCallback = callback;
    observerState.current = this;
  }
}

const mediaQuery = (matches: boolean): MediaQueryList =>
  ({
    matches,
    media: "(prefers-reduced-motion: reduce)",
    onchange: null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn(),
  }) as unknown as MediaQueryList;

const intersect = (target: Element, isIntersecting: boolean) => {
  act(() => {
    intersectionCallback(
      [{ target, isIntersecting } as IntersectionObserverEntry],
      observerState.current!,
    );
  });
};

beforeEach(() => {
  vi.stubGlobal("IntersectionObserver", MockIntersectionObserver);
  vi.stubGlobal("matchMedia", vi.fn(() => mediaQuery(false)));
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe("ViewportReplayController", () => {
  it("resets on exit, replays on re-entry, and survives a React className rewrite", async () => {
    const view = render(
      <>
        <ViewportReplayController />
        <div data-testid="target" data-viewport-replay="" className="loading" />
      </>,
    );
    const target = view.getByTestId("target");

    await waitFor(() => expect(target).toHaveAttribute("data-viewport-observed"));
    expect(target).not.toHaveAttribute("data-viewport-visible");
    expect(observerState.current?.observe).toHaveBeenCalledWith(target);

    intersect(target, true);
    expect(target).toHaveAttribute("data-viewport-visible");

    // Data-driven components commonly reuse their loading element. React
    // rewrites className here, but must not erase the observer's own state.
    view.rerender(
      <>
        <ViewportReplayController />
        <div data-testid="target" data-viewport-replay="" className="complete" />
      </>,
    );
    expect(target).toHaveClass("complete");
    expect(target).toHaveAttribute("data-viewport-observed");
    expect(target).toHaveAttribute("data-viewport-visible");

    intersect(target, false);
    expect(target).not.toHaveAttribute("data-viewport-visible");
    intersect(target, true);
    expect(target).toHaveAttribute("data-viewport-visible");
  });

  it("discovers a target mounted after the controller", async () => {
    const view = render(<ViewportReplayController />);
    view.rerender(
      <>
        <ViewportReplayController />
        <div data-testid="late-target" data-viewport-replay="" />
      </>,
    );

    const target = view.getByTestId("late-target");
    await waitFor(() => expect(target).toHaveAttribute("data-viewport-observed"));
    expect(observerState.current?.observe).toHaveBeenCalledWith(target);
  });

  it("resolves immediately to the settled state for reduced motion", async () => {
    vi.stubGlobal("matchMedia", vi.fn(() => mediaQuery(true)));
    const view = render(
      <>
        <ViewportReplayController />
        <div data-testid="target" data-viewport-replay="" />
      </>,
    );
    const target = view.getByTestId("target");

    await waitFor(() => expect(target).toHaveAttribute("data-viewport-observed"));
    expect(target).toHaveAttribute("data-viewport-visible");
    expect(observerState.current?.observe).not.toHaveBeenCalled();
  });
});
