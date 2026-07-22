import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { LockedState } from "./LockedState";
import type { DesktopStatus } from "../types";

vi.mock("../api/desktop", () => ({
  WEBSITE_URL: "https://rainingembers.org",
  openWebsite: vi.fn(),
  scanNow: vi.fn().mockResolvedValue(undefined),
}));

const status: DesktopStatus = {
  membership: "denied",
  vault: "ready",
  connection: "unpaired",
  watcherRunning: true,
  discoveredFiles: 1,
  guilds: [],
  queue: { pending: 0, uploading: 0, failed: 0, bytesEncrypted: 0 },
  roots: [],
};

describe("LockedState", () => {
  it("shows the required nonmember message and full guild website URL", () => {
    render(<LockedState status={status} onRefresh={vi.fn()} />);
    expect(screen.getByText(
      "EmberSync is exclusively for members of Raining Embers and Raining Embers Alts. This character is not a member of an approved Raining Embers guild, so EmberSync serves no purpose for this character.",
    )).toBeVisible();
    expect(screen.getByRole("button", { name: /https:\/\/rainingembers\.org/i })).toBeEnabled();
    expect(screen.getByText(/No game or guild data from an ineligible export/i)).toBeVisible();
  });
});
