import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DesktopStatus } from "../../types";
import { SettingsScreen } from "./SettingsScreen";

const desktopMocks = vi.hoisted(() => ({
  addWowRoot: vi.fn(),
  browseForWowRoot: vi.fn(),
  getStartAtLogin: vi.fn().mockResolvedValue(false),
  openTrustedWebsiteUrl: vi.fn(),
  pollPairing: vi.fn(),
  revokeDevice: vi.fn(),
  setStartAtLogin: vi.fn(),
  startPairing: vi.fn(),
}));

vi.mock("../../api/desktop", () => desktopMocks);
vi.mock("../../api/updater", () => ({ checkForUpdate: vi.fn() }));

const status: DesktopStatus = {
  membership: "authorized",
  vault: "ready",
  connection: "unpaired",
  watcherRunning: true,
  discoveredFiles: 0,
  guilds: [],
  queue: { pending: 0, uploading: 0, failed: 0, bytesEncrypted: 0 },
  roots: ["G:\\Battle.net\\World of Warcraft\\_retail_\\WTF"],
};

describe("SettingsScreen World of Warcraft location browser", () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
    desktopMocks.getStartAtLogin.mockResolvedValue(false);
    desktopMocks.addWowRoot.mockResolvedValue({ ...status, discoveredFiles: 2 });
  });

  it("saves a browsed folder and refreshes discovery", async () => {
    const onRefresh = vi.fn();
    const selected = "G:\\Battle.net\\World of Warcraft\\_retail_\\Interface\\AddOns\\EmberSync";
    desktopMocks.browseForWowRoot.mockResolvedValue(selected);

    render(<SettingsScreen status={status} onRefresh={onRefresh} />);
    fireEvent.click(screen.getByRole("button", { name: /browse/i }));

    await waitFor(() => expect(desktopMocks.browseForWowRoot).toHaveBeenCalledWith(status.roots[0]));
    await waitFor(() => expect(desktopMocks.addWowRoot).toHaveBeenCalledWith(selected));
    expect(onRefresh).toHaveBeenCalledOnce();
    expect(screen.getByRole("status")).toHaveTextContent("Location saved. Found 2 EmberSync SavedVariables files.");
  });

  it("does not change configured locations when the browser is cancelled", async () => {
    desktopMocks.browseForWowRoot.mockResolvedValue(null);

    render(<SettingsScreen status={status} onRefresh={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: /browse/i }));

    await waitFor(() => expect(desktopMocks.browseForWowRoot).toHaveBeenCalledOnce());
    expect(desktopMocks.addWowRoot).not.toHaveBeenCalled();
  });
});
