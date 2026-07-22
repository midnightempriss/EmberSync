import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { DesktopStatus } from "../types";
import { App } from "./App";

const status: DesktopStatus = {
  membership: "no_exports",
  vault: "ready",
  connection: "unpaired",
  watcherRunning: true,
  discoveredFiles: 0,
  guilds: [],
  queue: { pending: 0, uploading: 0, failed: 0, bytesEncrypted: 0 },
  roots: [],
};

vi.mock("../hooks/useDesktopState", () => ({
  useDesktopState: () => ({
    status,
    coverage: [],
    diagnostics: [],
    loading: false,
    error: null,
    refresh: vi.fn().mockResolvedValue(undefined),
  }),
}));

vi.mock("../api/desktop", () => ({
  WEBSITE_URL: "https://rainingembers.org",
  addWowRoot: vi.fn(),
  browseForWowRoot: vi.fn().mockResolvedValue(null),
  getStartAtLogin: vi.fn().mockResolvedValue(false),
  openTrustedWebsiteUrl: vi.fn(),
  openWebsite: vi.fn(),
  pollPairing: vi.fn(),
  revokeDevice: vi.fn(),
  scanNow: vi.fn(),
  setStartAtLogin: vi.fn(),
  startPairing: vi.fn(),
  syncNow: vi.fn(),
}));

vi.mock("../api/updater", () => ({ checkForUpdate: vi.fn() }));

describe("App settings access", () => {
  afterEach(cleanup);

  it("keeps WoW location settings available before an export is discovered", () => {
    render(<App />);
    expect(screen.getByRole("heading", { name: "No eligible EmberSync data found" })).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: "Settings" }));

    expect(screen.getByRole("heading", { name: "World of Warcraft locations" })).toBeVisible();
    expect(screen.getByRole("button", { name: /browse/i })).toBeEnabled();
  });
});
