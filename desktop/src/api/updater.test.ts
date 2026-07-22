import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  runtime: true,
  check: vi.fn(),
  relaunch: vi.fn(),
}));

vi.mock("./desktop", () => ({ isDesktopRuntime: () => mocks.runtime }));
vi.mock("@tauri-apps/plugin-updater", () => ({ check: mocks.check }));
vi.mock("@tauri-apps/plugin-process", () => ({ relaunch: mocks.relaunch }));

import { checkForUpdate } from "./updater";

describe("signed desktop updates", () => {
  beforeEach(() => {
    mocks.runtime = true;
    mocks.check.mockReset();
    mocks.relaunch.mockReset();
  });

  it("does not contact the updater outside the Tauri runtime", async () => {
    mocks.runtime = false;
    await expect(checkForUpdate()).resolves.toBeNull();
    expect(mocks.check).not.toHaveBeenCalled();
  });

  it("reports download progress and relaunches after installation", async () => {
    const close = vi.fn();
    const downloadAndInstall = vi.fn(async (onEvent: (event: unknown) => void) => {
      onEvent({ event: "Started", data: { contentLength: 100 } });
      onEvent({ event: "Progress", data: { chunkLength: 40 } });
      onEvent({ event: "Progress", data: { chunkLength: 60 } });
      onEvent({ event: "Finished" });
    });
    mocks.check.mockResolvedValue({
      currentVersion: "0.1.0",
      version: "0.2.0",
      body: "Signed release",
      close,
      downloadAndInstall,
    });

    const update = await checkForUpdate();
    expect(update).toMatchObject({ currentVersion: "0.1.0", version: "0.2.0", notes: "Signed release" });
    const progress: Array<[number, number | undefined]> = [];
    await update?.install((downloaded, total) => progress.push([downloaded, total]));

    expect(progress).toEqual([[0, 100], [40, 100], [100, 100], [100, 100]]);
    expect(mocks.relaunch).toHaveBeenCalledOnce();
    await update?.close();
    expect(close).toHaveBeenCalledOnce();
  });
});
