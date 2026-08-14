import { Hono } from "hono";
import { describe, expect, it, vi } from "vitest";
import { InstanceRegistry } from "../src/panel/config/instance-registry.js";
import { registerChatMemoryRoutes } from "../src/panel/http/routes/chat-memory.js";
import type { PanelDeps } from "../src/panel/panel-deps.js";

const BLOCK_ID = "chat_memory-team-1-agt-1";
const HEADERS = {
  "content-type": "application/json",
  "x-tdai-service-id": "instance-1",
  "x-tdai-user-key": "sk-user",
};

interface TestHarness {
  app: Hono;
  kernelPost: ReturnType<typeof vi.fn>;
}

function createHarness(
  options: { ownerUserId?: string; callerUserId?: string } = {},
): TestHarness {
  const ownerUserId = options.ownerUserId ?? "user-owner";
  const callerUserId = options.callerUserId ?? ownerUserId;
  const kernelPost = vi.fn(async () => ({
    code: 0,
    message: "ok",
    request_id: "core-request",
    data: { deleted_count: 1 },
  }));
  const metaInvoke = vi.fn(async (action: string) => {
    if (action === "auth/verify") {
      return {
        code: 0,
        message: "ok",
        request_id: "auth-request",
        data: { valid: true, user: { user_id: callerUserId } },
      };
    }
    if (action === "asset/get") {
      return {
        code: 0,
        message: "ok",
        request_id: "asset-request",
        data: {
          asset_id: BLOCK_ID,
          team_id: "team-1",
          asset_type: "chat_memory",
          name: "Agent memory",
          owner_user_id: ownerUserId,
          visibility: "team",
          status: "active",
          updated_at: "2026-08-14T00:00:00.000Z",
        },
      };
    }
    throw new Error(`unexpected meta action: ${action}`);
  });
  const logger = {
    debug: vi.fn(),
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    child: vi.fn(),
  };
  logger.child.mockReturnValue(logger);

  const deps = {
    config: { ui: { distDir: "." } },
    logger,
    instanceRegistry: new InstanceRegistry([
      {
        instance_id: "instance-1",
        name: "Test",
        gateway_endpoint: "https://memory.example.test",
        api_key: "gateway-key",
      },
    ]),
    kernelHttp: { postEnvelope: kernelPost },
    metaKernel: { invoke: metaInvoke },
    knowledgeClientFactory: vi.fn(),
    skillKernel: { invoke: vi.fn() },
    knowledgeTaskRegistry: {},
    ingestProgressStore: {},
  } as unknown as PanelDeps;

  const app = new Hono();
  registerChatMemoryRoutes(app, deps);
  return { app, kernelPost };
}

async function postDelete(app: Hono, body: Record<string, unknown>) {
  return app.request("/chat-memory/layer-delete", {
    method: "POST",
    headers: HEADERS,
    body: JSON.stringify(body),
  });
}

describe("POST /chat-memory/layer-delete", () => {
  it("forwards owner L0 message ids without a synthetic session filter", async () => {
    const { app, kernelPost } = createHarness();

    const response = await postDelete(app, {
      block_id: BLOCK_ID,
      layer: "L0",
      message_ids: ["msg-1"],
    });

    expect(response.status).toBe(200);
    expect(kernelPost).toHaveBeenCalledWith(
      "/v3/conversation/delete",
      {
        team_id: "team-1",
        agent_id: "agt-1",
        user_id: "user-owner",
        message_ids: ["msg-1"],
      },
      expect.objectContaining({ instanceId: "instance-1", userKey: "sk-user" }),
    );
  });

  it("forwards owner L1 ids to atomic delete", async () => {
    const { app, kernelPost } = createHarness();

    const response = await postDelete(app, {
      block_id: BLOCK_ID,
      layer: "L1",
      ids: ["atomic-1"],
    });

    expect(response.status).toBe(200);
    expect(kernelPost).toHaveBeenCalledWith(
      "/v3/atomic/delete",
      {
        team_id: "team-1",
        agent_id: "agt-1",
        user_id: "user-owner",
        session_id: "default",
        ids: ["atomic-1"],
      },
      expect.objectContaining({ instanceId: "instance-1", userKey: "sk-user" }),
    );
  });

  it("forwards an owner L2 path to scenario removal", async () => {
    const { app, kernelPost } = createHarness();

    const response = await postDelete(app, {
      block_id: BLOCK_ID,
      layer: "L2",
      path: "reports/monthly.md",
    });

    expect(response.status).toBe(200);
    expect(kernelPost).toHaveBeenCalledWith(
      "/v3/scenario/rm",
      {
        team_id: "team-1",
        agent_id: "agt-1",
        user_id: "user-owner",
        session_id: "default",
        path: "reports/monthly.md",
      },
      expect.objectContaining({ instanceId: "instance-1", userKey: "sk-user" }),
    );
  });

  it("rejects an empty L2 path before calling Memory Core", async () => {
    const { app, kernelPost } = createHarness();

    const response = await postDelete(app, {
      block_id: BLOCK_ID,
      layer: "L2",
      path: "   ",
    });
    const envelope = (await response.json()) as {
      code: number;
      message: string;
    };

    expect(response.status).toBe(400);
    expect(envelope).toMatchObject({ code: 400, message: "MISSING_PATH" });
    expect(kernelPost).not.toHaveBeenCalled();
  });

  it("rejects L2 deletion by a shared reader who does not own the asset", async () => {
    const { app, kernelPost } = createHarness({ callerUserId: "user-reader" });

    const response = await postDelete(app, {
      block_id: BLOCK_ID,
      layer: "L2",
      path: "reports/monthly.md",
    });
    const envelope = (await response.json()) as {
      code: number;
      message: string;
    };

    expect(response.status).toBe(403);
    expect(envelope).toMatchObject({ code: 403, message: "NOT_ASSET_OWNER" });
    expect(kernelPost).not.toHaveBeenCalled();
  });
});
