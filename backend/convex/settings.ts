import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { requireUser } from "./lib";

export const get = query({
  args: { token: v.string() },
  handler: async (ctx, { token }) => {
    const { user } = await requireUser(ctx, token);
    const row = await ctx.db.query("userSettings").withIndex("by_user", (q) => q.eq("userId", user._id)).first();
    return row ? { settings: row.settings, updatedAt: row.updatedAt } : null;
  },
});

export const set = mutation({
  args: { token: v.string(), settings: v.any() },
  handler: async (ctx, { token, settings }) => {
    const { user } = await requireUser(ctx, token);
    const row = await ctx.db.query("userSettings").withIndex("by_user", (q) => q.eq("userId", user._id)).first();
    const now = Date.now();
    if (row) await ctx.db.patch(row._id, { settings, updatedAt: now });
    else await ctx.db.insert("userSettings", { userId: user._id, settings, updatedAt: now });
    return now;
  },
});

export const backupSidebar = mutation({
  args: { token: v.string(), device: v.string(), document: v.any(), tabCount: v.number() },
  handler: async (ctx, { token, device, document, tabCount }) => {
    const { user } = await requireUser(ctx, token);
    const row = await ctx.db
      .query("sidebarBackups")
      .withIndex("by_user_device", (q) => q.eq("userId", user._id).eq("device", device))
      .first();
    const now = Date.now();
    if (row) await ctx.db.patch(row._id, { document, tabCount, updatedAt: now });
    else await ctx.db.insert("sidebarBackups", { userId: user._id, device, document, tabCount, updatedAt: now });
    return now;
  },
});

export const listBackups = query({
  args: { token: v.string() },
  handler: async (ctx, { token }) => {
    const { user } = await requireUser(ctx, token);
    const rows = await ctx.db.query("sidebarBackups").withIndex("by_user_device", (q) => q.eq("userId", user._id)).collect();
    return rows.map((r) => ({ device: r.device, tabCount: r.tabCount, updatedAt: r.updatedAt }));
  },
});

export const getBackup = query({
  args: { token: v.string(), device: v.string() },
  handler: async (ctx, { token, device }) => {
    const { user } = await requireUser(ctx, token);
    const row = await ctx.db
      .query("sidebarBackups")
      .withIndex("by_user_device", (q) => q.eq("userId", user._id).eq("device", device))
      .first();
    return row ? { document: row.document, updatedAt: row.updatedAt } : null;
  },
});
