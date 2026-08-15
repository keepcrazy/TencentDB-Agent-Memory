import { describe, expect, it } from "vitest";

import { createRequestSchema } from "./skill-schemas.js";

function createResources(count: number) {
  return Array.from({ length: count }, (_, index) => ({
    path: `references/resource-${index}.md`,
    content: `resource ${index}`,
    encoding: "utf-8" as const,
  }));
}

describe("createRequestSchema", () => {
  it("accepts a skill package with 175 resource files", () => {
    const result = createRequestSchema.safeParse({
      name: "ask-five-pro",
      content: "---\nname: ask-five-pro\n---\n",
      resources: createResources(175),
    });

    expect(result.success).toBe(true);
  });

  it("rejects a skill package with more than 256 resource files", () => {
    const result = createRequestSchema.safeParse({
      name: "too-many-resources",
      content: "---\nname: too-many-resources\n---\n",
      resources: createResources(257),
    });

    expect(result.success).toBe(false);
  });
});
