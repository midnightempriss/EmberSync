import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { DesktopStatus } from "../../types";
import { QueueScreen } from "./QueueScreen";

const desktopMocks = vi.hoisted(() => ({
  openTrustedWebsiteUrl: vi.fn(),
  syncNow: vi.fn(),
  unlockWithPassphrase: vi.fn(),
}));

vi.mock("../../api/desktop", () => desktopMocks);

const status: DesktopStatus = {
  membership: "authorized",
  vault: "ready",
  connection: "paired",
  watcherRunning: true,
  discoveredFiles: 1,
  guilds: [],
  queue: {
    pending: 0,
    uploading: 0,
    failed: 0,
    actionRequired: 53,
    authorizationRequired: true,
    bytesEncrypted: 128,
  },
  roots: [],
};

describe("QueueScreen authorization and vault status", () => {
  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("separates Battle.net action from retry and shows that encryption is active", () => {
    render(<QueueScreen status={status} onRefresh={vi.fn()} />);

    expect(screen.getByText("Needs attention").nextElementSibling).toHaveTextContent("53");
    expect(screen.getByText("Battle.net verification is required")).toBeVisible();
    expect(screen.getByText("Local payload encryption is active")).toBeVisible();
    expect(screen.queryByText("Unlock a passphrase vault")).not.toBeInTheDocument();
  });

  it("opens only the trusted Battle.net reauthorization route", () => {
    render(<QueueScreen status={status} onRefresh={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: /reverify with battle\.net/i }));

    expect(desktopMocks.openTrustedWebsiteUrl).toHaveBeenCalledWith(
      "https://rainingembers.org/api/auth/battlenet/start?return_to=%2Fmembers%3Fview%3Dsettings",
    );
  });
});
