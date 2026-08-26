import { beforeEach, describe, expect, it, vi } from "vitest";

const { requestMock } = vi.hoisted(() => ({ requestMock: vi.fn() }));

vi.mock("../web/src/lib/panelSession.ts", () => ({
  getPanelSession: () => ({ instanceId: "instance-1", userKey: "sk-user" }),
}));

vi.mock("../web/src/lib/api/base.ts", () => ({
  request: requestMock,
  ApiError: class ApiError extends Error {},
}));

import { chatMemoryApi } from "../web/src/lib/api/chat-memory.ts";

describe("chatMemoryApi.deleteLayerItem", () => {
  beforeEach(() => {
    requestMock.mockReset();
    requestMock.mockResolvedValue({
      code: 0,
      message: "ok",
      request_id: "request-1",
      data: { deleted_count: 1 },
    });
  });

  it.each([
    ["L0", "msg-1", { message_ids: ["msg-1"] }],
    ["L1", "atomic-1", { ids: ["atomic-1"] }],
    ["L2", "reports/monthly.md", { path: "reports/monthly.md" }],
  ] as const)(
    "maps %s item deletion to the existing layer-delete contract",
    async (layer, itemId, target) => {
      await chatMemoryApi.deleteLayerItem(
        "chat_memory-team-1-agt-1",
        layer,
        itemId,
      );

      expect(requestMock).toHaveBeenCalledWith(
        "POST",
        "/api/v1/chat-memory/layer-delete",
        {
          block_id: "chat_memory-team-1-agt-1",
          layer,
          ...target,
        },
        {
          "X-Tdai-Service-Id": "instance-1",
          "X-Tdai-User-Key": "sk-user",
        },
      );
    },
  );
});
